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
    private let spatialDelay = AVAudioUnitDelay()
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

        spatialDelay.delayTime = 0
        spatialDelay.feedback = 0
        spatialDelay.wetDryMix = 0

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
        scheduleTrackEndTimer(delay: max(0.1, remainingAtStart - beatAlignedCrossfadeTime))

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
        engine.attach(spatialDelay)
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
        engine.connect(mixerNode, to: spatialDelay, format: format)
        spatialDelay.wetDryMix = 0
        engine.connect(spatialDelay, to: profileEq, format: format)
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

        spatialDelay.delayTime = 0
        spatialDelay.feedback = 0
        spatialDelay.wetDryMix = 0
        for band in profileEq.bands { band.bypass = true }
        profileEq.globalGain = 0

        hallReverb.wetDryMix = 0
    }

    // MARK: - Playback Controls

    func loadTrack(url: URL, rate: Float = 1.0, barTimestamps: [Double] = [], analysis: TrackAnalysis? = nil) throws {
        cancelTrackEndTimer()
        stop()

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

        scheduleTrackEndTimer(delay: finalDelay)
    }

    func play() {
        guard engine.isRunning else { return }
        currentPlayer.play()
        isPlaying = true
        restartTrackEndTimer()
    }

    func setMasterVolume(_ volume: Float) {
        mixerNode.volume = min(2.0, max(0, volume))
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
            let crossfadeDuration = params.duration
            actualIncomingDuration = incomingDuration    // may shrink if intro skipped

            // ── 1. BPM SYNC via timePitch (pitch preserved) ──────────
            // Only slow incoming to match outgoing, never speed up.
            // Cap slowdown to prevent audible artifacts.
            // Skip sync when BPMs within 8% — time stretching artifacts
            // are more noticeable than the tiny tempo mismatch.
            let outBPM = outgoingAnalysis?.bpm ?? 0
            let inBPM = incomingAnalysis?.bpm ?? 0
            let bpmRatio = outBPM > 0 && inBPM > 0 ? abs(outBPM - inBPM) / max(outBPM, inBPM) : 0
            if outBPM > 0, inBPM > 0, inBPM >= outBPM, bpmRatio >= 0.08 {
                let rawRate = Float(outBPM / inBPM)
                incomingTargetRate = max(0.90, rawRate)
                print("[Engine] BPM sync: outgoing \(String(format: "%.1f", outBPM)) → incoming \(String(format: "%.1f", inBPM)), rate \(String(format: "%.4f", incomingTargetRate))")
            } else {
                incomingTargetRate = 1.0
                print("[Engine] \(outBPM > 0 && inBPM > 0 ? "Incoming faster/close — no sync" : "No BPM data") — no tempo sync")
            }

            // ── 2. BEAT PHASE ALIGNMENT ──────────────────────────────────
            // Cue the incoming to its first detected beat so its downbeat lands on
            // the outgoing bar line at the crossfade point (real beat lock, no pitch shift).
            let incomingFirstBeat = incomingAnalysis?.beatTimestamps.first ?? 0
            var beatPhaseOffset: Double = 0  // grids align via cue; no silence padding needed
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

            // Gradual tempo sync: glide incoming from its natural tempo down to the
            // matched tempo so beats converge smoothly instead of snapping.
            // Only activate timePitch when rate actually differs — toggling bypass
            // mid-playback resets internal buffers and can glitch the audio.
            if abs(incomingTargetRate - 1.0) > 0.001 {
                otherTimePitch.bypass = false
                self.startTempoRamp(node: otherTimePitch, from: 1.0, to: incomingTargetRate, duration: min(2.0, crossfadeDuration * 0.4))
            }

            // ── 3b. VOCAL CONNECTION POINT / INTRO SKIP ────────────────
            let sampleRate = incomingFile.processingFormat.sampleRate
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
                        bufferToSchedule = self.padWithSilence(trimmed, sampleRate: sampleRate, beatPhaseOffset: beatPhaseOffset, rate: incomingTargetRate)
                    }
                }
            } else {
                let fileBuffer = try readEntireFile(incomingFile)
                bufferToSchedule = self.padWithSilence(fileBuffer, sampleRate: sampleRate, beatPhaseOffset: beatPhaseOffset, rate: incomingTargetRate)
            }

            // Cue incoming to its first detected beat for beat phase alignment.
            // Skipped when skipIntro is active — the vocal connection point already
            // positions the buffer at the right offset, and the first-beat timestamp
            // is relative to the full track, not the trimmed buffer.
            if !params.skipIntro,
               incomingFirstBeat > 0.01,
               let buf = bufferToSchedule {
                let cueFrames = AVAudioFramePosition(incomingFirstBeat * buf.format.sampleRate)
                if cueFrames > 0, cueFrames < AVAudioFramePosition(buf.frameLength) {
                    let remaining = buf.frameLength - AVAudioFrameCount(cueFrames)
                    if let cued = AudioHelpers.extractBuffer(buf, from: cueFrames, frameCount: remaining) {
                        actualIncomingDuration = max(1.0, incomingDuration - incomingFirstBeat)
                        bufferToSchedule = cued
                    }
                }
            }

            // Phase-aware splice: apply a 2ms linear fade-in on the cued buffer
            // so the first sample lands at zero regardless of where the cue point falls.
            // Prevents a click when the crossfade gain first opens on the incoming track.
            if let buf = bufferToSchedule {
                applyMicroFadeIn(buf)
            }

            if let bufferToSchedule {
                otherPlayer.scheduleBuffer(bufferToSchedule, at: nil)
            } else {
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
            self.curveExponent = computeEnergyCurveExponent(
                outgoingAnalysis: outgoingAnalysis,
                incomingAnalysis: incomingAnalysis,
                outgoingTime: self.outgoingCrossfadeStartPos,
                outgoingDuration: self.currentDuration,
                incomingTime: self.incomingCueOffset,
                incomingDuration: actualIncomingDuration
            )

            print("[Engine] Automix: \(String(format: "%.1f", crossfadeDuration))s, strategy \(params.vocalStrategy), curveExp \(String(format: "%.2f", self.curveExponent))")

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
                let warpedProgress: Double
                if self.curveExponent != 1.0 {
                    warpedProgress = pow(progress, self.curveExponent)
                } else {
                    warpedProgress = progress
                }
                let outAmplitude = Float(sqrt(1.0 - warpedProgress))
                let inAmplitude = Float(sqrt(warpedProgress))
                let outVol = outAmplitude * self.outgoingGain
                let inVol = inAmplitude * self.incomingGain
                self.currentPlayer.volume = self.clampVolume(outVol)
                self.otherPlayer.volume = self.clampVolume(inVol)

                if currentStep >= crossfadeSteps {
                    self.lastIncomingVolume = self.clampVolume(inVol)
                }

                // ── Spectral blend: EQ sweep ──────────────────────────────
                // Outgoing low-pass rolls off highs as it fades; incoming
                // high-pass opens lows. Keeps midrange from clashing.
                if self.config.eqFadeEnabled {
                    let eqP = Float(progress * progress * (3.0 - 2.0 * progress))  // smoothstep
                    let lpCut = self.config.eqLowPassStartHz * pow(self.config.eqLowPassEndHz / self.config.eqLowPassStartHz, eqP)
                    let hpCut = self.config.eqHighPassStartHz * pow(self.config.eqHighPassEndHz / self.config.eqHighPassStartHz, eqP)
                    // Set type every tick — player roles swap after completeCrossfade
                    // so the correct filter must follow the role, not the hardware node.
                    let outEQ = self.currentEQ
                    outEQ.bands[0].filterType = .lowPass
                    outEQ.bands[0].frequency = lpCut
                    outEQ.bands[0].bypass = false
                    let inEQ = self.otherEQ
                    inEQ.bands[0].filterType = .highPass
                    inEQ.bands[0].frequency = hpCut
                    inEQ.bands[0].bypass = false
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

    var activePlayerNode: AVAudioPlayerNode { currentPlayer }

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
            scheduleTrackEndTimer(delay: remaining - beatAlignedCrossfadeTime)
        } else if remaining > 0 {
            scheduleTrackEndTimer(delay: max(0.1, remaining))
        }
    }

    private func cancelTrackEndTimer() {
        trackEndTimer?.invalidate()
        trackEndTimer = nil
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
    /// Computes crossfade curve exponent from energy ratio at the transition point.
    /// When outgoing energy >> incoming energy, exponent > 1 delays incoming blend
    /// (outgoing stays full longer, incoming rises gradually). When incoming energy >>
    /// outgoing, exponent < 1 blends incoming sooner. Keeps perceived volume smooth.
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
        // Average a small window (3 samples) for stability
        let outSlice = max(0, outIdx - 1)...min(outEnergy.count - 1, outIdx + 1)
        let inSlice = max(0, inIdx - 1)...min(inEnergy.count - 1, inIdx + 1)
        let outAvg = outSlice.map { Double(outEnergy[$0]) }.reduce(0, +) / Double(outSlice.count)
        let inAvg = inSlice.map { Double(inEnergy[$0]) }.reduce(0, +) / Double(inSlice.count)
        let ratio = inAvg / max(outAvg, 0.001)
        // Map ratio to exponent: ratio=1 → 1.0, ratio=0.25 → 0.4, ratio=4 → 2.5
        // When outgoing is louder (ratio < 1), exponent < 1 → tracks cross early,
        // so the quiet incoming becomes audible before the loud outgoing fully fades.
        // When incoming is louder (ratio > 1), exponent > 1 → incoming rises gradually
        // so it doesn't blast over the quieter outgoing.
        // Clamped to [0.4, 2.5] — outside this range the crossfade sounds abrupt.
        return max(0.4, min(2.5, ratio))
    }

    // MARK: - Private Helpers

    private func readEntireFile(_ file: AVAudioFile) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "MixAudioEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate buffer"])
        }
        try file.read(into: buffer)
        return buffer
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
        print("[Engine] Automix done")

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

        // Immediately return to normal tempo. The incoming track already glided
        // from 1.0 → incomingTargetRate during the crossfade (2s ramp). A gradual
        // tempo return after the crossfade (6-12s) makes the track audibly slower
        // for a significant portion of the song — users reported this as a bug.
        otherTimePitch.bypass = true
        otherTimePitch.rate = 1.0
        currentTimePitch.bypass = true
        currentRate = 1.0

        currentDuration = incomingDuration

        isCrossfading = false
        isPlaying = true

        let elapsed = -(crossfadeStartTime ?? Date()).timeIntervalSinceNow
        let totalBuffer = self.actualIncomingDuration
        // Incoming track tempo ramps from 1.0 → incomingTargetRate over first 2s
        // (or 40% of crossfade). Account for lower rate during ramp so remaining
        // time doesn't overestimate.
        let rampDuration = min(2.0, currentCrossfadeDuration * 0.4)
        let targetRate = Double(incomingTargetRate)
        let audioConsumedDuringCrossfade: Double
        if elapsed <= rampDuration {
            audioConsumedDuringCrossfade = elapsed * (1.0 + targetRate) / 2.0
        } else {
            let rampAudio = rampDuration * (1.0 + targetRate) / 2.0
            audioConsumedDuringCrossfade = rampAudio + (elapsed - rampDuration) * targetRate
        }
        let remaining = max(0.1, totalBuffer - audioConsumedDuringCrossfade)
        // No tempo return ramp — currentRate is already 1.0. Wall clock = audio time.
        remainingAtStart = remaining / Double(currentRate)
        seekOffset = max(0, actualIncomingDuration - remaining)
        trackStartTime = Date()

        // Recompute beat-aligned crossfade trigger for the now-current track
        let maxFadeDuration = max(config.crossfadeDuration * 1.5, 12.0)
        beatAlignedCrossfadeTime = computeBeatAlignedCrossfadeTime(
            duration: incomingDuration,
            rate: Double(currentRate),
            barTimestamps: currentBarTimestamps,
            crossfadeDuration: maxFadeDuration,
            outgoingAnalysis: currentTrackAnalysis,
            incomingAnalysis: nil
        )
        scheduleTrackEndTimer(delay: max(0.1, remainingAtStart - beatAlignedCrossfadeTime))
    }

}
