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

        var irL = [Float](repeating: 0, count: capped)
        var irR = [Float](repeating: 0, count: capped)
        for i in 0..<capped {
            let env = Float(exp(-3.0 * Double(i) / (sr * floorSec)))
            irL[i] = Float.random(in: -1...1) * env
            irR[i] = Float.random(in: -1...1) * env
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
        lock.unlock()

        processChannel(left, count: count, ir: irL, history: &historyL)
        if let right {
            processChannel(right, count: count, ir: irR, history: &historyR)
        }
    }

    private func processChannel(_ buffer: UnsafeMutablePointer<Float>, count: Int,
                                 ir: [Float], history: inout [Float]) {
        let p = ir.count
        guard p > 0 else { return }

        // The IR can change length whenever the reverb knob moves (setDecay,
        // main thread). Detect that here, on the audio thread, and resize our
        // own history — avoids any cross-thread race on this state.
        if history.count != p - 1 {
            history = [Float](repeating: 0, count: max(0, p - 1))
        }

        var a = history
        a.append(contentsOf: UnsafeBufferPointer(start: buffer, count: count))

        var wet = [Float](repeating: 0, count: count)
        ir.withUnsafeBufferPointer { irPtr in
            a.withUnsafeBufferPointer { aPtr in
                vDSP_conv(aPtr.baseAddress!, 1, irPtr.baseAddress!, 1, &wet, 1,
                          vDSP_Length(count), vDSP_Length(p))
            }
        }

        if p > 1 { history = Array(a.suffix(p - 1)) }

        for i in 0..<count {
            buffer[i] = buffer[i] * 0.6 + wet[i] * 0.8
        }
    }
}
