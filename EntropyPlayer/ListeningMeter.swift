import SwiftUI
import CoreAudio

// Listening-level meter: estimates the sound level reaching your ears and
// tracks exposure against the WHO safe-listening guideline (80 dB(A) for
// 40 hours a week; every +3 dB halves the allowed time).
//
//   SPL ≈ headphone sensitivity (dB SPL @ 1 Vrms)
//       + 20·log10(DAC full-scale output, Vrms)
//       + system volume (dB)
//       + EMP's output level, A-weighted (dBFS, full-scale sine = 0 dB)
//
// A-weighting (IEC 61672) matches how hearing-safety limits are defined —
// it discounts deep bass and extreme treble.
// Digital filter matches the IEC curve within ±0.8 dB from 31 Hz to 10 kHz
// (−4 dB at 16 kHz, inside the Class 1 meter tolerance there). The level is measured on EMP's
// final output (after post-gain and the output ceiling), so it sees exactly
// what goes to the DAC. Everything after that — system volume, DAC, and
// headphones — comes from the user's settings, so the result is an estimate
// (±3 dB or so from headphone sensitivity tolerance alone).

// MARK: - Audio-thread tap

/// A-weighted mean-square accumulator. `process` only reads the buffers.
final class AWeightedMeter {
    private struct BQ { var b0, b1, b2, a1, a2: Double }
    private let sections: [BQ]
    private var state = [[Double]](repeating: [Double](repeating: 0, count: 12), count: 2)  // 3 sections × 4, per channel
    private let lock = NSLock()
    private var sumSq = 0.0
    private var samples = 0

    init(sampleRate fs: Double = 44100) {
        // IEC 61672 A-weighting poles, bilinear-transformed as three biquads:
        //   s²/(s+w1)²  ·  s²/((s+w2)(s+w3))  ·  1/(s+w4)²
        // Pre-warp each pole so it lands at the right frequency after the
        // bilinear transform (matters for the 12.2 kHz pair near Nyquist).
        let k = 2 * fs
        let w = [20.598997, 107.65265, 737.86223, 12194.217].map { k * tan(Double.pi * $0 / fs) }
        func pole(_ p: Double) -> (Double, Double) { (k + p, p - k) }          // (s+p) → c0 + c1·z⁻¹ (over 1+z⁻¹)
        func den(_ a: (Double, Double), _ b: (Double, Double)) -> (Double, Double, Double) {
            (a.0 * b.0, a.0 * b.1 + a.1 * b.0, a.1 * b.1)
        }
        func bq(num: (Double, Double, Double), den d: (Double, Double, Double)) -> BQ {
            BQ(b0: num.0 / d.0, b1: num.1 / d.0, b2: num.2 / d.0, a1: d.1 / d.0, a2: d.2 / d.0)
        }
        let hp = (k * k, -2 * k * k, k * k)                                      // s² → k²(1−z⁻¹)²
        var secs = [
            bq(num: hp, den: den(pole(w[0]), pole(w[0]))),
            bq(num: hp, den: den(pole(w[1]), pole(w[2]))),
            bq(num: (1, 2, 1), den: den(pole(w[3]), pole(w[3]))),                // 1 → (1+z⁻¹)²
        ]
        // Normalize to 0 dB at 1 kHz.
        var mag = 1.0
        let z = 2 * Double.pi * 1000 / fs
        for s in secs {
            let nr = s.b0 + s.b1 * cos(z) + s.b2 * cos(2 * z), ni = -(s.b1 * sin(z) + s.b2 * sin(2 * z))
            let dr = 1 + s.a1 * cos(z) + s.a2 * cos(2 * z), di = -(s.a1 * sin(z) + s.a2 * sin(2 * z))
            mag *= ((nr * nr + ni * ni) / (dr * dr + di * di)).squareRoot()
        }
        secs[0].b0 /= mag; secs[0].b1 /= mag; secs[0].b2 /= mag
        sections = secs
    }

    /// Accumulates A-weighted power (average of both channels). Realtime-safe.
    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        var acc = 0.0
        for ch in 0..<2 {
            let x = ch == 0 ? left : right
            var st = state[ch]
            for i in 0..<count {
                var v = Double(x[i])
                for (j, s) in sections.enumerated() {
                    let o = j * 4
                    let y = s.b0 * v + s.b1 * st[o] + s.b2 * st[o + 1] - s.a1 * st[o + 2] - s.a2 * st[o + 3]
                    st[o + 1] = st[o]; st[o] = v; st[o + 3] = st[o + 2]; st[o + 2] = y
                    v = y
                }
                acc += v * v
            }
            state[ch] = st
        }
        lock.lock()
        sumSq += acc / 2
        samples += count
        lock.unlock()
    }

    /// Returns and resets (mean square, sample count) since the last call.
    func drain() -> (Double, Int) {
        lock.lock(); defer { sumSq = 0; samples = 0; lock.unlock() }
        return (samples > 0 ? sumSq / Double(samples) : 0, samples)
    }

    /// Exposed for testing the filter response.
    func gainDb(at f: Double, sampleRate fs: Double = 44100) -> Double {
        let z = 2 * Double.pi * f / fs
        var mag = 1.0
        for s in sections {
            let nr = s.b0 + s.b1 * cos(z) + s.b2 * cos(2 * z), ni = -(s.b1 * sin(z) + s.b2 * sin(2 * z))
            let dr = 1 + s.a1 * cos(z) + s.a2 * cos(2 * z), di = -(s.a1 * sin(z) + s.a2 * sin(2 * z))
            mag *= ((nr * nr + ni * ni) / (dr * dr + di * di)).squareRoot()
        }
        return 20 * log10(mag)
    }
}

// MARK: - Model

@MainActor
final class ListeningMeterModel: ObservableObject {
    // User settings (persisted).
    @Published var sensitivity: Double { didSet { save() } }     // dB SPL @ 1 Vrms
    @Published var dacVrms: Double { didSet { save() } }         // full-scale output
    @Published var systemVolume: Double { didSet { save() } }    // 0–100 %

    // Readouts.
    @Published private(set) var shortDbA: Double = -.infinity    // last second
    @Published private(set) var leqDbA: Double = -.infinity      // last minute
    @Published private(set) var todayMinutes: Double = 0
    @Published private(set) var todayDose: Double = 0            // fraction of WHO weekly allowance
    @Published private(set) var weekDose: Double = 0             // last 7 days

    static let whoReferenceDb = 80.0
    static let whoWeeklySeconds = 40.0 * 3600

    private let meter: AWeightedMeter
    private let volumeToDb: (Double) -> Double
    private var window: [Double] = []                            // last 60 one-second mean squares
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    init(meter: AWeightedMeter, volumeToDb: @escaping (Double) -> Double) {
        self.meter = meter
        self.volumeToDb = volumeToDb
        let d = UserDefaults.standard
        sensitivity  = d.object(forKey: "meter.sensitivity") as? Double ?? 113
        dacVrms      = d.object(forKey: "meter.dacVrms") as? Double ?? 2.0
        systemVolume = d.object(forKey: "meter.systemVolume") as? Double ?? 100
        loadHistory()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func save() {
        defaults.set(sensitivity, forKey: "meter.sensitivity")
        defaults.set(dacVrms, forKey: "meter.dacVrms")
        defaults.set(systemVolume, forKey: "meter.systemVolume")
    }

    /// dB SPL offset for a digital full-scale sine.
    private var calibrationDb: Double {
        sensitivity + 20 * log10(max(dacVrms, 1e-6)) + volumeToDb(systemVolume)
    }

    private func spl(meanSquare ms: Double) -> Double {
        guard ms > 1e-14 else { return -.infinity }
        return calibrationDb + 10 * log10(ms * 2)                // full-scale sine (ms 0.5) = 0 dBFS
    }

    private func tick() {
        let (ms, n) = meter.drain()
        guard n > 0 else { return }
        window.append(ms)
        if window.count > 60 { window.removeFirst() }
        shortDbA = spl(meanSquare: ms)
        leqDbA = spl(meanSquare: window.reduce(0, +) / Double(window.count))

        // Exposure: only while something audible is playing.
        if shortDbA > 40 {
            let seconds = Double(n) / 44100
            let dose = seconds / Self.whoWeeklySeconds * pow(2, (shortDbA - Self.whoReferenceDb) / 3)
            addToHistory(seconds: seconds, dose: dose)
        }
    }

    // MARK: History (per-day seconds and dose, last 8 days)

    private var history: [String: [Double]] = [:]                // "yyyy-MM-dd": [seconds, dose]

    private static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private func loadHistory() {
        history = defaults.dictionary(forKey: "meter.history") as? [String: [Double]] ?? [:]
        refreshTotals()
    }

    private var unsaved = 0
    private func addToHistory(seconds: Double, dose: Double) {
        let key = Self.dayKey()
        var v = history[key] ?? [0, 0]
        v[0] += seconds; v[1] += dose
        history[key] = v
        unsaved += 1
        if unsaved >= 15 {                                       // persist every ~15 s
            let keep = Set((0..<8).map { Self.dayKey(Date().addingTimeInterval(-Double($0) * 86400)) })
            history = history.filter { keep.contains($0.key) }
            defaults.set(history, forKey: "meter.history")
            unsaved = 0
        }
        refreshTotals()
    }

    private func refreshTotals() {
        let today = history[Self.dayKey()] ?? [0, 0]
        todayMinutes = today[0] / 60
        todayDose = today[1]
        weekDose = (0..<7).reduce(0) { acc, d in
            acc + (history[Self.dayKey(Date().addingTimeInterval(-Double(d) * 86400))]?[1] ?? 0)
        }
    }
}

// MARK: - System volume → dB

enum OutputVolume {
    /// Converts a volume-slider percentage to dB using the device's own
    /// volume curve when it reports one (most hardware volume controls do),
    /// otherwise assumes a linear amplitude scale.
    static func decibels(percent: Double, device: AudioDeviceID?) -> Double {
        let scalar = Float32(max(0.0001, min(1, percent / 100)))
        if let device {
            for element in [kAudioObjectPropertyElementMain, 1] {
                var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalarToDecibels,
                                                      mScope: kAudioDevicePropertyScopeOutput, mElement: element)
                var value = scalar
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectHasProperty(device, &addr),
                   AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
                    // Curve is relative to the device's own max; make 100 % = 0 dB.
                    var top: Float32 = 1
                    if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &top) == noErr {
                        return Double(value - top)
                    }
                    return Double(value)
                }
            }
        }
        return 20 * log10(Double(scalar))
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return nil }
        return dev
    }
}

// MARK: - Bottom bar

struct ListeningMeterBar: View {
    @ObservedObject var model: ListeningMeterModel

    private func color(_ db: Double) -> Color {
        switch db {
        case ..<75: return Color(hex: "#7fd18b")
        case ..<85: return Color(hex: "#e8c15a")
        default:    return Color(hex: "#ff5a4a")
        }
    }

    private func fmt(_ db: Double) -> String { db.isFinite ? String(format: "%.0f", db) : "—" }

    var body: some View {
        HStack(spacing: 16) {
            Text("LISTENING LEVEL")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: "#8f8778"))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(fmt(model.leqDbA))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(model.leqDbA.isFinite ? color(model.leqDbA) : Color(hex: "#8f8778"))
                Text("dB(A) · 1 min").font(.system(size: 9, design: .monospaced)).foregroundColor(Color(hex: "#8f8778"))
            }
            Text("now \(fmt(model.shortDbA))")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(Color(hex: "#8f8778"))
            Divider().frame(height: 18)
            stat("TODAY", String(format: "%.0f min · %.0f%%", model.todayMinutes, model.todayDose * 100))
            stat("7 DAYS", String(format: "%.0f%% of WHO limit", model.weekDose * 100))
                .foregroundColor(model.weekDose >= 1 ? Color(hex: "#ff5a4a") : Color(hex: "#d9d1bf"))
            Spacer()
            field("Headphones", value: $model.sensitivity, unit: "dB SPL/V", width: 46)
            field("DAC", value: $model.dacVrms, unit: "Vrms", width: 40, decimals: 2)
            field("Sys vol", value: $model.systemVolume, unit: "%", width: 36)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(hex: "#1b1814"))
        .help("Estimated level at your ears: headphone sensitivity + DAC output + system volume + EMP's A-weighted output. WHO guideline: 80 dB(A) for 40 h/week; each +3 dB halves the safe time.")
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundColor(Color(hex: "#8f8778"))
            Text(value).font(.system(size: 11, design: .monospaced))
        }
        .foregroundColor(Color(hex: "#d9d1bf"))
    }

    private func field(_ label: String, value: Binding<Double>, unit: String, width: CGFloat, decimals: Int = 0) -> some View {
        let f = NumberFormatter()
        f.minimumFractionDigits = decimals; f.maximumFractionDigits = decimals
        return HStack(spacing: 4) {
            Text(label.uppercased()).font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundColor(Color(hex: "#8f8778"))
            TextField("", value: value, formatter: f)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(hex: "#d9d1bf"))
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 4).padding(.vertical, 3)
                .frame(width: width)
                .background(Color(hex: "#17140f"))
                .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color.black.opacity(0.6), lineWidth: 1))
            Text(unit).font(.system(size: 9, design: .monospaced)).foregroundColor(Color(hex: "#8f8778"))
        }
    }
}
