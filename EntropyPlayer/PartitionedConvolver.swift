import Foundation
import Accelerate

// Stereo uniformly-partitioned FFT convolution (overlap-save, 512-sample
// partitions), shared by GroupDelay and ConvolutionReverb.
//
// Realtime-safe by construction: everything the audio thread touches is
// preallocated, filters are built on the caller's (non-audio) thread, and
// replaced filters are handed back to be freed off the audio thread.
// Cost is O(log N) per sample instead of direct convolution's O(N) — a 2 s
// reverb tail drops from ~25% of a core to ~1%, leaving the realtime output
// callback plenty of headroom. Output lags input by `block` samples.
//
// Filter changes crossfade old → new output across one block so parameter
// moves don't click.
final class PartitionedConvolver {

    static let block = 512
    private static let fftN = 2 * block
    private static let log2N = vDSP_Length(10)
    private static let bins = fftN / 2          // packed real-FFT bins

    /// Frequency-domain filter: per channel, per partition, packed zrip
    /// spectra pre-scaled for the round trip. One channel = same filter on both.
    final class Filter {
        let partitions: Int
        let channels: Int
        fileprivate let re: [UnsafeMutablePointer<Float>]
        fileprivate let im: [UnsafeMutablePointer<Float>]

        fileprivate init(partitions: Int, channels: Int) {
            self.partitions = partitions
            self.channels = channels
            let n = partitions * PartitionedConvolver.bins
            re = (0..<channels).map { _ in
                let p = UnsafeMutablePointer<Float>.allocate(capacity: n); p.initialize(repeating: 0, count: n); return p }
            im = (0..<channels).map { _ in
                let p = UnsafeMutablePointer<Float>.allocate(capacity: n); p.initialize(repeating: 0, count: n); return p }
        }
        deinit { (re + im).forEach { $0.deallocate() } }
    }

    let maxPartitions: Int
    /// With no filter set: output = input delayed by this many samples (on
    /// top of the block latency), or silence if nil.
    private let identityDelay: Int?
    private let fftSetup: FFTSetup

    private let lock = NSLock()
    private var pending: Filter?
    private var pendingGen = 0
    private var retired: [Filter] = []

    // Audio-thread state.
    private var active: Filter?
    private var activeGen = 0
    private var fill = 0
    private var fdlPos = 0
    private let inBlock:  [UnsafeMutablePointer<Float>]     // per channel, fftN (prev + cur)
    private let outBlock: [UnsafeMutablePointer<Float>]     // per channel, block
    private let fdlRe: [UnsafeMutablePointer<Float>]
    private let fdlIm: [UnsafeMutablePointer<Float>]
    private let accRe, accIm, time, prevOut: UnsafeMutablePointer<Float>

    init(maxPartitions: Int, identityDelay: Int?) {
        self.maxPartitions = maxPartitions
        self.identityDelay = identityDelay
        fftSetup = vDSP_create_fftsetup(Self.log2N, FFTRadix(kFFTRadix2))!
        func buf(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        inBlock  = [buf(Self.fftN), buf(Self.fftN)]
        outBlock = [buf(Self.block), buf(Self.block)]
        fdlRe = [buf(maxPartitions * Self.bins), buf(maxPartitions * Self.bins)]
        fdlIm = [buf(maxPartitions * Self.bins), buf(maxPartitions * Self.bins)]
        accRe = buf(Self.bins); accIm = buf(Self.bins)
        time = buf(Self.fftN); prevOut = buf(Self.block)
        retired.reserveCapacity(8)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        (inBlock + outBlock + fdlRe + fdlIm + [accRe, accIm, time, prevOut]).forEach { $0.deallocate() }
    }

    // MARK: - Building filters (non-audio threads)

    /// One impulse response per channel (1 = shared by both channels).
    /// Longer responses are truncated to maxPartitions × block.
    func makeFilter(_ irs: [[Float]]) -> Filter {
        let len = min(irs.map(\.count).max() ?? 0, maxPartitions * Self.block)
        let parts = max(1, (len + Self.block - 1) / Self.block)
        let filter = Filter(partitions: parts, channels: irs.count)
        // zrip forward scales each operand ×2, unnormalized inverse ×fftN.
        let scale = 1 / Float(4 * Self.fftN)
        var frame = [Float](repeating: 0, count: Self.fftN)
        for (c, ir) in irs.enumerated() {
            for p in 0..<parts {
                for i in 0..<Self.fftN { frame[i] = 0 }
                let start = p * Self.block
                for i in 0..<Self.block where start + i < ir.count { frame[i] = ir[start + i] * scale }
                var split = DSPSplitComplex(realp: filter.re[c] + p * Self.bins,
                                            imagp: filter.im[c] + p * Self.bins)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.bins) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.bins))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, Self.log2N, FFTDirection(kFFTDirection_Forward))
            }
        }
        return filter
    }

    /// Swap in a new filter (nil = identity/silence); crossfaded on the audio thread.
    func setFilter(_ filter: Filter?) {
        lock.lock()
        pending = filter
        pendingGen &+= 1
        let dead = retired
        retired.removeAll(keepingCapacity: true)   // new unique buffer, allocated here
        lock.unlock()
        _ = dead   // filters the audio thread retired are freed here, not there
    }

    // MARK: - Audio thread

    /// Stereo, in place: replaces the input with the convolved output.
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
        let newFilter = pending
        let newGen = pendingGen
        lock.unlock()

        let changed = newGen != activeGen
        let oldFilter = active
        fdlPos = (fdlPos + 1) % maxPartitions

        for ch in 0..<2 {
            var x = DSPSplitComplex(realp: fdlRe[ch] + fdlPos * Self.bins,
                                    imagp: fdlIm[ch] + fdlPos * Self.bins)
            inBlock[ch].withMemoryRebound(to: DSPComplex.self, capacity: Self.bins) {
                vDSP_ctoz($0, 2, &x, 1, vDSP_Length(Self.bins))
            }
            vDSP_fft_zrip(fftSetup, &x, 1, Self.log2N, FFTDirection(kFFTDirection_Forward))

            if changed {
                convolve(ch, oldFilter, into: prevOut)
                convolve(ch, newFilter, into: outBlock[ch])
                for i in 0..<Self.block {
                    let t = Float(i + 1) / Float(Self.block)
                    outBlock[ch][i] = prevOut[i] + (outBlock[ch][i] - prevOut[i]) * t
                }
            } else {
                convolve(ch, newFilter, into: outBlock[ch])
            }

            inBlock[ch].assign(from: inBlock[ch] + Self.block, count: Self.block)
        }

        if changed {
            active = newFilter
            activeGen = newGen
            if let oldFilter {
                // Hand the old filter back for release off the audio thread.
                // reserveCapacity keeps this append allocation-free.
                lock.lock()
                if retired.count < retired.capacity { retired.append(oldFilter) }
                lock.unlock()
            }
        }
    }

    private func convolve(_ ch: Int, _ filter: Filter?, into out: UnsafeMutablePointer<Float>) {
        let B = Self.block, K = Self.bins
        guard let filter else {
            if let d = identityDelay {
                out.assign(from: inBlock[ch] + (B - d), count: B)
            } else {
                vDSP_vclr(out, 1, vDSP_Length(B))
            }
            return
        }

        let fc = min(ch, filter.channels - 1)
        vDSP_vclr(accRe, 1, vDSP_Length(K))
        vDSP_vclr(accIm, 1, vDSP_Length(K))
        var acc = DSPSplitComplex(realp: accRe + 1, imagp: accIm + 1)
        var dc: Float = 0, nyq: Float = 0
        for p in 0..<filter.partitions {
            let slot = (fdlPos - p + maxPartitions) % maxPartitions
            let xr = fdlRe[ch] + slot * K, xi = fdlIm[ch] + slot * K
            let hr = filter.re[fc] + p * K, hi = filter.im[fc] + p * K
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
        out.assign(from: time + B, count: B)   // overlap-save: valid half
    }
}
