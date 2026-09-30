import Foundation
import Accelerate

// Spectral Blur ("nostalgia blur"): each frequency's level is slewed over
// time, so notes bloom in and dissolve out instead of starting and stopping
// crisply — music heard as a half-remembered version of itself.
//
// STFT (2048-point Hann, 75% overlap). Per bin, a smoothed magnitude follows
// the live magnitude with a slow attack (bloom) and a much slower release
// (linger); the output magnitude is interpolated from live toward smoothed
// by `strength`, which also scales both time constants. Live phase is kept
// wherever the bin has energy; where only the lingering magnitude remains
// (true silence), the bin gets a random phase each frame so the tail
// dissolves into a soft wash instead of vanishing.
//
// At strength 0 the output is the input exactly (the STFT still runs, so
// latency — 2048 samples, ~46 ms — stays constant and toggling never jumps).
// Realtime-safe: all buffers preallocated.
final class SpectralBlur {

    private static let n = 2048
    private static let hop = 512
    private static let bins = n / 2
    private static let log2n = vDSP_Length(11)
    private static let frameRate = 44100.0 / Double(hop)
    /// zrip round trip ×2N, Hann² overlap-add at 75% sums to 1.5.
    private static let outScale = 1 / (2 * Float(n) * 1.5)

    private let lock = NSLock()
    private var targetStrength: Double = 0

    private let fft = vDSP_create_fftsetup(SpectralBlur.log2n, FFTRadix(kFFTRadix2))!
    private let window: UnsafeMutablePointer<Float>
    private let inBuf:  [UnsafeMutablePointer<Float>]
    private let accum:  [UnsafeMutablePointer<Float>]
    private let ready:  [UnsafeMutablePointer<Float>]
    private let smooth: [UnsafeMutablePointer<Float>]
    private let phase:  [UnsafeMutablePointer<Float>]
    private let frame, re, im: UnsafeMutablePointer<Float>
    private var fill = 0
    private var strength: Double = 0
    private var rng: UInt64 = 0x9E3779B97F4A7C15

    init() {
        func buf(_ c: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: c); p.initialize(repeating: 0, count: c); return p
        }
        let n = Self.n, b = Self.bins
        window = buf(n)
        vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        inBuf  = [buf(n), buf(n)]
        accum  = [buf(n), buf(n)]
        ready  = [buf(Self.hop), buf(Self.hop)]
        smooth = [buf(b), buf(b)]
        phase  = [buf(b), buf(b)]
        frame = buf(n); re = buf(b); im = buf(b)
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
        (inBuf + accum + ready + smooth + phase + [window, frame, re, im]).forEach { $0.deallocate() }
    }

    /// strength: 0 (transparent) … 1 (heavy bloom, ~2.5 s linger).
    func setStrength(_ s: Double) {
        lock.lock()
        targetStrength = max(0, min(1, s))
        lock.unlock()
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        let H = Self.hop, N = Self.n
        for i in 0..<count {
            let l = left[i], r = right?[i] ?? l
            left[i] = ready[0][fill]
            right?[i] = ready[1][fill]
            inBuf[0][N - H + fill] = l
            inBuf[1][N - H + fill] = r
            fill += 1
            if fill == H {
                fill = 0
                lock.lock(); let target = targetStrength; lock.unlock()
                // Per-frame glide so knob moves don't step.
                strength += (target - strength) * 0.15
                processFrame(0)
                processFrame(1)
            }
        }
    }

    private func processFrame(_ ch: Int) {
        let N = Self.n, H = Self.hop, B = Self.bins
        let s = Float(strength)

        vDSP_vmul(inBuf[ch], 1, window, 1, frame, 1, vDSP_Length(N))
        var split = DSPSplitComplex(realp: re, imagp: im)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: B) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(B))
        }
        vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))

        if s > 1e-4 {
            let attackSec  = 0.05 + strength * 0.35
            let releaseSec = 0.10 + strength * 2.40
            let aAtk = Float(1 - exp(-1 / (attackSec * Self.frameRate)))
            let aRel = Float(1 - exp(-1 / (releaseSec * Self.frameRate)))
            let sm = smooth[ch], ph = phase[ch]
            // Bin 0 packs DC and Nyquist — left untouched.
            for k in 1..<B {
                let x = re[k], y = im[k]
                let m = (x * x + y * y).squareRoot()
                var st = sm[k]
                st += (m > st ? aAtk : aRel) * (m - st)
                sm[k] = st
                let out = m + s * (st - m)
                if m > 1e-9 {
                    let g = out / m
                    re[k] = x * g; im[k] = y * g
                    ph[k] = atan2f(y, x)
                } else {
                    // Only the lingering tail remains (true silence): give it a
                    // fresh random phase each frame so it dissolves into a soft
                    // wash. Continuing the last frame's phases instead replayed
                    // its time structure every hop — a buzzy click train with
                    // peaks several times the input's.
                    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
                    let p = Float(rng >> 40) / Float(1 << 24) * 2 * .pi
                    re[k] = out * cosf(p); im[k] = out * sinf(p)
                }
            }
        } else {
            // Keep state warm so turning it up blooms from the current spectrum.
            let sm = smooth[ch]
            for k in 1..<B { sm[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() }
        }

        vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Inverse))
        frame.withMemoryRebound(to: DSPComplex.self, capacity: B) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(B))
        }
        var scale = Self.outScale
        vDSP_vsmul(frame, 1, &scale, frame, 1, vDSP_Length(N))
        vDSP_vmul(frame, 1, window, 1, frame, 1, vDSP_Length(N))
        vDSP_vadd(accum[ch], 1, frame, 1, accum[ch], 1, vDSP_Length(N))

        // First hop of the accumulator is complete → next output block.
        ready[ch].assign(from: accum[ch], count: H)
        accum[ch].assign(from: accum[ch] + H, count: N - H)
        vDSP_vclr(accum[ch] + (N - H), 1, vDSP_Length(H))
        inBuf[ch].assign(from: inBuf[ch] + H, count: N - H)
    }
}
