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
final class WebAudioSaturator {

    // Written from the main thread (macro/slider updates), read on the audio
    // thread. Updates are UI-rate, so an uncontended lock here is effectively free.
    private let lock = NSLock()
    private var driveLin: Double = 1.0
    private var tanhDrive: Double = 1.0
    private var postGain: Double = 1.0

    /// driveDb: 0–8 dB, matches the web edition's `eff * 8` range exactly.
    func setDrive(driveDb: Double) {
        lock.lock()
        let d = pow(10, driveDb / 20)
        driveLin  = d
        tanhDrive = tanh(max(d, 0.001))
        postGain  = 1 / max(d, 1)
        lock.unlock()
    }

    func process(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock()
        let drive = driveLin, tdrive = tanhDrive, post = postGain
        lock.unlock()

        for i in 0..<count {
            let xOrig   = Double(buffer[i])
            let xScaled = xOrig * drive              // preGain
            let y       = tanh(xScaled * drive) / tdrive  // waveshaper curve
            buffer[i]   = Float(y * post)             // postGain
        }
    }
}
