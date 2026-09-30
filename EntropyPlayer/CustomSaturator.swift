import Foundation

// AVAudioUnitDistortion is Apple's own distortion algorithm (its presets are
// built from ring-modulation, decimation, and delay-based effects, not a plain
// tanh soft-clip) — a fundamentally different DSP than the web edition's
// saturator. That mismatch is what caused a boomy artifact once the EQ's bass
// boost drove it: AVAudioUnitDistortion's internal processing doesn't behave
// like a simple waveshaper on boosted low-frequency content.
//
// This ports the web app's exact saturator: a fixed pre-gain, a tanh
// waveshaper curve normalized so tanh(drive) maps to unity, then a post-gain
// that compensates for level except below unity drive. Same algorithm,
// evaluated directly per-sample instead of via a 512-point lookup table
// (equivalent audible result, no interpolation error).
//
// Analog voicing: a plain tanh is odd-symmetric, so it only ever adds odd
// harmonics (3rd, 5th… — the harsher, "transistor" sound). Like a tube
// stage's grid-bias shift, the curve's operating point here is offset by a
// bias proportional to the signal's own envelope. Because the bias scales
// with level, the clipping stays asymmetric even when driven hard (a fixed
// bias gets swamped and the output turns square/odd again), so 2nd/4th
// harmonics dominate at every drive setting — measured ~7–20 dB more even
// than odd content, and ~15 dB less 3rd harmonic than the plain tanh at full
// drive. The asymmetry produces a level-dependent DC offset, removed by a
// 10 Hz high-pass (4th-order Butterworth, 24 dB/oct). It's steep because
// even-order distortion also makes intermodulation difference tones (two
// bass notes at 55 + 62 Hz → a 7 Hz throb) that a gentle DC blocker let
// through as an engine-like whirr. The envelope follower is also slow
// (50 ms attack / 400 ms release) so the bias doesn't track — and
// re-modulate — individual bass cycles and beats.
//
// Two voicings share this class: `.even` (the biased curve above) and `.odd`
// (the web edition's original plain tanh, kept as its own "Odd Saturator"
// control for a brighter, grittier edge).
final class WebAudioSaturator {

    enum Voicing { case even, odd }
    private let voicing: Voicing

    init(voicing: Voicing) {
        self.voicing = voicing
    }

    // Written from the main thread (macro/slider updates), read on the audio
    // thread. Updates are UI-rate, so an uncontended lock here is effectively free.
    private let lock = NSLock()
    private var driveLin: Double = 1.0
    private var tanhDrive: Double = 1.0
    private var postGain: Double = 1.0

    /// Bias as a fraction of the envelope — sets the even/odd balance.
    private var biasAmount = 0.5
    private static let sampleRate = 44100.0
    private static let attackCoef  = 1 - exp(-1 / (0.050 * sampleRate))
    private static let releaseCoef = 1 - exp(-1 / (0.400 * sampleRate))
    // Two cascaded RBJ high-pass biquads, Q = 0.5412 and 1.3066 → 4th-order Butterworth at 10 Hz.
    private static let hpCoefs: [(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double)] =
        [0.5411961, 1.3065630].map { q in
            let w0 = 2 * Double.pi * 10 / sampleRate, alpha = sin(w0) / (2 * q), c = cos(w0), a0 = 1 + alpha
            return ((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0)
        }
    // [channel][stage] biquad state: x1, x2, y1, y2
    private var hpState = [[[Double]]](repeating: [[0, 0, 0, 0], [0, 0, 0, 0]], count: 2)

    // Per-channel filter state, owned by the audio thread.
    private var env:  [Double] = [0, 0]
    // Loudness makeup state per channel: smoothed input / output power.
    private var pIn:  [Double] = [0, 0]
    private var pOut: [Double] = [0, 0]
    private static let powerCoef = 1 - exp(-1 / (0.300 * sampleRate))

    /// driveDb: 0–16 dB (the web edition used 0–8; doubled for more warmth).
    /// Even voicing: bias as a fraction of the envelope (sets even/odd balance).
    func setBias(_ b: Double) {
        lock.lock()
        biasAmount = max(0, min(1, b))
        lock.unlock()
    }

    func setDrive(driveDb: Double) {
        lock.lock()
        let d = pow(10, driveDb / 20)
        driveLin  = d
        tanhDrive = tanh(max(d, 0.001))
        // Level normalization, two parts:
        // 1. Unity small-signal gain: the curve's input is scaled by d², so
        //    divide by d² after it (|tanh u| ≤ |u| → never louder).
        // 2. Loudness makeup (in process): input and output power are tracked
        //    with the same 300 ms smoothing and the output is scaled so its
        //    RMS matches the input's. Clipping lowers the crest factor, so at
        //    matched RMS the peaks still come out at or below the input's —
        //    loudness-neutral, never hotter into the limiter.
        // (The web edition's 1/tanh(d)·1/max(d,1) scaling left quiet material
        // up to d/tanh(d) louder: +2.4 dB at 0 dB drive, ~+16 dB at 16 dB.)
        postGain  = 1 / (d * d)
        lock.unlock()
    }

    func process(_ buffer: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        lock.lock()
        let drive = driveLin, post = postGain, biasAmt = biasAmount
        lock.unlock()

        let ch = min(max(channel, 0), 1)
        var pi = pIn[ch], po = pOut[ch]
        let maxMakeup = 1 / post
        @inline(__always) func makeup(_ x: Double, _ y: Double) -> Double {
            pi += Self.powerCoef * (x * x - pi)
            po += Self.powerCoef * (y * y - po)
            return max(1, min(maxMakeup, ((pi + 1e-12) / (po + 1e-12)).squareRoot()))
        }

        if voicing == .odd {
            for i in 0..<count {
                let xOrig   = Double(buffer[i])
                let xScaled = xOrig * drive              // preGain
                let y       = tanh(xScaled * drive) * post   // unity small-signal gain
                buffer[i]   = Float(y * makeup(xOrig, y))
            }
            pIn[ch] = pi; pOut[ch] = po
            return
        }

        var e = env[ch]
        var st = hpState[ch]
        for i in 0..<count {
            let xOrig   = Double(buffer[i])
            let xScaled = xOrig * drive * drive       // preGain + curve drive

            // Envelope follower (50 ms attack / 400 ms release) → tube-style bias.
            let mag = abs(xScaled)
            e += (mag > e ? Self.attackCoef : Self.releaseCoef) * (mag - e)
            let bias = biasAmt * e

            // Biased waveshaper, re-centered so silence stays at zero.
            let shaped = tanh(xScaled + bias) - tanh(bias)

            // 4th-order high-pass (removes DC and sub-10 Hz difference tones).
            var y = shaped
            for k in 0..<2 {
                let c = Self.hpCoefs[k]
                let out = c.b0 * y + c.b1 * st[k][0] + c.b2 * st[k][1] - c.a1 * st[k][2] - c.a2 * st[k][3]
                st[k][1] = st[k][0]; st[k][0] = y
                st[k][3] = st[k][2]; st[k][2] = out
                y = out
            }

            let yn = y * post                          // unity small-signal gain
            buffer[i] = Float(yn * makeup(xOrig, yn))
        }
        env[ch] = e; hpState[ch] = st
        pIn[ch] = pi; pOut[ch] = po
    }
}
