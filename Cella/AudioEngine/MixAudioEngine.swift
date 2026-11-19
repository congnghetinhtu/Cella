
//
//  MixAudioEngine.swift
//  Cella
//
//  AVAudioEngine-based dual-player audio engine for automix.
//  BPM sync, beat phase alignment, vocal-preserving crossfade.
//  Gradual tempo synchronization with multi-step rate adjustment.
//

import AVFoundation
import Accelerate
import SPFKAudioBase

typealias TrackEndHandler = () -> Void

class MixAudioEngine {
    // MARK: - Properties

    private let engine = AVAudioEngine()
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    private let timePitchA = AVAudioUnitTimePitch()
    private let timePitchB = AVAudioUnitTimePitch()
    private let eqA = AVAudioUnitEQ(numberOfBands: 3)
    private let eqB = AVAudioUnitEQ(numberOfBands: 3)
    private let reverbA = AVAudioUnitReverb()
    private let reverbB = AVAudioUnitReverb()
    private let hallReverb = AVAudioUnitReverb()
    private let profileEq: AVAudioUnitEQ
    private let surroundEq: AVAudioUnitEQ

    /// Stereo width factor for the current surround mode. Updated by the
    /// ramp timer. `StereoWidthEffect.process()` reads this value to apply
    /// real-time M/S widening to the mixer output buffer.
    private var currentWidthValue: Float = 1.0

    /// Current surround staging mode (family of stage EQ + reverb mix).
    private var surroundMode: SurroundMode = .off
    /// Reverb node for surround/preset ambience (wet/dry driven by callers).
    private var motionReverb = false
    /// Index (0–9) of a soloed EQ band, or nil. All other bands bypassed.
    private var soloBand: Int?

    private let peakLimiter: AVAudioUnit = {
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        var result: AVAudioUnit?
        let semaphore = DispatchSemaphore(value: 0)
        AVAudioUnit.instantiate(with: desc, options: []) { au, _ in
            result = au
            semaphore.signal()
        }
        semaphore.wait()
        guard let unit = result else {
            fatalError("MixAudioEngine: failed to instantiate Apple PeakLimiter")
        }
        return unit
    }()
    private let mixerNode = AVAudioMixerNode()

    private var currentPlayer: AVAudioPlayerNode
    private var otherPlayer: AVAudioPlayerNode
    private var currentTimePitch: AVAudioUnitTimePitch
    private var otherTimePitch: AVAudioUnitTimePitch
    private var currentEQ: AVAudioUnitEQ { playerA === currentPlayer ? eqA : eqB }
    private var otherEQ: AVAudioUnitEQ { playerA === currentPlayer ? eqB : eqA }
    private var currentReverb: AVAudioUnitReverb { playerA === currentPlayer ? reverbA : reverbB }
    private var otherReverb: AVAudioUnitReverb { playerA === currentPlayer ? reverbB : reverbA }

    private var currentURL: URL?
    private var currentDuration: TimeInterval = 0

    private let config: AudioConfig

    var onTrackEnd: TrackEndHandler?
    var onCrossfadeCompleted: (() -> Void)?

    private(set) var isPlaying = false
    private(set) var isCrossfading = false
    /// Solo play-through: no beat-aligned crossfade trigger — track plays to its
    /// true end. Set by playThroughToEnd(), cleared by stop/crossfade/resume.
    private(set) var soloPlayThrough = false

    private var crossfadeTimer: Timer?
    private var trackEndTimer: Timer?
    private var preCrossfadeTimer: Timer?
    private var trackStartTime: Date?
    private var fxRampTimer: Timer?
    private var reverbRampTimer: Timer?

    private var remainingAtStart: TimeInterval = 0
    private var seekOffset: TimeInterval = 0
    private var currentCrossfadeDuration: TimeInterval = 0
    private var currentRate: Float = 1.0
    private var incomingTargetRate: Float = 1.0
    /// Tempo-match rate actually applied during the active blend (for post-
    /// swap bookkeeping + glide-back). Reset on stop / next blend start.
    private var blendTempoRate: Float = 1.0
    /// Real-second silence pad prepended to the incoming buffer (phase align).
    private var blendPadDelay: Double = 0
    private var currentBarTimestamps: [Double] = []
    private var beatAlignedCrossfadeTime: TimeInterval = 0
    private var incomingCueOffset: Double = 0
    private var currentTrackAnalysis: TrackAnalysis?
    private var crossfadeStartTime: Date?
    /// True when the armed crossfade trigger was picked by the second-half
    /// energy-match search (rather than the legacy near-the-end search) — the
    /// vocal never-cut floor only applies to the legacy path.
    private var triggerFromEnergyMatch: Bool = false

    private var configurationObserver: NSObjectProtocol?
    private var actualIncomingDuration: TimeInterval = 0  // post-intro-skip, pre-beat-padding
    private var fullIncomingDuration: TimeInterval = 0    // full source audio duration (untrimmed)
    private var pendingIncomingURL: URL?
    /// Seconds from loadTrack to the scheduled crossfade trigger. The view
    /// model uses it to stage the next track's buffer ahead of time.
    private(set) var crossfadeTriggerDelay: TimeInterval = 0

    /// Background-staged incoming buffer (decode + trim done, silence pad
    /// still pending — the pad needs transition-time phase). Consumed once
    /// by crossfadeToNext when the URL matches; otherwise the sync path runs.
    private struct PreparedCrossfade {
        let url: URL
        let buffer: AVAudioPCMBuffer
        let duration: TimeInterval
        let fullDuration: TimeInterval
    }
    private var preparedCrossfade: PreparedCrossfade?
    private var crossfadePrepGeneration = 0

    private var outgoingGain: Float = 1.0
    private var incomingGain: Float = 1.0
    private var outgoingCrossfadeStartPos: TimeInterval = 0
    private var curveExponent: Double = 1.0
    private var moodEqLowPassEndHz: Float = 3000.0  // mood-adapted EQ end frequency
    private var tempoRampTimer: Timer?
    private var tempoRampGeneration: Int = 0
    private var volumeRampTimer: Timer?
    private var lastIncomingVolume: Float = 1.0

    // MARK: - Initialization

    init(config: AudioConfig = .standard) {
        self.config = config
        self.profileEq = AVAudioUnitEQ(numberOfBands: 10)
        self.surroundEq = AVAudioUnitEQ(numberOfBands: 4)
        self.currentPlayer = playerA
        self.otherPlayer = playerB
        self.currentTimePitch = timePitchA
        self.otherTimePitch = timePitchB

        timePitchA.pitch = 0   // preserve original pitch
        timePitchA.rate = 1.0
        timePitchA.bypass = true
        timePitchB.pitch = 0
        timePitchB.rate = 1.0
        timePitchB.bypass = true

        eqA.globalGain = 0
        eqB.globalGain = 0

        profileEq.globalGain = 0
        surroundEq.globalGain = 0

        setupEngine()
        registerConfigurationObserver()
    }

    deinit {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        stop()
        crossfadeTimer?.invalidate()
        trackEndTimer?.invalidate()
        preCrossfadeTimer?.invalidate()
        tempoRampTimer?.invalidate()
        fxRampTimer?.invalidate()
        profileRampTimer?.invalidate()
        reverbRampTimer?.invalidate()
    }

    // MARK: - Audio Device / Route Change

    /// Restarts the engine and resumes playback when the output device changes
    /// (e.g., headphones unplugged). The engine stops on such changes; without
    /// this the app would go silent permanently.
    private func registerConfigurationObserver() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }
    }

    private func handleEngineConfigurationChange() {
        guard let url = currentURL, currentDuration > 0 else { return }
        let wasPlaying = isPlaying
        let position = currentTime
        let rate = currentRate
        let bars = currentBarTimestamps

        print("[Engine] Output config changed — restarting on new device (wasPlaying=\(wasPlaying), pos=\(String(format: "%.1f", position)))")

        try? engine.start()

        do {
            try reloadTrack(url: url, position: position, rate: rate, barTimestamps: bars, play: wasPlaying)
        } catch {
            print("[Engine] Reload after config change failed: \(error)")
        }
    }

    /// Re-establishes the current track on a (re)started engine at a given position.
    private func reloadTrack(url: URL, position: TimeInterval, rate: Float, barTimestamps: [Double], play: Bool) throws {
        cancelTrackEndTimer()
        tempoRampTimer?.invalidate()
        tempoRampTimer = nil
        stop()

        let file = try AudioHelpers.readAudio(url: url)
        let duration = file.duration

        currentURL = url
        currentDuration = duration
        currentRate = rate
        currentBarTimestamps = barTimestamps

        if currentPlayer === playerA {
            currentTimePitch = timePitchA
            otherTimePitch = timePitchB
        } else {
            currentTimePitch = timePitchB
            otherTimePitch = timePitchA
        }

        playerA.stop(); playerA.reset(); playerB.stop(); playerB.reset()
        currentPlayer.volume = 1.0
        currentTimePitch.rate = rate
        currentTimePitch.bypass = true
        otherPlayer.volume = 0
        otherTimePitch.rate = 1.0
        otherTimePitch.bypass = true

        seekOffset = 0
        remainingAtStart = duration / Double(rate)
        trackStartTime = Date()

        currentPlayer.scheduleFile(file, at: nil)
        if position > 0.05 {
            seek(to: position)
        }

        if play {
            currentPlayer.play()
            isPlaying = true
        } else {
            isPlaying = false
        }

        let maxFade = max(config.crossfadeDuration * 1.5, 12.0)
        beatAlignedCrossfadeTime = computeBeatAlignedCrossfadeTime(
            duration: duration,
            rate: Double(rate),
            barTimestamps: barTimestamps,
            crossfadeDuration: maxFade,
            outgoingAnalysis: nil,
            incomingAnalysis: nil
        )
        let reloadDelay = max(0.1, remainingAtStart - beatAlignedCrossfadeTime)
        schedulePreCrossfadeEQ(delay: reloadDelay - 5.0)
        scheduleTrackEndTimer(delay: reloadDelay)

        print("[Engine] Resumed on new device at \(String(format: "%.1f", position))s")

        // Re-apply current width if surround mode is active.
        if surroundMode != .off {
            StereoWidthEffect.currentWidth = widthValue(for: surroundMode)
            currentWidthValue = widthValue(for: surroundMode)
        }
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(timePitchA)
        engine.attach(timePitchB)
        engine.attach(eqA)
        engine.attach(eqB)
        engine.attach(reverbA)
        engine.attach(reverbB)
        engine.attach(profileEq)
        engine.attach(surroundEq)
        engine.attach(hallReverb)
        engine.attach(peakLimiter)
        engine.attach(mixerNode)

        let format = config.processingFormat
        engine.connect(playerA, to: timePitchA, format: format)
        engine.connect(playerB, to: timePitchB, format: format)
        engine.connect(timePitchA, to: eqA, format: format)
        engine.connect(timePitchB, to: eqB, format: format)
        engine.connect(eqA, to: reverbA, format: format)
        engine.connect(eqB, to: reverbB, format: format)
        engine.connect(reverbA, to: mixerNode, format: format)
        engine.connect(reverbB, to: mixerNode, format: format)

        reverbA.loadFactoryPreset(.mediumHall)
        reverbA.wetDryMix = 0
        reverbA.bypass = true
        reverbB.loadFactoryPreset(.mediumHall)
        reverbB.wetDryMix = 0
        reverbB.bypass = true

        mixerNode.volume = 1.0
        engine.connect(mixerNode, to: profileEq, format: format)
        profileEq.globalGain = 0

        engine.connect(profileEq, to: surroundEq, format: format)
        surroundEq.globalGain = 0

        engine.connect(surroundEq, to: hallReverb, format: format)
        hallReverb.loadFactoryPreset(.largeHall)
        hallReverb.wetDryMix = 0

        engine.connect(hallReverb, to: peakLimiter, format: format)

        engine.connect(peakLimiter, to: engine.mainMixerNode, format: nil)

        // Start with current (A) playing, other (B) stopped
        playerA.volume = 1.0
        playerB.volume = 0

        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[Engine] FAILED to start: \(error)")
        }

        // Stereo width tap — processes M/S widening on the mixer output
        // in-place. Runs every render cycle; StereoWidthEffect.currentWidth
        // controls the width factor (1.0 = unmodified).
        mixerNode.installTap(onBus: 0, bufferSize: 512, format: config.processingFormat) { buffer, _ in
            StereoWidthEffect.process(buffer)
        }

        // Re-apply defaults after engine start — engine may reinitialize
        // node internal state on start, losing pre-attach values.
        timePitchA.pitch = 0
        timePitchA.rate = 1.0
        timePitchA.bypass = true
        timePitchB.pitch = 0
        timePitchB.rate = 1.0
        timePitchB.bypass = true

        for band in profileEq.bands { band.bypass = true }
        profileEq.globalGain = 0

        for band in surroundEq.bands { band.bypass = true }
        surroundEq.globalGain = 0

        hallReverb.wetDryMix = 0
    }

    // MARK: - Playback Controls

    func loadTrack(url: URL, rate: Float = 1.0, barTimestamps: [Double] = [], analysis: TrackAnalysis? = nil) throws {
        cancelTrackEndTimer()
        stop()
        clearPreparedCrossfade()

        // Ensure the audio engine is running — may have been stopped by
        // a device configuration change while idle.
        if !engine.isRunning {
            try? engine.start()
        }

        let file = try AudioHelpers.readAudio(url: url)
        let duration = file.duration

        currentURL = url
        currentDuration = duration
        currentRate = rate
        currentBarTimestamps = barTimestamps

        // Preserve current player assignment — after a crossfade, currentPlayer
        // may be playerB. Hardcoding to playerA would apply rate/bypass to the
        // wrong timePitch node, shifting pitch on the loaded track.
        if currentPlayer === playerA {
            currentTimePitch = timePitchA
            otherTimePitch = timePitchB
        } else {
            currentTimePitch = timePitchB
            otherTimePitch = timePitchA
        }

        playerA.stop()
        playerA.reset()
        playerB.stop()
        playerB.reset()

        resetEQ(eqA)
        resetEQ(eqB)
        resetReverb(reverbA)
        resetReverb(reverbB)

        currentPlayer.volume = 1.0
        currentTimePitch.rate = rate
        currentTimePitch.bypass = true
        otherPlayer.volume = 0
        otherTimePitch.rate = 1.0
        otherTimePitch.bypass = true

            remainingAtStart = duration / Double(rate)
        seekOffset = 0
        trackStartTime = Date()

        // Compute beat-aligned crossfade trigger time.
        // Use generous lead time to cover max possible Crossfader.computeCrossfadeParams duration (1.3× config + bar quantization).
        let maxFadeDuration = max(config.crossfadeDuration * 1.5, 12.0)
        beatAlignedCrossfadeTime = computeBeatAlignedCrossfadeTime(
            duration: duration,
            rate: Double(rate),
            barTimestamps: barTimestamps,
            crossfadeDuration: maxFadeDuration,
            outgoingAnalysis: analysis,
            incomingAnalysis: nil
        )

        currentTrackAnalysis = analysis

        currentPlayer.scheduleFile(file, at: nil)
        currentPlayer.play()
        isPlaying = true

        let triggerOffset = remainingAtStart - beatAlignedCrossfadeTime
        let finalDelay = max(0.1, triggerOffset)
        crossfadeTriggerDelay = finalDelay

        print("[Engine] Playing: \(url.lastPathComponent) — \(String(format: "%.1f", duration))s @ rate \(String(format: "%.3f", rate)), crossfade in \(String(format: "%.2f", finalDelay))s (bar=\(String(format: "%.2f", triggerOffset)))")

        // Start low-pass filter 5 seconds before crossfade for smooth prep
        schedulePreCrossfadeEQ(delay: finalDelay - 5.0)
        scheduleTrackEndTimer(delay: finalDelay)
    }

    func play() {
        guard engine.isRunning else { return }
        trackStartTime = Date()
        currentPlayer.play()
        isPlaying = true
        restartTrackEndTimer()
    }

    func smoothVolume(to target: Float, duration: TimeInterval = 2.0) {
        volumeRampTimer?.invalidate()
        let start = mixerNode.volume
        let target = min(2.0, max(0, target))
        guard duration > 0, abs(target - start) > 0.001 else {
            mixerNode.volume = target
            return
        }
        let interval: TimeInterval = 0.03
        let steps = max(1, Int(duration / interval))
        var step = 0
        volumeRampTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            step += 1
            let t = min(1.0, Double(step) / Double(steps))
            let s = t * t * (3.0 - 2.0 * t)
            self.mixerNode.volume = start + Float(s) * (target - start)
            if step >= steps {
                timer.invalidate()
                self.volumeRampTimer = nil
                self.mixerNode.volume = target
            }
        }
    }

    /// Immediate volume without timer — for scroll wheel scrubbing (no runloop churn, no stutter)
    func setVolumeImmediate(_ volume: Float) {
        volumeRampTimer?.invalidate()
        volumeRampTimer = nil
        mixerNode.volume = min(2.0, max(0, volume))
    }

    func pause() {
        guard isPlaying else { return }
        currentPlayer.pause()
        seekOffset = currentTime
        isPlaying = false
        cancelTrackEndTimer()
        // Cancel any active tempo recovery ramp — resume will restart if needed
        tempoRampTimer?.invalidate()
        tempoRampTimer = nil
    }

    func stop() {
        playerA.stop()
        playerA.reset()
        playerB.stop()
        playerB.reset()
        currentWidthValue = 1.0
        StereoWidthEffect.currentWidth = 1.0
        resetEQ(eqA)
        resetEQ(eqB)
        resetReverb(reverbA)
        resetReverb(reverbB)
        isPlaying = false
        isCrossfading = false
        soloPlayThrough = false
        currentURL = nil
        currentDuration = 0
        seekOffset = 0
        pendingIncomingURL = nil
        currentRate = 1.0
        incomingTargetRate = 1.0
        blendTempoRate = 1.0
        blendPadDelay = 0
        crossfadeStartTime = nil
        lastIncomingVolume = 1.0
        cancelTrackEndTimer()
        cancelPreCrossfadeEQ()
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        tempoRampTimer?.invalidate()
        tempoRampTimer = nil

        timePitchA.pitch = 0
        timePitchA.rate = 1.0
        timePitchA.bypass = true
        timePitchB.pitch = 0
        timePitchB.rate = 1.0
        timePitchB.bypass = true
    }

    // MARK: - Playback Head

    /// Current playback head in source samples (0-based), or nil if unknown.
    private func currentPlaybackFrame() -> Int64? {
        guard let nodeTime = currentPlayer.lastRenderTime,
              let playerTime = currentPlayer.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        return Int64(playerTime.sampleTime) + Int64(seekOffset * playerTime.sampleRate)
    }

    var isWidenModeActive: Bool { surroundMode != .off }

    func seek(to time: TimeInterval) {
        guard let url = currentURL else { return }

        cancelTrackEndTimer()
        // Cancel any active tempo recovery ramp
        tempoRampTimer?.invalidate()
        tempoRampTimer = nil

        do {
            let file = try AudioHelpers.readAudio(url: url)

            currentPlayer.stop()
            currentPlayer.reset()
            otherPlayer.stop()
            otherPlayer.reset()
            resetEQ(eqA)
            resetEQ(eqB)

            currentRate = 1.0
            currentTimePitch.bypass = true
            currentTimePitch.rate = 1.0
            otherTimePitch.bypass = true
            otherTimePitch.rate = 1.0

            let sampleRate = file.processingFormat.sampleRate
            let framePosition = AVAudioFramePosition(time * sampleRate)

            guard framePosition >= 0, framePosition < file.length else { return }

            let remainingFrames = AVAudioFrameCount(file.length - framePosition)
            let seekDuration = Double(remainingFrames) / sampleRate
            remainingAtStart = seekDuration / Double(currentRate)
            seekOffset = time
            trackStartTime = Date()

            currentPlayer.scheduleSegment(file, startingFrame: framePosition, frameCount: remainingFrames, at: nil)
            if isPlaying {
                currentPlayer.play()
            }
            if soloPlayThrough {
                if remainingAtStart > 0 {
                    scheduleTrackEndTimer(delay: max(0.1, remainingAtStart))
                }
                return
            }
            // Reuse the armed trigger (bar seam in FULL-song time). If the user
            // scrubbed past the planned seam (e.g. near the end to preview the
            // AutoMix), pick an upcoming bar a few seconds ahead instead of
            // waiting until 0.0s remaining and cutting into silence!
            let remaining = trueRemaining()
            let newDelay: TimeInterval
            if remaining > beatAlignedCrossfadeTime {
                newDelay = remaining - beatAlignedCrossfadeTime
            } else if remaining > 4.0 {
                let targetMinTime = time + 2.5
                let minFadeRoom = min(config.crossfadeDuration, remaining * 0.55)
                let maxSafeTime = max(targetMinTime, currentDuration - max(4.0, minFadeRoom))
                if let bar = currentBarTimestamps.first(where: { $0 >= targetMinTime && $0 <= maxSafeTime }) {
                    newDelay = max(0.5, bar - time)
                } else {
                    newDelay = max(1.5, remaining - minFadeRoom)
                }
            } else {
                newDelay = 0.25
            }
            crossfadeTriggerDelay = newDelay
            schedulePreCrossfadeEQ(delay: newDelay - 5.0)
            scheduleTrackEndTimer(delay: newDelay)
            print("[Engine] Seek to \(String(format: "%.1f", time))s — transition armed in \(String(format: "%.1f", newDelay))s (remaining=\(String(format: "%.1f", remaining))s)")
        } catch {
            print("[Engine] Seek failed: \(error)")
        }
    }

    // MARK: - Automix Crossfade

    /// Full automix transition with beat phase alignment, vocal preservation,
    /// gradual tempo sync, and soft limiting.
    /// Returns `false` when a crossfade is already in progress (caller should
    /// not advance the queue).
    /// Full decode + intro-skip/beat-cue trim of the incoming track (no
    /// silence pad — beatPhaseDelay is only known at transition time).
    /// Heavy: whole-file decode, conversion, and buffer copies. Must run off
    /// the main thread (see prepareCrossfadeBuffer); the in-transition sync
    /// call is a last-resort fallback. Returns nil buffer when the file
    /// should stream directly instead (trim failed) — duration still set.
    private func decodeIncomingBuffer(
        incomingURL: URL,
        params: CrossfadeParams,
        incomingFirstBeat: Double
    ) throws -> (buffer: AVAudioPCMBuffer?, duration: TimeInterval, fullDuration: TimeInterval) {
        let incomingFile = try AudioHelpers.readAudio(url: incomingURL)
        let incomingDuration = incomingFile.duration
        // Use engine processing format sample rate for frame calculations,
        // since readEntireFile converts buffers to engine format.
        let sampleRate = config.processingFormat.sampleRate

        if params.vocalConnectionPoint > 0.05 {
            let skipTime = params.vocalConnectionPoint
            let duration = max(1.0, incomingDuration - skipTime)  // trimmed buffer length
            print("[Engine] Entry trim \(String(format: "%.2f", skipTime))s (skipIntro=\(params.skipIntro))")

            let fileBuffer = try readEntireFile(incomingFile)
            let skipFrames = AVAudioFramePosition(skipTime * sampleRate)
            if skipFrames > 0, skipFrames < AVAudioFramePosition(fileBuffer.frameLength) {
                let remainingFrames = fileBuffer.frameLength - AVAudioFrameCount(skipFrames)
                if let trimmed = AudioHelpers.extractBuffer(fileBuffer, from: skipFrames, frameCount: remainingFrames) {
                    return (trimmed, duration, incomingDuration)
                }
            }
            return (nil, duration, incomingDuration)
        }

        let fileBuffer = try readEntireFile(incomingFile)
        // Cue incoming to its first beat only when beat-phase locking is active.
        if params.beatPhaseLock && incomingFirstBeat > 0.01 {
            let cueFrames = AVAudioFramePosition(incomingFirstBeat * sampleRate)
            if cueFrames > 0, cueFrames < AVAudioFramePosition(fileBuffer.frameLength) {
                let remaining = fileBuffer.frameLength - AVAudioFrameCount(cueFrames)
                if let cued = AudioHelpers.extractBuffer(fileBuffer, from: cueFrames, frameCount: remaining) {
                    return (cued, max(1.0, incomingDuration - incomingFirstBeat), incomingDuration)
                }
            }
        }
        return (fileBuffer, incomingDuration, incomingDuration)
    }

    /// Background-decodes + trims the upcoming track ahead of the automatic
    /// transition, so the bar-boundary handoff never blocks main on a full
    /// file decode. Safe to call from main; stale results are dropped and a
    /// URL mismatch at transition time silently uses the sync path.
    func prepareCrossfadeBuffer(
        incomingURL: URL,
        params: CrossfadeParams,
        incomingAnalysis: TrackAnalysis?
    ) {
        crossfadePrepGeneration += 1
        let gen = crossfadePrepGeneration
        let firstBeat = incomingAnalysis?.beatTimestamps.first ?? 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let made = try? self.decodeIncomingBuffer(
                incomingURL: incomingURL,
                params: params,
                incomingFirstBeat: firstBeat
            ), let buffer = made.buffer else { return }
            // Hop to main for the handoff so crossfadeToNext (main) never races it.
            DispatchQueue.main.async { [weak self, buffer] in
                guard let self, gen == self.crossfadePrepGeneration else { return }
                self.preparedCrossfade = PreparedCrossfade(
                    url: incomingURL,
                    buffer: buffer,
                    duration: made.duration,
                    fullDuration: made.fullDuration
                )
            }
        }
    }

    /// Drops any staged buffer (track changed, fresh load, queue cleared).
    func clearPreparedCrossfade() {
        crossfadePrepGeneration += 1
        preparedCrossfade = nil
    }

    @discardableResult
    func crossfadeToNext(
        outgoingURL: URL,
        incomingURL: URL,
        crossfader: Crossfader,
        params: CrossfadeParams,
        outgoingAnalysis: TrackAnalysis? = nil,
        incomingAnalysis: TrackAnalysis? = nil
    ) -> Bool {
        guard !isCrossfading else {
            print("[Engine] Crossfade skipped — already in progress")
            return false
        }

        guard !soloPlayThrough else {
            print("[Engine] Crossfade refused — solo play-through")
            return false
        }

        soloPlayThrough = false
        cancelTrackEndTimer()
        cancelPreCrossfadeEQ()
        tempoRampTimer?.invalidate()
        tempoRampTimer = nil

        // Sync timePitch with actual current player — after a crossfade role swap,
        // currentTimePitch may still point to the old node.
        if currentPlayer === playerA {
            currentTimePitch = timePitchA
            otherTimePitch = timePitchB
        } else {
            currentTimePitch = timePitchB
            otherTimePitch = timePitchA
        }

        // Ensure the outgoing (current) track plays cleanly at its original tempo.
        currentTimePitch.bypass = true
        currentTimePitch.rate = 1.0
        // Beat-fit: incoming runs at the tempo-matched rate through the blend
        // (bypassed only when the rate is exactly natural).
        let tempoRate = Float(params.tempoRate)
        if abs(tempoRate - 1.0) < 0.001 {
            otherTimePitch.bypass = true
            otherTimePitch.rate = 1.0
        } else {
            otherTimePitch.bypass = false
            otherTimePitch.rate = tempoRate
        }

        do {
            pendingIncomingURL = incomingURL
            var crossfadeDuration = params.duration

            // ── 0. MOOD PRESERVATION ──────────────────────────────────────
            // Compute mood-based adaptations: curve shape, EQ intensity, duration.
            let moodParams = computeMoodPreservationParams(
                outgoingAnalysis: outgoingAnalysis,
                incomingAnalysis: incomingAnalysis
            )
            // Only apply mood duration multipliers to beatmatch/bassSwap blends;
            // echoOut, ambientBlend, and quickPhraseCut are already precisely sized.
            if params.style == .beatmatchBlend || params.style == .bassSwap {
                if moodParams.bothEnergetic {
                    crossfadeDuration *= 1.15
                } else {
                    crossfadeDuration *= moodParams.durationMultiplier
                }
            }
            self.moodEqLowPassEndHz = moodParams.eqLowPassEndHz

            // ── 1. BPM SYNC — during the crossfade window ───────────────
            let outBPM = outgoingAnalysis?.bpm ?? 0
            let inBPM = incomingAnalysis?.bpm ?? 0
            incomingTargetRate = tempoRate
            print("[Engine] Style=\(params.style.rawValue) (\(params.styleReason)) | out \(String(format: "%.1f", outBPM)) BPM → in \(String(format: "%.1f", inBPM)) BPM @ rate \(String(format: "%.4f", tempoRate))")

            // ── 2. BEAT PHASE ALIGNMENT ──────────────────────────────────
            let incomingFirstBeat = params.beatPhaseLock ? (incomingAnalysis?.beatTimestamps.first ?? 0) : 0
            incomingCueOffset = params.vocalConnectionPoint > 0.05 ? params.vocalConnectionPoint : incomingFirstBeat
            currentTrackAnalysis = incomingAnalysis

            currentCrossfadeDuration = crossfadeDuration

            // Store incoming track metadata for future beat-aligned scheduling
            currentBarTimestamps = incomingAnalysis?.barTimestamps ?? []

            otherPlayer.stop()
            otherPlayer.reset()
            otherPlayer.volume = 0

            // Prepare per-deck EQ & Reverb cleanly before playback starts.
            resetEQ(currentEQ)
            resetEQ(otherEQ)
            resetReverb(currentReverb)
            resetReverb(otherReverb)

            // Bass-Swap prep: start incoming with low-end cut so both kicks never collide.
            if params.style == .bassSwap {
                otherEQ.bands[0].filterType = .highPass
                otherEQ.bands[0].frequency = config.bassSwapCutoffHz
                otherEQ.bands[0].bypass = false
            }

            // Store loudness-matching gains so track-to-track volume stays consistent.
            self.outgoingGain = Float(params.outgoingGainCompensation)
            self.incomingGain = Float(params.incomingGainCompensation)

            // ── 3. INCOMING BUFFER — staged if the warmup beat us here ──
            // Fetch/decode BEFORE measuring outgoingNow so decode latency never
            // shifts beat-phase alignment!
            let sampleRate = config.processingFormat.sampleRate
            let prePad: AVAudioPCMBuffer?
            if let staged = preparedCrossfade, staged.url == incomingURL {
                prePad = staged.buffer
                actualIncomingDuration = staged.duration
                fullIncomingDuration = staged.fullDuration
                preparedCrossfade = nil
            } else {
                if preparedCrossfade != nil { preparedCrossfade = nil }
                let made = try decodeIncomingBuffer(
                    incomingURL: incomingURL,
                    params: params,
                    incomingFirstBeat: incomingFirstBeat
                )
                prePad = made.buffer
                actualIncomingDuration = made.duration
                fullIncomingDuration = made.fullDuration
            }

            // Beat phase: land incoming downbeat on an outgoing bar line ONLY when beatPhaseLock is true.
            // Measured RIGHT BEFORE silence padding & play() so phase is tight to the millisecond.
            let outgoingNow = self.currentTime
            var beatPhaseDelay: Double = 0
            if params.beatPhaseLock, let outBars = outgoingAnalysis?.barTimestamps, !outBars.isEmpty {
                let onGridTolerance = 0.35
                var targetBar: Double?
                for barTime in outBars {
                    if barTime >= outgoingNow - onGridTolerance {
                        targetBar = barTime
                        break
                    }
                }
                if targetBar == nil, let lastBar = outBars.last, let outBPM = outgoingAnalysis?.bpm, outBPM > 0 {
                    targetBar = lastBar + 240.0 / outBPM
                }
                if let targetBar {
                    beatPhaseDelay = max(0, targetBar - outgoingNow)
                }
            }
            print("[Engine] Beat phase delay: \(String(format: "%.3f", beatPhaseDelay))s (lock=\(params.beatPhaseLock), outgoingNow=\(String(format: "%.2f", outgoingNow)))")
            blendTempoRate = tempoRate
            blendPadDelay = beatPhaseDelay

            // Silence pad needs the transition-time beatPhaseDelay, so it
            // always runs here — but it is a fast memcpy, not a decode.
            var bufferToSchedule: AVAudioPCMBuffer?
            if let pre = prePad {
                bufferToSchedule = self.padWithSilence(pre, sampleRate: sampleRate, beatPhaseOffset: beatPhaseDelay, rate: incomingTargetRate)
            }

            // Phase-aware splice: apply a 2ms linear fade-in on the cued buffer
            // so the first sample lands at zero regardless of where the cue point falls.
            // Prevents a click when the crossfade gain first opens on the incoming track.
            if let buf = bufferToSchedule {
                applyMicroFadeIn(buf)
            }

            if let bufferToSchedule {
                print("[Engine] Scheduling incoming buffer: \(bufferToSchedule.frameLength) frames @ \(String(format: "%.0f", bufferToSchedule.format.sampleRate))Hz/\(bufferToSchedule.format.channelCount)ch")
                otherPlayer.scheduleBuffer(bufferToSchedule, at: nil)
            } else {
                print("[Engine] Scheduling incoming file directly (no buffer prep)")
                otherPlayer.scheduleFile(try AudioHelpers.readAudio(url: incomingURL), at: nil)
            }

            otherPlayer.play()
            crossfadeStartTime = Date()
            // Outgoing track position in FULL-song coordinates (seek/intro-trim aware)
            // for accurate real-time vocal sampling & energy curve exponent.
            self.outgoingCrossfadeStartPos = max(0, self.currentTime)

            // Energy-aware curve exponent: measure energy ratio at transition.
            // When the outgoing is much louder, the incoming fades in more gradually
            // (exponent > 1). When the incoming is louder, it blends in sooner
            // (exponent < 1). This prevents sudden volume jumps from energy mismatch.
            let energyExponent = computeEnergyCurveExponent(
                outgoingAnalysis: outgoingAnalysis,
                incomingAnalysis: incomingAnalysis,
                outgoingTime: self.outgoingCrossfadeStartPos,
                outgoingDuration: self.currentDuration,
                incomingTime: self.incomingCueOffset,
                incomingDuration: actualIncomingDuration
            )
            // Mood bias: energetic = steeper (×0.9), calm = gentler (×1.3)
            self.curveExponent = max(0.3, min(3.5, energyExponent * moodParams.curveExponentBias))

            print("[Engine] Automix: \(String(format: "%.1f", crossfadeDuration))s, strategy \(params.vocalStrategy), curveExp \(String(format: "%.2f", self.curveExponent)), moodExpBias \(String(format: "%.2f", moodParams.curveExponentBias))")

            // ── 4. PHASE-ALIGNED CROSSFADE VOLUME & STYLE DSP ENVELOPE ──
            isCrossfading = true
            let rampInterval = 0.02
            let crossfadeSteps = max(1, Int(crossfadeDuration / rampInterval))
            let padSteps = Int((beatPhaseDelay / rampInterval).rounded(.up))
            var currentStep = -padSteps
            var smoothedOutDuckDB: Float = 0
            var smoothedInDuckDB: Float = 0
            let transitionStyle = params.style
            let vocalStrategy = params.vocalStrategy
            let outAnalysisForLoop = outgoingAnalysis
            let inAnalysisForLoop = incomingAnalysis
            let outStartPos = self.outgoingCrossfadeStartPos
            let inStartPos = self.incomingCueOffset
            let inRateForLoop = Double(tempoRate)

            crossfadeTimer?.invalidate()
            crossfadeTimer = Timer.scheduledTimer(withTimeInterval: rampInterval, repeats: true) { [weak self] timer in
                guard let self = self, self.isCrossfading else {
                    timer.invalidate()
                    return
                }

                currentStep += 1

                // During the beat-phase pad (currentStep < 0) the incoming buffer
                // is still playing silence — keep outgoing clean at full volume.
                if currentStep < 0 {
                    self.currentPlayer.volume = self.clampVolume(self.outgoingGain)
                    self.otherPlayer.volume = 0
                    return
                }

                let progress = min(1.0, max(0.0, Double(currentStep) / Double(crossfadeSteps)))
                let s = progress * progress * (3.0 - 2.0 * progress)  // smoothstep

                // ── DJ-style & Context-Aware Volume Envelope ───────────────
                let outAmplitude: Float
                let inAmplitude: Float
                switch transitionStyle {
                case .bassSwap:
                    // Real DJ Bass-Swap deck curve:
                    // 0.00–0.45: outgoing stays strong (1.0 → 0.86) while incoming rises (0.0 → 0.86) under HPF.
                    // 0.45–0.58: mid-phrase bass swap — incoming hits full power (0.86 → 1.0), outgoing holds steady then yields.
                    // 0.58–1.00: outgoing rolls off cleanly (0.86 → 0.0) with HPF + LPF while incoming leads at 1.0.
                    if progress < 0.45 {
                        let t = progress / 0.45
                        let st = t * t * (3.0 - 2.0 * t)
                        outAmplitude = Float(1.0 - 0.14 * st)
                        inAmplitude = Float(0.86 * st)
                    } else if progress <= 0.58 {
                        let t = (progress - 0.45) / 0.13
                        let st = t * t * (3.0 - 2.0 * t)
                        outAmplitude = Float(0.86 - 0.10 * st)
                        inAmplitude = Float(0.86 + 0.14 * st)
                    } else {
                        let t = (progress - 0.58) / 0.42
                        let st = t * t * (3.0 - 2.0 * t)
                        outAmplitude = Float(0.76 * cos(st * .pi / 2.0))
                        inAmplitude = 1.0
                    }
                case .beatmatchBlend:
                    // DJ energy-preserving blend: hold combined groove high instead of dipping mid-fade.
                    if progress < 0.50 {
                        let t = progress / 0.50
                        let st = t * t * (3.0 - 2.0 * t)
                        outAmplitude = Float(1.0 - 0.18 * st)
                        inAmplitude = Float(0.88 * st)
                    } else {
                        let t = (progress - 0.50) / 0.50
                        let st = t * t * (3.0 - 2.0 * t)
                        outAmplitude = Float(0.82 * cos(st * .pi / 2.0))
                        inAmplitude = Float(0.88 + 0.12 * st)
                    }
                case .echoOut:
                    // Outgoing drops into a lush reverb tail while incoming enters cleanly.
                    let outP = min(1.0, progress / 0.68)
                    let outS = outP * outP * (3.0 - 2.0 * outP)
                    let inP = max(0.0, (progress - 0.15) / 0.70)
                    let inClamped = min(1.0, inP)
                    let inS = inClamped * inClamped * (3.0 - 2.0 * inClamped)
                    outAmplitude = Float(cos(outS * .pi / 2.0))
                    inAmplitude = Float(sin(inS * .pi / 2.0))
                case .ambientBlend:
                    let warped = pow(s, max(1.15, self.curveExponent))
                    let angle = warped * .pi / 2.0
                    outAmplitude = Float(cos(angle))
                    inAmplitude = Float(sin(angle))
                case .quickPhraseCut:
                    let warped = pow(s, 0.85)
                    let angle = warped * .pi / 2.0
                    outAmplitude = Float(cos(angle))
                    inAmplitude = Float(sin(angle))
                }

                self.currentPlayer.volume = self.clampVolume(outAmplitude * self.outgoingGain)
                self.otherPlayer.volume = self.clampVolume(inAmplitude * self.incomingGain)

                if currentStep >= crossfadeSteps {
                    self.lastIncomingVolume = self.clampVolume(self.incomingGain)
                }

                // ── Style-specific 3-Band EQ & Per-Deck Reverb DSP ─────────
                let outEQ = self.currentEQ
                let inEQ = self.otherEQ
                let outRev = self.currentReverb

                switch transitionStyle {
                case .bassSwap:
                    // Band 0 (HPF): swap low-end cleanly around mid-phrase (0.45 → 0.62)
                    let bassHz = self.config.bassSwapCutoffHz
                    if progress < 0.45 {
                        outEQ.bands[0].bypass = true
                        inEQ.bands[0].filterType = .highPass
                        inEQ.bands[0].frequency = bassHz
                        inEQ.bands[0].bypass = false
                    } else if progress <= 0.62 {
                        let t = Float((progress - 0.45) / 0.17)
                        let swapS = t * t * (3.0 - 2.0 * t)
                        let outHP = 20.0 * pow(bassHz / 20.0, swapS)
                        let inHP = bassHz * pow(20.0 / bassHz, swapS)
                        outEQ.bands[0].filterType = .highPass
                        outEQ.bands[0].frequency = outHP
                        outEQ.bands[0].bypass = outHP < 25.0
                        inEQ.bands[0].filterType = .highPass
                        inEQ.bands[0].frequency = inHP
                        inEQ.bands[0].bypass = inHP < 25.0
                    } else {
                        outEQ.bands[0].filterType = .highPass
                        outEQ.bands[0].frequency = bassHz
                        outEQ.bands[0].bypass = false
                        inEQ.bands[0].bypass = true
                    }
                    // Band 2 (LPF): gentle warm roll-off on outgoing highs
                    if self.config.eqFadeEnabled {
                        let lpCut = self.config.eqLowPassStartHz * pow(self.moodEqLowPassEndHz / self.config.eqLowPassStartHz, Float(s))
                        outEQ.bands[2].filterType = .lowPass
                        outEQ.bands[2].frequency = lpCut
                        outEQ.bands[2].bypass = false
                    }

                case .echoOut:
                    // Per-deck reverb tail ONLY on outgoing deck + HPF to keep tail airy
                    let revP = min(1.0, Float(progress / 0.55))
                    let revS = revP * revP * (3.0 - 2.0 * revP)
                    outRev.bypass = false
                    outRev.wetDryMix = self.config.echoOutMaxWetMix * revS

                    let hpCut = 20.0 * pow(200.0 / 20.0, Float(s))
                    outEQ.bands[0].filterType = .highPass
                    outEQ.bands[0].frequency = hpCut
                    outEQ.bands[0].bypass = hpCut < 25.0

                    if self.config.eqFadeEnabled {
                        let lpCut = self.config.eqLowPassStartHz * pow(3200.0 / self.config.eqLowPassStartHz, Float(s))
                        outEQ.bands[2].filterType = .lowPass
                        outEQ.bands[2].frequency = lpCut
                        outEQ.bands[2].bypass = false
                    }

                case .ambientBlend:
                    if self.config.eqFadeEnabled {
                        let lpCut = self.config.eqLowPassStartHz * pow(2200.0 / self.config.eqLowPassStartHz, Float(s))
                        outEQ.bands[2].filterType = .lowPass
                        outEQ.bands[2].frequency = lpCut
                        outEQ.bands[2].bypass = false
                    }

                case .beatmatchBlend:
                    // Gentle HPF in the final 40% to clear outgoing sub-bass + LPF on highs
                    if progress > 0.60 {
                        let hpP = Float((progress - 0.60) / 0.40)
                        let hpCut = 20.0 * pow(140.0 / 20.0, hpP)
                        outEQ.bands[0].filterType = .highPass
                        outEQ.bands[0].frequency = hpCut
                        outEQ.bands[0].bypass = hpCut < 25.0
                    }
                    if self.config.eqFadeEnabled {
                        let lpCut = self.config.eqLowPassStartHz * pow(self.moodEqLowPassEndHz / self.config.eqLowPassStartHz, Float(s))
                        outEQ.bands[2].filterType = .lowPass
                        outEQ.bands[2].frequency = lpCut
                        outEQ.bands[2].bypass = false
                    }

                case .quickPhraseCut:
                    if self.config.eqFadeEnabled {
                        let lpCut = self.config.eqLowPassStartHz * pow(4000.0 / self.config.eqLowPassStartHz, Float(s))
                        outEQ.bands[2].filterType = .lowPass
                        outEQ.bands[2].frequency = lpCut
                        outEQ.bands[2].bypass = false
                    }
                }

                // ── Dynamic Vocal Mid-Ducking (Band 1 @ 1800 Hz) ───────────
                // Ducks the background deck's vocal presence band in real time
                // when the priority deck is actively singing (prevents vocal clash).
                if transitionStyle == .beatmatchBlend || transitionStyle == .bassSwap,
                   vocalStrategy != .standard {
                    let elapsedBlend = Double(currentStep) * rampInterval
                    let outVocal = Self.sampleVocalActivity(outAnalysisForLoop, at: outStartPos + elapsedBlend)
                    let inVocal = Self.sampleVocalActivity(inAnalysisForLoop, at: inStartPos + elapsedBlend * inRateForLoop)
                    let maxDuck = self.config.vocalDuckMaxDB  // negative dB (e.g. -4.5)

                    var targetOutDuck: Float = 0
                    var targetInDuck: Float = 0

                    switch vocalStrategy {
                    case .duckIncoming, .priorityOutgoing:
                        if outVocal > 0.30 {
                            targetInDuck = maxDuck * min(1.0, (outVocal - 0.25) / 0.55)
                        }
                    case .duckOutgoing, .priorityIncoming:
                        if inVocal > 0.30 {
                            targetOutDuck = maxDuck * min(1.0, (inVocal - 0.25) / 0.55)
                        }
                    case .standard:
                        break
                    }

                    // Exponential smoothing avoids zipper noise on EQ gain changes
                    smoothedOutDuckDB += (targetOutDuck - smoothedOutDuckDB) * 0.25
                    smoothedInDuckDB += (targetInDuck - smoothedInDuckDB) * 0.25

                    outEQ.bands[1].filterType = .parametric
                    outEQ.bands[1].frequency = self.config.vocalDuckFreqHz
                    outEQ.bands[1].bandwidth = 1.2
                    outEQ.bands[1].gain = smoothedOutDuckDB
                    outEQ.bands[1].bypass = abs(smoothedOutDuckDB) < 0.15

                    inEQ.bands[1].filterType = .parametric
                    inEQ.bands[1].frequency = self.config.vocalDuckFreqHz
                    inEQ.bands[1].bandwidth = 1.2
                    inEQ.bands[1].gain = smoothedInDuckDB
                    inEQ.bands[1].bypass = abs(smoothedInDuckDB) < 0.15
                }

                // ── End ─────────────────────────────────────────────────
                if currentStep >= crossfadeSteps {
                    timer.invalidate()
                    self.crossfadeTimer = nil
                    self.completeCrossfade(incomingDuration: self.actualIncomingDuration)
                    return
                }
            }

            return true
        } catch {
            pendingIncomingURL = nil
            tempoRampTimer?.invalidate()
            tempoRampTimer = nil
            print("[Engine] Crossfade failed: \(error)")
            return false
        }
    }

    // MARK: - Current State

    var currentTime: TimeInterval {
        guard let startTime = trackStartTime else { return 0 }
        guard isPlaying else { return seekOffset }
        let elapsed = -startTime.timeIntervalSinceNow
        return seekOffset + min(elapsed, remainingAtStart)
    }

    var duration: TimeInterval { currentDuration }

    // MARK: - Track End Detection

    private func scheduleTrackEndTimer(delay: TimeInterval) {
        cancelTrackEndTimer()
        trackEndTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self, !self.isCrossfading, self.isPlaying else { return }
            print("[Engine] Track end")
            self.trackEndTimer = nil
            self.onTrackEnd?()
        }
    }

    /// True remaining playback time, pause-aware (elapsed before a pause is kept
    /// in seekOffset, so wall-clock since resume alone would overestimate).
    private func trueRemaining() -> TimeInterval {
        guard remainingAtStart > 0 else { return 0 }
        let played = max(0, currentTime - seekOffset)
        return max(0, remainingAtStart - played)
    }

    /// Solo play-through: fire onTrackEnd at the true track end, no early
    /// crossfade trigger and no pre-crossfade EQ. Safe to call while paused
    /// (flag only — play() schedules via restartTrackEndTimer).
    func playThroughToEnd() {
        soloPlayThrough = true
        cancelTrackEndTimer()
        cancelPreCrossfadeEQ()
        guard isPlaying else { return }
        scheduleTrackEndTimer(delay: max(0.1, trueRemaining()))
    }

    /// Clears solo play-through without scheduling (paused exit path).
    func cancelSoloPlayThrough() {
        soloPlayThrough = false
        cancelTrackEndTimer()
        cancelPreCrossfadeEQ()
    }

    /// Restores normal beat-aligned crossfade scheduling after solo (playing path).
    /// Delay counts from NOW (true remaining), not from track load — otherwise
    /// the trigger lands past the true end and the song just stops with no mix.
    func resumeAutoCrossfade() {
        soloPlayThrough = false
        guard isPlaying, currentDuration > 0 else { return }
        cancelTrackEndTimer()
        cancelPreCrossfadeEQ()
        let remaining = trueRemaining()
        guard remaining > 0.15 else {
            // Song basically over — hand off immediately so it mixes to next.
            scheduleTrackEndTimer(delay: 0.1)
            return
        }
        let finalDelay = max(0.1, remaining - beatAlignedCrossfadeTime)
        schedulePreCrossfadeEQ(delay: finalDelay - 5.0)
        scheduleTrackEndTimer(delay: finalDelay)
    }

    /// Refreshes the current track's analysis + bar grid in place after the
    /// library analysis pass attaches richer data to a track that already
    /// loaded (import flow analyzes after loading). The caller re-arms the
    /// transition right after so the new grid is actually used.
    func refreshCurrentTrackAnalysis(_ analysis: TrackAnalysis) {
        currentTrackAnalysis = analysis
        if !analysis.barTimestamps.isEmpty { currentBarTimestamps = analysis.barTimestamps }
    }

    /// Re-arms the automatic transition timer now that the next track (and its
    /// analysis) is known — e.g. once the queue resolves the successor of the
    /// current song. Recomputes the beat-aligned trigger with BOTH analyses so
    /// the second-half energy-match search can score real RMS/slope fit, then
    /// re-arms the timer. Safe to call any time during playback (idempotent).
    /// `incomingEntryTime` (the actual landing point of the incoming buffer,
    /// after intro trim) anchors the energy comparison to the real audio.
    func rescheduleForNextTrack(
        nextAnalysis: TrackAnalysis?,
        incomingEntryTime: Double = 0,
        crossfadeDuration: Double? = nil
    ) {
        guard !soloPlayThrough, isPlaying, currentDuration > 0 else { return }
        cancelTrackEndTimer()
        cancelPreCrossfadeEQ()
        let effectiveFade = max(crossfadeDuration ?? config.crossfadeDuration, 8.0)
        beatAlignedCrossfadeTime = computeBeatAlignedCrossfadeTime(
            duration: currentDuration,
            rate: Double(currentRate),
            barTimestamps: currentBarTimestamps,
            crossfadeDuration: effectiveFade,
            outgoingAnalysis: currentTrackAnalysis,
            incomingAnalysis: nextAnalysis,
            incomingEntryTime: incomingEntryTime
        )
        let remaining = trueRemaining()
        let finalDelay: TimeInterval
        if remaining > beatAlignedCrossfadeTime {
            finalDelay = max(0.1, remaining - beatAlignedCrossfadeTime)
        } else if remaining > 4.0 {
            // Already past the optimal bar (e.g. analysis finished late in the song):
            // trigger on the next clean bar instead of waiting until 0s left.
            let now = currentTime
            let minFadeRoom = min(effectiveFade, remaining * 0.55)
            let maxSafe = max(now + 1.5, currentDuration - max(4.0, minFadeRoom))
            if let nextBar = currentBarTimestamps.first(where: { $0 >= now + 1.0 && $0 <= maxSafe }) {
                finalDelay = max(0.5, nextBar - now)
            } else {
                finalDelay = max(0.5, remaining - minFadeRoom)
            }
        } else {
            finalDelay = 0.1
        }
        crossfadeTriggerDelay = finalDelay
        schedulePreCrossfadeEQ(delay: finalDelay - 5.0)
        scheduleTrackEndTimer(delay: finalDelay)
        print("[Engine] Transition for next track re-armed in " + String(format: "%.2f", finalDelay) + "s (pos=\(String(format: "%.1f", currentTime))/\(String(format: "%.1f", currentDuration))s, triggerFromEnd=\(String(format: "%.1f", beatAlignedCrossfadeTime))s, energyMatch=\(triggerFromEnergyMatch))")
    }

    private func restartTrackEndTimer() {
        guard trackStartTime != nil, remainingAtStart > 0 else { return }
        let remaining = trueRemaining()
        if soloPlayThrough {
            if remaining > 0 {
                scheduleTrackEndTimer(delay: max(0.1, remaining))
            }
            return
        }
        if remaining > beatAlignedCrossfadeTime {
            let delay = remaining - beatAlignedCrossfadeTime
            schedulePreCrossfadeEQ(delay: delay - 5.0)
            scheduleTrackEndTimer(delay: delay)
        } else if remaining > 0 {
            scheduleTrackEndTimer(delay: max(0.1, remaining))
        }
    }

    private func cancelTrackEndTimer() {
        trackEndTimer?.invalidate()
        trackEndTimer = nil
    }

    private func cancelPreCrossfadeEQ() {
        preCrossfadeTimer?.invalidate()
        preCrossfadeTimer = nil
    }

    /// Pre-roll-off DISABLED. The outgoing used to start low-passing 5 seconds
    /// BEFORE the crossfade even began — the song sounded filtered/dull long
    /// before any blend was audible. The blend's own EQ fade (see the crossfade
    /// envelope below) handles the handoff, so there is deliberately nothing to
    /// schedule here; this stays as a no-op so callers remain valid.
    private func schedulePreCrossfadeEQ(delay: TimeInterval) {
        _ = delay
        cancelPreCrossfadeEQ()
    }

    /// Time (seconds) of the outgoing track's last musical content (vocal OR energy
    /// spike), so the crossfade can overlap the resolving tail consistently. Uses a
    /// smoothed signal so brief dips / bright tails don't skew it per-song.
    private static func lastContentEndTime(analysis: TrackAnalysis?, duration: Double) -> Double {
        guard let a = analysis, duration > 0 else { return 0 }
        var end: Double = 0

        if !a.vocalActivity.isEmpty {
            let s = smooth(a.vocalActivity, window: 3)
            let timePer = duration / Double(s.count)
            for i in (0..<s.count).reversed() where s[i] > 0.15 {
                end = max(end, Double(i) * timePer)
                break
            }
        }

        if !a.energyProfile.isEmpty {
            let s = smooth(a.energyProfile, window: 3)
            let tailCount = max(1, s.count / 10)
            let tailAvg = s.suffix(tailCount).reduce(0, +) / Float(tailCount)
            let threshold = tailAvg * 1.4 + 0.02
            let timePer = duration / Double(s.count)
            for i in (0..<s.count).reversed() where s[i] > threshold {
                end = max(end, Double(i) * timePer)
                break
            }
        }

        return end
    }

    private static func smooth(_ values: [Float], window: Int) -> [Float] {
        guard values.count > window else { return values }
        var out = [Float](repeating: 0, count: values.count)
        let half = window / 2
        for i in 0..<values.count {
            let lo = max(0, i - half)
            let hi = min(values.count - 1, i + half)
            var sum: Float = 0
            for j in lo...hi { sum += values[j] }
            out[i] = sum / Float(hi - lo + 1)
        }
        return out
    }

    /// End time of the last high-energy section ("chorus" / "bridge") in the
    /// outgoing track. Returns 0 if none found — the crossfade should never
    /// trigger before this point or the musical climax gets cut.
    private static func lastHighEnergySectionEnd(analysis: TrackAnalysis?) -> Double {
        guard let sections = analysis?.structureSections, !sections.isEmpty else { return 0 }
        for section in sections.reversed() {
            if section.label == "chorus" || section.label == "bridge" {
                return section.endTime
            }
        }
        return 0
    }

    // MARK: - Beat Phase Alignment

    /// Computes the best bar boundary for crossfade based on beat alignment, energy matching,
    /// and musical structure awareness. Avoids outgoing intro, prefers phrase boundaries.
    /// Returns seconds-from-end when the crossfade should trigger.
    private func computeBeatAlignedCrossfadeTime(
        duration: Double,
        rate: Double,
        barTimestamps: [Double],
        crossfadeDuration: Double,
        outgoingAnalysis: TrackAnalysis?,
        incomingAnalysis: TrackAnalysis?,
        incomingEntryTime: Double = 0
    ) -> Double {
        // ── Second-half energy match ─────────────────────────
        // Prefer a bar boundary in the second half of the outgoing track whose
        // local energy segment matches the incoming track's entry (RMS level
        // + slope direction). The search spans the BODY of the outgoing track
        // (from ~35% onward, after the intro) and actively favours seams in
        // the 40–70% region, so the handoff adapts to the music instead of
        // always being pulled toward the outro. Returns nil — falling back to
        // the legacy near-the-end search — when no viable candidate scores
        // well or the incoming analysis is unknown.
        triggerFromEnergyMatch = false
        if let energyBar = energyMatchedTransitionBar(
            duration: duration,
            rate: rate,
            minTriggerTime: crossfadeDuration,
            barTimestamps: barTimestamps,
            outgoingAnalysis: outgoingAnalysis,
            incomingAnalysis: incomingAnalysis,
            crossfadeDuration: crossfadeDuration,
            incomingEntryTime: incomingEntryTime
        ) {
            triggerFromEnergyMatch = true
            let adjusted = duration / rate
            print("[Engine] Energy-matched transition at bar " +
                  String(format: "%.2f", energyBar) +
                  "s (score wins the adaptive seam search)")
            return adjusted - energyBar
        }

        guard !barTimestamps.isEmpty, rate > 0 else {
            return crossfadeDuration
        }

        let adjustedDuration = duration / rate
        let effectiveEnd: Double
        if let trail = outgoingAnalysis?.trailingSilence, trail > 1.0 {
            effectiveEnd = min(adjustedDuration, trail / rate)
        } else {
            effectiveEnd = adjustedDuration
        }
        let minTriggerTime = max(crossfadeDuration, 12.0)

        // Proactive Apple AutoMix fallback (when incoming analysis is unknown or
        // energyMatchedTransitionBar returned nil): pick a clean 8/16-bar phrase
        // boundary in the 72–88% zone (or right at outro start), NEVER waiting
        // until 12s before dead silence!
        let outIntroEnd = outgoingAnalysis?.introRegion?.end ?? 0
        let outroStart = outgoingAnalysis?.outroRegion?.start ?? 0
        let chorusEnd = Self.lastHighEnergySectionEnd(analysis: outgoingAnalysis)
        let lower = max(effectiveEnd * 0.68, outIntroEnd)
        let upper = effectiveEnd - minTriggerTime

        var bestBar: Double?
        var bestRank = -Double.infinity

        if upper > lower {
            let chorusCap = min(chorusEnd - 0.5, effectiveEnd * 0.86)
            for (barIndex, barTime) in barTimestamps.enumerated() {
                guard barTime >= lower, barTime <= upper else { continue }

                let phraseScore: Double
                if barIndex % 16 == 0 {
                    phraseScore = 1.0
                } else if barIndex % 8 == 0 {
                    phraseScore = 0.85
                } else if barIndex % 4 == 0 {
                    phraseScore = 0.55
                } else {
                    phraseScore = 0.20
                }

                let pos = barTime / max(1.0, effectiveEnd)
                let posScore: Double
                if pos >= 0.74 && pos <= 0.88 {
                    posScore = 1.0
                } else if pos >= 0.68 && pos < 0.74 {
                    posScore = 0.6
                } else {
                    posScore = 0.3
                }

                let outroBonus = (outroStart > effectiveEnd * 0.65 && abs(barTime - outroStart) <= 4.5) ? 0.35 : 0.0
                let chorusPenalty = (chorusEnd > 0 && chorusCap <= upper && barTime < chorusCap) ? 0.25 : 0.0
                let vCost = vocalCost(
                    at: barTime,
                    windowSeconds: 3.0,
                    activity: outgoingAnalysis?.vocalActivity ?? [],
                    duration: adjustedDuration
                )
                let rank = posScore * 0.45 + phraseScore * 0.30 + (1.0 - vCost) * 0.25 + outroBonus - chorusPenalty
                if rank > bestRank {
                    bestRank = rank
                    bestBar = barTime
                }
            }
        }

        if let bar = bestBar {
            let triggerPoint = adjustedDuration - bar
            print("[Engine] Phrase-aligned bar at \(String(format: "%.2f", bar))s → \(String(format: "%.1f", triggerPoint))s from end (rank \(String(format: "%.2f", bestRank)))")
            return triggerPoint
        }

        // Ultimate fallback (no bars available): aim ~18% before audible end (clamped 16–32s).
        let proportionalLead = min(32.0, max(minTriggerTime + 4.0, effectiveEnd * 0.18))
        let silenceMargin = max(0, adjustedDuration - effectiveEnd)
        let fallbackFromEnd = min(adjustedDuration * 0.35, silenceMargin + proportionalLead)
        print("[Engine] No bar boundary found, using smart proportional trigger at \(String(format: "%.2f", fallbackFromEnd))s from end")
        return fallbackFromEnd
    }

    /// Scores how well the outgoing energy trajectory matches the incoming energy trajectory.
    /// Compares both absolute levels and slope direction during the crossfade window.
    private func computeEnergyMatchScore(
        outgoingTime: Double,
        outgoingDuration: Double,
        outgoingEnergy: [Float],
        incomingEnergy: [Float]
    ) -> Double {
        guard !outgoingEnergy.isEmpty, !incomingEnergy.isEmpty else { return 0.5 }

        let outCount = outgoingEnergy.count
        let inCount = incomingEnergy.count

        // Outgoing energy at trigger point
        let outIndex = Int(outgoingTime / outgoingDuration * Double(outCount))
        let outClamped = max(0, min(outIndex, outCount - 1))
        let outEnergyVal = Double(outgoingEnergy[outClamped])

        // Incoming energy at start
        let inEnergyVal = Double(incomingEnergy[0])

        // Absolute level match (60% weight)
        let levelDiff = abs(outEnergyVal - inEnergyVal)
        let levelScore = max(0, 1.0 - levelDiff * 2.0)

        // Slope match (40% weight) — compare energy direction during crossfade window
        let windowSize = max(1, outCount / 20)  // ~5% of track
        let outSlopeStart = max(0, outClamped - windowSize)
        let outSlopeEnd = min(outCount - 1, outClamped + windowSize)
        let outSlope = Double(outgoingEnergy[outSlopeEnd] - outgoingEnergy[outSlopeStart])

        let inSlopeEnd = min(inCount - 1, windowSize)
        let inSlope = Double(incomingEnergy[inSlopeEnd] - incomingEnergy[0])

        // Normalize slopes to [-1, 1]
        let maxSlope = max(abs(outSlope), abs(inSlope), 0.001)
        let outSlopeNorm = outSlope / maxSlope
        let inSlopeNorm = inSlope / maxSlope

        // Score: same direction = high, opposite = low
        let slopeSimilarity = 1.0 - abs(outSlopeNorm - inSlopeNorm) / 2.0
        let slopeScore = max(0, slopeSimilarity)

        return levelScore * 0.6 + slopeScore * 0.4
    }

    // MARK: - Adaptive Energy-Matched Transition

    /// Finds a bar boundary in the BODY of the outgoing track (from ~35%
    /// onward, after the intro) where the outgoing energy segment matches the
    /// incoming track's entry energy — RMS level plus slope direction. A
    /// position prior favours the 40–70% region and penalises the outro, so
    /// the seam adapts to the music (Apple-Automix-like) instead of being
    /// magnetically pulled to the end of the song. The crossfade may start as
    /// early as 35% in; the incoming entry (after intro trim) is the reference.
    ///
    /// Returns the bar timestamp (seconds) of the winning seam, or nil when
    /// nothing scores well or either track has no usable analysis — the caller
    /// then falls back to the legacy near-the-end search.
    private func energyMatchedTransitionBar(
        duration: Double,
        rate: Double,
        minTriggerTime: Double,
        barTimestamps: [Double],
        outgoingAnalysis: TrackAnalysis?,
        incomingAnalysis: TrackAnalysis?,
        crossfadeDuration: Double,
        incomingEntryTime: Double = 0
    ) -> Double? {
        guard !barTimestamps.isEmpty, duration > 0, rate > 0 else { return nil }
        guard let out = outgoingAnalysis else { return nil }
        // The incoming analysis drives the energy match — without it the search
        // degenerates to the legacy heuristics, so bail out and let the fallback run.
        guard let inn = incomingAnalysis else { return nil }
        guard !out.energyProfile.isEmpty, !inn.energyProfile.isEmpty else { return nil }

        let adjustedDuration = duration / rate
        let effectiveEnd: Double
        if out.trailingSilence > 1.0 {
            effectiveEnd = min(adjustedDuration, out.trailingSilence / rate)
        } else {
            effectiveEnd = adjustedDuration
        }

        let outIntroEnd = out.introRegion?.end ?? 0
        // Proactive Apple AutoMix zone: search 68%..effectiveEnd - max(crossfadeDuration, 14s)
        // so transitions overlap active groove/outro instead of waiting for silence at 96%.
        let chorusEnd = Self.lastHighEnergySectionEnd(analysis: out)
        let outroStart = out.outroRegion?.start ?? 0
        let rawLower = max(effectiveEnd * 0.68, outIntroEnd)
        let minLeadOut = max(minTriggerTime, 14.0)
        let upper = effectiveEnd - minLeadOut
        guard upper > 1.0 else { return nil }
        // Protect final chorus climax, but cap protection at 86% of audible length so
        // songs whose chorus runs all the way to the end still mix out cleanly in their final bars.
        let chorusCap = min(chorusEnd - 0.5, effectiveEnd * 0.86)
        let protectedLower = (chorusEnd > 0 && chorusCap <= upper) ? max(rawLower, chorusCap) : rawLower
        let lower = min(protectedLower, upper)
        guard upper >= lower else { return nil }

        let outEnergy = out.energyProfile
        var inEnergy = inn.energyProfile
        // Anchor the comparison to the ACTUAL landing segment of the incoming
        // buffer (after intro trim) — index 0 may be a skipped intro that never
        // plays, which would misjudge the seam energy.
        if incomingEntryTime > 0.5, inn.duration > 0, !inEnergy.isEmpty {
            let entryIdx = max(0, min(inEnergy.count - 1,
                                      Int(incomingEntryTime / inn.duration * Double(inEnergy.count))))
            if entryIdx > 0, inEnergy.count - entryIdx >= 8 {
                inEnergy = Array(inEnergy[entryIdx...])
            }
        }
        let activity = out.vocalActivity

        var bestBar: Double?
        var bestScore = 0.0

        for bar in barTimestamps {
            guard bar >= lower, bar <= upper else { continue }

            // Energy seam fit: outgoing segment at the candidate vs incoming at 0.
            let energyScore = computeEnergyMatchScore(
                outgoingTime: bar,
                outgoingDuration: adjustedDuration,
                outgoingEnergy: outEnergy,
                incomingEnergy: inEnergy
            )

            // Phrase bonus: prefer 8-/16-bar boundaries.
            let barIndex = barTimestamps.firstIndex(of: bar) ?? 0
            let phraseScore: Double
            if barIndex % 16 == 0 {
                phraseScore = 1.0
            } else if barIndex % 8 == 0 {
                phraseScore = 0.8
            } else if barIndex % 4 == 0 {
                phraseScore = 0.5
            } else {
                phraseScore = 0.2
            }

            // BPM proximity — closer tempos = tighter blend through the handoff.
            let bpmScore: Double
            if let outBPM = out.bpm, let inBPM = inn.bpm, outBPM > 0, inBPM > 0 {
                let bpmDiff = abs(outBPM - inBPM) / max(outBPM, inBPM)
                bpmScore = max(0, 1.0 - bpmDiff * 5.0)
            } else {
                bpmScore = 0.5
            }

            // Vocal cost: short window — the blend ducks anyway; only the
            // moment the crossfade opens matters. A 12s window vetoed every
            // mid-song seam in vocal-dense songs, pushing transitions to the
            // sparse outro — which is exactly what this search must avoid.
            let vocalCost = vocalCost(at: bar, windowSeconds: min(crossfadeDuration, 3.0),
                                      activity: activity, duration: adjustedDuration)
            let vocalScore = max(0, 1.0 - vocalCost)

            // Section awareness: penalise seams that land deep inside a
            // high-energy section (chorus / bridge). Cutting mid-chorus is the
            // "skipped the chorus and jumped" feel the listener flags — prefer
            // section starts, phrase boundaries, or lower-energy regions.
            var sectionPenalty: Double = 0
            let sections = out.structureSections
            if !sections.isEmpty {
                for s in sections {
                    if (s.label == "chorus" || s.label == "bridge")
                        && bar > s.startTime + max(4.0, s.duration * 0.25)
                        && bar < s.endTime - 1.0 {
                        sectionPenalty = max(sectionPenalty, 0.2)
                        break
                    }
                }
            }

            // Position prior: Apple AutoMix sweet spot is 74–88% of audible track
            // (trims long outros and keeps groove alive; penalizes waiting past 90%).
            let position = bar / max(1.0, effectiveEnd)
            let positionPrior: Double
            if position >= 0.74 && position <= 0.88 {
                positionPrior = 0.25
            } else if position >= 0.68 && position < 0.74 {
                positionPrior = 0.08
            } else if position > 0.88 && position <= 0.91 {
                positionPrior = 0.02
            } else {
                positionPrior = -0.14
            }

            // Outro-start bonus: starting the blend right as the outro begins
            // (after the final chorus resolves) is the cleanest musical handoff.
            let outroBonus: Double
            if outroStart > effectiveEnd * 0.65, abs(bar - outroStart) <= 4.5 {
                outroBonus = 0.22
            } else {
                outroBonus = 0.0
            }

            // Momentum: never cut straight through a rising, above-average
            // "good mood" build — that is the abrupt-change the ear notices.
            // Reward natural gaps where the energy dips or is already falling.
            let centerIdx = max(0, min(outEnergy.count - 1,
                                       Int(bar / adjustedDuration * Double(outEnergy.count))))
            let win = max(1, outEnergy.count / 34)  // ~3s either side
            let lo = max(0, centerIdx - win)
            let hi = min(outEnergy.count, centerIdx + win + 1)
            let localAvg = outEnergy[lo..<hi].reduce(0, +) / Float(max(1, hi - lo))
            let ratio = Double(outEnergy[centerIdx]) / max(0.001, Double(localAvg))
            let slopeAt = Double(outEnergy[min(outEnergy.count - 1, centerIdx + win * 2)]
                - outEnergy[max(0, centerIdx - win * 2)])
            let buildPenalty = -0.12 * min(1, max(0, (ratio - 1.05) * 3))
                * min(1, max(0, slopeAt * 6))
            let gapBonus = 0.05 * min(1, max(0, -slopeAt * 4))
            let momentum = buildPenalty + gapBonus

            let combined = energyScore * 0.45 + phraseScore * 0.18 + bpmScore * 0.15
                + vocalScore * 0.17 + positionPrior + outroBonus + momentum - sectionPenalty
            if combined > bestScore {
                bestScore = combined
                bestBar = bar
            }
        }

        // Accept any solid musical phrase match instead of falling back to the rigid last-12s cut.
        guard bestScore >= 0.40, let bar = bestBar else { return nil }
        print("[Engine] Adaptive energy seam: bar " + String(format: "%.2f", bar) +
              "s — RMS/slope match " + String(format: "%.3f", bestScore))
        return bar
    }

    /// Max (mean) outgoing vocal activity over the crossfade window starting at
    /// `time` — higher means the candidate starts deep inside a vocal line.
    private func vocalCost(at time: Double, windowSeconds: Double,
                           activity: [Float], duration: Double) -> Double {
        guard !activity.isEmpty, duration > 0, windowSeconds > 0 else { return 0 }
        let startIdx = max(0, min(activity.count - 1,
                                  Int(time / duration * Double(activity.count))))
        let rawEnd = Int((time + windowSeconds) / duration * Double(activity.count))
        let endIdx = min(activity.count, max(startIdx + 1, rawEnd))
        let slice = activity[startIdx..<endIdx]
        guard !slice.isEmpty else { return Double(activity[startIdx]) }
        return Double(slice.reduce(0, +) / Float(slice.count))
    }

    // MARK: - Vocal Preservation

    private func clampVolume(_ volume: Float) -> Float {
        min(2.0, max(0, volume))
    }

    private func resetEQ(_ eq: AVAudioUnitEQ) {
        // Band 0: High-Pass (Bass Swap)
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = 20.0
        eq.bands[0].bypass = true

        // Band 1: Parametric Mid (Dynamic Vocal Ducking)
        if eq.bands.count > 1 {
            eq.bands[1].filterType = .parametric
            eq.bands[1].frequency = config.vocalDuckFreqHz
            eq.bands[1].bandwidth = 1.2
            eq.bands[1].gain = 0
            eq.bands[1].bypass = true
        }

        // Band 2: Low-Pass (Warm Roll-off)
        if eq.bands.count > 2 {
            eq.bands[2].filterType = .lowPass
            eq.bands[2].frequency = config.eqLowPassStartHz
            eq.bands[2].bypass = true
        }
    }

    private func resetReverb(_ reverb: AVAudioUnitReverb) {
        reverb.wetDryMix = 0
        reverb.bypass = true
    }

    /// Samples a track's vocal activity (0.0–1.0) at a given timestamp in seconds.
    private static func sampleVocalActivity(_ analysis: TrackAnalysis?, at time: Double) -> Float {
        guard let analysis, !analysis.vocalActivity.isEmpty, analysis.duration > 0 else { return 0 }
        let ratio = max(0.0, min(1.0, time / analysis.duration))
        let idx = min(analysis.vocalActivity.count - 1, Int(ratio * Double(analysis.vocalActivity.count)))
        return analysis.vocalActivity[idx]
    }

    // MARK: - Hall Reverb (Motions tab only)

    func setHallReverb(_ enabled: Bool) {
        motionReverb = enabled
        beginReverbRamp(motionReverb ? 55 : 0)
    }

    private func beginReverbRamp(_ target: Float) {
        reverbRampTimer?.invalidate()
        reverbRampTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let diff = target - self.hallReverb.wetDryMix
            if abs(diff) > 0.2 {
                self.hallReverb.wetDryMix += diff * 0.25
            } else {
                self.hallReverb.wetDryMix = target
                self.reverbRampTimer?.invalidate()
                self.reverbRampTimer = nil
            }
        }
        reverbRampTimer?.tolerance = 0.005
    }

    // MARK: - Surround Staging (EQ restage + stereo width, inline)

    func setSurroundMode(_ mode: SurroundMode) {
        surroundMode = mode
        beginSurroundRamp()
    }

    /// Width factor for each surround mode. 1.0 = original stereo, >1 = wider.
    /// Controls the StereoWidthEffect AUAudioUnit parameter directly — no
    /// player swapping, no silent gaps.
    private func widthValue(for mode: SurroundMode) -> Float {
        switch mode {
        case .off: return 1.0
        case .ampliado: return 2.0
        case .teatro: return 1.5
        }
    }

    private func beginSurroundRamp() {
        let configs: [(type: AVAudioUnitEQFilterType, freq: Float)] = [
            (.lowShelf, 60),
            (.parametric, 400),
            (.parametric, 2500),
            (.highShelf, 10000),
        ]

        let targets: [Float]
        let widthTarget = widthValue(for: surroundMode)
        switch surroundMode {
        case .off:
            targets = [0, 0, 0, 0]
        case .ampliado:
            targets = [-2.5, -1.0, -2.0, 6.0]
        case .teatro:
            targets = [6.0, 2.0, -3.0, -1.5]
        }

        for (i, band) in surroundEq.bands.enumerated() {
            band.bypass = false
            band.bandwidth = 0.6
            band.filterType = configs[i].type
            band.frequency = configs[i].freq
        }
        surroundEq.globalGain = 0

        // Gain compensation — the surround EQ stacks on top of profileEq.
        // Half compensation — reduce profileEq.globalGain by half the max
        // surround boost. Provides clipping headroom without killing volume.
        let maxSurroundBoost = targets.max() ?? 0
        profileEq.globalGain = -max(0, maxSurroundBoost) / 2

        fxRampTimer?.invalidate()
        fxRampTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            var done = true

            // Ramp EQ bands.
            for (i, band) in self.surroundEq.bands.enumerated() {
                let target = i < targets.count ? targets[i] : 0
                let diff = target - band.gain
                if abs(diff) > 0.01 { done = false }
                band.gain += diff * 0.25
            }

            // Ramp stereo width — writes directly to the static processor.
            let cur = self.currentWidthValue
            let diff = widthTarget - cur
            if abs(diff) > 0.003 { done = false }
            let next = cur + diff * 0.25
            self.currentWidthValue = next
            StereoWidthEffect.currentWidth = next

            if done {
                self.fxRampTimer?.invalidate()
                self.fxRampTimer = nil
            }
        }
        fxRampTimer?.tolerance = 0.005
    }

    #if DEBUG
    /// Returns the current surround effect state (for tests / debugging).
    var debugSurroundReverbMix: Float {
        motionReverb ? 55 : 0
    }
    #endif

    // MARK: - Gain Compensation

    /// Max positive gain (dB) the surround EQ will apply for the current mode.
    /// Used to reduce profileEq.globalGain so both EQs don't stack and clip.
    /// Returns half the actual boost for more natural volume.
    private func maxSurroundBoostForCurrentMode() -> Float {
        let full: Float
        switch surroundMode {
        case .off: full = 0
        case .ampliado: full = 6.0
        case .teatro: full = 6.0
        }
        return full / 2
    }

    // MARK: - Solo Band

    func setSoloBand(_ index: Int?) {
        soloBand = index
    }

    // MARK: - Audio Profile (EQ only)

    private var profileRampTimer: Timer?
    private var profileTargets: [Float] = []

    func applyProfileEQ(_ preset: OrquestaPreset) {
        let bands = preset.eqBands

        // Fixed geometry per band — only gain animates, so a preset swap never
        // re-engages a filter (that transient is what pops the gain).
        for (i, band) in profileEq.bands.enumerated() {
            band.filterType = .parametric
            band.bandwidth = 0.5
            if i < bands.count {
                band.frequency = bands[i].freq
                band.bypass = false
            } else {
                band.bypass = true
            }
        }
        // Solo masking — keep only the soloed band audible.
        if let solo = soloBand {
            for (i, band) in profileEq.bands.enumerated() {
                band.bypass = i != solo
            }
        }
        // Gain compensation — offset the surround EQ boost so combined
        // output doesn't clip when both EQs are active.
        let surroundBoost = maxSurroundBoostForCurrentMode()
        profileEq.globalGain = -max(0, surroundBoost)

        profileTargets = bands.map { $0.gain }
        startProfileRamp()
    }

    /// Glide each parametric band gain to its target — exponential approach,
    /// ~0.15s settle. Tight callers (live drag) just retarget mid-flight.
    private func startProfileRamp() {
        profileRampTimer?.invalidate()
        profileRampTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            var done = true
            for (i, band) in self.profileEq.bands.enumerated() where !band.bypass {
                let target = i < self.profileTargets.count ? self.profileTargets[i] : 0
                let diff = target - band.gain
                if abs(diff) > 0.01 { done = false }
                band.gain += diff * 0.22
            }
            if done {
                self.profileRampTimer?.invalidate()
                self.profileRampTimer = nil
            }
        }
        profileRampTimer?.tolerance = 0.005
    }

    /// Samples a track's vocal activity level (0–1) at a given time.
    /// Computes crossfade curve exponent from energy ratio and slope direction at the transition.
    /// When outgoing energy >> incoming energy, exponent > 1 delays incoming blend
    /// (outgoing stays full longer, incoming rises gradually). When incoming energy >>
    /// outgoing, exponent < 1 blends incoming sooner. Slope direction adjusts the exponent:
    /// both falling (calm→calm) = smoother blend, outgoing falling + incoming rising (build) =
    /// incoming rises faster, outgoing rising + incoming falling (drop) = outgoing stays dominant.
    private func computeEnergyCurveExponent(
        outgoingAnalysis: TrackAnalysis?,
        incomingAnalysis: TrackAnalysis?,
        outgoingTime: Double,
        outgoingDuration: Double,
        incomingTime: Double,
        incomingDuration: Double
    ) -> Double {
        let outEnergy = outgoingAnalysis?.energyProfile ?? []
        let inEnergy = incomingAnalysis?.energyProfile ?? []
        guard !outEnergy.isEmpty, !inEnergy.isEmpty, outgoingDuration > 0, incomingDuration > 0 else {
            return 1.0
        }
        let outIdx = max(0, min(outEnergy.count - 1, Int(outgoingTime / outgoingDuration * Double(outEnergy.count))))
        let inIdx = max(0, min(inEnergy.count - 1, Int(incomingTime / incomingDuration * Double(inEnergy.count))))
        // Wider averaging window (5 samples) for stability
        let halfWindow = 2
        let outSlice = max(0, outIdx - halfWindow)...min(outEnergy.count - 1, outIdx + halfWindow)
        let inSlice = max(0, inIdx - halfWindow)...min(inEnergy.count - 1, inIdx + halfWindow)
        let outAvg = outSlice.map { Double(outEnergy[$0]) }.reduce(0, +) / Double(outSlice.count)
        let inAvg = inSlice.map { Double(inEnergy[$0]) }.reduce(0, +) / Double(inSlice.count)
        let ratio = inAvg / max(outAvg, 0.001)

        // Base exponent from ratio: ratio=1 → 1.0, ratio=0.25 → 0.4, ratio=4 → 2.5
        var exponent = max(0.4, min(2.5, ratio))

        // Slope adjustment: consider energy direction at transition point
        let outSlope = energyDirectionAt(outEnergy, index: outIdx)
        let inSlope = energyDirectionAt(inEnergy, index: inIdx)

        // Both falling (calm→calm): smooth blend, nudge exponent toward 1.0
        if outSlope < -0.01 && inSlope < -0.01 {
            exponent = exponent * 0.85 + 0.15 // pull toward 1.0
        }
        // Outgoing falling, incoming rising (build): incoming rises faster
        else if outSlope < -0.01 && inSlope > 0.01 {
            exponent = max(0.35, exponent * 0.8)
        }
        // Outgoing rising, incoming falling (drop): outgoing stays dominant
        else if outSlope > 0.01 && inSlope < -0.01 {
            exponent = min(3.0, exponent * 1.2)
        }

        return max(0.35, min(3.0, exponent))
    }

    /// Energy direction at a given index: positive = rising, negative = falling.
    private func energyDirectionAt(_ profile: [Float], index: Int) -> Double {
        guard profile.count >= 3 else { return 0 }
        let window = 3
        let lo = max(0, index - window)
        let hi = min(profile.count - 1, index + window)
        guard hi > lo else { return 0 }
        let firstHalf = profile[lo..<(lo + (hi - lo) / 2 + 1)]
        let secondHalf = profile[(lo + (hi - lo) / 2)...hi]
        let firstAvg = Double(firstHalf.reduce(0, +)) / Double(firstHalf.count)
        let secondAvg = Double(secondHalf.reduce(0, +)) / Double(secondHalf.count)
        return secondAvg - firstAvg
    }

    // MARK: - Mood Preservation

    struct MoodPreservationParams {
        /// Volume curve exponent adjustment: energetic tracks get steeper curves.
        let curveExponentBias: Double
        /// EQ low-pass end Hz: energetic = less filtering, calm = more.
        let eqLowPassEndHz: Float
        /// Duration multiplier: mood-matched = longer, clash = shorter.
        let durationMultiplier: Double
        /// Whether both tracks share a similar mood (for logging).
        let moodsMatch: Bool
        /// True when both tracks are energetic (happy/angry) — the energy-driven
        /// duration from computeCrossfadeDuration already decides the blend.
        let bothEnergetic: Bool
    }

    /// Computes mood-aware crossfade parameters.
    /// Energetic tracks: steeper curve, less EQ, shorter overlap.
    /// Calm tracks: gentler curve, more EQ, longer overlap.
    /// Mood-matched: extended crossfade for seamless blend.
    private func computeMoodPreservationParams(
        outgoingAnalysis: TrackAnalysis?,
        incomingAnalysis: TrackAnalysis?
    ) -> MoodPreservationParams {
        let outMood = MusicMood.from(analysis: outgoingAnalysis)
        let inMood = MusicMood.from(analysis: incomingAnalysis)

        // Mood energy classification
        let outEnergetic = outMood == .energeticHappy || outMood == .energeticAngry
        let inEnergetic = inMood == .energeticHappy || inMood == .energeticAngry

        // Similarity: same mood = 1.0, same energy class = 0.7, different = 0.3
        let moodsMatch = outMood == inMood
        let sameEnergyClass = outEnergetic == inEnergetic
        let similarity: Double
        if moodsMatch {
            similarity = 1.0
        } else if sameEnergyClass {
            similarity = 0.7
        } else {
            similarity = 0.3
        }

        // Curve exponent: energetic = steeper (0.8–1.2), calm = gentler (1.0–1.5)
        let curveBias: Double
        if outEnergetic && inEnergetic {
            curveBias = 0.9   // fast in, fast out — keep energy up
        } else if !outEnergetic && !inEnergetic {
            curveBias = 1.3   // slow in, slow out — preserve calm
        } else {
            curveBias = 1.1   // mixed — balanced
        }

        // EQ: calm tracks benefit from more filtering, energetic need clarity
        let eqEndHz: Float
        if outEnergetic && inEnergetic {
            eqEndHz = 5000.0   // less filtering — preserve brightness
        } else if !outEnergetic && !inEnergetic {
            eqEndHz = 2000.0   // more filtering — smooth warm blend
        } else {
            eqEndHz = 3000.0   // default
        }

        // Duration: mood-matched gets longer, clash gets shorter
        let durationMult: Double
        if moodsMatch {
            durationMult = 1.2   // 20% longer for seamless mood preservation
        } else if sameEnergyClass {
            durationMult = 1.0   // normal
        } else {
            durationMult = 0.8   // shorter — minimize mood clash
        }

        print("[Mood] out=\(outMood.rawValue), in=\(inMood.rawValue), match=\(moodsMatch), curveBias=\(String(format: "%.2f", curveBias)), eqEnd=\(Int(eqEndHz))Hz, durMult=\(String(format: "%.2f", durationMult))")

        return MoodPreservationParams(
            curveExponentBias: curveBias,
            eqLowPassEndHz: eqEndHz,
            durationMultiplier: durationMult,
            moodsMatch: moodsMatch,
            bothEnergetic: outEnergetic && inEnergetic
        )
    }

    // MARK: - Private Helpers

    private func readEntireFile(_ file: AVAudioFile) throws -> AVAudioPCMBuffer {
        let engineFormat = config.processingFormat
        let fileFormat = file.processingFormat

        // Read into engine processing format so scheduled buffers match the
        // connection format. When the file's native rate differs from the
        // engine rate (e.g. 48 kHz vs 44.1 kHz), scheduleBuffer may not
        // resample correctly, causing a pitch shift that persists for the
        // entire scheduled buffer duration.
        if fileFormat.sampleRate == engineFormat.sampleRate
            && fileFormat.channelCount == engineFormat.channelCount {
            // Formats match — fast path, no conversion needed.
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount) else {
                throw NSError(domain: "MixAudioEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate buffer"])
            }
            try file.read(into: buffer)
            return buffer
        }

        // Read in file's native format, then convert to engine format.
        print("[Engine] Format mismatch: file=\(String(format: "%.0f", fileFormat.sampleRate))Hz/\(fileFormat.channelCount)ch, engine=\(String(format: "%.0f", engineFormat.sampleRate))Hz/\(engineFormat.channelCount)ch — converting")
        let frameCount = AVAudioFrameCount(file.length)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "MixAudioEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate source buffer"])
        }
        try file.read(into: srcBuffer)

        guard let converter = AVAudioConverter(from: fileFormat, to: engineFormat) else {
            print("[Engine] WARNING: Could not create format converter, using file format buffer")
            return srcBuffer
        }

        let dstFrameCount = AVAudioFrameCount(Double(frameCount) * engineFormat.sampleRate / fileFormat.sampleRate)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: dstFrameCount) else {
            print("[Engine] WARNING: Could not allocate destination buffer, using file format buffer")
            return srcBuffer
        }

        var conversionError: NSError?
        var isDone = false
        converter.convert(to: dstBuffer, error: &conversionError) { _, outStatus in
            if isDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            isDone = true
            outStatus.pointee = .haveData
            return srcBuffer
        }

        if let error = conversionError {
            print("[Engine] Format conversion failed: \(error), using file format buffer")
            return srcBuffer
        }

        print("[Engine] Converted buffer: \(dstBuffer.frameLength) frames @ \(String(format: "%.0f", engineFormat.sampleRate))Hz")
        return dstBuffer
    }

    /// Prepends silence to align the incoming track's first beat with the outgoing
    /// track's beat phase. The silence length is scaled by the playback rate so it
    /// lasts the intended real-world time.
    /// Applies a 2ms linear fade-in so the buffer starts at zero. Eliminates
    /// clicks from phase-discontinuous splice points when the incoming track's
    /// cue position lands on a non-zero sample.
    private func applyMicroFadeIn(_ buffer: AVAudioPCMBuffer) {
        let fadeFrames = max(1, Int(0.002 * buffer.format.sampleRate))
        let chs = Int(buffer.format.channelCount)
        let limit = min(fadeFrames, Int(buffer.frameLength))
        for f in 0..<limit {
            let gain = Float(f) / Float(limit)
            for ch in 0..<chs {
                guard let ptr = buffer.floatChannelData?[ch] else { continue }
                ptr[f] *= gain
            }
        }
    }

    private func padWithSilence(_ buffer: AVAudioPCMBuffer, sampleRate: Double, beatPhaseOffset: Double, rate: Float) -> AVAudioPCMBuffer {
        guard beatPhaseOffset > 0.01 else { return buffer }
        let silenceFrames = AVAudioFramePosition(beatPhaseOffset * sampleRate * Double(rate))
        guard silenceFrames > 0 else { return buffer }
        if let silence = AudioHelpers.createSilence(frames: silenceFrames, format: buffer.format),
           let mixed = AudioHelpers.concatenateBuffers([silence, buffer]) {
            return mixed
        }
        return buffer
    }

    /// Smoothly ramps a timePitch node's rate using a smoothstep curve.
    private func startTempoRamp(node: AVAudioUnitTimePitch, from startRate: Float, to targetRate: Float, duration: TimeInterval, completion: (() -> Void)? = nil) {
        tempoRampTimer?.invalidate()
        tempoRampGeneration += 1
        let generation = tempoRampGeneration
        guard duration > 0, abs(targetRate - startRate) > 0.001 else {
            node.rate = targetRate
            completion?()
            return
        }
        let interval: TimeInterval = 0.05
        let steps = max(1, Int(duration / interval))
        var step = 0
        tempoRampTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self, self.tempoRampGeneration == generation else {
                timer.invalidate()
                return
            }
            step += 1
            let t = min(1.0, Double(step) / Double(steps))
            let s = t * t * (3.0 - 2.0 * t)  // smoothstep
            node.rate = startRate + Float(s) * (targetRate - startRate)
            if step >= steps {
                timer.invalidate()
                self.tempoRampTimer = nil
                node.rate = targetRate
                completion?()
            }
        }
    }

    private func completeCrossfade(incomingDuration: TimeInterval) {
        print("[Engine] Automix done — incomingDuration=\(String(format: "%.2f", incomingDuration))s")

        // ── Diagnostic: snapshot all audio node states before swap ──────
        let outPlayerID = currentPlayer === playerA ? "A" : "B"
        let inPlayerID = otherPlayer === playerA ? "A" : "B"
        print("[Engine] Pre-swap: current=\(outPlayerID) vol=\(String(format: "%.3f", currentPlayer.volume)), other=\(inPlayerID) vol=\(String(format: "%.3f", otherPlayer.volume))")
        print("[Engine] Pre-swap: currentTimePitch rate=\(String(format: "%.4f", currentTimePitch.rate)) bypass=\(currentTimePitch.bypass), otherTimePitch rate=\(String(format: "%.4f", otherTimePitch.rate)) bypass=\(otherTimePitch.bypass)")
        print("[Engine] Pre-swap: eqA lpf=\(String(format: "%.0f", eqA.bands[2].frequency))Hz hpf=\(String(format: "%.0f", eqA.bands[0].frequency))Hz rev=\(String(format: "%.0f", reverbA.wetDryMix))%, eqB lpf=\(String(format: "%.0f", eqB.bands[2].frequency))Hz hpf=\(String(format: "%.0f", eqB.bands[0].frequency))Hz rev=\(String(format: "%.0f", reverbB.wetDryMix))%")
        print("[Engine] Pre-swap: currentRate=\(String(format: "%.4f", currentRate)), isCrossfading=\(isCrossfading), isPlaying=\(isPlaying)")
        print("[Engine] Pre-swap: actualIncomingDuration=\(String(format: "%.2f", actualIncomingDuration)), currentDuration=\(String(format: "%.2f", currentDuration)), seekOffset=\(String(format: "%.2f", seekOffset))")

        if let url = pendingIncomingURL {
            currentURL = url
            pendingIncomingURL = nil
        }

        currentPlayer.stop()
        currentPlayer.reset()

        let temp = currentPlayer
        currentPlayer = otherPlayer
        otherPlayer = temp
        let tempPitch = currentTimePitch
        currentTimePitch = otherTimePitch
        otherTimePitch = tempPitch

        resetEQ(eqA)
        resetEQ(eqB)
        resetReverb(reverbA)
        resetReverb(reverbB)

        currentPlayer.volume = lastIncomingVolume
        otherPlayer.volume = 0

        // Keep engine clock in FULL-song coordinates (matching TrackAnalysis,
        // barTimestamps, lyrics, and seek) even when incoming intro was trimmed!
        let fullDur = max(fullIncomingDuration, incomingCueOffset + actualIncomingDuration)
        currentDuration = fullDur
        isCrossfading = false
        isPlaying = true

        let elapsed = -(crossfadeStartTime ?? Date()).timeIntervalSinceNow
        // Track-seconds of the trimmed incoming buffer consumed: pad plays first
        // (real seconds), then audio at the blend rate.
        let consumedTrack = max(0, elapsed - blendPadDelay) * Double(blendTempoRate)
        let remaining = max(0.1, actualIncomingDuration - consumedTrack)
        // True playback timestamp in full-song coordinates = cue offset + consumed!
        seekOffset = min(fullDur, incomingCueOffset + consumedTrack)
        trackStartTime = Date()

        if abs(blendTempoRate - 1.0) < 0.001 {
            currentRate = 1.0
            remainingAtStart = remaining
            currentTimePitch.rate = 1.0
            currentTimePitch.bypass = true
            otherTimePitch.rate = 1.0
            otherTimePitch.bypass = true
        } else {
            // Glide back to natural tempo smoothly — duration scales with tempo delta
            // (4s for tiny tweaks up to 8s for wider stretches) so recovery is imperceptible.
            let delta = Double(abs(blendTempoRate - 1.0))
            let glideDuration = 4.0 + min(4.0, delta * 35.0)
            currentRate = blendTempoRate
            remainingAtStart = remaining
            currentTimePitch.bypass = false
            currentTimePitch.rate = blendTempoRate
            otherTimePitch.rate = 1.0
            otherTimePitch.bypass = true
            startTempoRamp(node: currentTimePitch, from: blendTempoRate, to: 1.0, duration: glideDuration) { [weak self] in
                self?.currentTimePitch.bypass = true
                self?.currentRate = 1.0
            }
        }

        // Arm default phrase-aligned fallback BEFORE notifying ViewModel so that
        // `onCrossfadeCompleted -> scheduleCrossfadeWarmup -> rescheduleForNextTrack`
        // ALWAYS wins with the true next-track analysis instead of getting overwritten!
        let maxFade = max(config.crossfadeDuration * 1.2, 12.0)
        beatAlignedCrossfadeTime = computeBeatAlignedCrossfadeTime(
            duration: fullDur,
            rate: 1.0,
            barTimestamps: currentBarTimestamps,
            crossfadeDuration: maxFade,
            outgoingAnalysis: currentTrackAnalysis,
            incomingAnalysis: nil
        )
        crossfadeTriggerDelay = max(0.1, remainingAtStart - beatAlignedCrossfadeTime)
        scheduleTrackEndTimer(delay: crossfadeTriggerDelay)

        onCrossfadeCompleted?()

        // ── Diagnostic: verify state after swap ────────────────────────
        let newCurrentPlayerID = currentPlayer === playerA ? "A" : "B"
        let newOtherPlayerID = otherPlayer === playerA ? "A" : "B"
        print("[Engine] Post-swap: currentPlayer=\(newCurrentPlayerID) (was \(inPlayerID)), otherPlayer=\(newOtherPlayerID) (was \(outPlayerID))")
        print("[Engine] Post-swap: fullDur=\(String(format: "%.1f", fullDur))s, pos=\(String(format: "%.1f", seekOffset))s (cue=\(String(format: "%.1f", incomingCueOffset))s), remaining=\(String(format: "%.1f", remaining))s, nextTriggerIn=\(String(format: "%.1f", crossfadeTriggerDelay))s")
    }

}
