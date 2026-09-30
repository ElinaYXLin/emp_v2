import SwiftUI
import AppKit
import UniformTypeIdentifiers

// "Listener Report": a shareable PNG card summarizing the listener's current
// settings as concrete audio-engineering values, a measured THD "score", and
// some deliberately unscientific comparisons. Colors are derived from the
// waveform color's hue.

// MARK: - Data

struct ListenerReport {
    struct Row { let label: String; let value: String }
    struct Section { let title: String; let rows: [Row] }

    let macro: Double
    let macroNote: String
    let presetName: String
    let thd100: Double          // %
    let thd1k: Double           // %
    let thdn100: Double, thdn1k: Double     // %
    let imdPercent: Double      // multitone: % of output power that is new frequencies
    let c50Db: Double           // smear clarity
    let centerTimeMs: Double
    let evenOddDb: Double       // H2 − H3 at 100 Hz, dB (positive = even-dominant)
    let archetype: String
    let tagline: String
    let sections: [Section]
    let soundsLike: [String]
    let pairings: [String]
    let cozyIndex: Int
    let hue: Double
}

// MARK: - Building from app state

extension AppState {

    /// Macro value the report describes: the live value in Manual mode, or
    /// the mean of the vibrato's motion range (origin ± 10, clamped).
    var reportMacro: Double {
        guard macroMode == .vibrato else { return macro }
        let lo = max(0, vibratoCenter - 10), hi = min(100, vibratoCenter + 10)
        return (lo + hi) / 2
    }

    func effective(_ key: String, atMacro m: Double) -> Double {
        var s = (sensitivity[key] ?? 50) / 100
        if key == "reverb" { s *= s }             // quadratic knob, as in AppState.effective
        let r = ranges[key] ?? RangeValue()
        return (r.min + (r.max - r.min) * (m / 100)) / 100 * s
    }

    func makeListenerReport() -> ListenerReport {
        let m = reportMacro
        let eff = { self.effective($0, atMacro: m) }

        let eqDb      = eff("eq") * 12
        let evenDb    = eff("sat") * 16
        let oddDb     = eff("oddsat") * 16
        let rollSlope = eff("rolloff") * 6
        let decaySec  = pow(eff("reverb"), 1.5) * 60
        let gdScale   = eff("gd") * 20
        let gdRand    = eff("gdrand") * 50
        let grain     = eff("grain")
        let grainMemMs = grain * 200
        let grainMixDb = grain > 0 ? 20 * log10(grain) : -Double.infinity
        let grainLenMs = 30 + grainMemMs * 0.25
        let grainCents = 4 + 31 * grain
        let blur       = eff("blur")
        let blurAtk    = 0.05 + blur * 0.35
        let blurRel    = 0.10 + blur * 2.40
        let shimmer    = eff("shimmer")
        let shimMixDb  = shimmer > 0 ? 20 * log10(shimmer) : -Double.infinity
        let recipe     = SaturatorRecipe.named(satRecipe)
        let hyst       = eff("hyst")
        let sag        = eff("sag")
        let shimRT     = shimmer > 0 ? 0.095 * 3 / -log10(0.40 + 0.50 * shimmer) : 0   // loop trip / dB per trip → RT60

        var cs = ChainSettings()
        cs.preampDb = preampDb; cs.eqDb = eqDb; cs.evenDb = evenDb; cs.oddDb = oddDb
        cs.recipe = recipe; cs.hysteresis = hyst; cs.sag = sag; cs.rolloff = rollSlope
        cs.compressor = dynamicsMode == .compressor
        cs.gdScale = gdScale; cs.blur = blur; cs.grain = grain
        cs.reverbDecaySec = decaySec; cs.shimmer = shimmer
        let meas = ReportMeasurer.measure(cs)
        let thd100 = meas.thd100, thd1k = meas.thd1k
        let evenOdd = 20 * log10(max(meas.h2, 1e-9) / max(meas.h3, 1e-9))

        let gd100ms = min(1600, gdScale / 100 * 1000)
        let gd50ms  = min(1600, gdScale / 50 * 1000)
        let gd1kms  = gdScale / 1000 * 1000
        let roll10k = rollSlope * log2(10.0)
        let tailSec = min(decaySec, 2.0)

        let sections: [ListenerReport.Section] = [
            .init(title: "COLOR", rows: [
                .init(label: "Lo-mid bell",   value: String(format: "%+.1f dB @ 150 Hz, Q 0.1 (~10 oct wide)", eqDb)),
                .init(label: "Even saturator", value: String(format: "%.1f dB drive, tube-biased tanh", evenDb)),
                .init(label: "Odd saturator",  value: String(format: "%.1f dB drive, symmetric tanh", oddDb)),
                .init(label: "High roll-off",  value: String(format: "%.1f dB/oct above 1 kHz (%.1f dB @ 10 kHz)", rollSlope, -roll10k)),
                .init(label: "Recipe",         value: recipe.name == "Classic" ? "Classic (plain even/odd)" : "\(recipe.name): \(recipe.blurb)"),
                .init(label: "Tape hysteresis", value: hyst > 0.001
                      ? String(format: "%.0f%%: %.1f× drive, loop %.0f%% of level, +%.1f dB head bump @ 90 Hz", hyst * 100, 1 + 2 * hyst, hyst * 28, 2.5 * hyst)
                      : "off"),
                .init(label: "Tape sag",       value: sag > 0.001
                      ? String(format: "%.0f%%: up to −%.1f dB dip, top → %.0f kHz, %.1f ms motor droop", sag * 100, -20 * log10(1 - 0.5 * sag), (18000 - 12000 * sag) / 1000, 4 * sag)
                      : "off"),
                .init(label: "Subsonic cut",   value: "12 dB/oct below 25 Hz"),
            ]),
            .init(title: "SPECTRAL HAZE", rows: [
                .init(label: "Group delay",   value: String(format: "%.1f periods → %.0f ms @ 50 Hz, %.0f ms @ 100 Hz, %.1f ms @ 1 kHz", gdScale, gd50ms, gd100ms, gd1kms)),
                .init(label: "Spectral smear", value: gdScale > 0 ? "±60% delay scatter per 1/12 octave" : "off"),
                .init(label: "Delay drift",   value: String(format: "±%.0f%%, 3–6 s glides", gdRand)),
                .init(label: "Spectral blur", value: blur > 0.001
                      ? String(format: "%.0f%% depth, %.2f s bloom / %.1f s linger per bin", blur * 100, blurAtk, blurRel)
                      : "off"),
            ]),
            .init(title: "TEMPORAL HAZE", rows: [
                .init(label: "Reverb decay",  value: decaySec > 2
                      ? String(format: "%.1f s RT (tail capped at 2 s)", decaySec)
                      : String(format: "%.2f s RT", decaySec)),
                .init(label: "Reverb color",  value: "wet 0.8 / dry 0.6, tail darkens 7k→1.2k Hz"),
                .init(label: "Shimmer",       value: shimmer > 0.001
                      ? String(format: "−1 octave glow, %.1f dB re dry, ~%.1f s sustain", shimMixDb, shimRT)
                      : "off"),
                .init(label: "Grain echo",    value: grain > 0.001
                      ? String(format: "%.0f ms memory, %.0f ms grains ±%.0f¢, %.1f dB re dry", grainMemMs, grainLenMs, grainCents, grainMixDb)
                      : "off"),
            ]),
            .init(title: "GAIN STAGING", rows: [
                .init(label: "Pre-amp",   value: String(format: "%+.1f dB", preampDb)),
                .init(label: "Dynamics",  value: dynamicsMode == .limiter
                      ? "Brickwall limiter, 20:1 @ 0 dBFS, 1 ms attack"
                      : "Compressor, 4:1 @ −18 dBFS, 12 dB knee"),
                .init(label: "Post-gain", value: String(format: "%+.1f dB", postGainDb)),
            ]),
        ]

        // ── The unscientific part ─────────────────────────────────────────
        var like: [String] = []
        switch roll10k {
        case ..<3:  like.append("Treble: a freshly unwrapped CD, still smelling of plastic")
        case ..<9:  like.append("Treble: a well-loved LP on your uncle's turntable")
        case ..<15: like.append("Treble: a 10-year-old cassette that lived in a glovebox")
        case ..<21: like.append("Treble: a mixtape dubbed three times on a boombox")
        default:    like.append("Treble: AM radio in a 1978 station wagon, windows up")
        }
        switch tailSec {
        case ..<0.15: like.append("Room: a closet full of winter coats")
        case ..<0.6:  like.append("Room: a carpeted bedroom with the door shut")
        case ..<1.2:  like.append("Room: a small café at closing time")
        case ..<1.8:  like.append("Room: a tiled bathroom at 2 a.m.")
        default:      like.append("Room: an empty cathedral during a snowstorm")
        }
        switch gd100ms {
        case ..<2:   like.append("Bass timing: tight as a studio monitor")
        case ..<20:  like.append("Bass timing: the neighbour's party through one wall")
        case ..<80:  like.append("Bass timing: a concert heard from the parking lot")
        case ..<250: like.append("Bass timing: listening from the bottom of a swimming pool")
        default:     like.append("Bass timing: sound slowly pouring through warm honey")
        }
        switch thd100 {
        case ..<0.5: like.append("Grit: clinically clean, like a mastering-room null test")
        case ..<2:   like.append("Grit: a gently warmed tube preamp")
        case ..<6:   like.append("Grit: tape pushed into the red on purpose")
        case ..<15:  like.append("Grit: an overdriven guitar amp in a garage")
        default:     like.append("Grit: a boombox bravely giving its all")
        }
        like.append(evenOdd >= 0
            ? String(format: "Harmonics: tube-flavored (2nd beats 3rd by %.0f dB)", evenOdd)
            : String(format: "Harmonics: transistor-flavored (3rd beats 2nd by %.0f dB)", -evenOdd))
        switch grainMemMs {
        case ..<1:   break
        case ..<40:  like.append("Memory: a faint déjà vu you can't quite place")
        case ..<100: like.append("Memory: a chorus hummed back by a friend in the next room")
        case ..<160: like.append("Memory: last summer's song drifting out of a parked car")
        default:     like.append("Memory: a dream you're half-remembering over breakfast")
        }
        switch blur {
        case ..<0.05: break
        case ..<0.3:  like.append("Focus: a photo with a little Vaseline on the lens")
        case ..<0.6:  like.append("Focus: a song remembered in the shower, mostly right")
        default:      like.append("Focus: watercolor left out in the rain")
        }
        switch shimmer {
        case ..<0.05: break
        case ..<0.4:  like.append("Undertow: a cello quietly agreeing from the basement")
        case ..<0.7:  like.append("Undertow: the building itself humming along")
        default:      like.append("Undertow: whale song under the floorboards")
        }
        if eqDb >= 6 { like.append("Low mids: a blanket fort, fully fortified") }

        // Coziness: darkness + space + softness + warmth, capped 0–100.
        let darkPts: Double  = min(roll10k, 24) / 24 * 30
        let spacePts: Double = min(tailSec, 2) / 2 * 20
        let softPts: Double  = min(gd100ms, 200) / 200 * 20
        let bodyPts: Double  = min(eqDb, 12) / 12 * 15
        let warmPts: Double  = evenOdd > 0 ? min(evenOdd, 20) / 20 * 15 : 0
        let hazePts: Double  = grain * 6 + blur * 7 + shimmer * 7
        let cozy = Int(max(0, min(100, darkPts + spacePts + softPts + bodyPts + warmPts + hazePts)))

        let traits: [(Double, String, String)] = [
            (min(roll10k, 24) / 24, "The Velvet Fog Dweller", "prefers their treble wrapped in a wool scarf"),
            (min(tailSec, 2) / 2, "The Cathedral Daydreamer", "hears every song from the back pew"),
            (min(gd100ms, 300) / 300, "The Deep-Sea Listener", "lets the bass arrive fashionably late"),
            (min(evenDb + oddDb, 16) / 16, "The Warm Static Collector", "likes a little fuzz on the edges"),
            (min(eqDb, 12) / 12, "The Blanket Fort Architect", "builds walls out of low-mids"),
            (grain, "The Memory Collector", "hears every song as if it already happened once"),
            (blur, "The Soft-Focus Romantic", "lets every note melt before it lands"),
            (shimmer, "The Basement Choir Director", "keeps an octave-down choir on standby"),
            ((hyst + sag) / 2, "The Tape Whisperer", "can hear the reels turning"),
        ]
        switch meas.imdPercent {
        case ..<3:  like.append("Intermod: every instrument keeps to its own lane")
        case ..<10: like.append("Intermod: a friendly crowd where voices blend a little")
        case ..<25: like.append("Intermod: a busy café where conversations tangle")
        default:    like.append("Intermod: soup — delicious, but you can't tell the vegetables apart")
        }
        switch meas.c50Db {
        case 15...:    like.append("Smear: crisp as a studio booth")
        case 5..<15:   like.append("Smear: a cozy room with soft furniture")
        case -5..<5:   like.append("Smear: a stairwell where every note hangs around")
        case -15..<(-5): like.append("Smear: a cathedral full of fog")
        default:       like.append("Smear: sound dissolving into a warm cloud")
        }
        switch hyst + sag {
        case ..<0.05: break
        case ..<0.4:  like.append("Tape: a mixtape that's only been played a few times")
        case ..<0.9:  like.append("Tape: a cassette that survived three summers on a dashboard")
        default:      like.append("Tape: a reel-to-reel wheezing heroically through the chorus")
        }
        let top = traits.max { $0.0 < $1.0 }!
        let archetype = top.0 < 0.1 ? "The Purist" : top.1
        let tagline = top.0 < 0.1 ? "likes their music exactly as it left the studio" : top.2

        // Pairings, loosely keyed to the dominant traits.
        var pairings: [String] = []
        pairings.append(tailSec > 1 ? "a rainy window and a candle that smells like cedar"
                                    : "a desk lamp and a cup of something warm")
        pairings.append(gd100ms > 30 ? "a slow train through fog, headphones on"
                                     : "a late walk home under sodium streetlights")
        pairings.append(roll10k > 9 ? "a knitted blanket of questionable origin"
                                    : "fresh sheets and an open window")
        pairings.append(thd100 > 5 ? "a thrift-store cassette deck with one working speaker"
                                   : "a very clean pair of studio headphones")

        let macroNote = macroMode == .vibrato
            ? String(format: "vibrato (%@), mean of motion range", vibratoSpeed == .slow ? "slow" : "fast")
            : "manual"

        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (NSColor(waveColor).usingColorSpace(.sRGB) ?? .systemTeal).getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        return ListenerReport(macro: m, macroNote: macroNote, presetName: selectedPreset, thd100: thd100, thd1k: thd1k,
                              thdn100: meas.thdn100, thdn1k: meas.thdn1k, imdPercent: meas.imdPercent,
                              c50Db: meas.c50Db, centerTimeMs: meas.centerTimeMs,
                              evenOddDb: evenOdd, archetype: archetype, tagline: tagline,
                              sections: sections, soundsLike: like, pairings: pairings,
                              cozyIndex: cozy, hue: Double(h))
    }

    func exportListenerReport() {
        let report = makeListenerReport()
        guard let png = ListenerReportRenderer.png(for: report) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "listener_report.png"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }
}

// MARK: - Card view

struct ListenerReportCard: View {
    let r: ListenerReport

    private func hue(_ dh: Double = 0, s: Double, b: Double) -> Color {
        Color(hue: (r.hue + dh).truncatingRemainder(dividingBy: 1), saturation: s, brightness: b)
    }
    private var accent: Color { hue(s: 0.75, b: 0.95) }
    private var accent2: Color { hue(0.08, s: 0.6, b: 0.85) }
    private var ink: Color { hue(s: 0.08, b: 0.95) }
    private var dim: Color { hue(s: 0.15, b: 0.62) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header + score
            HStack(alignment: .firstTextBaseline) {
                Text("ENTROPY PLAYER · LISTENER REPORT")
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundColor(dim)
                Spacer()
                Text(Self.dateString)
                    .font(.system(size: 16, design: .monospaced)).foregroundColor(dim)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("SCORE · TOTAL HARMONIC DISTORTION")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundColor(accent2)
                HStack(alignment: .firstTextBaseline, spacing: 36) {
                    scoreBlock(String(format: "%.2f%%", r.thd100), "@ 100 Hz")
                    scoreBlock(String(format: "%.2f%%", r.thd1k), "@ 1 kHz")
                }
                Text("−6 dBFS sine (re full-scale input) through pre-amp + Color chain")
                    .font(.system(size: 13, design: .monospaced)).foregroundColor(dim)
                HStack(spacing: 14) {
                    metric("THD+N", String(format: "%.1f%% / %.1f%%", r.thdn100, r.thdn1k), "incl. aliasing & noise")
                    metric("INTERMOD", String(format: "%.1f%%", r.imdPercent), "5-tone, new freqs")
                    metric("CLARITY C50", r.c50Db.isFinite ? String(format: "%+.1f dB", r.c50Db) : "∞", "click: first 50 ms vs rest")
                    metric("CENTRE TIME", String(format: "%.0f ms", r.centerTimeMs), "where a click's energy lands")
                }
                .padding(.top, 6)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(r.archetype)
                    .font(.system(size: 40, weight: .bold, design: .serif)).foregroundColor(ink)
                Text("…who \(r.tagline).")
                    .font(.system(size: 20, design: .serif).italic()).foregroundColor(dim)
            }

            HStack(spacing: 16) {
                pill(String(format: "MACRO %.0f%%", r.macro), r.macroNote)
                pill("COZY INDEX \(r.cozyIndex)/100", cozyWord)
                pill("PRESET", r.presetName)
            }

            ForEach(r.sections, id: \.title) { sec in
                VStack(alignment: .leading, spacing: 8) {
                    Text(sec.title)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundColor(accent)
                    ForEach(sec.rows, id: \.label) { row in
                        HStack(alignment: .top, spacing: 12) {
                            Text(row.label)
                                .font(.system(size: 15, design: .monospaced)).foregroundColor(dim)
                                .frame(width: 190, alignment: .leading)
                            Text(row.value)
                                .font(.system(size: 15, weight: .medium, design: .monospaced)).foregroundColor(ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("SOUNDS LIKE…")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundColor(accent)
                ForEach(r.soundsLike, id: \.self) { line in
                    Text("◆  " + line)
                        .font(.system(size: 17, design: .serif)).foregroundColor(ink)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("BEST ENJOYED WITH…")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundColor(accent2)
                ForEach(r.pairings, id: \.self) { line in
                    Text("✦  " + line)
                        .font(.system(size: 17, design: .serif).italic()).foregroundColor(ink.opacity(0.85))
                }
            }

            Spacer(minLength: 0)
            wave.frame(height: 60)
            Text("THD tops out near 48% (a square wave) however hard you clip; Intermod and Clarity track how mushy music actually gets. Comparisons are vibes, not science.")
                .font(.system(size: 12, design: .monospaced)).foregroundColor(dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(48)
        .frame(width: 1080, height: 1780, alignment: .topLeading)
        .background(
            LinearGradient(colors: [hue(s: 0.55, b: 0.16), hue(0.06, s: 0.45, b: 0.08), Color.black],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private static var dateString: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: Date())
    }

    private var cozyWord: String {
        switch r.cozyIndex {
        case ..<20: return "crisp & bright"
        case ..<45: return "comfy"
        case ..<70: return "blanket weather"
        default:    return "maximum hibernation"
        }
    }

    private func metric(_ title: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(accent2)
            Text(value).font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundColor(ink)
            Text(sub).font(.system(size: 10, design: .monospaced)).foregroundColor(dim)
        }
        .frame(width: 230, alignment: .leading)
    }

    private func scoreBlock(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(value).font(.system(size: 64, weight: .bold, design: .monospaced)).foregroundColor(accent)
            Text(label).font(.system(size: 18, design: .monospaced)).foregroundColor(dim)
        }
    }

    private func pill(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundColor(ink)
            Text(sub).font(.system(size: 13, design: .monospaced)).foregroundColor(dim)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(hue(s: 0.5, b: 0.3).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.5), lineWidth: 1))
    }

    // Decorative waveform whose wobble follows the report's own numbers.
    private var wave: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                let wobble = 0.3 + min(r.thd100, 20) / 20 * 0.7
                p.move(to: CGPoint(x: 0, y: h / 2))
                for i in stride(from: 0.0, through: Double(w), by: 2) {
                    let t = i / Double(w)
                    let y = sin(t * 18 * .pi) * 0.6 + sin(t * 47 * .pi) * 0.4 * wobble
                    p.addLine(to: CGPoint(x: i, y: Double(h) / 2 + y * Double(h) * 0.4 * sin(t * .pi)))
                }
            }
            .stroke(LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing), lineWidth: 3)
        }
    }
}

// MARK: - Rendering

enum ListenerReportRenderer {
    @MainActor
    static func png(for report: ListenerReport) -> Data? {
        let card = ListenerReportCard(r: report)
        if #available(macOS 13.0, *) {
            let renderer = ImageRenderer(content: card)
            renderer.scale = 1
            guard let cg = renderer.cgImage else { return nil }
            return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        }
        let host = NSHostingView(rootView: card)
        host.frame = NSRect(x: 0, y: 0, width: 1080, height: 1780)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
