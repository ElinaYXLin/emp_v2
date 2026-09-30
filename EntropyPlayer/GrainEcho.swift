import Foundation

// Grain Echo: granular "memory" haze. Short overlapping grains are replayed
// from the last `memory` milliseconds of audio — each starting at a random
// point in that window, detuned (±4 → ±35 cents with strength), Hann-windowed and
// panned somewhere across the stereo field — and mixed quietly under the dry
// signal. It sounds like the music echoing back from a memory.
//
// One strength control (0…1) scales how loud the haze is (up to as loud as
// the dry signal), how far back it reaches (up to 200 ms) and how detuned
// the grains are (up to ±35 cents), together. Memory stays capped at 200 ms
// — longer windows mean longer grains and more overlapping voices.
//
// Realtime-safe: fixed voice pool and buffers, a tiny xorshift RNG, no locks
// beyond reading the parameter, no allocation on the audio thread.
final class GrainEcho {

    private static let sampleRate = 44100.0
    private static let maxMemorySec = 0.200
    private static let maxMixDb = 0.0
    private static let fullScaleGain = 1.388   // measured: puts full strength at maxMixDb
    private static let minDetuneCents = 4.0
    private static let maxDetuneCents = 35.0
    private static let overlap = 4.0
    private static let bufSize = 1 << 14            // ~370 ms
    private static let voiceCount = 12

    private let lock = NSLock()
    private var targetStrength: Double = 0

    // Audio-thread state.
    private let bufL = UnsafeMutablePointer<Float>.allocate(capacity: GrainEcho.bufSize)
    private let bufR = UnsafeMutablePointer<Float>.allocate(capacity: GrainEcho.bufSize)
    private var writeIdx = 0
    private var strength: Double = 0                // smoothed
    private var untilNextGrain: Double = 0
    private var rng: UInt64 = 0x2545F4914F6CDD1D

    private struct Voice {
        var active = false
        var pos: Double = 0          // absolute read position (samples)
        var rate: Double = 1
        var phase: Double = 0        // 0…1 through the grain
        var phaseInc: Double = 0
        var gainL: Float = 0
        var gainR: Float = 0
    }
    private var voices = [Voice](repeating: Voice(), count: GrainEcho.voiceCount)

    init() {
        bufL.initialize(repeating: 0, count: Self.bufSize)
        bufR.initialize(repeating: 0, count: Self.bufSize)
    }

    deinit {
        bufL.deallocate()
        bufR.deallocate()
    }

    /// strength: 0 (off) … 1 (200 ms memory, loudest haze).
    func setStrength(_ s: Double) {
        lock.lock()
        targetStrength = max(0, min(1, s))
        lock.unlock()
    }

    // MARK: - Audio thread

    @inline(__always) private func random() -> Double {   // 0..<1
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Double(rng >> 11) / Double(1 << 53)
    }

    private func spawnGrain(memory: Double, detune: Double) {
        guard let v = voices.firstIndex(where: { !$0.active }) else { return }
        let grainLen = Self.grainLength(memory: memory)
        let cents = (random() * 2 - 1) * detune
        let rate = pow(2, cents / 1200)
        // Start somewhere in the memory window, far enough back that a
        // slightly-fast grain can't overtake the write head.
        let minBack = grainLen * max(0, rate - 1) + 8
        let back = minBack + random() * max(1, memory - minBack)
        let pan = random() * 2 - 1                         // −1…1
        let angle = (pan + 1) * Double.pi / 4              // equal-power
        voices[v] = Voice(active: true,
                          pos: Double(writeIdx) - back,
                          rate: rate,
                          phase: 0,
                          phaseInc: 1 / grainLen,
                          gainL: Float(cos(angle)),
                          gainR: Float(sin(angle)))
    }

    /// Grain length in samples: 30 ms plus a quarter of the memory window.
    private static func grainLength(memory: Double) -> Double {
        0.030 * sampleRate + memory * 0.25
    }

    @inline(__always) private func read(_ b: UnsafeMutablePointer<Float>, _ pos: Double) -> Float {
        let i = Int(floor(pos))
        let t = Float(pos - Double(i))
        let mask = Self.bufSize - 1
        let a = b[i & mask], c = b[(i &+ 1) & mask]
        return a + (c - a) * t
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, count: Int) {
        lock.lock()
        let target = targetStrength
        lock.unlock()

        let mask = Self.bufSize - 1
        let smooth = 1 - exp(-1 / (0.05 * Self.sampleRate))   // ~50 ms parameter glide
        let idle = target == 0 && strength < 1e-4 && !voices.contains(where: \.active)

        for i in 0..<count {
            let l = left[i]
            let r = right?[i] ?? l
            bufL[writeIdx & mask] = l
            bufR[writeIdx & mask] = r
            writeIdx &+= 1
            if idle { continue }

            strength += (target - strength) * smooth
            let memory = strength * Self.maxMemorySec * Self.sampleRate
            // Volume scales with strength (linear in amplitude, so it fades
            // fully to silence at 0), peaking at maxMixDb.
// Measured calibration: at this gain, full strength puts the haze at
            // maxMixDb (−6 dB) re the dry signal on broadband material.
            let mix = Float(strength * Self.fullScaleGain)

            untilNextGrain -= 1
            if untilNextGrain <= 0 && strength > 1e-3 {
                spawnGrain(memory: memory,
                           detune: Self.minDetuneCents + (Self.maxDetuneCents - Self.minDetuneCents) * strength)
                let hop = Self.grainLength(memory: memory) / Self.overlap
                untilNextGrain = hop * (0.7 + random() * 0.6)
            }

            var outL: Float = 0, outR: Float = 0
            for v in 0..<voices.count where voices[v].active {
                let ph = voices[v].phase
                let w = Float(sin(Double.pi * ph)); let win = w * w      // Hann
                let s = (read(bufL, voices[v].pos) + read(bufR, voices[v].pos)) * 0.5 * win
                outL += s * voices[v].gainL
                outR += s * voices[v].gainR
                voices[v].pos += voices[v].rate
                voices[v].phase = ph + voices[v].phaseInc
                if voices[v].phase >= 1 { voices[v].active = false }
            }

            // Level compensation (measured on pink noise): dry + haze would
            // otherwise sum up to ~4 dB louder at full strength.
            let comp = Float(1 / (1 + 1.45 * strength * strength).squareRoot())
            left[i] = (l + outL * mix) * comp
            right?[i] = (r + outR * mix) * comp
        }
        if idle { strength = 0 }
    }
}
