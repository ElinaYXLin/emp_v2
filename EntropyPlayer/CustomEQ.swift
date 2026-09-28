import Foundation

// AVAudioUnitEQ's underlying AUNBandEQ caps its "bandwidth" parameter at 5.0
// octaves. The web edition uses a Web Audio BiquadFilterNode (type "peaking")
// with Q = 0.1, which — via the RBJ Audio-EQ-Cookbook formula Web Audio
// implements — corresponds to roughly 10 octaves of bandwidth. That shape is
// unreachable on AVAudioUnitEQ, which is why the macOS EQ sounded narrower and
// more resonant than the web app's wide, gentle bell.
//
// This runs the identical RBJ peaking formula the Web Audio spec mandates, as
// plain Swift DSP (no AudioUnit involved), so both editions produce the exact
// same response curve for the same frequency/Q/gain. It's driven from
// AudioEngine via a tap + ring buffer + AVAudioSourceNode bridge — hosting a
// custom in-process AUAudioUnit inside AVAudioEngine turned out to be blocked
// under App Sandbox (component lookup fails with -3000 even though direct
// construction of the AUAudioUnit subclass succeeds), so this sidesteps that
// entirely.
final class PeakingBiquad {

    // Written from the main thread (macro/slider updates), read on the audio
    // thread. Updates are UI-rate (tens of Hz at most), so an uncontended lock
    // here never meaningfully delays the render thread.
    private let lock = NSLock()
    private var sampleRate: Double
    private var frequency: Double = 150
    private var q: Double = 0.1
    private var gainDb: Double = 0

    private struct Coeffs { var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0 }
    private var coeffs = Coeffs()

    // Per-channel Direct Form I state (stereo).
    private var x1 = [Double](repeating: 0, count: 2)
    private var x2 = [Double](repeating: 0, count: 2)
    private var y1 = [Double](repeating: 0, count: 2)
    private var y2 = [Double](repeating: 0, count: 2)

    init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
        recompute()
    }

    func setParameters(frequency: Double? = nil, q: Double? = nil, gainDb: Double? = nil) {
        lock.lock()
        if let frequency { self.frequency = frequency }
        if let q         { self.q = q }
        if let gainDb    { self.gainDb = gainDb }
        recompute()
        lock.unlock()
    }

    // RBJ Audio-EQ-Cookbook peaking EQ — the same formula the Web Audio spec
    // uses for BiquadFilterNode type "peaking".
    private func recompute() {
        let a  = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * frequency / max(sampleRate, 1)
        let alpha = sin(w0) / (2 * max(q, 0.0001))
        let cosw0 = cos(w0)

        let b0 = 1 + alpha * a
        let b1 = -2 * cosw0
        let b2 = 1 - alpha * a
        let a0 = 1 + alpha / a
        let a1 = -2 * cosw0
        let a2 = 1 - alpha / a

        coeffs = Coeffs(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Processes one channel's buffer in-place. `channel` selects which
    /// filter-state slot to use (0 = left/mono, 1 = right).
    func process(_ buffer: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        lock.lock()
        let c = coeffs
        lock.unlock()

        var x1 = self.x1[channel], x2 = self.x2[channel]
        var y1 = self.y1[channel], y2 = self.y2[channel]
        for i in 0..<count {
            let x0 = Double(buffer[i])
            let y0 = c.b0 * x0 + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
            buffer[i] = Float(y0)
        }
        self.x1[channel] = x1; self.x2[channel] = x2
        self.y1[channel] = y1; self.y2[channel] = y2
    }
}
