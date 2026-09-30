import Foundation

// Global presets: a full snapshot of knob sensitivities, the saturator
// recipe and a suggested macro position. Range sliders reset to 0–100%.
// INIT is the app's default state. Reverb values go through the quadratic
// reverb knob (see AppState.effective). The Lo-Mid EQ is a very wide bell
// (Q 0.1 at 150 Hz), so it's kept low except where a preset is meant to
// feel thick or blanket-warm.

struct GlobalPreset {
    let name: String
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

    static let initPreset = GlobalPreset(name: initName, macro: 0, recipe: "Classic", sensitivity:
        s(eq: 24, sat: 35.5, odd: 11, roll: 43, gd: 25, gdr: 36, blur: 50, rev: 15, shim: 50, grain: 50, hyst: 0, sag: 0))

    static let all: [GlobalPreset] = [
        initPreset,
        .init(name: "Boombox in a Summer Camp", macro: 65, recipe: "Summer '99", sensitivity:
            s(eq: 15, sat: 50, odd: 45, roll: 30, gd: 10, gdr: 20, blur: 10, rev: 25, shim: 0, grain: 20, hyst: 30, sag: 60)),
        .init(name: "Grandpa's Favorite Record", macro: 60, recipe: "Old Photograph", sensitivity:
            s(eq: 30, sat: 55, odd: 15, roll: 70, gd: 15, gdr: 20, blur: 25, rev: 20, shim: 15, grain: 20, hyst: 50, sag: 30)),
        .init(name: "Walkman on the School Bus", macro: 60, recipe: "Vintagize", sensitivity:
            s(eq: 0, sat: 40, odd: 25, roll: 60, gd: 10, gdr: 40, blur: 10, rev: 5, shim: 0, grain: 15, hyst: 60, sag: 70)),
        .init(name: "Rainy Window, Sunday Afternoon", macro: 55, recipe: "Rainy Sunday", sensitivity:
            s(eq: 15, sat: 45, odd: 5, roll: 65, gd: 25, gdr: 30, blur: 40, rev: 35, shim: 35, grain: 30, hyst: 25, sag: 10)),
        .init(name: "Cassette From an Old Friend", macro: 60, recipe: "Faded Polaroid", sensitivity:
            s(eq: 10, sat: 50, odd: 20, roll: 55, gd: 15, gdr: 35, blur: 20, rev: 15, shim: 10, grain: 35, hyst: 70, sag: 40)),
        .init(name: "Midnight Diner Jukebox", macro: 60, recipe: "Late Night Diner", sensitivity:
            s(eq: 15, sat: 40, odd: 40, roll: 50, gd: 15, gdr: 15, blur: 15, rev: 30, shim: 10, grain: 10, hyst: 30, sag: 35)),
        .init(name: "Campfire Under the Stars", macro: 55, recipe: "Campfire Crackle", sensitivity:
            s(eq: 15, sat: 50, odd: 25, roll: 55, gd: 20, gdr: 25, blur: 30, rev: 40, shim: 40, grain: 25, hyst: 20, sag: 20)),
        .init(name: "Mom's Car Radio, 1996", macro: 60, recipe: "Summer '99", sensitivity:
            s(eq: 10, sat: 35, odd: 35, roll: 60, gd: 10, gdr: 20, blur: 10, rev: 10, shim: 0, grain: 10, hyst: 40, sag: 50)),
        .init(name: "Lullaby From the Next Room", macro: 60, recipe: "Lullaby", sensitivity:
            s(eq: 25, sat: 30, odd: 0, roll: 85, gd: 50, gdr: 30, blur: 55, rev: 45, shim: 45, grain: 40, hyst: 20, sag: 5)),
        .init(name: "Snow Day at Grandma's", macro: 60, recipe: "Grandma's Kitchen", sensitivity:
            s(eq: 35, sat: 60, odd: 10, roll: 60, gd: 20, gdr: 20, blur: 30, rev: 35, shim: 30, grain: 25, hyst: 35, sag: 15)),
        .init(name: "First Dance in the Gym", macro: 60, recipe: "First Kiss", sensitivity:
            s(eq: 10, sat: 45, odd: 15, roll: 40, gd: 15, gdr: 20, blur: 25, rev: 45, shim: 30, grain: 35, hyst: 20, sag: 20)),
        .init(name: "Old Photograph in a Shoebox", macro: 60, recipe: "Old Photograph", sensitivity:
            s(eq: 10, sat: 50, odd: 20, roll: 75, gd: 30, gdr: 40, blur: 50, rev: 25, shim: 20, grain: 45, hyst: 45, sag: 25)),
        .init(name: "Underwater Summer Dream", macro: 65, recipe: "Velvet", sensitivity:
            s(eq: 20, sat: 30, odd: 5, roll: 90, gd: 70, gdr: 60, blur: 60, rev: 40, shim: 50, grain: 50, hyst: 10, sag: 10)),
        .init(name: "Attic Radio During a Storm", macro: 60, recipe: "Crunch", sensitivity:
            s(eq: 0, sat: 40, odd: 50, roll: 80, gd: 20, gdr: 50, blur: 20, rev: 20, shim: 25, grain: 40, hyst: 55, sag: 60)),
        .init(name: "Honey Tea by the Fireplace", macro: 55, recipe: "Honey & Smoke", sensitivity:
            s(eq: 35, sat: 60, odd: 10, roll: 55, gd: 20, gdr: 15, blur: 25, rev: 25, shim: 35, grain: 15, hyst: 30, sag: 10)),
        .init(name: "Last Day of Summer Vacation", macro: 60, recipe: "Sweeten", sensitivity:
            s(eq: 10, sat: 45, odd: 20, roll: 45, gd: 25, gdr: 40, blur: 35, rev: 35, shim: 30, grain: 50, hyst: 30, sag: 30)),
        .init(name: "Church Basement Choir Practice", macro: 60, recipe: "Glow", sensitivity:
            s(eq: 10, sat: 30, odd: 5, roll: 50, gd: 20, gdr: 15, blur: 30, rev: 55, shim: 70, grain: 20, hyst: 10, sag: 5)),
        .init(name: "VHS Tape of a Birthday Party", macro: 60, recipe: "Faded Polaroid", sensitivity:
            s(eq: 0, sat: 45, odd: 30, roll: 70, gd: 15, gdr: 55, blur: 25, rev: 15, shim: 5, grain: 30, hyst: 75, sag: 55)),
        .init(name: "Night Drive, Headlights on the Rain", macro: 60, recipe: "Silk", sensitivity:
            s(eq: 15, sat: 45, odd: 15, roll: 50, gd: 35, gdr: 40, blur: 40, rev: 40, shim: 45, grain: 35, hyst: 25, sag: 15)),
        .init(name: "Falling Asleep to the Radio", macro: 65, recipe: "Lullaby", sensitivity:
            s(eq: 25, sat: 35, odd: 10, roll: 80, gd: 45, gdr: 35, blur: 65, rev: 45, shim: 50, grain: 55, hyst: 30, sag: 20)),
    ]

    static func named(_ name: String) -> GlobalPreset? { all.first { $0.name == name } }
}
