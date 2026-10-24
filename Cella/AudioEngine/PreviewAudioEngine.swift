//
//  PreviewAudioEngine.swift
//  Cella
//
//  Lightweight single-track playback engine for the floating WAV preview mini
//  player. Mirrors MixAudioEngine's proven DSP chain — profile EQ → surround
//  EQ → PeakLimiter — but without the automix machinery:
//
//      playerNode → mixerNode (width tap) → profileEq (10-band)
//                  → surroundEq (4-band) → PeakLimiter → mainMixer
//
//  All Orquesta geometry (band configs, targets, width values, gain
//  compensation) comes from the shared OrquestaDSP constants so the preview
//  sounds identical to the Config tab. Stereo width is instance-scoped: the
//  render tap uses the parameterized StereoWidthEffect.process(_:width:)
//  overload and never touches the global StereoWidthEffect.currentWidth, so
//  the two engines can run at once without fighting.
//

import AVFoundation
import SPFKAudioBase

final class PreviewAudioEngine {
    // MARK: - Properties

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let mixerNode = AVAudioMixerNode()
    private let profileEq = AVAudioUnitEQ(numberOfBands: 10)
    private let surroundEq = AVAudioUnitEQ(numberOfBands: 4)
    private let peakLimiter: AVAudioUnit
    private let config: AudioConfig

    /// Instance-scoped stereo width factor. Updated by the surround ramp timer;
    /// consumed by the render tap. Never touches `StereoWidthEffect.currentWidth`.
    private var currentWidthValue: Float = 1.0
    private var surroundMode: SurroundMode = .off
    private var soloBand: Int?

    private var currentURL: URL?
    private var currentDuration: TimeInterval = 0
    private var seekOffset: TimeInterval = 0
    private var trackStartTime: Date?
    private var remainingAtStart: TimeInterval = 0

    private var trackEndTimer: Timer?
    private var profileRampTimer: Timer?
    private var fxRampTimer: Timer?
    private var profileTargets: [Float] = []
    private var configurationObserver: NSObjectProtocol?

    private(set) var isPlaying = false

    var onTrackEnd: (() -> Void)?

    // MARK: - Initialization

    init(config: AudioConfig = .standard) {
        self.config = config
        self.peakLimiter = Self.makePeakLimiter()
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
        trackEndTimer?.invalidate()
        profileRampTimer?.invalidate()
        fxRampTimer?.invalidate()
    }

    private static func makePeakLimiter() -> AVAudioUnit {
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
            fatalError("PreviewAudioEngine: failed to instantiate Apple PeakLimiter")
        }
        return unit
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(mixerNode)
        engine.attach(profileEq)
        engine.attach(surroundEq)
        engine.attach(peakLimiter)

        let format = config.processingFormat

        engine.connect(playerNode, to: mixerNode, format: format)
        mixerNode.volume = 1.0
        engine.connect(mixerNode, to: profileEq, format: format)
        engine.connect(profileEq, to: surroundEq, format: format)
        engine.connect(surroundEq, to: peakLimiter, format: format)
        engine.connect(peakLimiter, to: engine.mainMixerNode, format: nil)

        for band in profileEq.bands { band.bypass = true }
        profileEq.globalGain = 0
        for band in surroundEq.bands { band.bypass = true }
        surroundEq.globalGain = 0

        // Stereo width tap — instance-scoped M/S widening of the source buffer.
        mixerNode.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
            StereoWidthEffect.process(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[PreviewEngine] FAILED to start: \(error)")
        }
    }

    // MARK: - Audio Device / Route Change

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

        print("[PreviewEngine] Output config changed — restarting on new device (wasPlaying=\(wasPlaying), pos=\(String(format: "%.1f", position)))")

        try? engine.start()
        do {
            try reload(url: url, position: position, play: wasPlaying)
        } catch {
            print("[PreviewEngine] Reload after config change failed: \(error)")
        }
    }

    private func reload(url: URL, position: TimeInterval, play: Bool) throws {
        cancelTrackEndTimer()
        playerNode.stop()
        playerNode.reset()

        let file = try AudioHelpers.readAudio(url: url)
        if !engine.isRunning {
            try? engine.start()
        }

        currentURL = url
        currentDuration = file.duration
        isPlaying = play

        if position > 0.05 {
            seek(to: position)
            if play { playerNode.play() }
        } else {
            seekOffset = 0
            trackStartTime = Date()
            remainingAtStart = file.duration
            playerNode.scheduleFile(file, at: nil)
            if play { playerNode.play() }
            scheduleTrackEndTimer(delay: file.duration)
        }
        print("[PreviewEngine] Resumed on new device at \(String(format: "%.1f", position))s")
    }

    // MARK: - Transport

    func load(url: URL) throws {
        cancelTrackEndTimer()
        playerNode.stop()
        playerNode.reset()

        if !engine.isRunning {
            try? engine.start()
        }

        let file = try AudioHelpers.readAudio(url: url)

        currentURL = url
        currentDuration = file.duration
        isPlaying = false
        seekOffset = 0
        trackStartTime = Date()
        remainingAtStart = file.duration

        playerNode.scheduleFile(file, at: nil)
        scheduleTrackEndTimer(delay: file.duration)

        print("[PreviewEngine] Loaded: \(url.lastPathComponent) — \(String(format: "%.1f", file.duration))s")
    }

    func play() {
        guard currentURL != nil else { return }
        playerNode.play()
        isPlaying = true
        trackStartTime = Date()
        cancelTrackEndTimer()
        scheduleTrackEndTimer(delay: max(0.05, remainingAtStart))
    }

    func pause() {
        guard isPlaying else { return }
        playerNode.pause()
        seekOffset = currentTime
        isPlaying = false
        trackStartTime = nil
        cancelTrackEndTimer()
    }

    func stop() {
        playerNode.stop()
        playerNode.reset()
        isPlaying = false
        currentURL = nil
        currentDuration = 0
        seekOffset = 0
        trackStartTime = nil
        remainingAtStart = 0
        cancelTrackEndTimer()
    }

    func seek(to time: TimeInterval) {
        guard let url = currentURL else { return }
        do {
            let file = try AudioHelpers.readAudio(url: url)

            let sampleRate = file.processingFormat.sampleRate
            let framePosition = AVAudioFramePosition(time * sampleRate)
            guard framePosition >= 0, framePosition < file.length else { return }

            let remainingFrames = AVAudioFrameCount(file.length - framePosition)
            let remaining = Double(remainingFrames) / sampleRate

            playerNode.stop()
            playerNode.reset()
            playerNode.scheduleSegment(file, startingFrame: framePosition, frameCount: remainingFrames, at: nil)

            seekOffset = time
            remainingAtStart = remaining
            trackStartTime = Date()
            if isPlaying {
                playerNode.play()
            }
            scheduleTrackEndTimer(delay: max(0.05, remaining))
        } catch {
            print("[PreviewEngine] Seek failed: \(error)")
        }
    }

    func setVolume(_ volume: Float) {
        mixerNode.volume = min(2.0, max(0, volume))
    }

    /// Current playback head in seconds (wall clock), clamped to the track duration.
    var currentTime: TimeInterval {
        guard let startTime = trackStartTime else { return seekOffset }
        guard isPlaying else { return seekOffset }
        let elapsed = -startTime.timeIntervalSinceNow
        return min(seekOffset + elapsed, currentDuration)
    }

    var duration: TimeInterval { currentDuration }

    // MARK: - Track End Detection

    private func scheduleTrackEndTimer(delay: TimeInterval) {
        cancelTrackEndTimer()
        let safeDelay = max(0.05, delay)
        guard safeDelay.isFinite else { return }
        trackEndTimer = Timer.scheduledTimer(withTimeInterval: safeDelay, repeats: false) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            self.trackEndTimer = nil
            self.isPlaying = false
            print("[PreviewEngine] Track end")
            self.onTrackEnd?()
        }
    }

    private func cancelTrackEndTimer() {
        trackEndTimer?.invalidate()
        trackEndTimer = nil
    }

    // MARK: - Orquesta (profile EQ)

    func setSoloBand(_ index: Int?) {
        soloBand = index
    }

    func applyProfileEQ(_ preset: OrquestaPreset) {
        let bands = preset.eqBands

        // Fixed geometry per band — only gain animates, so a preset swap never
        // re-engages a filter (that transient is what pops the gain).
        for (i, band) in profileEq.bands.enumerated() {
            band.filterType = .parametric
            band.bandwidth = OrquestaDSP.profileBandwidth
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
        profileEq.globalGain = -OrquestaDSP.maxSurroundBoost(for: surroundMode)

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

    // MARK: - Surround Staging

    func setSurroundMode(_ mode: SurroundMode) {
        surroundMode = mode
        beginSurroundRamp()
    }

    private func beginSurroundRamp() {
        let configs = OrquestaDSP.surroundBands
        let targets = OrquestaDSP.surroundTargets(for: surroundMode)
        let widthTarget = OrquestaDSP.widthValue(for: surroundMode)

        for (i, band) in surroundEq.bands.enumerated() {
            band.bypass = false
            band.bandwidth = OrquestaDSP.surroundBandwidth
            band.filterType = configs[i].type
            band.frequency = configs[i].freq
        }
        surroundEq.globalGain = 0

        // Gain compensation — the surround EQ stacks on top of profileEq.
        profileEq.globalGain = -OrquestaDSP.maxSurroundBoost(for: surroundMode)

        fxRampTimer?.invalidate()
        fxRampTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            var done = true

            // Ramp surround EQ bands.
            for (i, band) in self.surroundEq.bands.enumerated() {
                let target = i < targets.count ? targets[i] : 0
                let diff = target - band.gain
                if abs(diff) > 0.01 { done = false }
                band.gain += diff * 0.25
            }

            // Ramp stereo width — instance-scoped, never touches the global.
            let cur = self.currentWidthValue
            let diff = widthTarget - cur
            if abs(diff) > 0.003 { done = false }
            self.currentWidthValue = cur + diff * 0.25

            if done {
                self.fxRampTimer?.invalidate()
                self.fxRampTimer = nil
            }
        }
        fxRampTimer?.tolerance = 0.005
    }
}