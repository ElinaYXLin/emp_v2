import Foundation

// Saturator Recipes: named characters for the Color stage. A recipe doesn't
// replace the Even/Odd saturator knobs — those still set the amount — it
// changes what surrounds and flavours them:
//
//   pre-emphasis (low + high shelf) → even sat → odd sat → harmonic recipe
//   → de-emphasis (exact inverse shelves) → post tone (tilt + low shelf)
//
// • Emphasis: boosting a band before the saturators and cutting it by the
//   same amount after makes that band distort more (or less) while the
//   overall tone stays put — how tape's pre-emphasis flavours its grit.
// • Drive multipliers and the even saturator's tube bias set the balance
//   of the two existing saturators.
// • Harmonic recipe: Chebyshev waveshaping. T_k(cos θ) = cos kθ, so each
//   polynomial adds exactly the k-th harmonic of a full-scale tone, with
//   naturally less of it on quieter material. Scaled by how hard the
//   saturator knobs are driven, so a recipe never adds color at zero drive.
// • Post tone: a final tilt/low shelf that isn't undone (darker, fuller…).
//
// "Classic" is fully neutral — exactly the plain Even/Odd saturators.

struct SaturatorRecipe {
    let name: String
    let blurb: String
    var evenMul = 1.0, oddMul = 1.0      // × knob drive
    var bias = 0.5                       // even saturator bias (× envelope)
    var preLowDb = 0.0                   // 250 Hz low shelf into the saturators (undone after)
    var preHighDb = 0.0                  // 3 kHz high shelf into the saturators (undone after)
    var h2 = 0.0, h3 = 0.0, h4 = 0.0, h5 = 0.0   // Chebyshev harmonic weights
    var harmonicMix = 0.0
    var postHighDb = 0.0                 // 5 kHz high shelf after (kept)
    var postLowDb = 0.0                  // 120 Hz low shelf after (kept)

    static let classic = SaturatorRecipe(name: "Classic", blurb: "the plain even/odd saturators")

    static let all: [SaturatorRecipe] = [
        classic,
        // ── Classic studio characters ──
        .init(name: "Sweeten", blurb: "silky even harmonics on the upper mids",
              evenMul: 1.2, oddMul: 0.3, bias: 0.6, preLowDb: -3, preHighDb: 3,
              h2: 0.5, h4: 0.15, harmonicMix: 0.35, postHighDb: -1),
        .init(name: "Thicken", blurb: "denser low-mids, 2nd + 3rd on the body",
              evenMul: 1.3, oddMul: 0.8, bias: 0.55, preLowDb: 4, preHighDb: -2,
              h2: 0.4, h3: 0.25, harmonicMix: 0.3, postHighDb: -1, postLowDb: 1.5),
        .init(name: "Vintagize", blurb: "worn gear: gritty mids, softened top",
              evenMul: 1.1, oddMul: 0.7, bias: 0.5, preLowDb: 1, preHighDb: 2,
              h2: 0.3, h3: 0.2, h5: 0.05, harmonicMix: 0.25, postHighDb: -4, postLowDb: 1),
        .init(name: "Glow", blurb: "tube bloom that opens up when pushed",
              evenMul: 1.5, oddMul: 0.2, bias: 0.75, preHighDb: 1,
              h2: 0.45, harmonicMix: 0.2, postHighDb: -1),
        .init(name: "Velvet", blurb: "the softest saturation, lows untouched",
              evenMul: 0.7, oddMul: 0, bias: 0.6, preLowDb: -4, preHighDb: -1,
              h2: 0.3, harmonicMix: 0.15, postHighDb: -2),
        .init(name: "Silk", blurb: "airy, smooth top-end sheen",
              evenMul: 1.0, oddMul: 0.2, bias: 0.5, preLowDb: -2, preHighDb: 4,
              h2: 0.35, h4: 0.2, harmonicMix: 0.25, postHighDb: -2),
        .init(name: "Warmth", blurb: "round, cozy low-mids, gently darker",
              evenMul: 1.3, oddMul: 0.4, bias: 0.6, preLowDb: 2, preHighDb: -1,
              h2: 0.5, harmonicMix: 0.3, postHighDb: -2, postLowDb: 1),
        .init(name: "Punch", blurb: "console-style bite on the low end",
              evenMul: 0.9, oddMul: 1.1, bias: 0.45, preLowDb: 3,
              h2: 0.2, h3: 0.3, harmonicMix: 0.2),
        .init(name: "Crunch", blurb: "edgy odd harmonics, lo-fi attitude",
              evenMul: 0.6, oddMul: 1.6, bias: 0.3, preLowDb: -3, preHighDb: 4,
              h3: 0.4, h5: 0.2, harmonicMix: 0.35),
        // ── Emotional / nostalgic characters ──
        .init(name: "First Kiss", blurb: "sweet, breathless, a little shy",
              evenMul: 1.2, oddMul: 0.2, bias: 0.65, preLowDb: -1, preHighDb: 2,
              h2: 0.4, h4: 0.2, harmonicMix: 0.25, postHighDb: -1.5, postLowDb: 0.5),
        .init(name: "Rainy Sunday", blurb: "muted and warm, like a window fogged over",
              evenMul: 1.1, oddMul: 0.3, bias: 0.6, preLowDb: 1, preHighDb: -3,
              h2: 0.35, harmonicMix: 0.2, postHighDb: -3, postLowDb: 1),
        .init(name: "Old Photograph", blurb: "grainy mids, faded highlights",
              evenMul: 1.2, oddMul: 0.6, bias: 0.5, preHighDb: 2,
              h2: 0.3, h3: 0.2, harmonicMix: 0.3, postHighDb: -5, postLowDb: -1),
        .init(name: "Grandma's Kitchen", blurb: "thick, warm, smells like something baking",
              evenMul: 1.4, oddMul: 0.3, bias: 0.7, preLowDb: 3, preHighDb: -2,
              h2: 0.5, h4: 0.1, harmonicMix: 0.3, postHighDb: -2.5, postLowDb: 2),
        .init(name: "Campfire Crackle", blurb: "a bit of sparkle and smoke",
              evenMul: 1.0, oddMul: 1.0, bias: 0.5, preLowDb: 1, preHighDb: 3,
              h2: 0.3, h3: 0.3, h5: 0.1, harmonicMix: 0.35, postHighDb: -2, postLowDb: 1),
        .init(name: "Late Night Diner", blurb: "jukebox grit through a tired speaker",
              evenMul: 1.1, oddMul: 0.8, bias: 0.45, preLowDb: -2, preHighDb: 1,
              h2: 0.25, h3: 0.25, harmonicMix: 0.3, postHighDb: -3, postLowDb: -1),
        .init(name: "Honey & Smoke", blurb: "rich, slow, golden",
              evenMul: 1.5, oddMul: 0.5, bias: 0.7, preLowDb: 2,
              h2: 0.55, h3: 0.1, harmonicMix: 0.35, postHighDb: -3, postLowDb: 1.5),
        .init(name: "Faded Polaroid", blurb: "washed-out highs, soft grain",
              evenMul: 1.0, oddMul: 0.5, bias: 0.55, preLowDb: -1, preHighDb: 3,
              h2: 0.3, h3: 0.15, harmonicMix: 0.25, postHighDb: -6, postLowDb: -2),
        .init(name: "Summer '99", blurb: "boombox bravado, bright and bouncy",
              evenMul: 0.9, oddMul: 1.0, bias: 0.4, preLowDb: 2, preHighDb: 3,
              h2: 0.2, h3: 0.3, harmonicMix: 0.3, postHighDb: -1, postLowDb: 1),
        .init(name: "Lullaby", blurb: "hushed, rounded, nothing sharp",
              evenMul: 0.8, oddMul: 0, bias: 0.6, preLowDb: -2, preHighDb: -3,
              h2: 0.3, harmonicMix: 0.15, postHighDb: -4, postLowDb: 1),
    ]

    static func named(_ name: String) -> SaturatorRecipe {
        all.first { $0.name == name } ?? classic
    }
}

// MARK: - Shelf biquad

/// RBJ cookbook low/high shelf (slope S = 1), stereo, parameters swappable
/// from any thread.
final class ShelfBiquad {
    enum Kind { case low, high }
    private let kind: Kind
    private let freq: Double
    private let lock = NSLock()
    private var c = (b0: 1.0, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0)
    private var s = [[Double]](repeating: [0, 0, 0, 0], count: 2)   // x1 x2 y1 y2
    private(set) var isFlat = true

    init(_ kind: Kind, frequency: Double) {
        self.kind = kind
        self.freq = frequency
    }

    func setGain(db: Double, sampleRate sr: Double = 44100) {
        let A = pow(10, db / 40), w0 = 2 * Double.pi * freq / sr
        let cs = cos(w0), alpha = sin(w0) / 2 * 2.0.squareRoot(), sa = 2 * A.squareRoot() * alpha
        var b0, b1, b2, a0, a1, a2: Double
        switch kind {
        case .low:
            b0 = A * ((A + 1) - (A - 1) * cs + sa); b1 = 2 * A * ((A - 1) - (A + 1) * cs)
            b2 = A * ((A + 1) - (A - 1) * cs - sa); a0 = (A + 1) + (A - 1) * cs + sa
            a1 = -2 * ((A - 1) + (A + 1) * cs);     a2 = (A + 1) + (A - 1) * cs - sa
        case .high:
            b0 = A * ((A + 1) + (A - 1) * cs + sa); b1 = -2 * A * ((A - 1) + (A + 1) * cs)
            b2 = A * ((A + 1) + (A - 1) * cs - sa); a0 = (A + 1) - (A - 1) * cs + sa
            a1 = 2 * ((A - 1) - (A + 1) * cs);      a2 = (A + 1) - (A - 1) * cs - sa
        }
        lock.lock()
        c = (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
        isFlat = abs(db) < 1e-6
        lock.unlock()
    }

    func process(_ buf: UnsafeMutablePointer<Float>, count: Int, channel ch: Int) {
        lock.lock(); let k = c; let flat = isFlat; lock.unlock()
        var st = s[ch]
        if flat {                        // keep state current so un-flattening is seamless
            for i in 0..<count { let x = Double(buf[i]); st[1] = st[0]; st[0] = x; st[3] = st[2]; st[2] = x }
            s[ch] = st
            return
        }
        for i in 0..<count {
            let x = Double(buf[i])
            let y = k.b0 * x + k.b1 * st[0] + k.b2 * st[1] - k.a1 * st[2] - k.a2 * st[3]
            st[1] = st[0]; st[0] = x; st[3] = st[2]; st[2] = y
            buf[i] = Float(y)
        }
        s[ch] = st
    }
}

// MARK: - Recipe stage DSP

/// The shaping around the saturators. Call `pre` before the even/odd
/// saturators and `post` after them.
final class RecipeStage {
    private let preLow  = ShelfBiquad(.low, frequency: 250)
    private let preHigh = ShelfBiquad(.high, frequency: 3000)
    private let deLow   = ShelfBiquad(.low, frequency: 250)
    private let deHigh  = ShelfBiquad(.high, frequency: 3000)
    private let toneHigh = ShelfBiquad(.high, frequency: 5000)
    private let toneLow  = ShelfBiquad(.low, frequency: 120)

    private let lock = NSLock()
    private var h = (h2: 0.0, h3: 0.0, h4: 0.0, h5: 0.0)
    private var mix = 0.0
    // 2nd-order 10 Hz high-pass on the harmonic path (even harmonics carry DC).
    private let hp: (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) = {
        let w0 = 2 * Double.pi * 10 / 44100, alpha = sin(w0) / (2 * 0.7071), c = cos(w0), a0 = 1 + alpha
        return ((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0)
    }()
    private var hpS = [[Double]](repeating: [0, 0, 0, 0], count: 2)

    /// amount 0…1: how hard the saturator knobs are driven (scales the harmonic recipe).
    func configure(_ r: SaturatorRecipe, amount: Double) {
        preLow.setGain(db: r.preLowDb);   deLow.setGain(db: -r.preLowDb)
        preHigh.setGain(db: r.preHighDb); deHigh.setGain(db: -r.preHighDb)
        toneHigh.setGain(db: r.postHighDb)
        toneLow.setGain(db: r.postLowDb)
        lock.lock()
        h = (r.h2, r.h3, r.h4, r.h5)
        mix = r.harmonicMix * max(0, min(1, amount))
        lock.unlock()
    }

    func pre(_ buf: UnsafeMutablePointer<Float>, count: Int, channel ch: Int) {
        preLow.process(buf, count: count, channel: ch)
        preHigh.process(buf, count: count, channel: ch)
    }

    func post(_ buf: UnsafeMutablePointer<Float>, count: Int, channel ch: Int) {
        lock.lock(); let w = h; let m = mix; lock.unlock()
        if m > 1e-6 {
            var st = hpS[ch]
            for i in 0..<count {
                let x = Double(buf[i])
                let u = tanh(x)                                 // bounded for the polynomials
                let u2 = u * u
                let t2 = 2 * u2 - 1, t3 = (4 * u2 - 3) * u
                let t4 = 8 * u2 * u2 - 8 * u2 + 1, t5 = (16 * u2 * u2 - 20 * u2 + 5) * u
                // Remove the polynomials' static offsets (T2(0) = −1, T4(0) = 1).
                let harm = w.h2 * (t2 + 1) + w.h3 * t3 + w.h4 * (t4 - 1) + w.h5 * t5
                let y = hp.b0 * harm + hp.b1 * st[0] + hp.b2 * st[1] - hp.a1 * st[2] - hp.a2 * st[3]
                st[1] = st[0]; st[0] = harm; st[3] = st[2]; st[2] = y
                buf[i] = Float(x + m * y)
            }
            hpS[ch] = st
        }
        deLow.process(buf, count: count, channel: ch)
        deHigh.process(buf, count: count, channel: ch)
        toneHigh.process(buf, count: count, channel: ch)
        toneLow.process(buf, count: count, channel: ch)
    }
}
