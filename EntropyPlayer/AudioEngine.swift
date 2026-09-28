import AVFoundation
import AudioToolbox
import CoreAudio
import AppKit
import Accelerate

// File-level C-callable render callback for the EarPods HAL Output unit.
// It drives the main engine's manual-rendering block, so the entire DSP chain
// renders synchronously on this realtime thread straight into the EarPods buffer.
// Non-capturing → implicitly @convention(c) → safe to pass as AURenderCallback.
private let _earPodsRender: AURenderCallback = { refCon, _, _, _, numFrames, ioData in
    let eng = Unmanaged<AudioEngine>.fromOpaque(refCon).takeUnretainedValue()
    guard let ioData else { return noErr }
    if let block = eng.manualRenderBlock {
        var status: OSStatus = noErr
        _ = block(numFrames, ioData, &status)
    } else {
        // No engine yet → output silence.
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        for buf in list { memset(buf.mData, 0, Int(buf.mDataByteSize)) }
    }
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
    //   group delay → reverb → EQ → +7 dB → 25 Hz high-pass → even sat → odd sat → high roll-off
    //   → limiter/compressor → post-gain → output ceiling
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
    private let dspRing = JitterRing()
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

    // Custom saturators (see CustomSaturator.swift): replace Apple's
    // AVAudioUnitDistortion, whose presets are built from ring-modulation,
    // decimation, and delay effects — not the plain tanh soft-clip the web
    // edition uses. That mismatch produced a boomy artifact once the EQ's
    // bass boost drove it.
    private let satFilter     = WebAudioSaturator(voicing: .even)
    private let oddSatFilter  = WebAudioSaturator(voicing: .odd)
    private let highRolloff   = HighRolloff()
    private let subsonic      = SubsonicFilter()

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

    // Custom peaking EQ (see CustomEQ.swift): AVAudioUnitEQ can't reach the
    // web edition's very wide Q 0.1 bell.
    private let eqFilter     = PeakingBiquad()

    // Fixed, always-on +7 dB drive into the saturator/limiter. Not exposed as
    // a control — the visible Pre-Amp slider's "0 dB" position stays the web
    // edition's nominal unity gain; this compensates for headroom the chain
    // otherwise loses (e.g. AUReverb2's internal dry-path insertion loss).
    private let preLimiterGainLinear: Float = pow(10, 7.0 / 20.0)

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

        buildGraph()
        setLowLatency()
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
        engine.stop()
        setLowLatency()
        do {
            try engine.start()
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

        try? engine.start()
    }

    /// The full DSP chain, in place, on the render thread.
    private func renderChain(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, count n: Int) {
        groupDelay.process(left: l, right: r, count: n)
        reverbFilter.process(left: l, right: r, count: n)

        eqFilter.process(l, count: n, channel: 0)
        eqFilter.process(r, count: n, channel: 1)
        var g = preLimiterGainLinear
        vDSP_vsmul(l, 1, &g, l, 1, vDSP_Length(n))
        vDSP_vsmul(r, 1, &g, r, 1, vDSP_Length(n))

        // Color stage: subsonic cut → even saturator → odd saturator → high
        // roll-off (after both, so it also tames the harmonics they add).
        for (buf, ch) in [(l, 0), (r, 1)] {
            subsonic.process(buf, count: n, channel: ch)
            satFilter.process(buf, count: n, channel: ch)
            oddSatFilter.process(buf, count: n, channel: ch)
            highRolloff.process(buf, count: n, channel: ch)
        }

        compressor.process(left: l, right: r, count: n)

        var pg = postGainLinear
        vDSP_vsmul(l, 1, &pg, l, 1, vDSP_Length(n))
        vDSP_vsmul(r, 1, &pg, r, 1, vDSP_Length(n))
        // Safety ceiling: catches any Post-Gain overs gracefully instead
        // of letting them hard-clip at the final hardware conversion.
        outputCeiling.process(left: l, right: r, count: n)
    }

    private func setLowLatency() {
        var devID = AudioDeviceID(kAudioObjectUnknown)
        var sz    = UInt32(MemoryLayout<AudioDeviceID>.size)
        var prop  = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &sz, &devID)
        guard devID != kAudioObjectUnknown else { return }
        var frames: UInt32 = 256
        prop.mSelector = kAudioDevicePropertyBufferFrameSize
        AudioObjectSetPropertyData(devID, &prop, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
    }

    // MARK: - DSP setters

    /// Pre-amp: -12 dB to 0 dB
    func setPreamp(db: Float) {
        preampMixer.outputVolume = pow(10, db / 20)
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

    /// Group delay: effective 0–1 → 0–5 periods of delay per frequency
    /// (τ = scale / f, so full strength delays 20 Hz by 250 ms).
    func setGroupDelay(effective eff: Float) {
        groupDelay.setScale(Double(eff) * 5)
    }

    /// Group delay randomness: effective 0–1 → ±0–50% drift around the scale.
    func setGroupDelayRandomness(effective eff: Float) {
        groupDelay.setRandomness(Double(eff) * 0.5)
    }

    /// EQ: 0–12 dB, peaking bell at 150 Hz, Q 0.1 — matches the web edition exactly.
    func setEQ(gainDb: Float) {
        eqFilter.setParameters(gainDb: Double(gainDb))
    }

    /// Even saturator: 0–8 dB drive, envelope-biased tanh (2nd/4th harmonics).
    func setSaturator(driveDb: Float) {
        satFilter.setDrive(driveDb: Double(driveDb))
    }

    /// Odd saturator: 0–8 dB drive, the web edition's plain tanh soft-clip.
    func setOddSaturator(driveDb: Float) {
        oddSatFilter.setDrive(driveDb: Double(driveDb))
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
    // Architecture — no shared hardware device, so nothing collides on BlackHole:
    //   captureEngine (system default input = BlackHole) → ring1 → AVAudioSourceNode → DSP
    //   main engine runs in MANUAL RENDERING mode → touches no hardware device at all
    //   earPodsAU (raw HAL AUHAL → EarPods) render callback pulls the engine's
    //     manualRenderingBlock, rendering the whole DSP chain straight into EarPods.

    private(set) var isSystemCapture = false
    private var captureEngine: AVAudioEngine?
    private var captureSourceNode: AVAudioSourceNode?
    private var previousDefaultInputDevice: AudioDeviceID = 0

    // ring1: capture tap → AVAudioSourceNode render callback. Cushioned
    // (JitterRing) because the capture device (BlackHole) and the output
    // device run on independent clocks, so the fill level slowly drifts.
    private let captureRing = JitterRing()

    // The main engine's manual rendering block, called from the EarPods render thread.
    var manualRenderBlock: AVAudioEngineManualRenderingBlock?
    private var earPodsAU: AudioUnit?

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
        case noInputAudioUnit
        var errorDescription: String? {
            "Could not access the capture device's audio unit. Try toggling System off and on."
        }
    }

    func startSystemCapture(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
        // ── Tear down any previous session ─────────────────────────────────────
        stopEarPodsOutput()
        manualRenderBlock = nil
        captureEngine?.inputNode.removeTap(onBus: 0)
        captureEngine?.stop()
        captureEngine = nil
        player.stop()

        // ── Capture engine: bind its input AUHAL DIRECTLY to BlackHole ─────────
        // We do NOT change the system default input device (the sandbox blocks
        // that → -10877). Setting kAudioOutputUnitProperty_CurrentDevice on the
        // input node's own AUHAL is permitted by the audio-input entitlement.
        let cEng    = AVAudioEngine()
        let inNode  = cEng.inputNode
        guard let inAU = inNode.audioUnit else { throw CaptureError.noInputAudioUnit }
        var dev = inputDeviceID
        AudioUnitSetProperty(inAU, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0,
                             &dev, UInt32(MemoryLayout<AudioDeviceID>.size))

        // Lock the whole chain to BlackHole's actual sample rate to avoid drift.
        let captureFmt = inNode.inputFormat(forBus: 0)
        let sr = captureFmt.sampleRate > 0 ? captureFmt.sampleRate : 44100
        let playFmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

        // ── Move the MAIN engine off all hardware, into manual rendering mode ──
        engine.stop()
        if let src = captureSourceNode {
            engine.detach(src)
            captureSourceNode = nil
        }
        if engine.isInManualRenderingMode {
            engine.disableManualRenderingMode()
        }
        try engine.enableManualRenderingMode(.realtime, format: playFmt, maximumFrameCount: 4096)

        // ── AVAudioSourceNode feeds ring1 → DSP chain ─────────────────────────
        // Stopped player produces silence, so preampMixer receives only srcNode.
        captureRing.reset()
        dspRing.reset()

        let srcNode = AVAudioSourceNode(format: playFmt) { [weak self] _, _, frameCount, abl in
            guard let self else { return noErr }
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard let l = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let r = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) ?? l : l
            self.captureRing.read(left: l, right: r, count: Int(frameCount))
            return noErr
        }
        engine.attach(srcNode)
        engine.connect(srcNode, to: preampMixer, format: playFmt)

        try engine.start()
        manualRenderBlock = engine.manualRenderingBlock
        captureSourceNode = srcNode

        // ── Start capture: BlackHole → ring1 ──────────────────────────────────
        inNode.installTap(onBus: 0, bufferSize: 512, format: captureFmt) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData else { return }
            let n        = Int(buf.frameLength)
            let isStereo = buf.format.channelCount > 1
            var mono = [Float](repeating: 0, count: n)
            for i in 0..<n {
                mono[i] = isStereo ? (ch[0][i] + ch[1][i]) * 0.5 : ch[0][i]
            }
            mono.withUnsafeBufferPointer { m in
                self.captureRing.write(left: m.baseAddress!, right: m.baseAddress!, count: n)
            }
        }
        try cEng.start()
        captureEngine = cEng

        // ── Raw HAL Output unit → EarPods; its callback drives manualRenderBlock ─
        isSystemCapture = true
        startEarPodsOutput(deviceID: outputDeviceID, sampleRate: sr)
    }

    func stopSystemCapture() {
        isSystemCapture = false

        stopEarPodsOutput()
        manualRenderBlock = nil

        captureEngine?.inputNode.removeTap(onBus: 0)
        captureEngine?.stop()
        captureEngine = nil

        // ── Return the main engine to normal hardware output ──────────────────
        engine.stop()
        if let src = captureSourceNode {
            engine.detach(src)
            captureSourceNode = nil
        }
        if engine.isInManualRenderingMode {
            engine.disableManualRenderingMode()
        }
        try? engine.start()
    }

    // MARK: - EarPods raw HAL Output unit

    private func startEarPodsOutput(deviceID: AudioDeviceID, sampleRate: Double) {
        stopEarPodsOutput()

        var desc = AudioComponentDescription(
            componentType:         kAudioUnitType_Output,
            componentSubType:      kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return }

        var au: AudioUnit?
        guard AudioComponentInstanceNew(comp, &au) == noErr, let au else { return }

        // Disable input bus — this unit is output-only.
        var off: UInt32 = 0; var on: UInt32 = 1
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input,  1, &off, 4)
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output, 0, &on,  4)

        // Route to the chosen output device (EarPods).
        var dev = deviceID
        let devSz = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &dev, devSz) == noErr else {
            AudioComponentInstanceDispose(au)
            return
        }

        // Client format: non-interleaved float32, stereo, at the capture sample rate.
        var fmt = AudioStreamBasicDescription(
            mSampleRate:       sampleRate,
            mFormatID:         kAudioFormatLinearPCM,
            mFormatFlags:      kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
            mBytesPerPacket:   4,
            mFramesPerPacket:  1,
            mBytesPerFrame:    4,
            mChannelsPerFrame: 2,
            mBitsPerChannel:   32,
            mReserved:         0)
        let fmtSz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0, &fmt, fmtSz)

        // Install render callback (defined at file scope, no captures).
        var cb = AURenderCallbackStruct(
            inputProc:       _earPodsRender,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        let cbSz = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input, 0, &cb, cbSz)

        guard AudioUnitInitialize(au) == noErr else {
            AudioComponentInstanceDispose(au)
            return
        }
        AudioOutputUnitStart(au)
        earPodsAU = au
    }

    private func stopEarPodsOutput() {
        guard let au = earPodsAU else { return }
        AudioOutputUnitStop(au)
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
        earPodsAU = nil
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

    func load(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        currentFile = file
        duration    = Double(file.length) / file.processingFormat.sampleRate
        player.stop()
        schedule(file: file, from: 0)
        if !engine.isRunning { try engine.start() }
    }

    private func schedule(file: AVAudioFile, from startFrame: AVAudioFramePosition) {
        scheduledStartSample = startFrame
        let remaining = AVAudioFrameCount(file.length - startFrame)
        guard remaining > 0 else { return }
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: remaining, at: nil) { [weak self] in
            DispatchQueue.main.async { self?.onTrackEnded?() }
        }
    }

    func play()  { player.play() }
    func pause() { player.pause() }
    func stop()  { player.stop() }

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
    private static let primeFrames = 4410 + 2048      // one tap chunk + ~46 ms
    private static let maxFrames   = 4410 * 3 + 2048

    // Raw storage (not Swift arrays): both threads touch it concurrently,
    // and array copy-on-write/exclusivity semantics aren't safe for that.
    private let bufL = UnsafeMutablePointer<Float>.allocate(capacity: JitterRing.size)
    private let bufR = UnsafeMutablePointer<Float>.allocate(capacity: JitterRing.size)
    private var writeIdx = 0
    private var readIdx  = 0
    private var priming  = true
    private let lock = NSLock()

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
        if avail > Self.maxFrames { readIdx = writeIdx &- Self.primeFrames }
        lock.unlock()
    }

    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock()
        let avail = writeIdx &- readIdx
        if priming && avail >= Self.primeFrames { priming = false }
        let n = priming ? 0 : min(count, avail)
        let r0 = readIdx
        readIdx = r0 &+ n
        if n < count { priming = true }                // underrun → rebuild cushion
        lock.unlock()

        let mask = Self.size - 1
        for i in 0..<n {
            left[i]  = bufL[(r0 &+ i) & mask]
            right[i] = bufR[(r0 &+ i) & mask]
        }
        for i in n..<count { left[i] = 0; right[i] = 0 }
    }
}
