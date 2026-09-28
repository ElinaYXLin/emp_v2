import Foundation

// Apple's AUDynamicsProcessor (kAudioUnitSubType_DynamicsProcessor) and the Web
// Audio API's DynamicsCompressorNode are two different proprietary DSP
// algorithms. Even with numerically matched threshold/ratio/attack/release,
// Apple's unit is tuned to sound smooth and "musical" (audible as gain-reduction
// pumping), while Chromium/WebKit's compressor lets fast transients slip past its
// gain smoothing and clip, which reads as actual harsh distortion. No amount of
// parameter tuning bridges that gap — the underlying curves differ.
//
// This ports the Web Audio spec's own soft-knee compression-curve algorithm
// (threshold/knee/ratio → output dB) plus a one-pole attack/release envelope on
// the gain-reduction amount, so the macOS app produces the same curve shape and
// the same "fast limiter lets transients through" character as the web edition.
final class WebAudioCompressor {

    // Written from the main thread (mode toggle), read on the audio thread.
    // Updates happen only on an explicit mode switch (never per-sample), so an
    // uncontended lock here is free in practice.
    private let lock = NSLock()
    private var sampleRate: Double = 44100
    private var thresholdDb: Double = 0
    private var kneeDb: Double = 0
    private var ratio: Double = 20
    private var attackSec: Double = 0.001
    private var releaseSec: Double = 0.1
    private var trimLinear: Double = 1.0

    private var attackCoeff: Double = 0
    private var releaseCoeff: Double = 0

    // Gain-reduction envelope state (audio-thread only).
    private var currentReductionDb: Double = 0

    init() { recomputeCoeffs() }

    func setSampleRate(_ sr: Double) {
        lock.lock()
        if sr > 0 { sampleRate = sr; recomputeCoeffs() }
        lock.unlock()
    }

    /// Mirrors the web edition's configureDynamics(): threshold/knee/ratio/
    /// attack/release match Web Audio's DynamicsCompressorNode parameters
    /// exactly; trimDb is the fixed makeup/safety trim applied after (Web Audio
    /// itself has no automatic makeup gain, so this is applied explicitly, same
    /// as the web app's separate `dynamicsTrim` gain node).
    func configure(thresholdDb: Double, kneeDb: Double, ratio: Double,
                   attackSec: Double, releaseSec: Double, trimDb: Double) {
        lock.lock()
        self.thresholdDb = thresholdDb
        self.kneeDb       = kneeDb
        self.ratio        = ratio
        self.attackSec    = attackSec
        self.releaseSec   = releaseSec
        self.trimLinear   = pow(10, trimDb / 20)
        recomputeCoeffs()
        lock.unlock()
    }

    private func recomputeCoeffs() {
        attackCoeff  = 1 - exp(-1.0 / (max(attackSec, 0.0001) * sampleRate))
        releaseCoeff = 1 - exp(-1.0 / (max(releaseSec, 0.0001) * sampleRate))
    }

    // Standard soft-knee compression curve — the same threshold/knee/ratio
    // shape the Web Audio spec's DynamicsCompressorNode parameters describe:
    // transparent below threshold, quadratic soft-knee blend through the knee
    // width, then a fixed-ratio slope beyond it.
    private func curve(_ inputDb: Double, threshold: Double, knee: Double, ratio: Double) -> Double {
        if inputDb < threshold { return inputDb }
        let kneeEnd = threshold + knee
        if knee > 0, inputDb < kneeEnd {
            let t = (inputDb - threshold) / knee
            let reduction = (1 - 1 / ratio) * knee * t * t / 2
            return inputDb - reduction
        }
        return kneeEnd + (inputDb - kneeEnd) / ratio
    }

    /// Stereo-linked in-place processing: a single gain-reduction envelope
    /// driven by the louder of the two channels is applied to both, matching
    /// Web Audio's stereo-linked compressor (keeps the stereo image stable
    /// instead of each channel ducking independently).
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        lock.lock()
        let th = thresholdDb, kn = kneeDb, ra = ratio, trim = trimLinear
        let atk = attackCoeff, rel = releaseCoeff
        lock.unlock()

        var reductionDb = currentReductionDb
        for i in 0..<count {
            let l = Double(left[i])
            let r = right != nil ? Double(right![i]) : l
            let peak = Swift.max(abs(l), abs(r), 1e-8)
            let inputDb  = 20 * log10(peak)
            let outputDb = curve(inputDb, threshold: th, knee: kn, ratio: ra)
            let targetReduction = Swift.max(0, inputDb - outputDb)

            if targetReduction > reductionDb {
                reductionDb += (targetReduction - reductionDb) * atk
            } else {
                reductionDb += (targetReduction - reductionDb) * rel
            }

            let gain = pow(10, -reductionDb / 20) * trim
            left[i] = Float(l * gain)
            if let right { right[i] = Float(r * gain) }
        }
        currentReductionDb = reductionDb
    }
}
