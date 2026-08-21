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
    private let eqA = AVAudioUnitEQ(numberOfBands: 1)
    private let eqB = AVAudioUnitEQ(numberOfBands: 1)
    private let hallReverb = AVAudioUnitReverb()
    private let profileEq: AVAudioUnitEQ
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

    private var currentURL: URL?
    private var currentDuration: TimeInterval = 0

    private let config: AudioConfig

    var onTrackEnd: TrackEndHandler?

    private(set) var isPlaying = false
    private(set) var isCrossfading = false

    private var crossfadeTimer: Timer?
    private var trackEndTimer: Timer?
    private var preCrossfadeTimer: Timer?
    private var preCrossfadeRampTimer: Timer?
    private var preCrossfadeRampStartTime: Date?
    private var trackStartTime: Date?

    private var remainingAtStart: TimeInterval = 0
    private var seekOffset: TimeInterval = 0
    private var currentCrossfadeDuration: TimeInterval = 0
    private var currentRate: Float = 1.0
    private var incomingTargetRate: Float = 1.0
    private var currentBarTimestamps: [Double] = []
    private var beatAlignedCrossfadeTime: TimeInterval = 0
    private var incomingCueOffset: Double = 0
    private var currentTrackAnalysis: TrackAnalysis?
    private var crossfadeStartTime: Date?

    private var configurationObserver: NSObjectProtocol?
    private var actualIncomingDuration: TimeInterval = 0  // post-intro-skip, pre-beat-padding
    private var pendingIncomingURL: URL?

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
        preCrossfadeRampTimer?.invalidate()
        tempoRampTimer?.invalidate()
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
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(timePitchA)
        engine.attach(timePitchB)
        engine.attach(eqA)
        engine.attach(eqB)
        engine.attach(profileEq)
        engine.attach(hallReverb)
        engine.attach(peakLimiter)
        engine.attach(mixerNode)

        let format = config.processingFormat
        engine.connect(playerA, to: timePitchA, format: format)
        engine.connect(playerB, to: timePitchB, format: format)
        engine.connect(timePitchA, to: eqA, format: format)
        engine.connect(timePitchB, to: eqB, format: format)
        engine.connect(eqA, to: mixerNode, format: format)
        engine.connect(eqB, to: mixerNode, format: format)

        mixerNode.volume = 1.0
        engine.connect(mixerNode, to: profileEq, format: format)
        profileEq.globalGain = 0
        engine.connect(profileEq, to: hallReverb, format: format)
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

        hallReverb.wetDryMix = 0
    }

    // MARK: - Playback Controls

    func loadTrack(url: URL, rate: Float = 1.0, barTimestamps: [Double] = [], analysis: TrackAnalysis? = nil) throws {
        cancelTrackEndTimer()
        stop()

        // Ensure the audio engine is running — may have been stopped by
        // StreamAudioEngine or a device configuration change while idle.
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

        // Floor: crossfade must not start before the outgoing vocal ends.
        // If the bar-aligned trigger fires too early, push it later so it
        // overlaps the vocal's resolving tail instead of cutting it short.
        let vocalEndFloor: Double
        if let vocalEnds = analysis?.vocalOffsetTimestamps, !vocalEnds.isEmpty {
            let lastVocalEnd = vocalEnds.last!
            // Delay = seconds from now until vocalEnd. Crossfade finishes at track end.
            vocalEndFloor = max(0, remainingAtStart - lastVocalEnd)
        } else {
            vocalEndFloor = 0
        }
        let finalDelay = max(0.1, triggerOffset, vocalEndFloor)

        print("[Engine] Playing: \(url.lastPathComponent) — \(String(format: "%.1f", duration))s @ rate \(String(format: "%.3f", rate)), crossfade in \(String(format: "%.2f", finalDelay))s (bar=\(String(format: "%.2f", triggerOffset)), vocalEnd=\(String(format: "%.2f", vocalEndFloor)))")

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
        resetEQ(eqA)
        resetEQ(eqB)
        isPlaying = false
        isCrossfading = false
        currentURL = nil
        currentDuration = 0
        seekOffset = 0
        pendingIncomingURL = nil
        currentRate = 1.0
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
            let maxFade = max(config.crossfadeDuration * 1.5, 12.0)
            beatAlignedCrossfadeTime = computeBeatAlignedCrossfadeTime(
                duration: seekDuration,
                rate: Double(currentRate),
                barTimestamps: currentBarTimestamps,
                crossfadeDuration: maxFade,
                outgoingAnalysis: currentTrackAnalysis,
                incomingAnalysis: nil
            )
            scheduleTrackEndTimer(delay: max(0.1, remainingAtStart - beatAlignedCrossfadeTime))
        } catch {
            print("[Engine] Seek failed: \(error)")
        }
    }

    // MARK: - Automix Crossfade

    /// Full automix transition with beat phase alignment, vocal preservation,
    /// gradual tempo sync, and soft limiting.
    /// Returns `false` when a crossfade is already in progress (caller should
    /// not advance the queue).
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
        otherTimePitch.bypass = true
        otherTimePitch.rate = 1.0

        do {
            pendingIncomingURL = incomingURL
            let incomingFile = try AudioHelpers.readAudio(url: incomingURL)
            let incomingDuration = incomingFile.duration
            var crossfadeDuration = params.duration
            actualIncomingDuration = incomingDuration    // may shrink if intro skipped

            // ── 0. MOOD PRESERVATION ──────────────────────────────────────
            // Compute mood-based adaptations: curve shape, EQ intensity, duration.
            let moodParams = computeMoodPreservationParams(
                outgoingAnalysis: outgoingAnalysis,
                incomingAnalysis: incomingAnalysis
            )
            crossfadeDuration *= moodParams.durationMultiplier
            self.moodEqLowPassEndHz = moodParams.eqLowPassEndHz

            // ── 1. BPM SYNC — only during crossfade window ────────────
            // Compute rate ratio so incoming beats align with outgoing during the blend.
            // After crossfade, smoothly ramp back to 1.0 so the rest of the song
            // plays at its natural tempo.
            let outBPM = outgoingAnalysis?.bpm ?? 0
            let inBPM = incomingAnalysis?.bpm ?? 0
            incomingTargetRate = 1.0

            // ── 2. BEAT PHASE ALIGNMENT ──────────────────────────────────
            // Align incoming's first beat with outgoing's bar boundary at crossfade point.
            // Compute delay = outgoingNextBar - outgoingCurrentTime.
            // Prepend that many seconds of silence to incoming buffer so its downbeat
            // lands exactly on the outgoing's bar line.
            let incomingFirstBeat = incomingAnalysis?.beatTimestamps.first ?? 0
            incomingCueOffset = incomingFirstBeat
            currentTrackAnalysis = incomingAnalysis

            currentCrossfadeDuration = crossfadeDuration

            // Store incoming track metadata for future beat-aligned scheduling
            currentBarTimestamps = incomingAnalysis?.barTimestamps ?? []

            otherPlayer.stop()
            otherPlayer.reset()
            otherPlayer.volume = 0

            // Store loudness-matching gains so track-to-track volume stays consistent.
            self.outgoingGain = Float(params.outgoingGainCompensation)
            self.incomingGain = Float(params.incomingGainCompensation)



            // Compute real beat phase delay: outgoing bar boundary - current time.
            let outgoingNow = self.currentTime
            var beatPhaseDelay: Double = 0
            if let outBars = outgoingAnalysis?.barTimestamps, !outBars.isEmpty {
                // Find next bar boundary after current position
                var nextBar: Double?
                for barTime in outBars {
                    if barTime > outgoingNow + 0.05 {
                        nextBar = barTime
                        break
                    }
                }
                // If no future bar, extrapolate from last bar + bar interval
                if nextBar == nil, let lastBar = outBars.last, let outBPM = outgoingAnalysis?.bpm, outBPM > 0 {
                    let barInterval = 240.0 / outBPM
                    nextBar = lastBar + barInterval
                }
                if let nextBar {
                    beatPhaseDelay = max(0, nextBar - outgoingNow)
                }
            }
            print("[Engine] Beat phase delay: \(String(format: "%.3f", beatPhaseDelay))s (outgoingNow=\(String(format: "%.2f", outgoingNow)), incomingFirstBeat=\(String(format: "%.3f", incomingFirstBeat)))")

            // ── 3b. VOCAL CONNECTION POINT / INTRO SKIP ────────────────
            // Use engine processing format sample rate for frame calculations,
            // since readEntireFile now converts buffers to engine format.
            let sampleRate = config.processingFormat.sampleRate
            var bufferToSchedule: AVAudioPCMBuffer?

            if params.skipIntro && params.vocalConnectionPoint > 0 {
                let skipTime = params.vocalConnectionPoint
                actualIncomingDuration = max(1.0, incomingDuration - skipTime)  // trimmed buffer length
                print("[Engine] Skipping \(String(format: "%.1f", skipTime))s intro → starting at vocal onset")

                let fileBuffer = try readEntireFile(incomingFile)
                let skipFrames = AVAudioFramePosition(skipTime * sampleRate)
                if skipFrames > 0, skipFrames < AVAudioFramePosition(fileBuffer.frameLength) {
                    let remainingFrames = fileBuffer.frameLength - AVAudioFrameCount(skipFrames)
                    if let trimmed = AudioHelpers.extractBuffer(fileBuffer, from: skipFrames, frameCount: remainingFrames) {
                        // Prepend silence for beat phase alignment
                        bufferToSchedule = self.padWithSilence(trimmed, sampleRate: sampleRate, beatPhaseOffset: beatPhaseDelay, rate: incomingTargetRate)
                    }
                }
            } else {
                let fileBuffer = try readEntireFile(incomingFile)
                // Cue incoming to its first beat, then prepend silence to align
                // that beat with outgoing's bar boundary.
                if incomingFirstBeat > 0.01 {
                    let cueFrames = AVAudioFramePosition(incomingFirstBeat * sampleRate)
                    if cueFrames > 0, cueFrames < AVAudioFramePosition(fileBuffer.frameLength) {
                        let remaining = fileBuffer.frameLength - AVAudioFrameCount(cueFrames)
                        if let cued = AudioHelpers.extractBuffer(fileBuffer, from: cueFrames, frameCount: remaining) {
                            actualIncomingDuration = max(1.0, incomingDuration - incomingFirstBeat)
                            // The cue trimmed the buffer so first beat is at frame 0.
                            // Now prepend silence so that frame 0 lands at outgoing's bar boundary.
                            bufferToSchedule = self.padWithSilence(cued, sampleRate: sampleRate, beatPhaseOffset: beatPhaseDelay, rate: incomingTargetRate)
                        } else {
                            bufferToSchedule = self.padWithSilence(fileBuffer, sampleRate: sampleRate, beatPhaseOffset: beatPhaseDelay, rate: incomingTargetRate)
                        }
                    } else {
                        bufferToSchedule = self.padWithSilence(fileBuffer, sampleRate: sampleRate, beatPhaseOffset: beatPhaseDelay, rate: incomingTargetRate)
                    }
                } else {
                    bufferToSchedule = self.padWithSilence(fileBuffer, sampleRate: sampleRate, beatPhaseOffset: beatPhaseDelay, rate: incomingTargetRate)
                }
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
                otherPlayer.scheduleFile(incomingFile, at: nil)
            }

            otherPlayer.play()
            crossfadeStartTime = Date()
            // Outgoing track position at crossfade start (for correct vocal sampling).
            // Track plays at 1.0x (timePitch bypassed) so real seconds = track seconds.
            let outElapsed = -(self.trackStartTime ?? Date()).timeIntervalSinceNow
            self.outgoingCrossfadeStartPos = max(0, outElapsed)

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

            // ── 4. CROSSFADE VOLUME ENVELOPE ──────────────────────
            isCrossfading = true
            let rampInterval = 0.02
            let crossfadeSteps = Int(crossfadeDuration / rampInterval)
            var currentStep = 0
            crossfadeTimer?.invalidate()
            crossfadeTimer = Timer.scheduledTimer(withTimeInterval: rampInterval, repeats: true) { [weak self] timer in
                guard let self = self, self.isCrossfading else {
                    timer.invalidate()
                    return
                }

                currentStep += 1

                // ── Energy-equalized crossfade ─────────────────────────
                let progress = min(1.0, Double(currentStep) / Double(max(1, crossfadeSteps)))
                // Smoothstep S-curve on raw progress: gentle start, gentle finish, fast middle.
                // Prevents incoming from jumping in too early.
                let s = progress * progress * (3.0 - 2.0 * progress)
                let warpedProgress: Double
                if self.curveExponent != 1.0 {
                    warpedProgress = pow(s, self.curveExponent)
                } else {
                    warpedProgress = s
                }
                let outAmplitude = Float(1.0 - warpedProgress)
                let inAmplitude = Float(warpedProgress)
                let outVol = outAmplitude * self.outgoingGain
                let inVol = inAmplitude * self.incomingGain
                self.currentPlayer.volume = self.clampVolume(outVol)
                self.otherPlayer.volume = self.clampVolume(inVol)

                if currentStep >= crossfadeSteps {
                    self.lastIncomingVolume = self.clampVolume(inVol)
                }

                // ── Low-pass filter on outgoing ──────────────────────────────
                // Smoothly rolls off highs on the outgoing track as it fades.
                // Keeps midrange from clashing with the incoming track.
                // EQ intensity adapts to mood: calm = more filtering, energetic = less.
                // If pre-crossfade ramp already started, continue from its position.
                if self.config.eqFadeEnabled {
                    // Compute starting progress from where pre-crossfade ramp left off
                    let preProgress: Double
                    if let rampStart = self.preCrossfadeRampStartTime {
                        let elapsed = Date().timeIntervalSince(rampStart)
                        preProgress = min(1.0, elapsed / 5.0)  // 5s ramp duration
                    } else {
                        preProgress = 0
                    }
                    let adjustedProgress = min(1.0, preProgress + (1.0 - preProgress) * progress)
                    let eqP = Float(adjustedProgress * adjustedProgress * (3.0 - 2.0 * adjustedProgress))  // smoothstep
                    let lpCut = self.config.eqLowPassStartHz * pow(self.moodEqLowPassEndHz / self.config.eqLowPassStartHz, eqP)
                    // Apply low-pass to outgoing only — incoming stays clean
                    let outEQ = self.currentEQ
                    outEQ.bands[0].filterType = .lowPass
                    outEQ.bands[0].frequency = lpCut
                    outEQ.bands[0].bypass = false
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

    private func restartTrackEndTimer() {
        guard let startTime = trackStartTime, remainingAtStart > 0 else { return }
        let elapsed = -startTime.timeIntervalSinceNow
        let remaining = remainingAtStart - elapsed
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
        preCrossfadeRampTimer?.invalidate()
        preCrossfadeRampTimer = nil
    }

    /// Starts a 5-second low-pass filter ramp on the outgoing player
    /// before the crossfade begins. Smoothly rolls off highs so the
    /// transition feels prepared, not abrupt.
    private func schedulePreCrossfadeEQ(delay: TimeInterval) {
        cancelPreCrossfadeEQ()
        guard delay > 0.5, config.eqFadeEnabled else { return }
        preCrossfadeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self, self.isPlaying, !self.isCrossfading else { return }
            self.preCrossfadeTimer = nil
            self.startPreCrossfadeRamp()
        }
    }

    private func startPreCrossfadeRamp() {
        let rampDuration: TimeInterval = 5.0  // 5 seconds to roll off
        let startHz = config.eqLowPassStartHz  // 20000
        let endHz = self.moodEqLowPassEndHz     // mood-adapted target
        let interval: TimeInterval = 0.1
        let steps = Int(rampDuration / interval)
        var currentStep = 0
        preCrossfadeRampStartTime = Date()

        preCrossfadeRampTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self, self.isPlaying, !self.isCrossfading else {
                timer.invalidate()
                self?.preCrossfadeRampTimer = nil
                return
            }
            currentStep += 1
            let progress = min(1.0, Double(currentStep) / Double(max(1, steps)))
            // Smoothstep for gentle roll-off
            let s = progress * progress * (3.0 - 2.0 * progress)
            let cutHz = startHz * pow(endHz / startHz, Float(s))
            let outEQ = self.currentEQ
            outEQ.bands[0].filterType = .lowPass
            outEQ.bands[0].frequency = cutHz
            outEQ.bands[0].bypass = false

            if currentStep >= steps {
                timer.invalidate()
                self.preCrossfadeRampTimer = nil
                self.preCrossfadeRampStartTime = nil
            }
        }
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
        incomingAnalysis: TrackAnalysis?
    ) -> Double {
        guard !barTimestamps.isEmpty, rate > 0 else {
            return crossfadeDuration
        }

        let adjustedDuration = duration / rate
        let minTriggerTime = crossfadeDuration

        // Get energy profiles for matching
        let outEnergy = outgoingAnalysis?.energyProfile ?? []
        let inEnergy = incomingAnalysis?.energyProfile ?? []

        // Outgoing intro region — avoid triggering during it
        let outIntroEnd = outgoingAnalysis?.introRegion?.end ?? 0

        // BPM alignment — closer BPMs = better beat sync during crossfade
        let outBPM = outgoingAnalysis?.bpm ?? 0
        let inBPM = incomingAnalysis?.bpm ?? 0
        let bpmScore: Double
        if outBPM > 0, inBPM > 0 {
            let bpmDiff = abs(outBPM - inBPM) / max(outBPM, inBPM)
            bpmScore = max(0, 1.0 - bpmDiff * 5.0)
        } else {
            bpmScore = 0.5
        }

        // Find bar boundaries that leave enough time for crossfade
        var candidates: [(barTime: Double, triggerPoint: Double, score: Double)] = []

        // Compute vocal end so we can skip bar boundaries that would cut the vocal.
        let vocalEnd = Self.lastContentEndTime(analysis: outgoingAnalysis, duration: adjustedDuration)
        let chorusEnd = Self.lastHighEnergySectionEnd(analysis: outgoingAnalysis)

        for barTime in barTimestamps.reversed() {
            let triggerPoint = adjustedDuration - barTime
            if triggerPoint >= minTriggerTime {
                // Skip if this bar is during the outgoing intro
                if barTime < outIntroEnd {
                    continue
                }

                // Skip bar boundaries before the vocal ends — crossfading here cuts the vocal.
                // Allow a 2s margin so the crossfade can overlap the vocal's resolving tail.
                if vocalEnd > 0 && barTime < vocalEnd - 2.0 {
                    continue
                }

                // Never start crossfade before the last chorus/drop ends.
                if chorusEnd > 0 && barTime < chorusEnd {
                    continue
                }

                // Compute energy match score
                let energyScore = computeEnergyMatchScore(
                    outgoingTime: barTime,
                    outgoingDuration: adjustedDuration,
                    outgoingEnergy: outEnergy,
                    incomingEnergy: inEnergy
                )

                // Phrase bonus: prefer 8-bar and 16-bar boundaries
                let barIndex = barTimestamps.firstIndex(of: barTime) ?? 0
                let phraseScore: Double
                if barIndex % 16 == 0 {
                    phraseScore = 1.0  // 16-bar phrase boundary — best
                } else if barIndex % 8 == 0 {
                    phraseScore = 0.8  // 8-bar phrase boundary — good
                } else if barIndex % 4 == 0 {
                    phraseScore = 0.5  // 4-bar boundary — okay
                } else {
                    phraseScore = 0.2  // Single bar — least preferred
                }

                // Combined score: 50% energy + 30% phrase + 20% BPM
                let combinedScore = energyScore * 0.5 + phraseScore * 0.3 + bpmScore * 0.2
                candidates.append((barTime, triggerPoint, combinedScore))
            }
        }

        // Prefer bar boundaries closest to (but after) the vocal end.
        let scored = candidates.map { c -> (cand: (barTime: Double, triggerPoint: Double, score: Double), rank: Double) in
            let dist = c.barTime - vocalEnd
            // Closer to vocal end = better (prefer just past the vocal tail).
            let proximity = max(0.0, 1.0 - abs(max(0, dist)) / 6.0)
            let rank = c.score * 0.4 + proximity * 0.6
            return (c, rank)
        }

        let best = scored.max(by: { $0.rank < $1.rank })?.cand

        if let best {
            print("[Engine] Best bar at \(String(format: "%.2f", best.barTime))s → trigger in \(String(format: "%.2f", best.triggerPoint))s (vocalEnd=\(String(format: "%.2f", vocalEnd)), score \(String(format: "%.3f", best.score)))")
            return best.triggerPoint
        }

        // Fallback
        print("[Engine] No bar boundary found, using fallback crossfade at \(String(format: "%.2f", crossfadeDuration))s from end")
        return crossfadeDuration
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

    // MARK: - Vocal Preservation

    private func clampVolume(_ volume: Float) -> Float {
        min(2.0, max(0, volume))
    }

    private func resetEQ(_ eq: AVAudioUnitEQ) {
        eq.bands[0].bypass = true
        eq.bands[0].frequency = config.eqLowPassStartHz
        eq.bands[0].filterType = .lowPass
    }

    // MARK: - Hall Reverb

    func setHallReverb(_ enabled: Bool) {
        hallReverb.wetDryMix = enabled ? 55 : 0
    }

    // MARK: - Audio Profile (EQ only)

    func applyProfileEQ(_ profile: AudioProfile) {
        let bands = profile.config.eqBands
        for (i, band) in profileEq.bands.enumerated() {
            if i < bands.count {
                let (freq, gain) = bands[i]
                band.filterType = .parametric
                band.frequency = freq
                band.gain = gain
                band.bandwidth = 0.5
                band.bypass = abs(gain) < 0.1
            } else {
                band.bypass = true
            }
        }
        profileEq.globalGain = 0
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
            moodsMatch: moodsMatch
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
        print("[Engine] Pre-swap: eqA band0 freq=\(String(format: "%.0f", eqA.bands[0].frequency))Hz bypass=\(eqA.bands[0].bypass), eqB band0 freq=\(String(format: "%.0f", eqB.bands[0].frequency))Hz bypass=\(eqB.bands[0].bypass)")
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

        currentPlayer.volume = lastIncomingVolume
        otherPlayer.volume = 0

        currentDuration = incomingDuration
        isCrossfading = false
        isPlaying = true

        let elapsed = -(crossfadeStartTime ?? Date()).timeIntervalSinceNow
        let remaining = max(0.1, actualIncomingDuration - elapsed)
        seekOffset = max(0, actualIncomingDuration - remaining)
        trackStartTime = Date()

        currentRate = 1.0
        remainingAtStart = remaining
        currentTimePitch.rate = 1.0
        currentTimePitch.bypass = true
        otherTimePitch.rate = 1.0
        otherTimePitch.bypass = true

        // ── Diagnostic: verify state after swap ────────────────────────
        let newCurrentPlayerID = currentPlayer === playerA ? "A" : "B"
        let newOtherPlayerID = otherPlayer === playerA ? "A" : "B"
        print("[Engine] Post-swap: currentPlayer=\(newCurrentPlayerID) (was \(inPlayerID)), otherPlayer=\(newOtherPlayerID) (was \(outPlayerID))")
        print("[Engine] Post-swap: currentTimePitch rate=\(String(format: "%.4f", currentTimePitch.rate)) bypass=\(currentTimePitch.bypass), otherTimePitch rate=\(String(format: "%.4f", otherTimePitch.rate)) bypass=\(otherTimePitch.bypass)")
        print("[Engine] Post-swap: remaining=\(String(format: "%.2f", remaining)), seekOffset=\(String(format: "%.2f", seekOffset)), currentRate=\(String(format: "%.4f", currentRate))")
        print("[Engine] Post-swap: currentPlayer playing=\(currentPlayer.isPlaying), otherPlayer playing=\(otherPlayer.isPlaying)")

        let maxFade = max(config.crossfadeDuration * 1.5, 12.0)
        beatAlignedCrossfadeTime = computeBeatAlignedCrossfadeTime(
            duration: incomingDuration,
            rate: 1.0,
            barTimestamps: currentBarTimestamps,
            crossfadeDuration: maxFade,
            outgoingAnalysis: currentTrackAnalysis,
            incomingAnalysis: nil
        )
        scheduleTrackEndTimer(delay: max(0.1, remainingAtStart - beatAlignedCrossfadeTime))
    }

}
