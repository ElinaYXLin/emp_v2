import SwiftUI
import Combine
import AVFoundation
import CoreAudio

// MARK: - Settings

struct RangeValue: Codable { var min: Double = 0; var max: Double = 100 }

struct AppSettings: Codable {
    var waveColor:    String = "#35d6d0"
    var macro:        Double = 0
    var sensitivity:  [String: Double] = GlobalPreset.initPreset.sensitivity
    var ranges:       [String: RangeValue] = [
        "reverb": .init(), "gd": .init(), "gdrand": .init(), "grain": .init(), "blur": .init(), "shimmer": .init(), "eq": .init(), "sat": .init(), "oddsat": .init(), "rolloff": .init(), "hyst": .init(), "sag": .init()
    ]
    var recipe:       String? = nil      // optional: older files predate recipes
    var order:        String = "alpha"
    var dynamics:     String = "limiter"
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {

    // MARK: Published UI state
    @Published var macro: Double = 0              // 0–100
    @Published var preampDb: Double = 0           // -12…0
    @Published var postGainDb: Double = 0         // -24…24, final output volume trim/boost
    @Published var sensitivity: [String: Double] = GlobalPreset.initPreset.sensitivity
    @Published var ranges: [String: RangeValue]  = ["reverb": .init(), "gd": .init(), "gdrand": .init(), "grain": .init(), "blur": .init(), "shimmer": .init(), "eq": .init(), "sat": .init(), "oddsat": .init(), "rolloff": .init(), "hyst": .init(), "sag": .init()]
    @Published var waveColor: Color = Color(hex: "#35d6d0")
    @Published var satRecipe: String = SaturatorRecipe.classic.name
    @Published var isExporting = false
    @Published var exportStatus: String? = nil
    @Published var selectedPreset: String = GlobalPreset.initName
    @Published var dynamicsMode: AudioEngine.DynamicsMode = .limiter
    @Published var macroMode: MacroMode = .manual
    @Published var vibratoSpeed: VibratoSpeed = .slow
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var trackName: String = "no track loaded"
    @Published var analyserSamples: [Float] = Array(repeating: 0, count: 256)
    @Published var waveformPeaks: [Float] = []

    // System audio capture
    @Published var systemCaptureActive = false
    @Published var inputDevices:  [(id: AudioDeviceID, name: String)] = []
    @Published var outputDevices: [(id: AudioDeviceID, name: String)] = []
    @Published var selectedInputDeviceID:  AudioDeviceID? = nil
    @Published var selectedOutputDeviceID: AudioDeviceID? = nil
    @Published var systemCaptureError: String? = nil

    enum MacroMode { case manual, vibrato }
    enum VibratoSpeed { case slow, fast }

    // MARK: Sub-objects
    let audio    = AudioEngine()
    @Published var playlist = PlaylistManager()

    /// Listening-level meter (bottom bar). System volume is converted with
    /// the current output device's own volume curve.
    lazy var meter = ListeningMeterModel(meter: audio.listeningMeter) { [weak self] pct in
        // Both modes now play to the OUT device.
        return OutputVolume.decibels(percent: pct, device: self?.selectedOutputDeviceID)
    }

    // MARK: Vibrato state
    private var vibratoTimer: Timer?
    private var vibratoOrigin: Double = 0
    private var vibratoTarget: Double = 0
    private var vibratoStartMacro: Double = 0
    private var vibratoStartTime: Date = .now
    /// Center of the vibrato's ±10 motion range (see Listener Report).
    var vibratoCenter: Double { vibratoOrigin }

    // MARK: Time timer
    private var timeTimer: Timer?

    // MARK: Init
    init() {
        audio.onSamples = { [weak self] s in
            DispatchQueue.main.async { self?.analyserSamples = s }
        }
        audio.onTrackEnded = { [weak self] in self?.advanceTrack() }

        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            self.currentTime = self.audio.currentTime
        }

        inputDevices  = audio.listInputDevices()
        outputDevices = audio.listOutputDevices()
        selectedInputDeviceID  = inputDevices.first?.id
        selectedOutputDeviceID = preferredOutputDevice()
        audio.setPlaybackOutputDevice(selectedOutputDeviceID)
    }

    // MARK: - System capture

    func toggleSystemCapture() {
        if systemCaptureActive {
            audio.stopSystemCapture()
            systemCaptureActive = false
            trackName = "no track loaded"
            isPlaying = false
            return
        }

        guard let inID  = selectedInputDeviceID  else { systemCaptureError = "Select an input (BlackHole) device"; return }
        guard let outID = selectedOutputDeviceID else { systemCaptureError = "Select an output (EarPods/speakers) device"; return }

        // macOS sandbox requires explicit permission before any audio input unit starts.
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.systemCaptureError = "Audio input denied — allow in System Preferences → Privacy → Microphone"
                    return
                }
                do {
                    try self.audio.startSystemCapture(inputDeviceID: inID, outputDeviceID: outID)
                    self.systemCaptureActive = true
                    self.trackName = "System Audio — LIVE"
                    self.isPlaying = false
                } catch {
                    self.systemCaptureError = error.localizedDescription
                }
            }
        }
    }

    func switchCaptureDevice(input: AudioDeviceID? = nil, output: AudioDeviceID? = nil) {
        if let id = input  { selectedInputDeviceID  = id }
        if let id = output {
            selectedOutputDeviceID = id
            audio.setPlaybackOutputDevice(id)        // file playback follows OUT too
        }
        guard systemCaptureActive,
              let inID  = selectedInputDeviceID,
              let outID = selectedOutputDeviceID else { return }
        do {
            try audio.startSystemCapture(inputDeviceID: inID, outputDeviceID: outID)
        } catch {
            systemCaptureError = error.localizedDescription
            systemCaptureActive = false
        }
    }

    func refreshInputDevices() {
        inputDevices  = audio.listInputDevices()
        outputDevices = audio.listOutputDevices()
        if let current = selectedInputDeviceID,
           !inputDevices.contains(where: { $0.id == current }) {
            selectedInputDeviceID = inputDevices.first?.id
        }
        if let current = selectedOutputDeviceID,
           !outputDevices.contains(where: { $0.id == current }) {
            selectedOutputDeviceID = preferredOutputDevice()
            audio.setPlaybackOutputDevice(selectedOutputDeviceID)
        }
    }

    /// The Mac's default output, unless that's a virtual loopback device
    /// (BlackHole etc. — where System mode users point their Mac's output),
    /// in which case the first real output device.
    private func preferredOutputDevice() -> AudioDeviceID? {
        func isVirtual(_ name: String) -> Bool {
            ["BlackHole", "Loopback", "Soundflower", "Aggregate", "Teams Audio", "ZoomAudio", "WeMeet"]
                .contains { name.localizedCaseInsensitiveContains($0) }
        }
        if let def = OutputVolume.defaultOutputDevice(),
           let entry = outputDevices.first(where: { $0.id == def }), !isVirtual(entry.name) {
            return def
        }
        return outputDevices.first { !isVirtual($0.name) }?.id ?? outputDevices.first?.id
    }

    // MARK: - Effective level computation
    // effective = lerp(range.min, range.max, macro) * sensitivity → 0…1
    func effective(_ key: String) -> Float {
        var s = Float(sensitivity[key] ?? 50) / 100
        // Reverb is very strong, so its knob is quadratic: 40% acts like the
        // old linear 16%, 60% like 36%.
        if key == "reverb" { s *= s }
        let r = ranges[key] ?? RangeValue()
        let mapped = Float(r.min + (r.max - r.min) * (macro / 100)) / 100
        return mapped * s
    }

    func applyAllDSP(skipReverb: Bool = false) {
        audio.setPreamp(db: Float(preampDb))
        audio.setReverb(effective: effective("reverb"), skipUpdate: skipReverb)
        audio.setGroupDelay(effective: effective("gd"))
        audio.setGroupDelayRandomness(effective: effective("gdrand"))
        audio.setGrainEcho(effective: effective("grain"))
        audio.setSpectralBlur(effective: effective("blur"))
        audio.setShimmer(effective: effective("shimmer"))
        audio.setTapeHysteresis(effective: effective("hyst"))
        audio.setTapeSag(effective: effective("sag"))
        audio.setSaturatorRecipe(SaturatorRecipe.named(satRecipe))
        audio.setEQ(gainDb: effective("eq") * 12)
        audio.setSaturator(driveDb: effective("sat") * 16)
        audio.setOddSaturator(driveDb: effective("oddsat") * 16)
        audio.setHighRolloff(dbPerOctave: effective("rolloff") * 6)
    }

    // MARK: - Macro
    func setMacro(_ value: Double, skipReverb: Bool = false) {
        macro = max(0, min(100, value))
        applyAllDSP(skipReverb: skipReverb)
    }

    // MARK: - Playback
    func loadAndPlay(url: URL) {
        do {
            try audio.load(url: url)
            if isPlaying { audio.play() }
            trackName = url.deletingPathExtension().lastPathComponent
            currentTime = 0
            decodeWaveform(url: url)
        } catch {
            trackName = "Error loading track"
        }
    }

    func togglePlay() {
        guard !playlist.tracks.isEmpty else { return }
        if isPlaying {
            audio.pause()
            isPlaying = false
        } else {
            isPlaying = true
            if audio.hasLoadedTrack {
                audio.play()
            } else if let url = playlist.currentTrack ?? playlist.tracks.first {
                // Freshly opened folder: nothing is loaded into the player yet.
                loadAndPlay(url: url)
            }
        }
    }

    func nextTrack() {
        guard let url = playlist.next() else { return }
        loadAndPlay(url: url)
    }

    func prevTrack() {
        guard let url = playlist.prev() else { return }
        loadAndPlay(url: url)
    }

    func selectTrack(index: Int) {
        // Map filtered index back to playlist
        let filtered = playlist.filteredTracks
        guard index < filtered.count else { return }
        let url = filtered[index]
        if let i = playlist.tracks.firstIndex(of: url) {
            playlist.currentIndex = i
        }
        isPlaying = true
        loadAndPlay(url: url)
    }

    private func advanceTrack() {
        guard let url = playlist.next() else { return }
        loadAndPlay(url: url)
    }

    // MARK: - Waveform decoding (peaks for static display)
    func decodeWaveform(url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self,
                  let file = try? AVAudioFile(forReading: url) else { return }
            let frameCount = AVAudioFrameCount(file.length)
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount),
                  (try? file.read(into: buf)) != nil,
                  let ch = buf.floatChannelData else { return }

            let numBars = 300
            let data    = ch[0]
            let block   = max(1, Int(buf.frameLength) / numBars)
            var peaks   = [Float]()
            for i in 0..<numBars {
                var mx: Float = 0
                for j in 0..<block { mx = max(mx, abs(data[i * block + j])) }
                peaks.append(mx)
            }
            let maxP = peaks.max() ?? 1
            let norm = maxP > 0 ? peaks.map { $0 / maxP } : peaks

            DispatchQueue.main.async { self.waveformPeaks = norm }
        }
    }

    // MARK: - Vibrato
    func setMacroMode(_ mode: MacroMode) {
        stopVibrato()
        macroMode = mode
        if mode == .vibrato { startVibrato() }
    }

    private func startVibrato() {
        vibratoOrigin     = macro
        vibratoStartMacro = macro
        vibratoStartTime  = .now
        pickVibratoTarget(from: macro)

        vibratoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.vibratoTick() }
        }
    }

    private func stopVibrato() {
        vibratoTimer?.invalidate()
        vibratoTimer = nil
    }

    private func pickVibratoTarget(from current: Double) {
        let delta        = Double.random(in: -10...10)
        vibratoTarget    = max(0, min(100, vibratoOrigin + delta))
        vibratoStartMacro = current
        vibratoStartTime  = .now
    }

    private func vibratoTick() {
        let duration = vibratoSpeed == .slow ? 10.0 : 2.0
        let t        = min(1, Date.now.timeIntervalSince(vibratoStartTime) / duration)
        let newMacro = vibratoStartMacro + (vibratoTarget - vibratoStartMacro) * t
        setMacro(newMacro, skipReverb: true)   // reverb stays locked during vibrato
        if t >= 1 { pickVibratoTarget(from: newMacro) }
    }

    // MARK: - Presets

    func applyPreset(named name: String) {
        guard let p = GlobalPreset.named(name) else { return }
        selectedPreset = p.name
        sensitivity = p.sensitivity
        ranges = AppSettings().ranges
        satRecipe = p.recipe
        if macroMode != .manual { setMacroMode(.manual) }
        setMacro(p.macro)
    }

    func setRecipe(_ name: String) {
        satRecipe = name
        applyAllDSP()
    }

    // MARK: - Settings save / load
    func saveSettings() {
        var s = AppSettings()
        s.waveColor   = waveColor.hexString
        s.macro       = macro
        s.sensitivity = sensitivity
        s.ranges      = ranges
        s.dynamics    = dynamicsMode == .limiter ? "limiter" : "compressor"
        s.recipe      = satRecipe

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "entropy_settings.json"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: url)
    }

    func loadSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let s    = try? JSONDecoder().decode(AppSettings.self, from: data) else { return }

        waveColor   = Color(hex: s.waveColor)
        // Merge onto INIT so knobs added after the file was saved get their defaults.
        sensitivity = GlobalPreset.initPreset.sensitivity.merging(s.sensitivity) { _, new in new }
        ranges      = AppSettings().ranges.merging(s.ranges) { _, new in new }
        satRecipe   = s.recipe ?? SaturatorRecipe.classic.name
        dynamicsMode = s.dynamics == "compressor" ? .compressor : .limiter
        audio.setDynamics(mode: dynamicsMode)
        setMacro(s.macro)
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(
            red:   Double((v >> 16) & 0xFF) / 255,
            green: Double((v >>  8) & 0xFF) / 255,
            blue:  Double( v        & 0xFF) / 255)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X",
            Int(c.redComponent   * 255),
            Int(c.greenComponent * 255),
            Int(c.blueComponent  * 255))
    }
}
