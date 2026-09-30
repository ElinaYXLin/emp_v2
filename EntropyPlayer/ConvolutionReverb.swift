import Foundation
import Accelerate

// AUReverb2 (Apple's algorithmic comb/allpass reverb) has a fundamentally
// different decay-length-vs-loudness relationship than the web edition's
// actual reverb: a real convolution with a randomly generated, exponentially
// decaying white-noise impulse response (see buildIR()/applyReverb() in the
// web app). No parameter tuning bridges that gap — the two algorithms scale
// differently as decay time changes, which is why the macOS app sounded
// boomy/quiet/reverberant at different macro points than the web app instead
// of scaling the same way. This runs the literal same algorithm.
//
// The IR is capped at 2 seconds (88,200 samples at 44.1kHz) rather than the
// web app's 10-second hard cap; nearly all audible reverb character lives in
// the first couple of seconds of decay regardless.
//
// The convolution runs as partitioned FFT convolution (PartitionedConvolver)
// — it used to be direct convolution on the audio thread, which cost ~25%
// of a core at long decays and allocated/copied several ~350 KB arrays per
// callback; together those occasionally made the realtime output callback
// miss its deadline, heard as a pop. The wet path now lags the dry path by
// one 512-sample block (~12 ms), which acts as a short pre-delay.
final class ConvolutionReverb {

    private let lock = NSLock()
    private var sampleRate: Double = 44100

    private static let maxIRSeconds = 2.0
    /// The web edition's fixed 0.6 dry + 0.8 wet sums ~2 dB louder than the
    /// input on real (pink, bursty) program material, at every knob setting.
    /// Measured and compensated so the reverb never raises the level.
    private static let levelComp: Float = 0.78
    private let convolver = PartitionedConvolver(
        maxPartitions: Int(44100 * ConvolutionReverb.maxIRSeconds) / PartitionedConvolver.block + 1,
        identityDelay: nil)

    // Dry copy for the mix (audio thread only).
    private static let maxChunk = 4096
    private let dryL = UnsafeMutablePointer<Float>.allocate(capacity: ConvolutionReverb.maxChunk)
    private let dryR = UnsafeMutablePointer<Float>.allocate(capacity: ConvolutionReverb.maxChunk)

    deinit { dryL.deallocate(); dryR.deallocate() }

    func setSampleRate(_ sr: Double) {
        lock.lock()
        if sr > 0 { sampleRate = sr }
        lock.unlock()
    }

    /// decaySec matches the web app's `Math.pow(eff, 1.5) * 60` exactly (capped
    /// here for real-time safety instead of the web app's 10s memory cap).
    func setDecay(_ decaySec: Double) {
        let sr = sampleRate
        let floorSec = max(decaySec, 0.05)
        let rawLen   = max(Int(ceil(sr * floorSec)), Int(sr * 0.05))
        let capped   = max(1, min(rawLen, Int(sr * Self.maxIRSeconds)))

        // Darker tail: the noise is run through a one-pole low-pass whose
        // cutoff glides exponentially from 7 kHz at the onset down to 1.2 kHz
        // by the end of the decay, so the reverb loses its highs as it fades
        // (as real rooms do — air and soft surfaces absorb treble fastest)
        // instead of ringing out as bright white-noise hiss.
        let fStart = 7000.0, fEnd = 1200.0
        var irL = [Float](repeating: 0, count: capped)
        var irR = [Float](repeating: 0, count: capped)
        var lpL = 0.0, lpR = 0.0
        for i in 0..<capped {
            let t   = Double(i) / (sr * floorSec)
            let env = exp(-3.0 * t)
            let fc  = fStart * pow(fEnd / fStart, min(t, 1))
            let a   = 1 - exp(-2 * Double.pi * fc / sr)
            lpL += a * (Double.random(in: -1...1) - lpL)
            lpR += a * (Double.random(in: -1...1) - lpR)
            irL[i] = Float(lpL * env)
            irR[i] = Float(lpR * env)
        }

        // Web Audio's ConvolverNode normalizes the impulse response's energy
        // by default (normalize=true) — without this, a longer decay simply
        // means more total IR energy, so the convolution output gets louder
        // and louder as decay increases (verified: unnormalized wet RMS grew
        // ~5x between a 0.05s and 2s decay in testing). Scaling the IR to
        // unit energy keeps the wet signal's RMS level roughly independent of
        // decay length, matching the web app's actual (non-runaway) behavior.
        normalizeEnergy(&irL)
        normalizeEnergy(&irR)

        // Independent IRs per channel (the web app's independent random
        // noise per channel, for stereo decorrelation). Crossfaded in by the
        // convolver, so the running tail is never cut off.
        convolver.setFilter(convolver.makeFilter([irL, irR]))
    }

    private func normalizeEnergy(_ ir: inout [Float]) {
        var energy: Float = 0
        vDSP_svesq(ir, 1, &energy, vDSP_Length(ir.count))
        guard energy > 1e-12 else { return }
        var scale = 1 / sqrt(energy)
        vDSP_vsmul(ir, 1, &scale, &ir, 1, vDSP_Length(ir.count))
    }

    /// In-place stereo convolution + dry mix. reverbDry=0.6 / reverbWet=0.8
    /// are the same constants the web app always sums regardless of the
    /// reverb knob position — only decay length (via setDecay) changes.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        var done = 0
        while done < count {
            let n = min(count - done, Self.maxChunk)
            let l = left + done, r = right.map { $0 + done }
            dryL.assign(from: l, count: n)
            if let r { dryR.assign(from: r, count: n) }
            convolver.process(left: l, right: r, count: n)     // → wet
            for i in 0..<n { l[i] = (dryL[i] * 0.6 + l[i] * 0.8) * Self.levelComp }
            if let r { for i in 0..<n { r[i] = (dryR[i] * 0.6 + r[i] * 0.8) * Self.levelComp } }
            done += n
        }
    }
}
