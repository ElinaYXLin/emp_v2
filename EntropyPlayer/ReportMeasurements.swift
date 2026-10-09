import Foundation

// Offline measurements for the Listener Report. Fresh DSP instances,
// configured like the live chain, so measuring never disturbs playback.
//
// Why more than THD: a single sine's THD saturates as clipping gets harder —
// the waveform tends toward a square wave, whose THD is only ~48% (harmonics
// fall as 1/n) — so "maxed out and unlistenable" still reads ~50–60%. What
// actually wrecks music is (1) intermodulation: many notes clipping together
// make new, non-harmonic tones, (2) aliasing: harmonics above Nyquist fold
// back out of tune, and (3) time smear from the haze effects. Hence:
//
//   • THD            harmonics 2–10 of one tone ÷ fundamental (the classic spec)
//   • THD+N          everything that isn't the fundamental (catches aliasing)
//   • Multitone IMD  five non-harmonic tones at once; share of output power
//                    that is new frequencies — closest to "how mushy music gets"
//   • Smear          a click through the haze chain → C50 clarity (energy in
//                    the first 50 ms vs after, room-acoustics standard) and
//                    centre time (energy's centre of gravity after arrival)

struct ChainSettings {
    var fileTrimDb = 0.0        // fixed local-file trim (export only)
    var preampDb = 0.0
    var postGainDb = 0.0        // export only
    var gdRandom = 0.0          // export only
    var eqDb = 0.0
    var evenDb = 0.0, oddDb = 0.0
    var recipe = SaturatorRecipe.classic
    var hysteresis = 0.0, sag = 0.0
    var rolloff = 0.0
    var compressor = false
    // Haze
    var gdScale = 0.0
    var blur = 0.0
    var grain = 0.0
    var reverbDecaySec = 0.0
    var shimmer = 0.0
}

struct Measurements {
    let thd100: Double, thd1k: Double          // %
    let h2: Double, h3: Double                 // 100 Hz harmonic amplitudes
    let thdn100: Double, thdn1k: Double        // %
    let imdPercent: Double                     // % of output power that is non-input frequencies
    let c50Db: Double                          // clarity, dB (∞ when nothing lands after 50 ms)
    let centerTimeMs: Double
}

enum ReportMeasurer {
    static let sr = 44100.0

    // MARK: Color chain (the nonlinear part) — mono

    private static func renderColor(_ s: ChainSettings, _ input: [Float]) -> [Float] {
        let n = input.count
        let eq = PeakingBiquad(); eq.setParameters(frequency: 150, q: 0.1, gainDb: s.eqDb)
        let ss = SubsonicFilter()
        let rs = RecipeStage(); rs.configure(s.recipe, amount: (s.evenDb + s.oddDb) / 16)
        let ev = WebAudioSaturator(voicing: .even)
        ev.setDrive(driveDb: min(24, s.evenDb * s.recipe.evenMul)); ev.setBias(s.recipe.bias)
        let od = WebAudioSaturator(voicing: .odd); od.setDrive(driveDb: min(24, s.oddDb * s.recipe.oddMul))
        let th = TapeHysteresis(); th.setStrength(s.hysteresis)
        let sg = TapeSag(); sg.setStrength(s.sag)
        let ro = HighRolloff(); ro.setSlope(dbPerOctave: s.rolloff)
        let dyn = WebAudioCompressor(); dyn.setSampleRate(sr)
        if s.compressor {
            dyn.configure(thresholdDb: -18, kneeDb: 12, ratio: 4, attackSec: 0.01, releaseSec: 0.25, trimDb: -12)
        } else {
            dyn.configure(thresholdDb: 0, kneeDb: 0, ratio: 20, attackSec: 0.001, releaseSec: 0.1, trimDb: -6)
        }
        let fixedDrive = Float(pow(10, 7.0 / 20))
        let gain = Float(pow(10, s.preampDb / 20)) * fixedDrive           // pre-amp + fixed drive
        var x = input.map { $0 * gain }
        x.withUnsafeMutableBufferPointer { b in
            let p = b.baseAddress!
            var i = 0
            while i < n {                                   // realistic callback-sized blocks
                let c = min(470, n - i), q = p + i
                eq.process(q, count: c, channel: 0)
                ss.process(q, count: c, channel: 0)
                rs.pre(q, count: c, channel: 0)
                ev.process(q, count: c, channel: 0)
                od.process(q, count: c, channel: 0)
                rs.post(q, count: c, channel: 0)
                th.process(q, count: c, channel: 0)
                sg.process(left: q, right: nil, count: c)
                for j in 0..<c { q[j] /= fixedDrive }     // fixed +7 dB is undone after the saturation stage
                ro.process(q, count: c, channel: 0)
                dyn.process(left: q, right: nil, count: c)
                i += c
            }
        }
        return x
    }

    // MARK: Haze chain (the temporal part) — stereo in, mid out

    private static func renderHaze(_ s: ChainSettings, _ input: [Float]) -> [Float] {
        let n = input.count
        let gd = GroupDelay(); gd.setScale(s.gdScale); gd.flushParameters()
        let bl = SpectralBlur(); bl.setStrength(s.blur)
        let gr = GrainEcho(); gr.setStrength(s.grain)
        let rv = ConvolutionReverb(); rv.setDecay(s.reverbDecaySec)
        let sh = Shimmer(); sh.setStrength(s.shimmer)
        var l = input, r = input
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                var i = 0
                while i < n {
                    let c = min(470, n - i), a = lb.baseAddress! + i, b = rb.baseAddress! + i
                    gd.process(left: a, right: b, count: c)
                    bl.process(left: a, right: b, count: c)
                    gr.process(left: a, right: b, count: c)
                    rv.process(left: a, right: b, count: c)
                    sh.process(left: a, right: b, count: c)
                    i += c
                }
            }
        }
        return (0..<n).map { (l[$0] + r[$0]) * 0.5 }
    }

    // MARK: Analysis helpers

    /// Amplitude of an integer-Hz sinusoid over [from, to) — exact bin for 1 s windows.
    private static func amplitude(_ x: [Float], _ f: Double, from: Int, to: Int) -> Double {
        var re = 0.0, im = 0.0
        for i in from..<to {
            let w = 2 * Double.pi * f * Double(i) / sr
            re += Double(x[i]) * cos(w); im += Double(x[i]) * sin(w)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(to - from)
    }

    private static func meanSquare(_ x: [Float], from: Int, to: Int) -> Double {
        var e = 0.0, mean = 0.0
        for i in from..<to { mean += Double(x[i]) }
        mean /= Double(to - from)
        for i in from..<to { let v = Double(x[i]) - mean; e += v * v }
        return e / Double(to - from)
    }

    // MARK: Measurements

    static func measure(_ s: ChainSettings) -> Measurements {
        let n = Int(sr) * 2, a = n / 2          // 1 s settle, analyze the 2nd second

        func toneTest(_ f: Double) -> (thd: Double, thdn: Double, h2: Double, h3: Double) {
            // −6 dB re a full-scale input.
            let x = (0..<n).map { Float(0.5 * sin(2 * Double.pi * f * Double($0) / sr)) }
            let y = renderColor(s, x)
            let h1 = amplitude(y, f, from: a, to: n)
            var sum = 0.0, h2 = 0.0, h3 = 0.0
            for k in 2...10 where f * Double(k) < sr / 2 {
                let hk = amplitude(y, f * Double(k), from: a, to: n)
                if k == 2 { h2 = hk }; if k == 3 { h3 = hk }
                sum += hk * hk
            }
            let residual = max(0, meanSquare(y, from: a, to: n) - h1 * h1 / 2)
            let fundRMS = h1 / 2.0.squareRoot()
            return (h1 > 0 ? sum.squareRoot() / h1 * 100 : 0,
                    fundRMS > 0 ? residual.squareRoot() / fundRMS * 100 : 0, h2, h3)
        }
        let t100 = toneTest(100), t1k = toneTest(1000)

        // Multitone: five non-harmonically related tones, same −6 dB peak budget.
        let tones: [Double] = [67, 223, 587, 1409, 3163]
        let each = 0.5 / Double(tones.count) * 1.6        // crest-factor allowance
        let mt = (0..<n).map { i -> Float in
            let t = Double(i) / sr
            return Float(tones.enumerated().reduce(0) { acc, e in
                acc + each * sin(2 * Double.pi * e.element * t + Double(e.offset) * 1.1) })
        }
        let ym = renderColor(s, mt)
        let total = meanSquare(ym, from: a, to: n)
        let toneEnergy = tones.reduce(0) { acc, f in let A = amplitude(ym, f, from: a, to: n); return acc + A * A / 2 }
        let imd = total > 0 ? max(0, total - toneEnergy) / total * 100 : 0

        // Smear: a click (after 0.5 s of silence so effect glides settle) through the haze chain.
        let pre = Int(sr / 2), len = Int(sr * 3.5)
        var click = [Float](repeating: 0, count: len); click[pre] = 0.5
        let h = renderHaze(s, click)
        let e = h.map { Double($0) * Double($0) }
        let peak = h.map { abs($0) }.max() ?? 0
        let t0 = h.firstIndex { abs($0) >= 0.1 * peak } ?? pre       // arrival (after all latencies)
        let w50 = Int(0.050 * sr)
        let early = e[t0..<min(len, t0 + w50)].reduce(0, +)
        let late = t0 + w50 < len ? e[(t0 + w50)...].reduce(0, +) : 0
        let c50 = late > 0 ? 10 * log10(early / late) : Double.infinity
        var num = 0.0, den = 0.0
        for i in t0..<len { num += Double(i - t0) * e[i]; den += e[i] }
        let ts = den > 0 ? num / den / sr * 1000 : 0

        return Measurements(thd100: t100.thd, thd1k: t1k.thd, h2: t100.h2, h3: t100.h3,
                            thdn100: t100.thdn, thdn1k: t1k.thdn, imdPercent: imd,
                            c50Db: c50, centerTimeMs: ts)
    }
}
