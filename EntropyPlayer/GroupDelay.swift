import Foundation
import Accelerate

// Frequency-dependent group delay: lower frequencies are delayed more, with
// delay inversely proportional to frequency — τ(f) = scale / f, i.e. `scale`
// periods of each frequency's oscillation. scale 0 = no group delay, scale 20
// = 1 s at 20 Hz, 200 ms at 100 Hz (held constant below 20 Hz so the delay
// stays bounded near DC, and capped at maxDelaySec overall).
//
// Spectral smear: a pure 1/f delay moves each frequency in time but keeps
// neighbouring frequencies aligned, so it barely blurs anything — attacks
// just arrive a little later, steady sounds are unchanged. To make it muddy,
// the delay is additionally varied pseudo-randomly across frequency by up to
// ±smearAmount of itself, changing every 1/12 octave (several times within
// one critical band of hearing). Components the ear hears together then
// arrive at different times, smearing transients into a wash. The smear
// pattern is fixed (seeded), so redesigns — knob moves, drift — never make
// it shimmer or reshuffle.
//
// Implemented as a unit-magnitude (allpass) FIR designed in the frequency
// domain: the phase is the integral of the delay, φ(f) = -2π∫τ df. The FIR
// is ~3 s long, far too long for direct convolution on the audio thread, so
// it runs as uniformly partitioned FFT convolution (overlap-save, 512-sample
// partitions) — adds 512 samples (~12 ms) of latency.
//
// When the scale changes (macro/knob/vibrato) the audio thread crossfades
// from the old filter's output to the new one's across one partition block,
// so moving the control doesn't click.
//
// Randomness: the scale wanders within base × (1 ± randomness) (randomness
// 0…0.5). A parameter-thread timer glides toward a random target with a
// smoothstep curve over several seconds, then picks the next target, so the
// delay drifts slowly rather than jumping; each small step is redesigned and
// crossfaded like any other change.
final class GroupDelay {

    private let lock = NSLock()
    private var sampleRate: Double = 44100

    /// Filter length: 2^17 taps ≈ 3 s at 44.1 kHz — covers the maxDelaySec
    /// cap plus bulk offset and dispersion tail.
    private static let taps = 1 << 17
    private static let maxScale = 30.0            // 20x base + 50% randomness
    private static let maxDelaySec = 1.6
    private static let smearAmount = 0.6
    private static let smearStepsPerOctave = 12.0
    /// Small fixed bulk delay so the chirp's high-frequency onset (and the
    /// ringing from band-limiting it) isn't truncated at t = 0. ~1.5 ms.
    private static let bulkDelay = 64
    /// Below this, delay is held constant instead of growing without bound.
    private static let floorHz = 20.0
    /// Half-Hann fade over the last taps so the FIR ends smoothly.
    private static let fadeTaps = 4096

    // Partitioned convolution geometry.
    private static let block = 512                         // partition / hop size
    private static let fftN = 2 * block
    private static let log2N = vDSP_Length(10)
    private static let partitions = taps / block           // 256
    private static let bins = fftN / 2                     // packed real-FFT bins

    private let fftSetup: FFTSetup = vDSP_create_fftsetup(GroupDelay.log2N, FFTRadix(kFFTRadix2))!

    /// Filter spectra, one per partition, packed zrip format, pre-scaled.
    private final class Spectra {
        let re: UnsafeMutablePointer<Float>
        let im: UnsafeMutablePointer<Float>
        init() {
            let n = GroupDelay.partitions * GroupDelay.bins
            re = .allocate(capacity: n); re.initialize(repeating: 0, count: n)
            im = .allocate(capacity: n); im.initialize(repeating: 0, count: n)
        }
        deinit { re.deallocate(); im.deallocate() }
    }

    // Pending (set from param thread) and active (audio thread only) filters.
    // `nil` means identity: a pure bulkDelay-sample delay, no convolution.
    private var pending: Spectra? = nil
    private var pendingGen = 0
    private var retired: Spectra? = nil   // released off the audio thread
    private var currentScale: Double = 0

    // Modulation state — touched only on paramQueue.
    private let paramQueue = DispatchQueue(label: "GroupDelay.params", qos: .userInitiated)
    private var modTimer: DispatchSourceTimer?
    private var baseScale: Double = 0
    private var randomness: Double = 0
    private var modFrom: Double = 0          // offset in -1…1
    private var modTo: Double = 0
    private var modElapsed: Double = 0
    private var modDuration: Double = 4
    private static let modTick = 1.0 / 30

    // Audio-thread state (all preallocated).
    private var active: Spectra? = nil
    private var activeGen = 0
    private var fill = 0                                    // samples in current block
    private let inBlock:  [UnsafeMutablePointer<Float>]     // per channel, fftN (prev + cur)
    private let outBlock: [UnsafeMutablePointer<Float>]     // per channel, block
    private let fdlRe: [UnsafeMutablePointer<Float>]        // per channel frequency-domain delay line
    private let fdlIm: [UnsafeMutablePointer<Float>]
    private var fdlPos = 0
    private let accRe = UnsafeMutablePointer<Float>.allocate(capacity: GroupDelay.bins)
    private let accIm = UnsafeMutablePointer<Float>.allocate(capacity: GroupDelay.bins)
    private let time  = UnsafeMutablePointer<Float>.allocate(capacity: GroupDelay.fftN)
    private let prevOut = UnsafeMutablePointer<Float>.allocate(capacity: GroupDelay.block)

    init() {
        func buf(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        inBlock  = [buf(Self.fftN), buf(Self.fftN)]
        outBlock = [buf(Self.block), buf(Self.block)]
        fdlRe = [buf(Self.partitions * Self.bins), buf(Self.partitions * Self.bins)]
        fdlIm = [buf(Self.partitions * Self.bins), buf(Self.partitions * Self.bins)]

        let t = DispatchSource.makeTimerSource(queue: paramQueue)
        t.schedule(deadline: .now() + Self.modTick, repeating: Self.modTick)
        t.setEventHandler { [weak self] in self?.modStep() }
        t.resume()
        modTimer = t
    }

    deinit {
        modTimer?.cancel()
        vDSP_destroy_fftsetup(fftSetup)
        for p in inBlock + outBlock + fdlRe + fdlIm { p.deallocate() }
        accRe.deallocate(); accIm.deallocate(); time.deallocate(); prevOut.deallocate()
    }

    func setSampleRate(_ sr: Double) {
        lock.lock()
        if sr > 0 { sampleRate = sr }
        lock.unlock()
    }

    /// scale: multiplier on one period of delay (0…20).
    func setScale(_ scale: Double) {
        paramQueue.async { [weak self] in
            guard let self else { return }
            self.baseScale = max(0, min(20, scale))
            self.applyModulated()
        }
    }

    /// randomness: max deviation as a fraction of the scale (0…0.5).
    func setRandomness(_ r: Double) {
        paramQueue.async { [weak self] in
            guard let self else { return }
            self.randomness = max(0, min(0.5, r))
            self.applyModulated()
        }
    }

    private func modOffset() -> Double {
        let t = min(1, modElapsed / modDuration)
        let eased = t * t * (3 - 2 * t)       // smoothstep: zero slope at both ends
        return modFrom + (modTo - modFrom) * eased
    }

    private func modStep() {
        modElapsed += Self.modTick
        if modElapsed >= modDuration {
            modFrom = modTo
            modTo = Double.random(in: -1...1)
            modElapsed = 0
            modDuration = Double.random(in: 3...6)
        }
        applyModulated()
    }

    private func applyModulated() {
        apply(scale: baseScale * (1 + randomness * modOffset()))
    }

    private func apply(scale: Double) {
        let s = max(0, min(Self.maxScale, scale))
        // Skip redundant redesigns (macro drags fire this on every event).
        guard abs(s - currentScale) > 1e-4 else { return }
        currentScale = s

        lock.lock()
        let sr = sampleRate
        lock.unlock()
        let spectra: Spectra? = s < 1e-4 ? nil : design(scale: s, sampleRate: sr)
        lock.lock()
        pending = spectra
        pendingGen &+= 1
        let old = retired
        retired = nil
        lock.unlock()
        _ = old   // any spectra the audio thread retired are freed here, off the audio thread
    }

    // MARK: - Design

    /// Deterministic smear offset in -1…1 for frequency f: seeded random
    /// values every 1/12 octave from 20 Hz, cosine-interpolated between.
    private static let smearTable: [Double] = {
        var state: UInt64 = 0x9E3779B97F4A7C15
        return (0..<200).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
    }()

    private static func smear(_ f: Double) -> Double {
        let pos = max(0, log2(max(f, floorHz) / floorHz) * smearStepsPerOctave)
        let i = min(Int(pos), smearTable.count - 2)
        let t = pos - Double(i)
        let w = 0.5 - 0.5 * cos(Double.pi * t)
        return smearTable[i] * (1 - w) + smearTable[i + 1] * w
    }

    /// Delay in seconds at frequency f.
    private static func tau(_ f: Double, scale: Double) -> Double {
        let base = scale / max(f, floorHz)
        return min(maxDelaySec, base * (1 + smearAmount * smear(f)))
    }

    private func design(scale: Double, sampleRate sr: Double) -> Spectra {
        let n = Self.taps
        let df = sr / Double(n)
        let bulkSec = Double(Self.bulkDelay) / sr

        // φ(f) = -2π ∫₀^f τ(f') df', integrated numerically bin by bin.
        var re = [Float](repeating: 0, count: n)
        var im = [Float](repeating: 0, count: n)
        var phi = 0.0
        re[0] = 1
        for k in 1...(n / 2) {
            let fMid = (Double(k) - 0.5) * df
            phi -= 2 * Double.pi * (Self.tau(fMid, scale: scale) + bulkSec) * df
            if k == n / 2 {
                re[k] = Float(cos(phi))          // Nyquist bin must be real
            } else {
                re[k] = Float(cos(phi)); im[k] = Float(sin(phi))
                re[n - k] = re[k];       im[n - k] = -im[k]   // Hermitian
            }
        }

        var h = [Float](repeating: 0, count: n)
        var hIm = [Float](repeating: 0, count: n)
        if let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .INVERSE) {
            vDSP_DFT_Execute(setup, re, im, &h, &hIm)
            vDSP_DFT_DestroySetup(setup)
        }
        // 1/n for the inverse DFT, and 1/(4·fftN) for the zrip round trip
        // (forward ×2 on each operand, unnormalized inverse ×fftN).
        var norm = 1 / Float(n) / Float(4 * Self.fftN)
        vDSP_vsmul(h, 1, &norm, &h, 1, vDSP_Length(n))
        for i in 0..<Self.fadeTaps {
            let w = 0.5 * (1 + cos(Double.pi * Double(i + 1) / Double(Self.fadeTaps)))
            h[n - Self.fadeTaps + i] *= Float(w)
        }

        // Partition: spectrum of [h_p (block samples), zeros (block)].
        let spectra = Spectra()
        var frame = [Float](repeating: 0, count: Self.fftN)
        for p in 0..<Self.partitions {
            for i in 0..<Self.block { frame[i] = h[p * Self.block + i] }
            for i in Self.block..<Self.fftN { frame[i] = 0 }
            var split = DSPSplitComplex(realp: spectra.re + p * Self.bins,
                                        imagp: spectra.im + p * Self.bins)
            frame.withUnsafeBufferPointer { fp in
                fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.bins) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.bins))
                }
            }
            vDSP_fft_zrip(fftSetup, &split, 1, Self.log2N, FFTDirection(kFFTDirection_Forward))
        }
        return spectra
    }

    // MARK: - Audio thread

    /// Stereo, in place. Output lags input by `block` samples (+ bulkDelay).
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        let B = Self.block
        for i in 0..<count {
            let l = left[i]
            let r = right?[i] ?? l
            left[i] = outBlock[0][fill]
            right?[i] = outBlock[1][fill]
            inBlock[0][B + fill] = l
            inBlock[1][B + fill] = r
            fill += 1
            if fill == B {
                processBlock()
                fill = 0
            }
        }
    }

    private func processBlock() {
        lock.lock()
        let newSpectra = pending
        let newGen = pendingGen
        lock.unlock()

        let changed = newGen != activeGen
        let oldSpectra = active
        fdlPos = (fdlPos + 1) % Self.partitions

        for ch in 0..<2 {
            // Forward FFT of the last 2·block input samples into the FDL.
            var x = DSPSplitComplex(realp: fdlRe[ch] + fdlPos * Self.bins,
                                    imagp: fdlIm[ch] + fdlPos * Self.bins)
            inBlock[ch].withMemoryRebound(to: DSPComplex.self, capacity: Self.bins) {
                vDSP_ctoz($0, 2, &x, 1, vDSP_Length(Self.bins))
            }
            vDSP_fft_zrip(fftSetup, &x, 1, Self.log2N, FFTDirection(kFFTDirection_Forward))

            if changed {
                convolve(ch, oldSpectra, into: prevOut)
                convolve(ch, newSpectra, into: outBlock[ch])
                let B = Self.block
                for i in 0..<B {
                    let t = Float(i + 1) / Float(B)
                    outBlock[ch][i] = prevOut[i] + (outBlock[ch][i] - prevOut[i]) * t
                }
            } else {
                convolve(ch, newSpectra, into: outBlock[ch])
            }

            // Slide: current block becomes "previous" half of the next frame.
            (inBlock[ch]).assign(from: inBlock[ch] + Self.block, count: Self.block)
        }

        if changed {
            lock.lock()
            if retired == nil { retired = oldSpectra }   // freed on the param thread
            lock.unlock()
            active = newSpectra
            activeGen = newGen
        }
    }

    /// One block of output for channel `ch` through `spectra` (nil = identity).
    private func convolve(_ ch: Int, _ spectra: Spectra?, into out: UnsafeMutablePointer<Float>) {
        let B = Self.block, K = Self.bins
        guard let spectra else {
            // Identity: match the designed filter's bulk latency exactly.
            out.assign(from: inBlock[ch] + (B - Self.bulkDelay), count: B)
            return
        }

        vDSP_vclr(accRe, 1, vDSP_Length(K))
        vDSP_vclr(accIm, 1, vDSP_Length(K))
        var acc = DSPSplitComplex(realp: accRe + 1, imagp: accIm + 1)
        var dc: Float = 0, nyq: Float = 0
        for p in 0..<Self.partitions {
            let slot = (fdlPos - p + Self.partitions) % Self.partitions
            let xr = fdlRe[ch] + slot * K, xi = fdlIm[ch] + slot * K
            let hr = spectra.re + p * K,   hi = spectra.im + p * K
            // Packed bin 0 holds DC (real) and Nyquist (imag) — both real.
            dc  += xr[0] * hr[0]
            nyq += xi[0] * hi[0]
            var x = DSPSplitComplex(realp: xr + 1, imagp: xi + 1)
            var h = DSPSplitComplex(realp: hr + 1, imagp: hi + 1)
            vDSP_zvma(&x, 1, &h, 1, &acc, 1, &acc, 1, vDSP_Length(K - 1))
        }
        accRe[0] = dc
        accIm[0] = nyq

        var y = DSPSplitComplex(realp: accRe, imagp: accIm)
        vDSP_fft_zrip(fftSetup, &y, 1, Self.log2N, FFTDirection(kFFTDirection_Inverse))
        time.withMemoryRebound(to: DSPComplex.self, capacity: K) {
            vDSP_ztoc(&y, 1, $0, 2, vDSP_Length(K))
        }
        // Overlap-save: the second half is the valid linear-convolution output.
        out.assign(from: time + B, count: B)
    }
}
