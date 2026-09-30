import Foundation

// Global presets: a full snapshot of knob sensitivities, the saturator
// recipe and a suggested macro position. Range sliders reset to 0–100%.
// INIT is the app's default state; the rest are grouped by vibe for the
// preset menu. Reverb values go through the quadratic reverb knob (see
// AppState.effective). The Lo-Mid EQ is a very wide bell (Q 0.1 at 150 Hz),
// so it's kept low except where a preset is meant to feel thick or warm.
//
// Vibe guidelines:
//   Nostalgic — worn tape, old radios: more roll-off, hysteresis/sag, grit
//   Calming   — dark, soft and slow: heavy roll-off, blur, little grit
//   Inspiring — open and airy: light roll-off, clean, roomy reverb/shimmer
//   Dreamy    — suspended in time: group delay, blur, grain, shimmer
//   Playful   — character and attitude: odd harmonics, crunchy recipes

struct GlobalPreset {
    enum Vibe: String, CaseIterable {
        case nostalgic = "Nostalgic", calming = "Calming", inspiring = "Inspiring",
             dreamy = "Dreamy", playful = "Playful"
    }

    let name: String
    let vibe: Vibe?          // nil only for INIT
    let macro: Double
    let recipe: String
    let sensitivity: [String: Double]

    // Keys: eq sat oddsat rolloff | gd gdrand blur | reverb shimmer grain | hyst sag
    private static func s(eq: Double, sat: Double, odd: Double, roll: Double,
                          gd: Double, gdr: Double, blur: Double,
                          rev: Double, shim: Double, grain: Double,
                          hyst: Double, sag: Double) -> [String: Double] {
        ["eq": eq, "sat": sat, "oddsat": odd, "rolloff": roll,
         "gd": gd, "gdrand": gdr, "blur": blur,
         "reverb": rev, "shimmer": shim, "grain": grain,
         "hyst": hyst, "sag": sag]
    }

    static let initName = "INIT"

    static let initPreset = GlobalPreset(name: initName, vibe: nil, macro: 0, recipe: "Classic", sensitivity:
        s(eq: 24, sat: 35.5, odd: 11, roll: 43, gd: 25, gdr: 36, blur: 50, rev: 15, shim: 50, grain: 50, hyst: 0, sag: 0))

    static let all: [GlobalPreset] = [
        initPreset,
        // ── Nostalgic ──
        .init(name: "Grandpa's Favorite Record", vibe: .nostalgic, macro: 60, recipe: "Old Photograph", sensitivity:
            s(eq: 30, sat: 55, odd: 15, roll: 70, gd: 15, gdr: 20, blur: 25, rev: 20, shim: 15, grain: 20, hyst: 50, sag: 30)),
        .init(name: "Walkman on the School Bus", vibe: .nostalgic, macro: 60, recipe: "Vintagize", sensitivity:
            s(eq: 0, sat: 40, odd: 25, roll: 60, gd: 10, gdr: 40, blur: 10, rev: 5, shim: 0, grain: 15, hyst: 60, sag: 70)),
        .init(name: "Cassette From an Old Friend", vibe: .nostalgic, macro: 60, recipe: "Faded Polaroid", sensitivity:
            s(eq: 10, sat: 50, odd: 20, roll: 55, gd: 15, gdr: 35, blur: 20, rev: 15, shim: 10, grain: 35, hyst: 70, sag: 40)),
        .init(name: "Midnight Diner Jukebox", vibe: .nostalgic, macro: 60, recipe: "Late Night Diner", sensitivity:
            s(eq: 15, sat: 40, odd: 40, roll: 50, gd: 15, gdr: 15, blur: 15, rev: 30, shim: 10, grain: 10, hyst: 30, sag: 35)),
        .init(name: "Mom's Car Radio, 1996", vibe: .nostalgic, macro: 60, recipe: "Summer '99", sensitivity:
            s(eq: 10, sat: 35, odd: 35, roll: 60, gd: 10, gdr: 20, blur: 10, rev: 10, shim: 0, grain: 10, hyst: 40, sag: 50)),
        .init(name: "Snow Day at Grandma's", vibe: .nostalgic, macro: 60, recipe: "Grandma's Kitchen", sensitivity:
            s(eq: 35, sat: 60, odd: 10, roll: 60, gd: 20, gdr: 20, blur: 30, rev: 35, shim: 30, grain: 25, hyst: 35, sag: 15)),
        .init(name: "Old Photograph in a Shoebox", vibe: .nostalgic, macro: 60, recipe: "Old Photograph", sensitivity:
            s(eq: 10, sat: 50, odd: 20, roll: 75, gd: 30, gdr: 40, blur: 50, rev: 25, shim: 20, grain: 45, hyst: 45, sag: 25)),
        .init(name: "VHS Tape of a Birthday Party", vibe: .nostalgic, macro: 60, recipe: "Faded Polaroid", sensitivity:
            s(eq: 0, sat: 45, odd: 30, roll: 70, gd: 15, gdr: 55, blur: 25, rev: 15, shim: 5, grain: 30, hyst: 75, sag: 55)),
        .init(name: "Arcade at the Mall, 1989", vibe: .nostalgic, macro: 60, recipe: "Crunch", sensitivity:
            s(eq: 10, sat: 40, odd: 40, roll: 45, gd: 10, gdr: 20, blur: 10, rev: 30, shim: 5, grain: 20, hyst: 35, sag: 30)),
        .init(name: "Sleepover Mixtape", vibe: .nostalgic, macro: 60, recipe: "Vintagize", sensitivity:
            s(eq: 15, sat: 45, odd: 20, roll: 60, gd: 15, gdr: 35, blur: 20, rev: 20, shim: 10, grain: 30, hyst: 60, sag: 45)),
        .init(name: "Grandma's Kitchen Radio", vibe: .nostalgic, macro: 60, recipe: "Grandma's Kitchen", sensitivity:
            s(eq: 30, sat: 50, odd: 20, roll: 70, gd: 15, gdr: 20, blur: 20, rev: 20, shim: 10, grain: 15, hyst: 45, sag: 30)),
        // ── Calming ──
        .init(name: "Rainy Window, Sunday Afternoon", vibe: .calming, macro: 55, recipe: "Rainy Sunday", sensitivity:
            s(eq: 15, sat: 45, odd: 5, roll: 65, gd: 25, gdr: 30, blur: 40, rev: 35, shim: 35, grain: 30, hyst: 25, sag: 10)),
        .init(name: "Campfire Under the Stars", vibe: .calming, macro: 55, recipe: "Campfire Crackle", sensitivity:
            s(eq: 15, sat: 50, odd: 25, roll: 55, gd: 20, gdr: 25, blur: 30, rev: 40, shim: 40, grain: 25, hyst: 20, sag: 20)),
        .init(name: "Lullaby From the Next Room", vibe: .calming, macro: 60, recipe: "Lullaby", sensitivity:
            s(eq: 25, sat: 30, odd: 0, roll: 85, gd: 50, gdr: 30, blur: 55, rev: 45, shim: 45, grain: 40, hyst: 20, sag: 5)),
        .init(name: "Honey Tea by the Fireplace", vibe: .calming, macro: 55, recipe: "Honey & Smoke", sensitivity:
            s(eq: 35, sat: 60, odd: 10, roll: 55, gd: 20, gdr: 15, blur: 25, rev: 25, shim: 35, grain: 15, hyst: 30, sag: 10)),
        .init(name: "Falling Asleep to the Radio", vibe: .calming, macro: 65, recipe: "Lullaby", sensitivity:
            s(eq: 25, sat: 35, odd: 10, roll: 80, gd: 45, gdr: 35, blur: 65, rev: 45, shim: 50, grain: 55, hyst: 30, sag: 20)),
        .init(name: "Ocean Hush at Dusk", vibe: .calming, macro: 60, recipe: "Velvet", sensitivity:
            s(eq: 20, sat: 25, odd: 0, roll: 70, gd: 40, gdr: 45, blur: 55, rev: 45, shim: 40, grain: 35, hyst: 10, sag: 0)),
        .init(name: "Tea Kettle Morning", vibe: .calming, macro: 55, recipe: "Warmth", sensitivity:
            s(eq: 20, sat: 30, odd: 5, roll: 55, gd: 15, gdr: 20, blur: 25, rev: 30, shim: 20, grain: 15, hyst: 20, sag: 5)),
        .init(name: "Snowfall Through a Window", vibe: .calming, macro: 60, recipe: "Lullaby", sensitivity:
            s(eq: 15, sat: 20, odd: 0, roll: 75, gd: 30, gdr: 30, blur: 60, rev: 50, shim: 45, grain: 40, hyst: 10, sag: 0)),
        .init(name: "Forest Cabin, Rain on the Roof", vibe: .calming, macro: 55, recipe: "Rainy Sunday", sensitivity:
            s(eq: 25, sat: 35, odd: 5, roll: 65, gd: 25, gdr: 30, blur: 35, rev: 35, shim: 30, grain: 25, hyst: 25, sag: 5)),
        .init(name: "Library Nap", vibe: .calming, macro: 55, recipe: "Velvet", sensitivity:
            s(eq: 20, sat: 25, odd: 0, roll: 80, gd: 20, gdr: 20, blur: 45, rev: 25, shim: 25, grain: 20, hyst: 15, sag: 0)),
        // ── Inspiring ──
        .init(name: "Sunrise Over the Rooftops", vibe: .inspiring, macro: 55, recipe: "Silk", sensitivity:
            s(eq: 10, sat: 30, odd: 5, roll: 15, gd: 10, gdr: 20, blur: 15, rev: 45, shim: 35, grain: 20, hyst: 10, sag: 0)),
        .init(name: "First Day of Something New", vibe: .inspiring, macro: 55, recipe: "Sweeten", sensitivity:
            s(eq: 5, sat: 35, odd: 10, roll: 10, gd: 5, gdr: 15, blur: 10, rev: 40, shim: 25, grain: 15, hyst: 5, sag: 0)),
        .init(name: "Mountain Air After Rain", vibe: .inspiring, macro: 60, recipe: "Silk", sensitivity:
            s(eq: 5, sat: 25, odd: 0, roll: 20, gd: 10, gdr: 20, blur: 20, rev: 50, shim: 40, grain: 25, hyst: 0, sag: 0)),
        .init(name: "Stadium Lights, Home Team Winning", vibe: .inspiring, macro: 60, recipe: "Punch", sensitivity:
            s(eq: 15, sat: 45, odd: 30, roll: 10, gd: 5, gdr: 10, blur: 5, rev: 50, shim: 20, grain: 10, hyst: 15, sag: 10)),
        .init(name: "Open Road, Windows Down", vibe: .inspiring, macro: 60, recipe: "Summer '99", sensitivity:
            s(eq: 10, sat: 40, odd: 20, roll: 20, gd: 10, gdr: 25, blur: 10, rev: 25, shim: 15, grain: 15, hyst: 20, sag: 15)),
        .init(name: "Graduation Morning", vibe: .inspiring, macro: 55, recipe: "Glow", sensitivity:
            s(eq: 10, sat: 35, odd: 10, roll: 15, gd: 10, gdr: 15, blur: 15, rev: 55, shim: 45, grain: 20, hyst: 5, sag: 0)),
        // ── Dreamy ──
        .init(name: "Underwater Summer Dream", vibe: .dreamy, macro: 65, recipe: "Velvet", sensitivity:
            s(eq: 20, sat: 30, odd: 5, roll: 90, gd: 70, gdr: 60, blur: 60, rev: 40, shim: 50, grain: 50, hyst: 10, sag: 10)),
        .init(name: "Church Basement Choir Practice", vibe: .dreamy, macro: 60, recipe: "Glow", sensitivity:
            s(eq: 10, sat: 30, odd: 5, roll: 50, gd: 20, gdr: 15, blur: 30, rev: 55, shim: 70, grain: 20, hyst: 10, sag: 5)),
        .init(name: "Night Drive, Headlights on the Rain", vibe: .dreamy, macro: 60, recipe: "Silk", sensitivity:
            s(eq: 15, sat: 45, odd: 15, roll: 50, gd: 35, gdr: 40, blur: 40, rev: 40, shim: 45, grain: 35, hyst: 25, sag: 15)),
        .init(name: "Floating in a Swimming Pool at Night", vibe: .dreamy, macro: 65, recipe: "Velvet", sensitivity:
            s(eq: 20, sat: 25, odd: 5, roll: 80, gd: 60, gdr: 55, blur: 55, rev: 45, shim: 50, grain: 55, hyst: 10, sag: 5)),
        .init(name: "Half-Asleep on a Long Flight", vibe: .dreamy, macro: 60, recipe: "First Kiss", sensitivity:
            s(eq: 15, sat: 30, odd: 5, roll: 75, gd: 35, gdr: 40, blur: 60, rev: 35, shim: 45, grain: 50, hyst: 20, sag: 10)),
        .init(name: "Aurora Over an Empty Field", vibe: .dreamy, macro: 60, recipe: "Glow", sensitivity:
            s(eq: 10, sat: 25, odd: 0, roll: 50, gd: 45, gdr: 50, blur: 55, rev: 50, shim: 65, grain: 45, hyst: 5, sag: 0)),
        .init(name: "Memory of a Song You Can't Name", vibe: .dreamy, macro: 60, recipe: "Faded Polaroid", sensitivity:
            s(eq: 15, sat: 40, odd: 10, roll: 60, gd: 40, gdr: 60, blur: 50, rev: 40, shim: 30, grain: 70, hyst: 30, sag: 20)),
        // ── Playful ──
        .init(name: "Boombox in a Summer Camp", vibe: .playful, macro: 65, recipe: "Summer '99", sensitivity:
            s(eq: 15, sat: 50, odd: 45, roll: 30, gd: 10, gdr: 20, blur: 10, rev: 25, shim: 0, grain: 20, hyst: 30, sag: 60)),
        .init(name: "First Dance in the Gym", vibe: .playful, macro: 60, recipe: "First Kiss", sensitivity:
            s(eq: 10, sat: 45, odd: 15, roll: 40, gd: 15, gdr: 20, blur: 25, rev: 45, shim: 30, grain: 35, hyst: 20, sag: 20)),
        .init(name: "Attic Radio During a Storm", vibe: .playful, macro: 60, recipe: "Crunch", sensitivity:
            s(eq: 0, sat: 40, odd: 50, roll: 80, gd: 20, gdr: 50, blur: 20, rev: 20, shim: 25, grain: 40, hyst: 55, sag: 60)),
        .init(name: "Last Day of Summer Vacation", vibe: .playful, macro: 60, recipe: "Sweeten", sensitivity:
            s(eq: 10, sat: 45, odd: 20, roll: 45, gd: 25, gdr: 40, blur: 35, rev: 35, shim: 30, grain: 50, hyst: 30, sag: 30)),
        .init(name: "Roller Rink Saturday", vibe: .playful, macro: 60, recipe: "Summer '99", sensitivity:
            s(eq: 15, sat: 45, odd: 35, roll: 30, gd: 10, gdr: 20, blur: 10, rev: 45, shim: 15, grain: 20, hyst: 20, sag: 25)),
        .init(name: "Tin-Can Telephone", vibe: .playful, macro: 65, recipe: "Crunch", sensitivity:
            s(eq: 0, sat: 40, odd: 60, roll: 85, gd: 5, gdr: 20, blur: 10, rev: 5, shim: 0, grain: 15, hyst: 50, sag: 40)),
    ]

    static func presets(in vibe: Vibe) -> [GlobalPreset] { all.filter { $0.vibe == vibe } }

    static func named(_ name: String) -> GlobalPreset? { all.first { $0.name == name } }
}
