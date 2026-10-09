import Foundation
import AVFoundation
import AppKit
import UniformTypeIdentifiers

// "Save": renders the current track through EMP's full effect chain with
// the current settings and writes it to a 24-bit WAV.
//
// Uses fresh DSP instances (OfflineChain), so exporting never disturbs live
// playback, and runs on a background thread. The chain mirrors
// AudioEngine.renderChain stage for stage. Notes:
//  • The macro is the same one the Listener Report uses: the live value in
//    Manual mode, the centre of the motion range in Vibrato.
//  • 3 s of silence are rendered after the track so reverb/shimmer tails ring
//    out, and the chain's fixed latency is trimmed from the start.
//  • Group-delay drift runs on its wall-clock timer, so in a faster-than-
//    realtime render it moves less than during playback.

// MARK: - Offline chain

final class OfflineChain {
    static let sampleRate = 44100.0
    /// Fixed latency of the chain: group delay (512 + 64), spectral blur
    /// (2048), tape sag (88).
    static let latency = 512 + 64 + 2048 + 88

    private let s: ChainSettings
    private let gd = GroupDelay(), bl = SpectralBlur(), gr = GrainEcho()
    private let rv = ConvolutionReverb(), sh = Shimmer()
    private let eq = PeakingBiquad(), ss = SubsonicFilter(), rs = RecipeStage()
    private let ev = WebAudioSaturator(voicing: .even), od = WebAudioSaturator(voicing: .odd)
    private let th = TapeHysteresis(), sg = TapeSag(), ro = HighRolloff()
    private let dyn = WebAudioCompressor(), ceiling = WebAudioCompressor()
    private let inGain: Float, fixedDrive: Float, postGain: Float

    init(_ s: ChainSettings) {
        self.s = s
        gd.setScale(s.gdScale); gd.setRandomness(s.gdRandom); gd.flushParameters()
        bl.setStrength(s.blur); gr.setStrength(s.grain)
        rv.setDecay(s.reverbDecaySec); sh.setStrength(s.shimmer)
        eq.setParameters(frequency: 150, q: 0.1, gainDb: s.eqDb)
        rs.configure(s.recipe, amount: (s.evenDb + s.oddDb) / 16)
        ev.setDrive(driveDb: min(24, s.evenDb * s.recipe.evenMul)); ev.setBias(s.recipe.bias)
        od.setDrive(driveDb: min(24, s.oddDb * s.recipe.oddMul))
        th.setStrength(s.hysteresis); sg.setStrength(s.sag); ro.setSlope(dbPerOctave: s.rolloff)
        dyn.setSampleRate(Self.sampleRate)
        if s.compressor {
            dyn.configure(thresholdDb: -18, kneeDb: 12, ratio: 4, attackSec: 0.01, releaseSec: 0.25, trimDb: -12)
        } else {
            dyn.configure(thresholdDb: 0, kneeDb: 0, ratio: 20, attackSec: 0.001, releaseSec: 0.1, trimDb: -6)
        }
        ceiling.setSampleRate(Self.sampleRate)
        ceiling.configure(thresholdDb: 0, kneeDb: 0, ratio: 20, attackSec: 0.0005, releaseSec: 0.05, trimDb: 0)
        inGain = Float(pow(10, (s.fileTrimDb + s.preampDb) / 20))
        fixedDrive = Float(pow(10, 7.0 / 20))
        postGain = Float(pow(10, s.postGainDb / 20))
    }

    /// Stereo, in place, any block size.
    func process(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, count total: Int) {
        var done = 0
        while done < total {
            let n = min(470, total - done), a = l + done, b = r + done
            for i in 0..<n { a[i] *= inGain; b[i] *= inGain }
            gd.process(left: a, right: b, count: n)
            bl.process(left: a, right: b, count: n)
            gr.process(left: a, right: b, count: n)
            rv.process(left: a, right: b, count: n)
            sh.process(left: a, right: b, count: n)
            eq.process(a, count: n, channel: 0); eq.process(b, count: n, channel: 1)
            for i in 0..<n { a[i] *= fixedDrive; b[i] *= fixedDrive }
            for ch in 0..<2 {
                let q = ch == 0 ? a : b
                ss.process(q, count: n, channel: ch)
                rs.pre(q, count: n, channel: ch)
                ev.process(q, count: n, channel: ch)
                od.process(q, count: n, channel: ch)
                rs.post(q, count: n, channel: ch)
                th.process(q, count: n, channel: ch)
            }
            sg.process(left: a, right: b, count: n)
            for i in 0..<n { a[i] /= fixedDrive; b[i] /= fixedDrive }
            ro.process(a, count: n, channel: 0); ro.process(b, count: n, channel: 1)
            dyn.process(left: a, right: b, count: n)
            for i in 0..<n { a[i] *= postGain; b[i] *= postGain }
            ceiling.process(left: a, right: b, count: n)
            done += n
        }
    }
}

// MARK: - File rendering

enum TrackExporter {
    enum ExportError: LocalizedError {
        case convert
        var errorDescription: String? { "Couldn't convert the track's audio format." }
    }

    /// Renders `source` through `settings` into a 24-bit WAV at `dest`.
    /// `progress` is called on an arbitrary thread with 0…1.
    static func render(source: URL, to dest: URL, settings: ChainSettings,
                       progress: (Double) -> Void) throws {
        let input = try AVAudioFile(forReading: source)
        let sr = OfflineChain.sampleRate
        let work = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)!
        guard let converter = AVAudioConverter(from: input.processingFormat, to: work) else { throw ExportError.convert }

        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let output = try AVAudioFile(forWriting: dest, settings: outSettings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)

        let chain = OfflineChain(settings)
        let chunk: AVAudioFrameCount = 8192
        let inBuf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk)!
        let totalOut = Double(input.length) * sr / input.processingFormat.sampleRate
        var toTrim = OfflineChain.latency
        var written = 0.0
        var inputDone = false
        var tailLeft = Int(sr * 3)

        func write(_ buf: AVAudioPCMBuffer) throws {
            let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
            chain.process(left: l, right: r, count: Int(buf.frameLength))
            // Drop the chain's fixed latency from the start of the file.
            let skip = min(toTrim, Int(buf.frameLength))
            toTrim -= skip
            guard Int(buf.frameLength) > skip else { return }
            if skip > 0 {
                let n = Int(buf.frameLength) - skip
                l.assign(from: l + skip, count: n); r.assign(from: r + skip, count: n)
                buf.frameLength = AVAudioFrameCount(n)
            }
            try output.write(from: buf)
            written += Double(buf.frameLength)
            progress(min(1, written / max(1, totalOut)))
        }

        // Decode + resample the track, chunk by chunk.
        while !inputDone {
            let outBuf = AVAudioPCMBuffer(pcmFormat: work, frameCapacity: chunk * 2)!
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
                do {
                    try input.read(into: inBuf, frameCount: chunk)
                } catch {
                    outStatus.pointee = .endOfStream; return nil
                }
                if inBuf.frameLength == 0 { outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return inBuf
            }
            if let err { throw err }
            if outBuf.frameLength > 0 {
                if input.processingFormat.channelCount == 1 {      // mono source → both sides
                    outBuf.floatChannelData![1].assign(from: outBuf.floatChannelData![0], count: Int(outBuf.frameLength))
                }
                try write(outBuf)
            }
            if status == .endOfStream || status == .error { inputDone = true }
        }

        // Let tails ring out (plus the trimmed latency).
        tailLeft += OfflineChain.latency
        while tailLeft > 0 {
            let n = min(Int(chunk), tailLeft)
            let buf = AVAudioPCMBuffer(pcmFormat: work, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            for c in 0..<2 { buf.floatChannelData![c].assign(repeating: 0, count: n) }
            try write(buf)
            tailLeft -= n
        }
        progress(1)
    }
}

// MARK: - App wiring

extension AppState {
    /// Snapshot of the current settings for offline rendering.
    func currentChainSettings() -> ChainSettings {
        let m = reportMacro
        let eff = { self.effective($0, atMacro: m) }
        var cs = ChainSettings()
        cs.fileTrimDb = AudioEngine.fileTrimDb
        cs.preampDb = preampDb
        cs.postGainDb = postGainDb
        cs.eqDb = eff("eq") * 12
        cs.evenDb = eff("sat") * 16
        cs.oddDb = eff("oddsat") * 16
        cs.recipe = SaturatorRecipe.named(satRecipe)
        cs.hysteresis = eff("hyst"); cs.sag = eff("sag")
        cs.rolloff = eff("rolloff") * 6
        cs.compressor = dynamicsMode == .compressor
        cs.gdScale = eff("gd") * 20
        cs.gdRandom = eff("gdrand") * 0.5
        cs.blur = eff("blur"); cs.grain = eff("grain")
        cs.reverbDecaySec = pow(eff("reverb"), 1.5) * 60
        cs.shimmer = eff("shimmer")
        return cs
    }

    func exportCurrentTrack() {
        guard !isExporting else { return }
        guard let source = playlist.currentTrack else {
            exportStatus = "Open a folder and pick a track first"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + " (EMP).wav"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let settings = currentChainSettings()
        isExporting = true
        exportStatus = "Exporting… 0%"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var lastShown = -1
            do {
                try TrackExporter.render(source: source, to: dest, settings: settings) { p in
                    let pct = Int(p * 100)
                    guard pct != lastShown else { return }
                    lastShown = pct
                    DispatchQueue.main.async { self?.exportStatus = "Exporting… \(pct)%" }
                }
                DispatchQueue.main.async {
                    self?.isExporting = false
                    self?.exportStatus = "Saved \(dest.lastPathComponent)"
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isExporting = false
                    self?.exportStatus = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
