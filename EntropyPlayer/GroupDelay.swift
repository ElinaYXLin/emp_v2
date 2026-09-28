import Foundation
import Accelerate

// Frequency-dependent group delay: lower frequencies are delayed more, with
// delay inversely proportional to frequency — τ(f) = scale / f, i.e. `scale`
// periods of each frequency's oscillation. scale 0 = no group delay, scale 5
// = 250 ms at 20 Hz (clamped to that constant below 20 Hz so the delay stays
// bounded near DC).
//
// Implemented as a unit-magnitude (allpass) FIR designed in the frequency
// domain: the phase is the integral of the delay, φ(f) = -2π∫τ df, which for
// τ = scale/f is logarithmic in f. The FIR is then run with the same
// history + vDSP_conv direct convolution as ConvolutionReverb.
//
// When the scale changes (macro/knob/vibrato) the audio thread crossfades
// from the old filter's output to the new one's across one block, so moving
// the control doesn't click.
final class GroupDelay {

    private let lock = NSLock()
    private var sampleRate: Double = 44100

    /// 16384 taps ≈ 370 ms at 44.1 kHz: covers the 250 ms max delay plus the
    /// bulk offset and dispersion tail with margin.
    private static let taps = 16384
    /// Small fixed bulk delay so the chirp's high-frequency onset (and the
    /// ringing from band-limiting it) isn't truncated at t = 0. ~1.5 ms.
    private static let bulkDelay = 64
    /// Below this, delay is held constant instead of growing without bound.
    private static let floorHz = 20.0
    /// Half-Hann fade over the last taps so the FIR ends smoothly.
    private static let fadeTaps = 2048

    // Pending (set from main thread) and active (audio thread only) filters.
    // `nil` means identity: a pure bulkDelay-sample delay, no convolution.
    private var pendingIR: [Float]? = nil
    private var pendingGen = 0
    private var currentScale: Double = 0

    private var activeIR: [Float]? = nil
    private var activeGen = 0
    private var historyL = [Float](repeating: 0, count: GroupDelay.taps - 1)
    private var historyR = [Float](repeating: 0, count: GroupDelay.taps - 1)

    func setSampleRate(_ sr: Double) {
        lock.lock()
        if sr > 0 { sampleRate = sr }
        lock.unlock()
    }

    /// scale: multiplier on one period of delay (0…5).
    func setScale(_ scale: Double) {
        let s = max(0, min(5, scale))
        // Skip redundant redesigns (macro drags fire this on every event).
        guard abs(s - currentScale) > 1e-4 else { return }
        currentScale = s

        let ir: [Float]? = s < 1e-4 ? nil : Self.design(scale: s, sampleRate: sampleRate)
        lock.lock()
        pendingIR = ir
        pendingGen &+= 1
        lock.unlock()
    }

    /// Builds the reversed FIR (vDSP_conv takes the filter reversed — see
    /// ConvolutionReverb) for τ(f) = scale / max(f, floorHz) + bulkDelay.
    private static func design(scale: Double, sampleRate sr: Double) -> [Float] {
        let n = taps
        let f0 = floorHz
        let bulkSec = Double(bulkDelay) / sr

        var re = [Float](repeating: 0, count: n)
        var im = [Float](repeating: 0, count: n)
        for k in 0...(n / 2) {
            let f = Double(k) * sr / Double(n)
            // φ(f) = -2π ∫₀^f τ(f') df'
            let integral: Double = f < f0
                ? scale * f / f0
                : scale * (1 + log(f / f0))
            let phi = -2 * Double.pi * (integral + f * bulkSec)
            if k == 0 || k == n / 2 {
                // DC and Nyquist bins must be real for a real-valued IR.
                re[k] = Float(k == 0 ? 1 : cos(phi))
            } else {
                re[k] = Float(cos(phi)); im[k] = Float(sin(phi))
                re[n - k] = re[k];       im[n - k] = -im[k]   // Hermitian
            }
        }

        var outRe = [Float](repeating: 0, count: n)
        var outIm = [Float](repeating: 0, count: n)
        if let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .INVERSE) {
            vDSP_DFT_Execute(setup, re, im, &outRe, &outIm)
            vDSP_DFT_DestroySetup(setup)
        }
        var norm = 1 / Float(n)
        vDSP_vsmul(outRe, 1, &norm, &outRe, 1, vDSP_Length(n))

        for i in 0..<fadeTaps {
            let w = 0.5 * (1 + cos(Double.pi * Double(i + 1) / Double(fadeTaps)))
            outRe[n - fadeTaps + i] *= Float(w)
        }
        return outRe.reversed()
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        let newIR = pendingIR
        let newGen = pendingGen
        lock.unlock()

        let changed = newGen != activeGen
        let oldIR = activeIR
        processChannel(left, count: count, oldIR: oldIR, newIR: newIR, crossfade: changed, history: &historyL)
        if let right {
            processChannel(right, count: count, oldIR: oldIR, newIR: newIR, crossfade: changed, history: &historyR)
        }
        activeIR = newIR
        activeGen = newGen
    }

    private func processChannel(_ buffer: UnsafeMutablePointer<Float>, count: Int,
                                oldIR: [Float]?, newIR: [Float]?, crossfade: Bool,
                                history: inout [Float]) {
        let p = Self.taps
        var a = history
        a.append(contentsOf: UnsafeBufferPointer(start: buffer, count: count))

        let target = render(a, ir: newIR, count: count)
        if crossfade {
            let prev = render(a, ir: oldIR, count: count)
            for i in 0..<count {
                let t = Float(i + 1) / Float(count)
                buffer[i] = prev[i] + (target[i] - prev[i]) * t
            }
        } else {
            for i in 0..<count { buffer[i] = target[i] }
        }

        history = Array(a.suffix(p - 1))
    }

    /// `a` = [history (taps-1)] + [block]; output[i] corresponds to a[taps-1+i].
    private func render(_ a: [Float], ir: [Float]?, count: Int) -> [Float] {
        let p = Self.taps
        guard let ir else {
            // Identity: match the designed filter's bulk latency exactly.
            let start = p - 1 - Self.bulkDelay
            return Array(a[start..<(start + count)])
        }
        var out = [Float](repeating: 0, count: count)
        ir.withUnsafeBufferPointer { irPtr in
            a.withUnsafeBufferPointer { aPtr in
                vDSP_conv(aPtr.baseAddress!, 1, irPtr.baseAddress!, 1, &out, 1,
                          vDSP_Length(count), vDSP_Length(p))
            }
        }
        return out
    }
}
