import AVFoundation
import AudioToolbox
import CoreAudio
import AppKit
import Accelerate

// File-level C-callable callbacks for System mode's raw HAL units.
// Non-capturing → implicitly @convention(c) → safe to pass as AURenderCallback.
// Both run on CoreAudio's realtime I/O threads.

// Capture (BlackHole) input unit: pull the just-captured frames and push
// them into the capture ring.
private let _captureInput: AURenderCallback = { refCon, ioActionFlags, inTimeStamp, inBusNumber, numFrames, _ in
    let eng = Unmanaged<AudioEngine>.fromOpaque(refCon).takeUnretainedValue()
    eng.captureInputArrived(flags: ioActionFlags, timeStamp: inTimeStamp, bus: inBusNumber, frames: numFrames)
    return noErr
}

// Output device unit: read the capture ring and run the whole DSP chain
// straight into the output buffer.
private let _captureOutput: AURenderCallback = { refCon, _, _, _, numFrames, ioData in
    let eng = Unmanaged<AudioEngine>.fromOpaque(refCon).takeUnretainedValue()
    guard let ioData else { return noErr }
    eng.renderCaptureOutput(ioData, frames: Int(numFrames))
    return noErr
}

final class AudioEngine {

    // MARK: - Nodes
    private let engine       = AVAudioEngine()
    private let player       = AVAudioPlayerNode()
    private let preampMixer  = AVAudioMixerNode()
    private let tapMixer     = AVAudioMixerNode()

    // DSP bridge. AVAudioEngine can't host our custom Swift DSP as an
    // in-graph effect under App Sandbox (custom AUAudioUnit lookup fails with
    // -3000), so audio leaves the graph through a tap on preampMixer and
    // re-enters through dspSourceNode, whose render callback runs the whole
    // chain inline:
    //   group delay → spectral blur → grain echo → reverb → shimmer → EQ → +7 dB → 25 Hz high-pass → even sat → odd sat → high roll-off
    //   (with recipe shaping around the saturators) → tape hysteresis → tape sag
//   → high roll-off → limiter/compressor → post-gain → output ceiling
    //
    // This used to be four chained tap→ring→source-node bridges, one per
    // stage. Taps deliver audio in ~100 ms chunks (4410 frames, whatever
    // bufferSize is requested) and none of those rings kept a cushion, so
    // any timing jitter — a reverb knob drag, or the capture and output
    // devices' clocks drifting apart in System mode — left a gap at chunk
    // boundaries: a ~10 Hz "tak-tak-tak" that the saturator made worse, and
    // that never recovered. Now there is exactly one bridge (see JitterRing),
    // it re-primes a proper cushion after any underrun, and the tap itself
    // only copies samples, so its timing no longer depends on DSP load.
    private let preampSink = AVAudioMixerNode()   // muted keep-alive for the tap
    private var dspSourceNode: AVAudioSourceNode!
    // Taps run on an ordinary (non-realtime) thread, so under system load a
    // chunk can arrive well over 100 ms late — keep ~150 ms of slack beyond
    // one chunk. (Latency only affects play/pause response here.)
    private let dspRing = JitterRing(primeFrames: 4410 + 6615, maxFrames: 4410 * 4 + 6615)
    private static let maxRenderFrames = 4096
    private var scratchL = [Float](repeating: 0, count: AudioEngine.maxRenderFrames)
    private var scratchR = [Float](repeating: 0, count: AudioEngine.maxRenderFrames)

    // Custom convolution reverb (see ConvolutionReverb.swift): replaces
    // AUReverb2, whose algorithmic comb/allpass decay scales completely
    // differently with decay-time than the web edition's real noise
    // convolution — no amount of parameter tuning matched the web app's
    // macro-to-loudness curve.
    private let reverbFilter     = ConvolutionReverb()
    // Frequency-dependent group delay (see GroupDelay.swift), just ahead of
    // the reverb.
    private let groupDelay       = GroupDelay()
    // Granular memory haze (see GrainEcho.swift), between group delay and
    // the reverb so its grains blur into the reverb tail.
    private let grainEcho        = GrainEcho()
    // Spectral haze: per-frequency level slew (see SpectralBlur.swift).
    private let spectralBlur     = SpectralBlur()
    // Temporal haze: octave-down feedback glow after the reverb (see Shimmer.swift).
    private let shimmer          = Shimmer()

    // Custom saturators (see CustomSaturator.swift): replace Apple's
    // AVAudioUnitDistortion, whose presets are built from ring-modulation,
    // decimation, and delay effects — not the plain tanh soft-clip the web
    // edition uses. That mismatch produced a boomy artifact once the EQ's
    // bass boost drove it.
    private let satFilter     = WebAudioSaturator(voicing: .even)
    private let oddSatFilter  = WebAudioSaturator(voicing: .odd)
    private let highRolloff   = HighRolloff()
    private let subsonic      = SubsonicFilter()
    // Saturator recipe shaping and tape stages (see SaturatorRecipes.swift, Tape.swift).
    private let recipeStage   = RecipeStage()
    private let tapeHyst      = TapeHysteresis()
    private let tapeSag       = TapeSag()
    private var evenDriveDb: Float = 0, oddDriveDb: Float = 0
    private var recipe = SaturatorRecipe.classic

    // Custom dynamics (see CustomDynamics.swift): replaces Apple's
    // AUDynamicsProcessor, which sounds fundamentally different from Web
    // Audio's DynamicsCompressorNode (smooth/pumping vs. transients slipping
    // past into real distortion) no matter how its parameters are tuned.
    private let compressor    = WebAudioCompressor()

    // Output ceiling: the Limiter/Compressor stage already targets peaks
    // close to 0 dBFS, so Post-Gain (applied after it, with no headroom
    // management of its own) can easily push samples past ±1.0 — which the
    // final float→hardware conversion hard-clips, a much harsher sound than
    // anything our own DSP produces. This is a second, always-on
    // WebAudioCompressor instance used purely as a brickwall safety ceiling
    // so pushing Post-Gain up compresses gracefully instead of clipping.
    private let outputCeiling = WebAudioCompressor()

    /// A-weighted level of the final output, for the listening-level meter.
    let listeningMeter = AWeightedMeter()

    // Custom peaking EQ (see CustomEQ.swift): AVAudioUnitEQ can't reach the
    // web edition's very wide Q 0.1 bell.
    private let eqFilter     = PeakingBiquad()

    // Fixed +7 dB drive *into the saturation stage only*, undone right after
    // it (after tape sag), so it sets how hard the saturators/tape are hit
    // without raising the level that reaches the limiter. (It used to stay
    // in the signal — a leftover from compensating AUReverb2's insertion
    // loss — and pushed everything 7 dB hotter into the limiter.)
    private let preLimiterGainLinear: Float = pow(10, 7.0 / 20.0)

    /// Fixed trim on local-file playback (see buildGraph). Also used by export.
    static let fileTrimDb = -12.0

    // MARK: - Tap output
    var onSamples: (([Float]) -> Void)?

    // MARK: - Track completion
    var onTrackEnded: (() -> Void)?

    // MARK: - Internal state
    private var currentFile: AVAudioFile?
    private(set) var duration: Double = 0
    private var scheduledStartSample: AVAudioFramePosition = 0

    // MARK: - Init

    init() {
        // Custom peaking EQ bridge (see CustomEQ.swift) — matches the web
        // edition's Web Audio biquad (150 Hz, Q 0.1) exactly. eqSourceNode's
        // real render block is created in buildGraph(), once self is fully
        // initialized and can be captured.
        eqFilter.setParameters(frequency: 150, q: 0.1, gainDb: 0)
        satFilter.setDrive(driveDb: 0)
        oddSatFilter.setDrive(driveDb: 0)
        highRolloff.setSlope(dbPerOctave: 0)
        compressor.setSampleRate(44100)
        reverbFilter.setSampleRate(44100)
        groupDelay.setSampleRate(44100)

        // Transparent until driven — same brickwall shape as the Limiter
        // mode, but this one is never user-switchable and always active,
        // purely to catch Post-Gain overs before they hit the hardware.
        outputCeiling.setSampleRate(44100)
        outputCeiling.configure(thresholdDb: 0, kneeDb: 0, ratio: 20,
                                 attackSec: 0.0005, releaseSec: 0.05, trimDb: 0)

        // Device buffer size first, then start the engine: resizing it after
        // start left the output unit with a stale 470-frame slice limit while
        // the device asked for 512 (kAudioUnitErr_TooManyFramesToProcess).
        setLowLatency()
        buildGraph()
        startDiagnostics()
        applyLimiterMode()
        setReverb(effective: 0)  // establish the baseline IR immediately, matching
                                  // the web edition's applyReverb(0) call at page load.
        observeAudioHardwareChanges()
    }

    deinit {
        if let configChangeObserver { NotificationCenter.default.removeObserver(configChangeObserver) }
        if let wakeObserver { NotificationCenter.default.removeObserver(wakeObserver) }
        if let deviceListener {
            var defaultAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, DispatchQueue.main, deviceListener)
            var listAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listAddr, DispatchQueue.main, deviceListener)
        }
    }

    // MARK: - Device / sleep-wake handling
    //
    // Without this, unplugging/replugging headphones or sleeping/waking the
    // Mac leaves the engine running against a stale hardware configuration —
    // manifests as distorted/slow-sounding audio (sample rate mismatch),
    // total silence, or stray CoreAudio device-ID errors in the console
    // ("no device with given ID") from code (including setLowLatency) that
    // cached a device ID from before the change.
    //
    // AVAudioEngineConfigurationChange alone wasn't reliably catching plug/
    // unplug events, so this also listens directly to the HAL's own device-
    // list and default-output-device properties — the same mechanism every
    // CoreAudio app uses to detect this. A short debounce coalesces the
    // several notifications a single unplug/replug can fire and gives
    // CoreAudio's device enumeration a moment to settle before we touch
    // anything — restarting mid-transition is what produced the "no device
    // with given ID" errors even with the first fix in place.

    private var configChangeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var restartWorkItem: DispatchWorkItem?

    private func observeAudioHardwareChanges() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.scheduleRestartAfterHardwareChange()
        }
        wakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleRestartAfterHardwareChange()
        }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRestartAfterHardwareChange()
        }
        deviceListener = listener
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, DispatchQueue.main, listener)
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listAddr, DispatchQueue.main, listener)
    }

    private func scheduleRestartAfterHardwareChange() {
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restartAfterHardwareChange() }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func restartAfterHardwareChange() {
        // System-capture mode manages the main engine (manual rendering) and
        // the raw EarPods AUHAL separately — restarting a fresh capture
        // session is the correct recovery there, not restarting the main
        // engine's normal hardware I/O.
        guard !isSystemCapture else { return }
        let wasPlaying = player.isPlaying
        engine.stop()
        applyPlaybackOutputDevice()
        setLowLatency()
        do {
            try engine.start()
            if wasPlaying { player.play() }
        } catch {
            // CoreAudio may still be settling right after a device change —
            // retry once more shortly rather than leaving the engine dead.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                try? self?.engine.start()
            }
        }
    }

    // MARK: - Graph setup

    private func buildGraph() {
        let dspFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

        dspSourceNode = AVAudioSourceNode(format: dspFormat) { [weak self] _, _, frameCount, abl in
            guard let self else { return noErr }
            let list = UnsafeMutableAudioBufferListPointer(abl)
            var done = 0
            let total = Int(frameCount)
            while done < total {
                let n = min(total - done, Self.maxRenderFrames)
                self.scratchL.withUnsafeMutableBufferPointer { lb in
                    self.scratchR.withUnsafeMutableBufferPointer { rb in
                        let l = lb.baseAddress!, r = rb.baseAddress!
                        self.dspRing.read(left: l, right: r, count: n)
                        self.renderChain(left: l, right: r, count: n)
                        if list.count > 0, let out = list[0].mData?.assumingMemoryBound(to: Float.self) {
                            (out + done).assign(from: l, count: n)
                        }
                        if list.count > 1, let out = list[1].mData?.assumingMemoryBound(to: Float.self) {
                            (out + done).assign(from: r, count: n)
                        }
                    }
                }
                done += n
            }
            return noErr
        }

        for n in [player, preampMixer, preampSink, dspSourceNode, tapMixer] as [AVAudioNode] {
            engine.attach(n)
        }
        engine.connect(player, to: preampMixer, format: nil)
        // Local files arrive at full mastered level, far hotter than System
        // mode usually sees (BlackHole sources are typically turned down), so
        // the same knobs clipped files much harder. A fixed trim puts files in
        // the same ballpark; Pre-Amp then sets the drive from there.
        player.volume = pow(10, Float(Self.fileTrimDb) / 20)

        // preampMixer's only downstream connection is this muted sink — it
        // keeps preampMixer part of the render graph (so its tap fires)
        // without adding a second, unprocessed copy of the signal.
        engine.connect(preampMixer, to: preampSink, format: dspFormat)
        preampSink.outputVolume = 0
        engine.connect(preampSink, to: engine.mainMixerNode, format: nil)

        // The tap only copies — all DSP happens in dspSourceNode's render.
        preampMixer.installTap(onBus: 0, bufferSize: 256, format: dspFormat) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData else { return }
            let stereo = buf.format.channelCount > 1
            self.dspRing.write(left: ch[0], right: stereo ? ch[1] : ch[0], count: Int(buf.frameLength))
        }

        engine.connect(dspSourceNode, to: tapMixer, format: dspFormat)
        engine.connect(tapMixer,      to: engine.mainMixerNode, format: nil)

        tapMixer.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buf, _ in
            guard let ch = buf.floatChannelData else { return }
            let n = min(Int(buf.frameLength), 256)
            self?.onSamples?((0..<n).map { ch[0][$0] })
        }

        allowLargeOutputSlices()
        try? engine.start()
    }

    /// Let the engine's hardware output unit render any slice size the
    /// device may request (must be set while the unit is uninitialized).
    private func allowLargeOutputSlices() {
        guard let au = engine.outputNode.audioUnit else { return }
        var maxFrames = UInt32(Self.maxRenderFrames)
        AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4)
    }

    // Once-a-minute glitch summary for normal playback (System mode logs its
    // own). Silent when nothing went wrong.
    private var diagTimer: Timer?
    private func startDiagnostics() {
        diagTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, !self.isSystemCapture else { return }
            let u = self.dspRing.underruns, t = self.dspRing.trims
            if u + t > 0 {
                NSLog("[EntropyPlayer] Playback glitches in last minute: ring underruns=%d, trims=%d", u, t)
            }
            self.dspRing.underruns = 0; self.dspRing.trims = 0
        }
    }

    /// The full DSP chain, in place, on the render thread.
    private func renderChain(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, count n: Int) {
        // Spectral haze, then temporal haze.
        groupDelay.process(left: l, right: r, count: n)
        spectralBlur.process(left: l, right: r, count: n)
        grainEcho.process(left: l, right: r, count: n)
        reverbFilter.process(left: l, right: r, count: n)
        shimmer.process(left: l, right: r, count: n)

        eqFilter.process(l, count: n, channel: 0)
        eqFilter.process(r, count: n, channel: 1)
        var g = preLimiterGainLinear
        vDSP_vsmul(l, 1, &g, l, 1, vDSP_Length(n))
        vDSP_vsmul(r, 1, &g, r, 1, vDSP_Length(n))

        // Color stage: subsonic cut → even saturator → odd saturator → high
        // roll-off (after both, so it also tames the harmonics they add).
        for ch in 0..<2 {
            let buf = ch == 0 ? l : r
            subsonic.process(buf, count: n, channel: ch)
            recipeStage.pre(buf, count: n, channel: ch)
            satFilter.process(buf, count: n, channel: ch)
            oddSatFilter.process(buf, count: n, channel: ch)
            recipeStage.post(buf, count: n, channel: ch)
            tapeHyst.process(buf, count: n, channel: ch)
        }
        tapeSag.process(left: l, right: r, count: n)
        var gInv = 1 / preLimiterGainLinear
        vDSP_vsmul(l, 1, &gInv, l, 1, vDSP_Length(n))
        vDSP_vsmul(r, 1, &gInv, r, 1, vDSP_Length(n))
        highRolloff.process(l, count: n, channel: 0)
        highRolloff.process(r, count: n, channel: 1)

        compressor.process(left: l, right: r, count: n)

        var pg = postGainLinear
        vDSP_vsmul(l, 1, &pg, l, 1, vDSP_Length(n))
        vDSP_vsmul(r, 1, &pg, r, 1, vDSP_Length(n))
        // Safety ceiling: catches any Post-Gain overs gracefully instead
        // of letting them hard-clip at the final hardware conversion.
        outputCeiling.process(left: l, right: r, count: n)
        // Listening-level meter taps the final output (read-only).
        listeningMeter.process(left: l, right: r, count: n)
    }

    // MARK: - Playback output device
    //
    // File playback goes to the same OUT device chosen for System mode, not
    // blindly to the Mac's default output — which, for anyone using System
    // mode, is usually BlackHole: file playback then went silently into
    // BlackHole instead of the headphones.

    private var playbackOutputDevice: AudioDeviceID?

    /// Routes file playback to `id` (restarting the engine if needed).
    func setPlaybackOutputDevice(_ id: AudioDeviceID?) {
        playbackOutputDevice = id
        guard !isSystemCapture else { return }       // capture units own the output then
        let wasRunning = engine.isRunning, wasPlaying = player.isPlaying
        engine.stop()
        applyPlaybackOutputDevice()
        setLowLatency()
        if wasRunning || currentFile != nil {
            try? engine.start()
            if wasPlaying { player.play() }
        }
    }

    private func applyPlaybackOutputDevice() {
        guard var dev = playbackOutputDevice, let au = engine.outputNode.audioUnit else { return }
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    private func setLowLatency() {
        var devID = AudioDeviceID(kAudioObjectUnknown)
        var sz    = UInt32(MemoryLayout<AudioDeviceID>.size)
        var prop  = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        if let chosen = playbackOutputDevice {
            devID = chosen
        } else {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &sz, &devID)
        }
        guard devID != kAudioObjectUnknown else { return }
        var frames: UInt32 = 256
        prop.mSelector = kAudioDevicePropertyBufferFrameSize
        AudioObjectSetPropertyData(devID, &prop, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
    }

    // MARK: - DSP setters

    /// Pre-amp: -12 dB to 0 dB
    func setPreamp(db: Float) {
        preampMixer.outputVolume = pow(10, db / 20)
        preampLinear = pow(10, db / 20)
    }

    // Post-gain: applied last, in dynSourceNode's render callback — after
    // reverb/EQ/saturator/limiter have all already run. Raising this makes
    // the final signal sent to the output device louder without re-driving
    // any of the DSP stages (unlike Pre-Amp, which sits at the front of the
    // chain and just pushes harder into the saturator/limiter, adding more
    // distortion rather than more clean volume).
    private var postGainLinear: Float = 1.0

    /// Post-gain: -24 to +24 dB — a clean final trim, louder or softer, with
    /// no effect on the DSP chain's own character (unlike Pre-Amp).
    func setPostGain(db: Float) {
        postGainLinear = pow(10, db / 20)
    }

    /// Reverb: effective 0–1 (already squared by caller). Matches the web
    /// edition's applyReverb() exactly: decay = eff^1.5 * 60, convolved with a
    /// decaying-noise impulse response (see ConvolutionReverb.swift) — real
    /// convolution, not an algorithmic reverb, so the loudness/character
    /// scales with the macro exactly the same way the web app's does.
    func setReverb(effective eff: Float, skipUpdate: Bool = false) {
        guard !skipUpdate else { return }
        let decaySec = Double(pow(eff, 1.5)) * 60
        reverbFilter.setDecay(decaySec)
    }

    /// Group delay: effective 0–1 → 0–20 periods of delay per frequency
    /// (τ = scale / f, so full strength delays 100 Hz by 200 ms), plus
    /// spectral smear (see GroupDelay.swift).
    func setGroupDelay(effective eff: Float) {
        groupDelay.setScale(Double(eff) * 20)
    }

    /// Group delay randomness: effective 0–1 → ±0–50% drift around the scale.
    func setGroupDelayRandomness(effective eff: Float) {
        groupDelay.setRandomness(Double(eff) * 0.5)
    }

    /// Grain echo: effective 0–1 scales the haze level (up to 0 dB re dry),
    /// its memory window (up to 200 ms) and grain detune (±4→±35 cents) together.
    func setGrainEcho(effective eff: Float) {
        grainEcho.setStrength(Double(eff))
    }

    /// Spectral blur: effective 0–1 scales bloom/linger time and depth.
    func setSpectralBlur(effective eff: Float) {
        spectralBlur.setStrength(Double(eff))
    }

    /// Downward shimmer: effective 0–1 scales glow level and sustain.
    func setShimmer(effective eff: Float) {
        shimmer.setStrength(Double(eff))
    }

    /// EQ: 0–12 dB, peaking bell at 150 Hz, Q 0.1 — matches the web edition exactly.
    func setEQ(gainDb: Float) {
        eqFilter.setParameters(gainDb: Double(gainDb))
    }

    /// Even saturator: 0–16 dB drive (× recipe multiplier), envelope-biased tanh.
    func setSaturator(driveDb: Float) {
        evenDriveDb = driveDb
        applySaturation()
    }

    /// Odd saturator: 0–16 dB drive (× recipe multiplier), plain tanh soft-clip.
    func setOddSaturator(driveDb: Float) {
        oddDriveDb = driveDb
        applySaturation()
    }

    /// Saturator recipe: shaping, drive balance and harmonic recipe around the saturators.
    func setSaturatorRecipe(_ r: SaturatorRecipe) {
        recipe = r
        applySaturation()
    }

    private func applySaturation() {
        satFilter.setDrive(driveDb: min(24, Double(evenDriveDb) * recipe.evenMul))
        oddSatFilter.setDrive(driveDb: min(24, Double(oddDriveDb) * recipe.oddMul))
        satFilter.setBias(recipe.bias)
        recipeStage.configure(recipe, amount: Double(evenDriveDb + oddDriveDb) / 16)
    }

    /// Tape hysteresis: effective 0–1 (drive, loop width, head bump, top-end loss).
    func setTapeHysteresis(effective eff: Float) {
        tapeHyst.setStrength(Double(eff))
    }

    /// Tape sag: effective 0–1 (level dip, dulling, pitch droop on loud passages).
    func setTapeSag(effective eff: Float) {
        tapeSag.setStrength(Double(eff))
    }

    /// High roll-off: 0–6 dB/octave slope above 1 kHz.
    func setHighRolloff(dbPerOctave: Float) {
        highRolloff.setSlope(dbPerOctave: Double(dbPerOctave))
    }

    enum DynamicsMode { case limiter, compressor }

    /// Mirrors the web edition's configureDynamics() exactly — same
    /// threshold/knee/ratio/attack/release/trim, run through the same
    /// soft-knee curve (see CustomDynamics.swift), so the macOS app produces
    /// the same compression behavior instead of Apple's differently-voiced
    /// AUDynamicsProcessor.
    func setDynamics(mode: DynamicsMode) {
        // Web edition applies its own per-mode trim (0 dB limiter / -6 dB
        // compressor) AND a separate, always-on -6 dB "masterGain" headroom
        // stage after that. We were missing the second one entirely — net
        // trim should be -6 dB (limiter) / -12 dB (compressor), not 0 / -6.
        switch mode {
        case .limiter:
            // Brickwall: won't clip on its own, but a hard/fast ratio at
            // threshold 0 dB lets fast transients push through before the
            // envelope catches up — same as the web edition's audible
            // "heavy distortion" character on hot material.
            compressor.configure(thresholdDb: 0, kneeDb: 0, ratio: 20,
                                  attackSec: 0.001, releaseSec: 0.1, trimDb: -6)
        case .compressor:
            // Gentler musical setting that lets more through above its
            // threshold, so it needs a fixed -6 dB trim to avoid clipping
            // on the way out — matches the web app's separate trim gain node,
            // plus the same -6 dB headroom stage as the limiter case.
            compressor.configure(thresholdDb: -18, kneeDb: 12, ratio: 4,
                                  attackSec: 0.01, releaseSec: 0.25, trimDb: -12)
        }
    }

    private func applyLimiterMode() { setDynamics(mode: .limiter) }

    // MARK: - System audio capture
    // Architecture — no AVAudioEngine and no taps in this path at all:
    //   captureAU (raw HAL input unit bound to BlackHole) → realtime input
    //     callback → captureRing (ResamplingRing)
    //   outputAU (raw HAL output unit → chosen device) → realtime render
    //     callback → captureRing.read (resampled to 44.1 kHz, drift-corrected)
    //     → preamp → renderChain → output buffer
    // The main AVAudioEngine is simply stopped while capturing.
    //
    // Previously capture went BlackHole → AVAudioEngine input tap → ring →
    // manual-rendering engine → preampMixer tap → ring → DSP. Taps fire on an
    // ordinary thread in ~100 ms chunks, so scheduling hiccups under load
    // ran the rings dry, and nothing compensated for BlackHole's clock vs.
    // the output device's clock — both showed up as periodic pops.

    private(set) var isSystemCapture = false
    private var captureAU: AudioUnit?
    private var outputAU: AudioUnit?
    private let captureRing = ResamplingRing()
    private var captureRate: Double = 44100
    private var captureChannels = 2
    private var captureABL: UnsafeMutableAudioBufferListPointer?
    private static let maxCaptureFrames = 8192
    private var preampLinear: Float = 1

    // Glitch diagnostics, logged once a minute when nonzero (counters are
    // bumped on realtime threads; approximate reads are fine for logging).
    private var captureRenderFailures = 0
    private var captureOverloads = 0
    private var captureMaxLoad = 0.0
    private var captureOversized = 0
    private var diagTicks = 0

    // Waveform display in System mode (no tapMixer tap running): the output
    // callback drops a snapshot here, a main-thread timer forwards it.
    private let vizLock = NSLock()
    private var vizSnapshot = [Float](repeating: 0, count: 256)
    private var vizTimer: Timer?

    /// Enumerate all audio devices that have the given scope (input or output).
    private func listDevices(scope: AudioObjectPropertyScope) -> [(id: AudioDeviceID, name: String)] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  0)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz) == noErr else { return [] }
        let count = Int(sz) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &ids) == noErr else { return [] }

        return ids.compactMap { devID -> (id: AudioDeviceID, name: String)? in
            var streamAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                        mScope: scope, mElement: 0)
            var streamSz: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(devID, &streamAddr, 0, nil, &streamSz) == noErr, streamSz > 0 else { return nil }
            let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(streamSz), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { rawPtr.deallocate() }
            guard AudioObjectGetPropertyData(devID, &streamAddr, 0, nil, &streamSz, rawPtr) == noErr else { return nil }
            guard rawPtr.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers > 0 else { return nil }

            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            var cfRef: Unmanaged<CFString>? = nil
            var nameSz = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
            guard withUnsafeMutablePointer(to: &cfRef, { ptr in
                AudioObjectGetPropertyData(devID, &nameAddr, 0, nil, &nameSz, ptr)
            }) == noErr, let name = cfRef?.takeRetainedValue() else { return nil }
            return (id: devID, name: name as String)
        }
    }

    func listInputDevices()  -> [(id: AudioDeviceID, name: String)] { listDevices(scope: kAudioDevicePropertyScopeInput) }
    func listOutputDevices() -> [(id: AudioDeviceID, name: String)] { listDevices(scope: kAudioDevicePropertyScopeOutput) }

    enum CaptureError: LocalizedError {
        case unit(String, OSStatus)
        var errorDescription: String? {
            if case let .unit(step, status) = self {
                return "Audio device error (\(step): \(status)). Try toggling System off and on."
            }
            return nil
        }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw CaptureError.unit(step, status) }
    }

    private func makeHALUnit() throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType:         kAudioUnitType_Output,
            componentSubType:      kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw CaptureError.unit("find HAL", -1) }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au), "new HAL unit")
        return au!
    }

    private static func floatFormat(rate: Double, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate:       rate,
            mFormatID:         kAudioFormatLinearPCM,
            mFormatFlags:      kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
            mBytesPerPacket:   4,
            mFramesPerPacket:  1,
            mBytesPerFrame:    4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel:   32,
            mReserved:         0)
    }

    func startSystemCapture(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
        // ── Tear down any previous session; take the main engine offline ────
        stopCaptureUnits()
        stopPlayer()
        engine.stop()
        captureRing.reset()

        // ── Input unit bound directly to BlackHole ──────────────────────────
        // (Setting the unit's own current device is permitted by the
        // audio-input entitlement; changing the system default input isn't.)
        let inAU = try makeHALUnit()
        captureAU = inAU
        var on: UInt32 = 1, off: UInt32 = 0
        try check(AudioUnitSetProperty(inAU, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4), "enable input")
        try check(AudioUnitSetProperty(inAU, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4), "disable output")
        var inDev = inputDeviceID
        try check(AudioUnitSetProperty(inAU, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &inDev, UInt32(MemoryLayout<AudioDeviceID>.size)), "bind input device")

        // Device-side format tells us BlackHole's actual rate/channels; the
        // input side of AUHAL can't sample-rate convert, so we take that rate
        // and resample ourselves in the ring.
        var devFmt = AudioStreamBasicDescription()
        var fmtSz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(inAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &devFmt, &fmtSz), "read input format")
        captureRate = devFmt.mSampleRate > 0 ? devFmt.mSampleRate : 44100
        captureChannels = max(1, min(2, Int(devFmt.mChannelsPerFrame)))
        var clientIn = Self.floatFormat(rate: captureRate, channels: captureChannels)
        try check(AudioUnitSetProperty(inAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                       &clientIn, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set input format")

        // Preallocated capture buffers (no allocation on the realtime thread).
        let abl = AudioBufferList.allocate(maximumBuffers: captureChannels)
        for i in 0..<captureChannels {
            abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(Self.maxCaptureFrames * 4),
                                 mData: UnsafeMutableRawPointer.allocate(byteCount: Self.maxCaptureFrames * 4, alignment: 16))
        }
        captureABL = abl

        // The unit's default slice limit is derived from the device's buffer
        // size (it came out as 470 frames), but BlackHole delivers 512-frame
        // cycles — AudioUnitRender then fails with TooManyFramesToProcess
        // (-10874) and that whole block is lost: a pop. Allow any size we
        // have buffers for.
        var maxIn = UInt32(Self.maxCaptureFrames)
        try check(AudioUnitSetProperty(inAU, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                       &maxIn, 4), "set input max frames")

        var inCB = AURenderCallbackStruct(inputProc: _captureInput,
                                          inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(inAU, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                       &inCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input callback")

        // ── Output unit → chosen device, DSP runs in its render callback ────
        let outAU = try makeHALUnit()
        outputAU = outAU
        try check(AudioUnitSetProperty(outAU, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &off, 4), "disable out-unit input")
        try check(AudioUnitSetProperty(outAU, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, 4), "enable output")
        var outDev = outputDeviceID
        try check(AudioUnitSetProperty(outAU, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &outDev, UInt32(MemoryLayout<AudioDeviceID>.size)), "bind output device")
        // The DSP chain is designed for 44.1 kHz; the output side of AUHAL
        // converts to whatever rate the device runs at.
        var clientOut = Self.floatFormat(rate: 44100, channels: 2)
        try check(AudioUnitSetProperty(outAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                       &clientOut, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set output format")
        var maxFrames = UInt32(Self.maxRenderFrames)
        try check(AudioUnitSetProperty(outAU, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                       &maxFrames, 4), "set output max frames")
        var outCB = AURenderCallbackStruct(inputProc: _captureOutput,
                                           inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(outAU, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &outCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set render callback")

        try check(AudioUnitInitialize(inAU), "init input")
        try check(AudioUnitInitialize(outAU), "init output")
        isSystemCapture = true
        try check(AudioOutputUnitStart(inAU), "start input")
        try check(AudioOutputUnitStart(outAU), "start output")

        vizTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.vizLock.lock(); let snap = self.vizSnapshot; self.vizLock.unlock()
            self.onSamples?(snap)
            self.diagTicks += 1
            if self.diagTicks % (20 * 60) == 0 {
                let u = self.captureRing.underruns, o = self.captureRing.overflows
                if u + o + self.captureRenderFailures + self.captureOversized + self.captureOverloads > 0 {
                    NSLog("[EntropyPlayer] System-mode glitches in last minute: capture render failures=%d, oversized=%d, ring underruns=%d, overflows=%d, DSP overloads=%d",
                          self.captureRenderFailures, self.captureOversized, u, o, self.captureOverloads)
                }
                NSLog("[EntropyPlayer] System-mode peak DSP load last minute: %.0f%% of callback budget", self.captureMaxLoad * 100)
                self.captureRenderFailures = 0; self.captureOversized = 0
                self.captureOverloads = 0; self.captureMaxLoad = 0
                self.captureRing.underruns = 0; self.captureRing.overflows = 0
            }
        }
    }

    func stopSystemCapture() {
        stopCaptureUnits()
        // ── Return the main engine to normal hardware output ──────────────────
        applyPlaybackOutputDevice()
        try? engine.start()
    }

    private func stopCaptureUnits() {
        isSystemCapture = false
        vizTimer?.invalidate(); vizTimer = nil
        for au in [captureAU, outputAU].compactMap({ $0 }) {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        captureAU = nil; outputAU = nil
        if let abl = captureABL {
            for b in abl { b.mData?.deallocate() }
            abl.unsafeMutablePointer.deallocate()
            captureABL = nil
        }
    }

    // Realtime input thread.
    fileprivate func captureInputArrived(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                         timeStamp: UnsafePointer<AudioTimeStamp>,
                                         bus: UInt32, frames: UInt32) {
        guard let au = captureAU, let abl = captureABL else { return }
        let n = min(Int(frames), Self.maxCaptureFrames)
        for i in 0..<abl.count { abl[i].mDataByteSize = UInt32(n * 4) }
        if Int(frames) > Self.maxCaptureFrames { captureOversized += 1 }
        guard AudioUnitRender(au, flags, timeStamp, bus, UInt32(n), abl.unsafeMutablePointer) == noErr else {
            captureRenderFailures += 1
            return
        }
        guard let l = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let r = abl.count > 1 ? abl[1].mData!.assumingMemoryBound(to: Float.self) : l
        // Mono sum, as before (both channels carry the same signal).
        for i in 0..<n { l[i] = (l[i] + r[i]) * 0.5 }
        captureRing.write(left: l, right: l, count: n)
    }

    // Realtime output thread.
    fileprivate func renderCaptureOutput(_ ioData: UnsafeMutablePointer<AudioBufferList>, frames total: Int) {
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            // A callback that runs past (most of) its buffer's duration makes
            // the device play a glitch even though no ring ran dry.
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            let budget = Double(total) / 44100
            if elapsed > budget * 0.8 { captureOverloads += 1 }
            captureMaxLoad = max(captureMaxLoad, elapsed / budget)
        }
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        let ratio = captureRate / 44100
        var done = 0
        while done < total {
            let n = min(total - done, Self.maxRenderFrames)
            scratchL.withUnsafeMutableBufferPointer { lb in
                scratchR.withUnsafeMutableBufferPointer { rb in
                    let l = lb.baseAddress!, r = rb.baseAddress!
                    captureRing.read(left: l, right: r, count: n, baseRatio: ratio)
                    var g = preampLinear
                    vDSP_vsmul(l, 1, &g, l, 1, vDSP_Length(n))
                    vDSP_vsmul(r, 1, &g, r, 1, vDSP_Length(n))
                    renderChain(left: l, right: r, count: n)
                    if list.count > 0, let out = list[0].mData?.assumingMemoryBound(to: Float.self) {
                        (out + done).assign(from: l, count: n)
                    }
                    if list.count > 1, let out = list[1].mData?.assumingMemoryBound(to: Float.self) {
                        (out + done).assign(from: r, count: n)
                    }
                    if done == 0, vizLock.try() {
                        let m = min(n, vizSnapshot.count)
                        vizSnapshot.withUnsafeMutableBufferPointer { $0.baseAddress!.assign(from: l, count: m) }
                        vizLock.unlock()
                    }
                }
            }
            done += n
        }
    }

    // MARK: - System device helpers

    private func systemDefaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var dev: AudioDeviceID = 0
        var sz   = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: 0)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev)
        return dev
    }

    private func setSystemDefaultDevice(_ selector: AudioObjectPropertySelector, to deviceID: AudioDeviceID) {
        var dev  = deviceID
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: 0)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
    }

    // MARK: - Playback

    /// Bumped whenever scheduled audio is abandoned. AVAudioPlayerNode fires a
    /// segment's completion handler when the player is *stopped* too, not
    /// just when it finishes — without this token, loading a track (which
    /// stops the player) fired the previous track's "ended" callback, which
    /// advanced to the next track, which stopped the player again… racing
    /// through the whole folder.
    private var scheduleGeneration = 0

    private func stopPlayer() {
        scheduleGeneration &+= 1
        player.stop()
    }

    /// True once a file has been loaded and scheduled.
    var hasLoadedTrack: Bool { currentFile != nil }

    func load(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        currentFile = file
        duration    = Double(file.length) / file.processingFormat.sampleRate
        stopPlayer()
        schedule(file: file, from: 0)
        // In System mode the DSP chain belongs to the capture units; the main
        // engine stays offline until capture stops.
        if !engine.isRunning && !isSystemCapture { try engine.start() }
    }

    private func schedule(file: AVAudioFile, from startFrame: AVAudioFramePosition) {
        scheduledStartSample = startFrame
        let remaining = AVAudioFrameCount(file.length - startFrame)
        guard remaining > 0 else { return }
        let generation = scheduleGeneration
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: remaining, at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                // Only a segment that actually played to the end advances the playlist.
                guard let self, self.scheduleGeneration == generation, !self.isSystemCapture else { return }
                self.scheduleGeneration &+= 1
                self.onTrackEnded?()
            }
        }
    }

    func play()  { player.play() }
    func pause() { player.pause() }
    func stop()  { stopPlayer() }

    var isPlaying: Bool { player.isPlaying }

    var currentTime: Double {
        guard let nodeTime   = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              let file       = currentFile else { return 0 }
        let s = Double(playerTime.sampleTime) / file.processingFormat.sampleRate
        return max(0, s)
    }
}

// MARK: - JitterRing
//
// Stereo single-producer/single-consumer ring between a tap (writer, which
// delivers ~100 ms chunks on its own thread) and a render callback (reader,
// a few ms at a time on the realtime thread). The reader only starts once a
// cushion of `primeFrames` is buffered — more than one tap chunk plus
// scheduling jitter — and after any underrun it outputs silence and re-primes
// that full cushion, instead of trickling out samples the moment they arrive
// (which is what left a gap at every chunk boundary before). If the writer
// runs ahead (device clock drift), excess beyond `maxFrames` is dropped back
// down to the cushion so latency can't grow without bound. Indices are
// guarded by an uncontended lock (which also orders the sample writes before
// the index update); sample copies happen outside it.
final class JitterRing {
    private static let size = 1 << 17                 // ~3 s at 44.1 kHz
    private let primeFrames: Int
    private let maxFrames: Int

    // Raw storage (not Swift arrays): both threads touch it concurrently,
    // and array copy-on-write/exclusivity semantics aren't safe for that.
    private let bufL = UnsafeMutablePointer<Float>.allocate(capacity: JitterRing.size)
    private let bufR = UnsafeMutablePointer<Float>.allocate(capacity: JitterRing.size)
    private var writeIdx = 0
    private var readIdx  = 0
    private var priming  = true
    private let lock = NSLock()
    var underruns = 0, trims = 0                      // diagnostics

    init(primeFrames: Int, maxFrames: Int) {
        self.primeFrames = primeFrames
        self.maxFrames = maxFrames
        bufL.initialize(repeating: 0, count: Self.size)
        bufR.initialize(repeating: 0, count: Self.size)
    }

    deinit {
        bufL.deallocate()
        bufR.deallocate()
    }

    func reset() {
        lock.lock()
        writeIdx = 0; readIdx = 0; priming = true
        lock.unlock()
    }

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        lock.lock()
        let w = writeIdx
        lock.unlock()
        let mask = Self.size - 1
        for i in 0..<count {
            bufL[(w &+ i) & mask] = left[i]
            bufR[(w &+ i) & mask] = right[i]
        }
        lock.lock()
        writeIdx = w &+ count
        let avail = writeIdx &- readIdx
        if avail > maxFrames { readIdx = writeIdx &- primeFrames; trims += 1 }
        lock.unlock()
    }

    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock()
        let avail = writeIdx &- readIdx
        if priming && avail >= primeFrames { priming = false }
        let n = priming ? 0 : min(count, avail)
        let r0 = readIdx
        readIdx = r0 &+ n
        if n < count {
            if !priming { underruns += 1 }
            priming = true                             // underrun → rebuild cushion
        }                // underrun → rebuild cushion
        lock.unlock()

        let mask = Self.size - 1
        for i in 0..<n {
            left[i]  = bufL[(r0 &+ i) & mask]
            right[i] = bufR[(r0 &+ i) & mask]
        }
        for i in n..<count { left[i] = 0; right[i] = 0 }
    }
}

// MARK: - ResamplingRing
//
// System-mode ring between two independent hardware clocks: the capture
// device (BlackHole) writes at its rate, the output device reads at 44.1 kHz.
// The reader resamples with 4-point Hermite interpolation at
// captureRate/44100, nudged by up to ±0.5% according to how full the ring
// is, so the fill level is held near `target` indefinitely — clock drift
// between the devices is absorbed smoothly instead of eventually running
// the ring dry or overfull (either of which is an audible pop). Both sides
// run on realtime threads with small (~512-frame) buffers, so a modest
// cushion suffices. Hard underrun/overflow handling remains as a last resort.
final class ResamplingRing {
    private static let size = 1 << 17
    private static let target = 4096.0          // ~85–93 ms cushion
    private static let maxCorrection = 0.005
    private static let gain = 0.002             // ratio correction per unit of fill error

    private let bufL = UnsafeMutablePointer<Float>.allocate(capacity: ResamplingRing.size)
    private let bufR = UnsafeMutablePointer<Float>.allocate(capacity: ResamplingRing.size)
    private var writeIdx = 0
    private var readPos: Double = 0              // reader only
    private var fillAvg: Double = ResamplingRing.target
    private var priming = true
    private var resetPending = false
    private let lock = NSLock()
    var underruns = 0, overflows = 0             // diagnostics

    init() {
        bufL.initialize(repeating: 0, count: Self.size)
        bufR.initialize(repeating: 0, count: Self.size)
    }

    deinit {
        bufL.deallocate()
        bufR.deallocate()
    }

    func reset() {
        lock.lock()
        writeIdx = 0
        resetPending = true
        lock.unlock()
    }

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        lock.lock()
        let w = writeIdx
        lock.unlock()
        let mask = Self.size - 1
        for i in 0..<count {
            bufL[(w &+ i) & mask] = left[i]
            bufR[(w &+ i) & mask] = right[i]
        }
        lock.lock()
        writeIdx = w &+ count
        lock.unlock()
    }

    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
              count: Int, baseRatio: Double) {
        lock.lock()
        let w = Double(writeIdx)
        if resetPending { readPos = 0; priming = true; resetPending = false }
        lock.unlock()

        var avail = w - readPos
        if priming {
            if avail >= Self.target {
                priming = false
                readPos = w - Self.target
                fillAvg = Self.target
                avail = Self.target
            } else {
                for i in 0..<count { left[i] = 0; right[i] = 0 }
                return
            }
        }
        if avail > Self.target * 4 {                 // way overfull (e.g. output stalled)
            overflows += 1
            readPos = w - Self.target
            avail = Self.target
        }

        // Smoothed fill level → gentle rate correction (≈1 s smoothing).
        fillAvg += 0.02 * (avail - fillAvg)
        let err = (fillAvg - Self.target) / Self.target
        let ratio = baseRatio * (1 + max(-Self.maxCorrection, min(Self.maxCorrection, Self.gain * err)))

        let mask = Self.size - 1
        var pos = readPos
        for i in 0..<count {
            if pos + 3 >= w {                        // underrun: re-prime the cushion
                for j in i..<count { left[j] = 0; right[j] = 0 }
                underruns += 1
                priming = true
                break
            }
            let i0 = Int(pos)
            let t = Float(pos - Double(i0))
            left[i]  = Self.hermite(bufL, i0, t, mask)
            right[i] = Self.hermite(bufR, i0, t, mask)
            pos += ratio
        }
        readPos = pos
    }

    @inline(__always)
    private static func hermite(_ b: UnsafeMutablePointer<Float>, _ i: Int, _ t: Float, _ mask: Int) -> Float {
        let y0 = b[(i &- 1) & mask], y1 = b[i & mask], y2 = b[(i &+ 1) & mask], y3 = b[(i &+ 2) & mask]
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * t + c2) * t + c1) * t + y1
    }
}
