import SwiftUI
import Combine
import AVFoundation
import CoreAudio

// MARK: - Settings

struct RangeValue: Codable { var min: Double = 0; var max: Double = 100 }

struct AppSettings: Codable {
    var waveColor:    String = "#35d6d0"
    var macro:        Double = 0
    var sensitivity:  [String: Double] = ["reverb": 70, "eq": 50, "sat": 50]
    var ranges:       [String: RangeValue] = [
        "reverb": .init(), "eq": .init(), "sat": .init()
    ]
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
    @Published var sensitivity: [String: Double] = ["reverb": 70, "eq": 50, "sat": 50]
    @Published var ranges: [String: RangeValue]  = ["reverb": .init(), "eq": .init(), "sat": .init()]
    @Published var waveColor: Color = Color(hex: "#35d6d0")
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

    // MARK: Vibrato state
    private var vibratoTimer: Timer?
    private var vibratoOrigin: Double = 0
    private var vibratoTarget: Double = 0
    private var vibratoStartMacro: Double = 0
    private var vibratoStartTime: Date = .now

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
        selectedOutputDeviceID = outputDevices.first?.id
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
        if let id = output { selectedOutputDeviceID = id }
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
            selectedOutputDeviceID = outputDevices.first?.id
        }
    }

    // MARK: - Effective level computation
    // effective = lerp(range.min, range.max, macro) * sensitivity → 0…1
    func effective(_ key: String) -> Float {
        let s = Float(sensitivity[key] ?? 50) / 100
        let r = ranges[key] ?? RangeValue()
        let mapped = Float(r.min + (r.max - r.min) * (macro / 100)) / 100
        return mapped * s
    }

    func applyAllDSP(skipReverb: Bool = false) {
        audio.setPreamp(db: Float(preampDb))
        audio.setReverb(effective: effective("reverb"), skipUpdate: skipReverb)
        audio.setEQ(gainDb: effective("eq") * 12)
        audio.setSaturator(driveDb: effective("sat") * 8)
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
            if playlist.currentTrack != nil {
                audio.play()
            } else {
                if let url = playlist.tracks.first {
                    loadAndPlay(url: url)
                }
            }
            isPlaying = true
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
        loadAndPlay(url: url)
        isPlaying = true
    }

    private func advanceTrack() {
        guard let url = playlist.next() else { return }
        loadAndPlay(url: url)
        if isPlaying { audio.play() }
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

    // MARK: - Settings save / load
    func saveSettings() {
        var s = AppSettings()
        s.waveColor   = waveColor.hexString
        s.macro       = macro
        s.sensitivity = sensitivity
        s.ranges      = ranges
        s.dynamics    = dynamicsMode == .limiter ? "limiter" : "compressor"

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
        sensitivity = s.sensitivity
        ranges      = s.ranges
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
