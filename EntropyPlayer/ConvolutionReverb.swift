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
// For real-time safety the IR is capped at 2 seconds (88,200 samples at
// 44.1kHz) rather than the web app's 10-second hard cap: direct convolution
// scales with IR length, and 10s would need ~19 GFLOP/s sustained, too risky
// for a realtime audio thread. Nearly all audible reverb character lives in
// the first couple of seconds of decay regardless.
final class ConvolutionReverb {

    private let lock = NSLock()
    private var sampleRate: Double = 44100

    // Reversed impulse responses (independent per channel, matching the web
    // app's independent random noise per channel for stereo decorrelation).
    // vDSP_conv computes C[n] = Σ_p A[n+p]·F[p]; using F = reversed h and
    // A = [history(P-1)] + [current block] yields the correct causal
    // convolution y[n] = Σ_k h[k]·x[n-k] (verified numerically against
    // numpy.convolve before writing this).
    private var irReversedL: [Float] = [0]
    private var irReversedR: [Float] = [0]
    private var irGen = 0
    // Audio-thread-only state. History is kept at the maximum IR length at
    // all times, so changing the decay never wipes the running tail, and a
    // new IR is crossfaded in over one block (old IR's output → new IR's).
    // Previously every knob movement resized/zeroed the history, cutting
    // the tail off abruptly — a stutter for as long as the knob moved.
    private var activeL: [Float] = [0]
    private var activeR: [Float] = [0]
    private var activeGen = 0
    private var historyL: [Float] = []
    private var historyR: [Float] = []

    private static let maxIRSeconds = 2.0

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

        // Only the IR (a parameter) is written here; historyL/historyR are
        // filter state exclusively owned by the audio thread (see
        // processChannel) — resizing it here too would race with process().
        lock.lock()
        irReversedL = irL.reversed()
        irReversedR = irR.reversed()
        irGen &+= 1
        lock.unlock()
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
        lock.lock()
        let irL = irReversedL
        let irR = irReversedR
        let gen = irGen
        let maxLen = max(1, Int(sampleRate * Self.maxIRSeconds))
        lock.unlock()

        let changed = gen != activeGen
        processChannel(left, count: count, ir: irL, oldIR: changed ? activeL : nil,
                       maxLen: maxLen, history: &historyL)
        if let right {
            processChannel(right, count: count, ir: irR, oldIR: changed ? activeR : nil,
                           maxLen: maxLen, history: &historyR)
        }
        activeL = irL; activeR = irR; activeGen = gen
    }

    private func processChannel(_ buffer: UnsafeMutablePointer<Float>, count: Int,
                                 ir: [Float], oldIR: [Float]?, maxLen: Int,
                                 history: inout [Float]) {
        if history.count != maxLen - 1 {
            history = [Float](repeating: 0, count: maxLen - 1)
        }

        var a = history
        a.append(contentsOf: UnsafeBufferPointer(start: buffer, count: count))

        // Convolve against the most recent (p-1) history samples + block.
        func convolve(_ h: [Float]) -> [Float] {
            let p = min(h.count, maxLen)
            var out = [Float](repeating: 0, count: count)
            guard p > 0 else { return out }
            h.withUnsafeBufferPointer { hPtr in
                a.withUnsafeBufferPointer { aPtr in
                    vDSP_conv(aPtr.baseAddress! + (maxLen - p), 1,
                              hPtr.baseAddress! + (h.count - p), 1, &out, 1,
                              vDSP_Length(count), vDSP_Length(p))
                }
            }
            return out
        }

        var wet = convolve(ir)
        if let oldIR {
            let prev = convolve(oldIR)
            for i in 0..<count {
                let t = Float(i + 1) / Float(count)
                wet[i] = prev[i] + (wet[i] - prev[i]) * t
            }
        }

        history = Array(a.suffix(maxLen - 1))

        for i in 0..<count {
            buffer[i] = buffer[i] * 0.6 + wet[i] * 0.8
        }
    }
}
