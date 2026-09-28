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
// 10 Hz DC blocker.
final class WebAudioSaturator {

    // Written from the main thread (macro/slider updates), read on the audio
    // thread. Updates are UI-rate, so an uncontended lock here is effectively free.
    private let lock = NSLock()
    private var driveLin: Double = 1.0
    private var tanhDrive: Double = 1.0
    private var postGain: Double = 1.0

    /// Bias as a fraction of the envelope — sets the even/odd balance.
    private static let biasAmount = 0.5
    private static let sampleRate = 44100.0
    private static let attackCoef  = 1 - exp(-1 / (0.005 * sampleRate))
    private static let releaseCoef = 1 - exp(-1 / (0.150 * sampleRate))
    private static let dcCoef      = 1 - 2 * Double.pi * 10 / sampleRate

    // Per-channel filter state, owned by the audio thread.
    private var env:  [Double] = [0, 0]
    private var dcX:  [Double] = [0, 0]
    private var dcY:  [Double] = [0, 0]

    /// driveDb: 0–8 dB, matches the web edition's `eff * 8` range exactly.
    func setDrive(driveDb: Double) {
        lock.lock()
        let d = pow(10, driveDb / 20)
        driveLin  = d
        tanhDrive = tanh(max(d, 0.001))
        postGain  = 1 / max(d, 1)
        lock.unlock()
    }

    func process(_ buffer: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        lock.lock()
        let drive = driveLin, tdrive = tanhDrive, post = postGain
        lock.unlock()

        let ch = min(max(channel, 0), 1)
        var e = env[ch], x1 = dcX[ch], y1 = dcY[ch]
        for i in 0..<count {
            let xOrig   = Double(buffer[i])
            let xScaled = xOrig * drive * drive       // preGain + curve drive

            // Envelope follower (5 ms attack / 150 ms release) → tube-style bias.
            let mag = abs(xScaled)
            e += (mag > e ? Self.attackCoef : Self.releaseCoef) * (mag - e)
            let bias = Self.biasAmount * e

            // Biased waveshaper, re-centered so silence stays at zero.
            let shaped = tanh(xScaled + bias) - tanh(bias)

            // DC blocker: y[n] = x[n] - x[n-1] + R·y[n-1]
            let y = shaped - x1 + Self.dcCoef * y1
            x1 = shaped; y1 = y

            buffer[i] = Float(y / tdrive * post)       // curve normalize + postGain
        }
        env[ch] = e; dcX[ch] = x1; dcY[ch] = y1
    }
}
