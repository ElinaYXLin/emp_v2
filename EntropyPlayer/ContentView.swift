import SwiftUI

// MARK: - Shared button style

struct EntBtn: ButtonStyle {
    var active: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(active
                ? LinearGradient(colors: [Color(hex:"#6b3524"), Color(hex:"#3a1c12")], startPoint:.topLeading, endPoint:.bottomTrailing)
                : LinearGradient(colors: [Color(hex:"#3a352c"), Color(hex:"#211d18")], startPoint:.topLeading, endPoint:.bottomTrailing))
            .foregroundColor(active ? Color(hex:"#ffd9c4") : Color(hex:"#d9d1bf"))
            .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color.black.opacity(0.5), lineWidth: 1))
            .shadow(color: active ? Color(hex:"#c65a2e").opacity(0.35) : .clear, radius: 8)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

// MARK: - Root view

struct ContentView: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            topBar
            mainGrid
            transport
        }
        .background(Color(hex: "#0f0d0b"))
        .preferredColorScheme(.dark)
    }

    // MARK: Top bar

    var topBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1
            HStack(spacing: 8) {
                Button("Open") { app.playlist.openFolder() }.buttonStyle(EntBtn())
                Button("Save") { app.audio.isPlaying ? nil : () /* no save feature in app */
                }.buttonStyle(EntBtn())
                searchField
                Divider().frame(height: 22)
                orderToggle
                Button("Save Settings") { app.saveSettings() }.buttonStyle(EntBtn())
                Button("Load Settings") { app.loadSettings() }.buttonStyle(EntBtn())
                Spacer()
                Text("COLOR").font(.system(size: 9, design: .monospaced)).foregroundColor(Color(hex:"#8f8778"))
                ColorPicker("", selection: $app.waveColor).labelsHidden().frame(width: 30)
            }
            .padding(.horizontal, 16).padding(.top, 12)

            // Row 2
            HStack(spacing: 8) {
                dynamicsToggle
                macroModeToggle
                if app.macroMode == .vibrato {
                    vibratoSpeedToggle
                        .transition(.opacity)
                }
                Divider().frame(height: 22)
                systemCaptureToggle
                if !app.inputDevices.isEmpty {
                    devicePicker
                }
                if let err = app.systemCaptureError {
                    Text(err)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex: "#ff4444"))
                        .onTapGesture { app.systemCaptureError = nil }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
        .background(Color(hex:"#29241e"))
    }

    var searchField: some View {
        ZStack(alignment: .bottomLeading) {
            TextField("Search tracks…", text: $app.playlist.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(hex:"#d9d1bf"))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color(hex:"#17140f"))
                .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color.black.opacity(0.6), lineWidth: 1))
                .frame(width: 160)

            if !app.playlist.searchQuery.isEmpty {
                searchDropdown
                    .offset(y: 30)
                    .zIndex(99)
            }
        }
    }

    var searchDropdown: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let hits = app.playlist.filteredTracks
                if hits.isEmpty {
                    Text("No matches").font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex:"#8f8778")).padding(8)
                } else {
                    ForEach(Array(hits.enumerated()), id: \.offset) { i, url in
                        let name = url.deletingPathExtension().lastPathComponent
                        Button(action: {
                            if let idx = app.playlist.tracks.firstIndex(of: url) {
                                app.playlist.currentIndex = idx
                                app.loadAndPlay(url: url)
                                app.isPlaying = true
                            }
                            app.playlist.searchQuery = ""
                        }) {
                            Text(name).font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(hex:"#8f8778"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .background(Color.clear)
                        .contentShape(Rectangle())
                        .hoverHighlight()
                        Divider().background(Color.black.opacity(0.4))
                    }
                }
            }
        }
        .frame(width: 260)
        .frame(maxHeight: 300)
        .background(Color(hex:"#29241e"))
        .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color.black.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 12, y: 8)
    }

    var orderToggle: some View {
        HStack(spacing: 0) {
            Button("Alphabetical") {
                app.playlist.order = .alpha
            }
            .buttonStyle(EntBtn(active: app.playlist.order == .alpha))

            Button("Shuffle") {
                app.playlist.order = .shuffle
            }
            .buttonStyle(EntBtn(active: app.playlist.order == .shuffle))
        }
    }

    var dynamicsToggle: some View {
        HStack(spacing: 0) {
            Button("Limiter") {
                app.dynamicsMode = .limiter
                app.audio.setDynamics(mode: .limiter)
            }
            .buttonStyle(EntBtn(active: app.dynamicsMode == .limiter))

            Button("Compressor") {
                app.dynamicsMode = .compressor
                app.audio.setDynamics(mode: .compressor)
            }
            .buttonStyle(EntBtn(active: app.dynamicsMode == .compressor))
        }
    }

    var macroModeToggle: some View {
        HStack(spacing: 0) {
            Button("Manual") { app.setMacroMode(.manual) }
                .buttonStyle(EntBtn(active: app.macroMode == .manual))
            Button("Vibrato") { app.setMacroMode(.vibrato) }
                .buttonStyle(EntBtn(active: app.macroMode == .vibrato))
        }
    }

    var vibratoSpeedToggle: some View {
        HStack(spacing: 0) {
            Button("Slow") { app.vibratoSpeed = .slow }
                .buttonStyle(EntBtn(active: app.vibratoSpeed == .slow))
            Button("Fast") { app.vibratoSpeed = .fast }
                .buttonStyle(EntBtn(active: app.vibratoSpeed == .fast))
        }
    }

    var systemCaptureToggle: some View {
        Button(action: { app.toggleSystemCapture() }) {
            HStack(spacing: 5) {
                if app.systemCaptureActive {
                    Circle().fill(Color(hex: "#ff4444")).frame(width: 6, height: 6)
                }
                Text("System")
            }
        }
        .buttonStyle(EntBtn(active: app.systemCaptureActive))
        .onAppear { app.refreshInputDevices() }
    }

    var devicePicker: some View {
        HStack(spacing: 4) {
            Text("IN").font(.system(size: 9, design: .monospaced)).foregroundColor(Color(hex:"#8f8778"))
            Picker("", selection: Binding(
                get: { app.selectedInputDeviceID },
                set: { if let id = $0 { app.switchCaptureDevice(input: id) } }
            )) {
                ForEach(app.inputDevices, id: \.id) { dev in
                    Text(dev.name).tag(Optional(dev.id))
                }
            }
            .labelsHidden()
            .frame(width: 140)
            .pickerStyle(.menu)

            Text("OUT").font(.system(size: 9, design: .monospaced)).foregroundColor(Color(hex:"#8f8778"))
            Picker("", selection: Binding(
                get: { app.selectedOutputDeviceID },
                set: { if let id = $0 { app.switchCaptureDevice(output: id) } }
            )) {
                ForEach(app.outputDevices, id: \.id) { dev in
                    Text(dev.name).tag(Optional(dev.id))
                }
            }
            .labelsHidden()
            .frame(width: 140)
            .pickerStyle(.menu)
        }
    }

    // MARK: Main grid

    var mainGrid: some View {
        HStack(alignment: .top, spacing: 14) {
            preampPanel
            macroPanel
            centerPanel
            macroSliderPanel
            postGainPanel
        }
        .padding(14)
    }

    // MARK: Pre-amp

    var preampPanel: some View {
        ZStack {
            panelBG
            VStack {
                let preampPct = Binding(
                    get: { (app.preampDb + 12) / 12 * 100 },   // -12→0 dB maps 0→100
                    set: { app.preampDb = $0 / 100 * 12 - 12;
                           app.audio.setPreamp(db: Float(app.preampDb)) })
                VerticalSliderView(
                    title: "PRE-AMP",
                    pct: preampPct,
                    displayText: app.preampDb == 0 ? "0 dB" : String(format: "%.1f dB", app.preampDb),
                    accentColor: Color(hex: "#ff7a3d"))
            }
            .padding(12)
        }
        .frame(width: 68)
    }

    // MARK: Knobs panel

    var macroPanel: some View {
        ZStack {
            panelBG
            VStack(alignment: .leading, spacing: 18) {
                knobRow(key: "reverb", label: "Reverb",    sub: "Decay time",
                        display: { String(format: "%.1fs", pow($0/100, 2) * 20) })
                knobRow(key: "eq",     label: "Lo-Mid EQ", sub: "Gain",
                        display: { String(format: "%.1fdB", $0/100*12) })
                knobRow(key: "sat",    label: "Saturator", sub: "Gain",
                        display: { String(format: "%.1fdB", $0/100*8) })
            }
            .padding(14)
        }
        .frame(width: 260)
    }

    @ViewBuilder
    func knobRow(key: String, label: String, sub: String, display: @escaping (Double) -> String) -> some View {
        let sensitivity = Binding(
            get: { app.sensitivity[key] ?? 50 },
            set: { app.sensitivity[key] = $0; app.applyAllDSP() })
        let rangeMin = Binding(
            get: { app.ranges[key]?.min ?? 0 },
            set: { var r = app.ranges[key] ?? .init(); r.min = $0; app.ranges[key] = r; app.applyAllDSP() })
        let rangeMax = Binding(
            get: { app.ranges[key]?.max ?? 100 },
            set: { var r = app.ranges[key] ?? .init(); r.max = $0; app.ranges[key] = r; app.applyAllDSP() })

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                KnobView(label: label, sublabel: "Sensitivity",
                         value: sensitivity, display: { "\(Int($0))%" })
            }
            HStack(spacing: 6) {
                Text("Range").font(.system(size: 8, design: .monospaced)).foregroundColor(Color(hex:"#8f8778")).frame(width:42)
                VStack(spacing: 3) {
                    HStack {
                        Text("\(Int(rangeMin.wrappedValue))%").font(.system(size: 8, design: .monospaced)).foregroundColor(Color(hex:"#8f8778")).frame(width:26)
                        Slider(value: rangeMin, in: 0...(rangeMax.wrappedValue - 1))
                            .accentColor(Color(hex:"#c65a2e"))
                    }
                    HStack {
                        Text("\(Int(rangeMax.wrappedValue))%").font(.system(size: 8, design: .monospaced)).foregroundColor(Color(hex:"#8f8778")).frame(width:26)
                        Slider(value: rangeMax, in: (rangeMin.wrappedValue + 1)...100)
                            .accentColor(Color(hex:"#ff7a3d"))
                    }
                }
            }
        }
    }

    // MARK: Center (waveform + track info)

    var centerPanel: some View {
        ZStack {
            panelBG
            VStack(spacing: 8) {
                Text("SIGNAL")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(hex:"#d9d1bf").opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)

                WaveformView(
                    peaks: app.waveformPeaks,
                    liveSamples: app.analyserSamples.map { abs($0) },
                    isPlaying: app.isPlaying,
                    macro: app.macro,
                    color: app.waveColor)
                .frame(height: 220)

                HStack {
                    Text(app.trackName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(hex:"#8f8778"))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(timeString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(hex:"#8f8778"))
                }
            }
            .padding(14)
        }
    }

    var timeString: String {
        if app.systemCaptureActive { return "LIVE" }
        func fmt(_ s: Double) -> String {
            let m = Int(s) / 60; let ss = Int(s) % 60
            return String(format: "%d:%02d", m, ss)
        }
        return "\(fmt(app.currentTime)) / \(fmt(app.audio.duration))"
    }

    // MARK: Macro slider

    var macroSliderPanel: some View {
        ZStack {
            panelBG
            VStack(spacing: 0) {
                VerticalSliderView(
                    title: "MACRO",
                    pct: Binding(get: { app.macro }, set: { v in
                        if app.macroMode != .manual { app.setMacroMode(.manual) }
                        app.setMacro(v)
                    }),
                    displayText: "\(Int(app.macro))%",
                    accentColor: app.waveColor)
            }
            .padding(8)
        }
        .frame(width: 68)
    }

    // MARK: Post-gain (final output volume, sent to the actual output device)

    var postGainPanel: some View {
        ZStack {
            panelBG
            VStack {
                let postGainPct = Binding(
                    get: { (app.postGainDb + 24) / 48 * 100 },   // -24→24 dB maps 0→100
                    set: { app.postGainDb = $0 / 100 * 48 - 24
                           app.audio.setPostGain(db: Float(app.postGainDb)) })
                VerticalSliderView(
                    title: "POST-GAIN",
                    pct: postGainPct,
                    displayText: app.postGainDb == 0 ? "0 dB" : String(format: "%.1f dB", app.postGainDb),
                    accentColor: Color(hex: "#3dd6ff"))
            }
            .padding(12)
        }
        .frame(width: 68)
    }

    // MARK: Transport

    var transport: some View {
        ZStack {
            Color(hex: "#29241e")
            if app.systemCaptureActive {
                HStack(spacing: 12) {
                    Circle().fill(Color(hex: "#ff4444")).frame(width: 8, height: 8)
                        .opacity(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : 0.3)
                    Text("LIVE — System Audio")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: "#d9d1bf").opacity(0.7))
                    Button("Stop") { app.toggleSystemCapture() }
                        .buttonStyle(EntBtn(active: false))
                }
                .padding(.vertical, 16)
            } else {
                HStack(spacing: 22) {
                    transportBtn(icon: "backward.fill", size: 15, diameter: 50) { app.prevTrack() }
                    transportBtn(icon: app.isPlaying ? "pause.fill" : "play.fill", size: 19, diameter: 62, accent: true) {
                        app.togglePlay()
                    }
                    transportBtn(icon: "forward.fill", size: 15, diameter: 50) { app.nextTrack() }
                }
                .padding(.vertical, 16)
            }
        }
        .frame(height: 90)
    }

    func transportBtn(icon: String, size: CGFloat, diameter: CGFloat, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size))
                .frame(width: diameter, height: diameter)
                .background(
                    Circle().fill(accent
                        ? RadialGradient(colors: [Color(hex:"#6b3524"), Color(hex:"#2a140c")], center:.init(x:0.32,y:0.28), startRadius:0, endRadius: diameter/2)
                        : RadialGradient(colors: [Color(hex:"#4a453d"), Color(hex:"#1c1a16")], center:.init(x:0.32,y:0.28), startRadius:0, endRadius: diameter/2))
                )
                .overlay(Circle().stroke(Color(hex: accent ? "#ff7a3d" : "#ffffff").opacity(accent ? 0.3 : 0.05), lineWidth: 1))
                .shadow(color: accent ? Color(hex:"#c65a2e").opacity(0.3) : .black.opacity(0.5), radius: accent ? 12 : 5, y: 3)
                .foregroundColor(Color(hex:"#d9d1bf"))
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    var panelBG: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(LinearGradient(
                colors: [Color(hex:"#29241e"), Color(hex:"#1b1814")],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 14, y: 10)
    }
}

// MARK: - Hover highlight modifier

extension View {
    func hoverHighlight() -> some View {
        self.modifier(HoverHighlightModifier())
    }
}

struct HoverHighlightModifier: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(hovered ? Color(hex:"#ff7a3d").opacity(0.12) : Color.clear)
            .onHover { hovered = $0 }
    }
}
