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

// High roll-off: a constant dB-per-octave slope above 1 kHz (0 dB/oct = flat,
// 6 dB/oct = -24 dB at 16 kHz). A single filter can only give fixed slopes
// (6, 12… dB/oct), so this is a cascade of first-order high shelves at
// half-octave spacing (707 Hz–16 kHz) whose gains were least-squares fitted
// to the ideal line -slope·log2(f/1k) over 100 Hz–20 kHz. Every shelf's gain
// scales with the slope, so any slope in between is available. Measured fit
// error < 0.1 dB at 1 dB/oct, < 0.9 dB at 6 dB/oct (largest at the knee).
final class HighRolloff {

    // Shelf centers (octaves relative to 1 kHz) and dB of gain per dB/oct of slope.
    private static let centerOctaves: [Double] = (-1...8).map { Double($0) / 2 }
    private static let gainPerSlope:  [Double] = [0.572, 0.839, -1.36, -1.422, -1.54,
                                                  0.308, 0.363, -1.31, -0.626, -0.155]
    private static let shelves = 10

    private let lock = NSLock()
    private let sampleRate: Double
    private struct Coeffs { var b0 = 1.0, b1 = 0.0, a1 = 0.0 }
    private var coeffs = [Coeffs](repeating: Coeffs(), count: HighRolloff.shelves)

    // Per-channel, per-shelf Direct Form I state.
    private var x1 = [[Double]](repeating: [Double](repeating: 0, count: HighRolloff.shelves), count: 2)
    private var y1 = [[Double]](repeating: [Double](repeating: 0, count: HighRolloff.shelves), count: 2)

    init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
    }

    /// dbPerOctave: 0 (flat) … 6.
    func setSlope(dbPerOctave slope: Double) {
        let s = max(0, slope)
        var c = [Coeffs]()
        for (oct, gps) in zip(Self.centerOctaves, Self.gainPerSlope) {
            // First-order high shelf, gain G above fc, bilinear with fc prewarped:
            // H(s) = (G·s + √G) / (s + √G)
            let fc = min(1000 * pow(2, oct), sampleRate * 0.49)
            let g  = pow(10, gps * s / 20)
            let sg = sqrt(g)
            let k  = tan(Double.pi * fc / sampleRate)
            let a0 = 1 + sg * k
            c.append(Coeffs(b0: (g + sg * k) / a0, b1: (sg * k - g) / a0, a1: (sg * k - 1) / a0))
        }
        lock.lock()
        coeffs = c
        lock.unlock()
    }

    func process(_ buffer: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        lock.lock()
        let cs = coeffs
        lock.unlock()

        var xs = x1[channel], ys = y1[channel]
        for i in 0..<count {
            var v = Double(buffer[i])
            for j in 0..<cs.count {
                let y = cs[j].b0 * v + cs[j].b1 * xs[j] - cs[j].a1 * ys[j]
                xs[j] = v; ys[j] = y
                v = y
            }
            buffer[i] = Float(v)
        }
        x1[channel] = xs; y1[channel] = ys
    }
}

// Subsonic filter: 2nd-order Butterworth high-pass at 25 Hz, ahead of the
// saturators. Inaudible sub-25 Hz rumble (from the source, or pushed around
// by group delay) otherwise drives the saturators' operating point up and
// down, audibly modulating everything else at the rumble rate.
final class SubsonicFilter {
    private let b0, b1, b2, a1, a2: Double
    private var x1 = [0.0, 0.0], x2 = [0.0, 0.0], y1 = [0.0, 0.0], y2 = [0.0, 0.0]

    init(cutoff: Double = 25, sampleRate: Double = 44100) {
        // RBJ cookbook high-pass, Q = 1/√2 (Butterworth).
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * 0.7071067811865476)
        let c = cos(w0), a0 = 1 + alpha
        b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = b0
        a1 = -2 * c / a0;      a2 = (1 - alpha) / a0
    }

    func process(_ buffer: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        var x1 = self.x1[channel], x2 = self.x2[channel]
        var y1 = self.y1[channel], y2 = self.y2[channel]
        for i in 0..<count {
            let x0 = Double(buffer[i])
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0; y2 = y1; y1 = y0
            buffer[i] = Float(y0)
        }
        self.x1[channel] = x1; self.x2[channel] = x2
        self.y1[channel] = y1; self.y2[channel] = y2
    }
}
