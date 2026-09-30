import Foundation

// Downward Shimmer: the (reverberated) signal is pitched down an octave,
// diffused, darkened and fed back into itself, building a warm, deep glow
// under the music — the inverse of the classic bright "shimmer" reverb,
// which tends to sound piercing. Each trip round the loop drops another
// octave; a 60 Hz high-pass and 2.5 kHz low-pass inside the loop keep the
// cascade from turning into rumble or fizz.
//
// One strength control (0…1) scales both how loud the glow is (up to 0 dB
// re dry) and how long it sustains: the diffused glow recirculates at its
// own pitch (sustain 0.40 → 0.90 per ~95 ms trip) and a
// smaller share (up to 0.08) goes back through the shifter for the next
// octave down. Their sum stays below 1, so the loop is always stable.
//
// Octave-down shifter: a delay line read by two taps whose delays ramp at
// 0.5 samples/sample (→ half speed), half a cycle apart, crossfaded with
// sin² windows that always sum to 1. Realtime-safe: fixed buffers only.
final class Shimmer {

    private static let sampleRate = 44100.0
    private static let maxMix = 1.0
    private static let window = 2048.0               // shifter window, ~46 ms
    private static let shiftSize = 1 << 13
    private static let apDelays: [[Int]] = [[556, 441, 341, 225], [579, 464, 356, 248]]
    private static let apGain: Float = 0.6
    private static let loopDelay = 2600              // ~59 ms before feeding back

    private let lock = NSLock()
    private var targetStrength: Double = 0
    private var strength: Double = 0

    private let shiftBuf = UnsafeMutablePointer<Float>.allocate(capacity: Shimmer.shiftSize)
    private var shiftWrite = 0
    private var shiftPhase = 0.0

    // Per channel: 4 allpasses + a loop delay.
    private let apBufs: [[UnsafeMutablePointer<Float>]]
    private var apIdx = [[Int]](repeating: [0, 0, 0, 0], count: 2)
    private let loopBuf: [UnsafeMutablePointer<Float>]
    private var loopIdx = 0

    private var lpState: Float = 0, hpState: Float = 0, hpPrev: Float = 0
    private let lpCoef = Float(1 - exp(-2 * Double.pi * 2500 / 44100))
    private let hpCoef = Float(exp(-2 * Double.pi * 60 / 44100))

    init() {
        func buf(_ c: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: c); p.initialize(repeating: 0, count: c); return p
        }
        shiftBuf.initialize(repeating: 0, count: Self.shiftSize)
        apBufs = Self.apDelays.map { $0.map { buf($0) } }
        loopBuf = [buf(Self.loopDelay), buf(Self.loopDelay)]
    }

    deinit {
        shiftBuf.deallocate()
        apBufs.flatMap { $0 }.forEach { $0.deallocate() }
        loopBuf.forEach { $0.deallocate() }
    }

    /// strength: 0 (off) … 1 (loud, long-sustaining glow).
    func setStrength(_ s: Double) {
        lock.lock()
        targetStrength = max(0, min(1, s))
        lock.unlock()
    }

    private func clear() {
        shiftBuf.assign(repeating: 0, count: Self.shiftSize)
        for (ch, bufs) in apBufs.enumerated() {
            for (a, b) in bufs.enumerated() { b.assign(repeating: 0, count: Self.apDelays[ch][a]) }
        }
        loopBuf.forEach { $0.assign(repeating: 0, count: Self.loopDelay) }
        lpState = 0; hpState = 0; hpPrev = 0
    }

    @inline(__always) private func readShift(_ delay: Double) -> Float {
        let pos = Double(shiftWrite) - delay
        let i = Int(floor(pos)), t = Float(pos - Double(i))
        let mask = Self.shiftSize - 1
        let a = shiftBuf[i & mask], b = shiftBuf[(i &+ 1) & mask]
        return a + (b - a) * t
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        lock.lock()
        let target = targetStrength
        lock.unlock()
        if target == 0 && strength < 1e-5 {                          // fully off: bypass
            if strength != 0 { clear() }                             // don't resurrect an old tail later
            strength = 0
            return
        }

        let glide = 1 - exp(-1 / (0.05 * Self.sampleRate))
        let mask = Self.shiftSize - 1
        let W = Self.window, slope = 0.5 / W          // phase advance per sample for ratio 0.5

        for i in 0..<count {
            strength += (target - strength) * glide
            let sustain = Float(0.40 + 0.50 * strength)
            let octaveFb = Float(0.08 * strength)
            let mix = Float(strength * Self.maxMix)

            let l = left[i], r = right?[i] ?? l
            // Loop input: dry mono + fed-back glow.
            let fbL = loopBuf[0][loopIdx], fbR = loopBuf[1][loopIdx]
            shiftBuf[shiftWrite & mask] = (l + r) * 0.5 + octaveFb * (fbL + fbR) * 0.5
            shiftWrite &+= 1

            // Octave-down shifter.
            let p1 = shiftPhase, p2 = (shiftPhase + 0.5).truncatingRemainder(dividingBy: 1)
            let g1 = Float(sin(Double.pi * p1)), g2 = Float(sin(Double.pi * p2))
            var y = readShift(4 + p1 * W) * g1 * g1 + readShift(4 + p2 * W) * g2 * g2
            shiftPhase += slope
            if shiftPhase >= 1 { shiftPhase -= 1 }

            // Darken + keep out of the sub-bass.
            lpState += lpCoef * (y - lpState)
            y = lpState
            let hp = hpCoef * (hpState + y - hpPrev)
            hpPrev = y; hpState = hp
            y = hp

            // Stereo diffusion (different allpass lengths per side).
            var outs: (Float, Float) = (y, y)
            for ch in 0..<2 {
                var v = (ch == 0 ? outs.0 : outs.1) + sustain * (ch == 0 ? fbL : fbR)
                for a in 0..<4 {
                    let b = apBufs[ch][a], len = Self.apDelays[ch][a]
                    let idx = apIdx[ch][a]
                    let delayed = b[idx]
                    let w = v + Self.apGain * delayed
                    b[idx] = w
                    v = delayed - Self.apGain * w
                    apIdx[ch][a] = idx + 1 == len ? 0 : idx + 1
                }
                if ch == 0 { outs.0 = v } else { outs.1 = v }
            }

            loopBuf[0][loopIdx] = outs.0
            loopBuf[1][loopIdx] = outs.1
            loopIdx = loopIdx + 1 == Self.loopDelay ? 0 : loopIdx + 1

            // Level compensation (measured on pink noise): the sustained glow
            // otherwise adds up to ~4.3 dB at full strength.
            let comp = Float(1 / (1 + 1.69 * pow(strength, 3.5)).squareRoot())
            left[i] = (l + outs.0 * mix) * comp
            right?[i] = (r + outs.1 * mix) * comp
        }
    }
}
