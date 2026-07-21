//
//  PlayerViewModel.swift
//  Cella
//
//  Manages the player state, automix analysis, and audio playback.
//

import SwiftUI
import AVFoundation
import MediaPlayer

@Observable
class PlayerViewModel {
    // MARK: - State

    var playerState: PlayerState = .idle
    var currentVolume: Float = 1.0
    var importError: String?
    var analysisProgress: Double = 0
    /// Buffered analysis results keyed by track URL — avoids per-callback COW copies.
    var analysisBuffer: [URL: TrackAnalysis?] = [:]
    var analyzedTrackCount: Int = 0
    var totalTrackCount: Int = 0

    private var animatedPattern: [[Bool]] = MatrixPatterns.smileyFace
    private var animationTimer: Timer?
    private var temporaryPattern: [[Bool]]?
    private var temporaryPatternTimer: Timer?
    private var nowPlayingTimer: Timer?
    private var currentMood: MusicMood = .neutral
    private var animationFrame: Int = 0
    private var moodTransitionTimer: Timer?
    private var pendingMood: MusicMood?

    var currentAudioProfile: AudioProfile = .flat

    // MARK: - Automix Components

    var mixQueue: MixQueue?
    private let audioEngine: MixAudioEngine
    private let trackAnalyzer: TrackAnalyzer
    private let crossfader: Crossfader
    private let config: AudioConfig

    // MARK: - Computed Properties

    var playlistCount: Int { mixQueue?.count ?? 0 }
    var hasTracks: Bool { mixQueue?.isEmpty == false }

    var currentPattern: [[Bool]] {
        if let temp = temporaryPattern {
            return temp
        }

        switch playerState {
        case .playing:
            return animatedPattern
        case .analyzing:
            return MatrixPatterns.analyzing
        case .autoMix:
            return MatrixPatterns.autoMix
        case .loading:
            return MatrixPatterns.loading
        default:
            return MatrixPatterns.smileyFace
        }
    }

    var isAnimating: Bool {
        playerState == .playing
    }

    var currentEnergyValue: Float {
        guard let profile = mixQueue?.currentTrack?.analysis?.energyProfile,
              !profile.isEmpty,
              currentDuration > 0
        else { return 0.3 }
        let idx = Int((currentTime / currentDuration) * Double(profile.count))
        let clamped = max(0, min(idx, profile.count - 1))
        return min(1.0, profile[clamped] / 0.5)
    }

    var statusText: String? {
        guard let queue = mixQueue, !queue.isEmpty else {
            switch playerState {
            case .idle: return nil
            case .analyzing(let progress):
                return "Analyzing: \(Int(progress * 100))%"
            case .loading:
                return "Building mix queue..."
            default:
                return nil
            }
        }

        let track = queue.currentTrack
        let trackName = track?.fileName ?? "Unknown"

        switch playerState {
        case .idle:
            return "Ready"
        case .playing:
            var text = "Playing: \(trackName)"
            if let analysis = track?.analysis {
                if let bpm = analysis.bpm {
                    text += " • \(Int(bpm)) BPM"
                }
                if let key = analysis.keySignature {
                    text += " • \(key.tonic) \(key.mode)"
                }
            }
            return text
        case .paused:
            return "Paused: \(trackName)"
        case .analyzing(let progress):
            return "Analyzing \(analyzedTrackCount)/\(totalTrackCount) • \(Int(progress * 100))%"
        case .loading:
            return "Building mix queue..."
        case .autoMix:
            return "AutoMix"
        }
    }

    // MARK: - Initialization

    init() {
        self.config = .standard
        self.audioEngine = MixAudioEngine(config: .standard)
        self.trackAnalyzer = TrackAnalyzer(config: .standard)
        self.crossfader = Crossfader(config: .standard)

        setupRemoteCommandCenter()
        setupTrackEndHandler()
        startNowPlayingTimer()
    }

    deinit {
        animationTimer?.invalidate()
        temporaryPatternTimer?.invalidate()
        nowPlayingTimer?.invalidate()
        moodTransitionTimer?.invalidate()
    }

    // MARK: - Setup

    private func setupTrackEndHandler() {
        audioEngine.onTrackEnd = { [weak self] in
            print("[PlayerViewModel] onTrackEnd callback fired")
            self?.handleTrackEnd()
        }
    }

    private func startNowPlayingTimer() {
        nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateNowPlayingInfo()
        }
    }

    // MARK: - Playback Info

    var currentTime: TimeInterval { audioEngine.currentTime }
    var currentDuration: TimeInterval { audioEngine.duration }

    func seekTo(time: TimeInterval) {
        guard playerState == .playing || playerState == .paused else { return }
        guard let queue = mixQueue, !queue.isEmpty else { return }
        let clamped = max(0, min(time, audioEngine.duration))
        audioEngine.seek(to: clamped)
        updateNowPlayingInfo()
    }

    // MARK: - Queue Management

    func moveTrack(from source: IndexSet, to destination: Int) {
        guard var queue = mixQueue else { return }
        queue.tracks.move(fromOffsets: source, toOffset: destination)

        let wasPlaying = queue.currentIndex
        var newIndex = wasPlaying
        for srcIdx in source {
            if srcIdx < wasPlaying {
                newIndex = min(newIndex + 1, queue.tracks.count - 1)
            } else if srcIdx > wasPlaying {
                newIndex = max(newIndex - 1, 0)
            }
        }
        if source.contains(wasPlaying) {
            newIndex = destination > wasPlaying ? destination - 1 : destination
        }
        queue.currentIndex = min(max(newIndex, 0), queue.tracks.count - 1)
        mixQueue = queue
    }

    func removeTrack(at index: Int) {
        guard var queue = mixQueue, index >= 0, index < queue.tracks.count else { return }
        cancelPendingMoodTransition()

        let wasPlayingCurrent = index == queue.currentIndex
        queue.tracks.remove(at: index)

        if queue.tracks.isEmpty {
            mixQueue = nil
            playerState = .idle
            audioEngine.stop()
            stopAnimationLoop()
            return
        }

        if wasPlayingCurrent {
            queue.currentIndex = min(index, queue.tracks.count - 1)
            if let track = queue.currentTrack {
                do {
                    try loadTrackAndRestore(
                        url: track.url,
                        barTimestamps: track.analysis?.barTimestamps ?? [],
                        analysis: track.analysis
                    )
                    if playerState == .playing || playerState == .paused {
                        playerState = .playing
                        audioEngine.play()
                        stopAnimationLoop()
                        startAnimationLoop()
                    }
                } catch {
                    importError = "Failed to load track: \(error.localizedDescription)"
                }
            }
        } else if index < queue.currentIndex {
            queue.currentIndex -= 1
        }

        mixQueue = queue
    }

    func jumpToTrack(at index: Int) {
        guard var queue = mixQueue, index >= 0, index < queue.tracks.count else { return }
        guard index != queue.currentIndex else { return }
        cancelPendingMoodTransition()

        queue.currentIndex = index
        mixQueue = queue

        if let track = queue.currentTrack {
            do {
                try loadTrackAndRestore(
                    url: track.url,
                    barTimestamps: track.analysis?.barTimestamps ?? [],
                    analysis: track.analysis
                )
                playerState = .playing
                audioEngine.play()
                stopAnimationLoop()
                startAnimationLoop()
            } catch {
                importError = "Failed to load track: \(error.localizedDescription)"
            }
        }

        updateNowPlayingInfo()
    }

    // MARK: - Actions

    func setVolume(_ volume: Float) {
        currentVolume = volume
        audioEngine.smoothVolume(to: volume)
    }

    func setHallReverb(_ enabled: Bool) {
        audioEngine.setHallReverb(enabled)
    }

    func applyAudioProfile(_ profile: AudioProfile) {
        currentAudioProfile = profile
        audioEngine.applyProfileEQ(profile)
    }

    private func restoreAudioSettings() {
        audioEngine.applyProfileEQ(currentAudioProfile)
    }

    private func loadTrackAndRestore(url: URL, rate: Float = 1.0, barTimestamps: [Double] = [], analysis: TrackAnalysis? = nil) throws {
        try audioEngine.loadTrack(url: url, rate: rate, barTimestamps: barTimestamps, analysis: analysis)
        restoreAudioSettings()
    }

    func togglePlayPause() {
        switch playerState {
        case .playing:
            playerState = .paused
            audioEngine.pause()
            stopAnimationLoop()

        case .paused:
            guard let queue = mixQueue, !queue.isEmpty else { return }
            playerState = .playing
            audioEngine.play()
            // Apply any pending mood immediately on resume
            if pendingMood != nil {
                applyPendingMood()
            } else {
                startAnimationLoop()
            }

        case .idle:
            guard let queue = mixQueue, !queue.isEmpty,
                  let track = queue.currentTrack else { return }
            playerState = .playing
            do {
                try loadTrackAndRestore(
                    url: track.url,
                    barTimestamps: track.analysis?.barTimestamps ?? [],
                    analysis: track.analysis
                )
                startAnimationLoop()
            } catch {
                importError = "Failed to start playback: \(error.localizedDescription)"
            }

        default:
            break
        }

        updateNowPlayingInfo()
    }

    func skipForward() {
        showTemporaryPattern(MatrixPatterns.skipForward)
        cancelPendingMoodTransition()

        guard var queue = mixQueue, !queue.isEmpty else { return }

        if let nextTrack = queue.nextTrack,
           let outgoingTrack = queue.currentTrack {
            playerState = .autoMix

            let params = crossfader.computeCrossfadeParams(
                outgoing: outgoingTrack,
                incoming: nextTrack
            )

            let started = audioEngine.crossfadeToNext(
                outgoingURL: outgoingTrack.url,
                incomingURL: nextTrack.url,
                crossfader: crossfader,
                params: params,
                outgoingAnalysis: outgoingTrack.analysis,
                incomingAnalysis: nextTrack.analysis
            )
            guard started else { return }

            queue.advanceToNext()
            mixQueue = queue

            DispatchQueue.main.asyncAfter(deadline: .now() + params.duration) { [weak self] in
                if self?.playerState == .autoMix {
                    self?.playerState = .playing
                    self?.stopAnimationLoop()
                    self?.startAnimationLoop()
                }
            }
        }

        updateNowPlayingInfo()
    }

    func skipBackward() {
        showTemporaryPattern(MatrixPatterns.skipBackward)
        cancelPendingMoodTransition()

        guard var queue = mixQueue, !queue.isEmpty else { return }

        if audioEngine.currentTime > 3.0 {
            audioEngine.seek(to: 0)
        } else {
            queue.advanceToPrevious()
            mixQueue = queue

            do {
                guard let track = queue.currentTrack else { return }
                try loadTrackAndRestore(
                    url: track.url,
                    barTimestamps: track.analysis?.barTimestamps ?? [],
                    analysis: track.analysis
                )
                if playerState == .playing {
                    audioEngine.play()
                    stopAnimationLoop()
                    startAnimationLoop()
                }
            } catch {
                importError = "Failed to skip: \(error.localizedDescription)"
            }
        }

        updateNowPlayingInfo()
    }

    // MARK: - Import & Analysis

    func importFolder(url: URL) {
        importError = nil
        analysisProgress = 0
        analysisBuffer = [:]

        print("[PlayerViewModel] importFolder called: \(url.path)")

        let audioExtensions = ["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"]

        // Move directory listing + validation off main thread
        Task.detached { [weak self] in
            guard let self else { return }
            let fileManager = FileManager.default
            let contents = (try? fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil
            )) ?? []

            let audioFiles = contents.filter {
                audioExtensions.contains($0.pathExtension.lowercased())
            }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

            print("[PlayerViewModel] Audio files found: \(audioFiles.count)")

            guard !audioFiles.isEmpty else {
                await MainActor.run {
                    self.importError = "No audio files found in folder"
                    print("[PlayerViewModel] ERROR: No audio files found")
                }
                return
            }

            // Validate off main thread — reads audio headers, not full files
            var validTracks: [TrackAsset] = []
            for rawTrack in audioFiles.map({ TrackAsset(url: $0) }) {
                do {
                    _ = try AudioHelpers.readAudio(url: rawTrack.url)
                    validTracks.append(rawTrack)
                } catch {
                    print("[PlayerViewModel] Skipping unplayable: \(rawTrack.fileName) — \(error.localizedDescription)")
                }
            }

            guard !validTracks.isEmpty else {
                await MainActor.run {
                    self.importError = "No playable audio files found"
                    print("[PlayerViewModel] ERROR: No playable files after validation")
                }
                return
            }

            let tracks = validTracks

            // Switch back to main actor for state updates and playback
            await MainActor.run {
                self.totalTrackCount = tracks.count
                self.analyzedTrackCount = 0

                print("[PlayerViewModel] Importing \(tracks.count) playable tracks from \(url.lastPathComponent)")

                let tempQueue = MixQueue(
                    tracks: tracks,
                    transitions: [nil] + Array(repeating: nil, count: max(0, tracks.count - 1))
                )
                self.mixQueue = tempQueue

                print("[PlayerViewModel] Queue created, loading first track: \(tracks[0].url.lastPathComponent)")

                do {
                    try self.loadTrackAndRestore(
                        url: tracks[0].url,
                        barTimestamps: tracks[0].analysis?.barTimestamps ?? []
                    )
                    self.playerState = .playing
                    self.startAnimationLoop()
                    print("[PlayerViewModel] Now playing: \(tracks[0].fileName)")
                } catch {
                    self.importError = "Failed to start playback: \(error.localizedDescription)"
                    self.playerState = .idle
                    print("[PlayerViewModel] ERROR loading track: \(error)")
                    return
                }
            } // MainActor.run

            Task { @MainActor [weak self] in
                guard let self else { return }
                // Prioritize: current track first, next track second, rest after
                var prioritized = tracks
                if let currentURL = self.mixQueue?.currentTrack?.url,
                   let currentIndex = prioritized.firstIndex(where: { $0.url == currentURL }) {
                    let current = prioritized.remove(at: currentIndex)
                    prioritized.insert(current, at: 0)

                    if let nextURL = self.mixQueue?.nextTrack?.url,
                       let nextIndex = prioritized.firstIndex(where: { $0.url == nextURL }) {
                        let next = prioritized.remove(at: nextIndex)
                        prioritized.insert(next, at: 1)
                    }
                }

                if prioritized.count >= 2 {
                    print("[PlayerViewModel] Analysis Task started — \(prioritized[0].fileName) first, then \(prioritized[1].fileName), then \(prioritized.count - 2) more...")
                } else {
                    print("[PlayerViewModel] Analysis Task started — \(prioritized[0].fileName) only")
                }
                do {
                    let analyzedTracks = try await self.trackAnalyzer.analyzeAll(
                        assets: prioritized,
                        maxConcurrent: self.config.maxConcurrentAnalysis
                    ) { [weak self] completed, total, analyzedAsset in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.analyzedTrackCount = completed
                            self.analysisProgress = Double(completed) / Double(total)

                            // Buffer analysis results — avoid per-callback COW copy of MixQueue tracks array.
                            // Results are merged into the queue after all analysis completes.
                            self.analysisBuffer[analyzedAsset.url] = analyzedAsset.analysis

                            // Apply mood transition for current track from buffered analysis
                            if let currentURL = self.mixQueue?.currentTrack?.url,
                               analyzedAsset.url == currentURL,
                               let analysis = analyzedAsset.analysis {
                                let newMood = MusicMood.from(analysis: analysis)
                                if self.playerState == .playing {
                                    self.scheduleMoodTransition(mood: newMood, analysis: analysis)
                                } else {
                                    self.currentMood = newMood
                                    self.stopAnimationLoop()
                                    self.startAnimationLoop()
                                }
                            }
                        }
                    }

                    // Rebuild the mix queue with optimized ordering
                    let optimizedQueue = MixEngine.buildMixQueue(tracks: analyzedTracks)

                    // Anchor current track at index 0, reorder rest
                    if let currentTrackURL = self.mixQueue?.currentTrack?.url,
                       let currentIndex = optimizedQueue.tracks.firstIndex(where: { $0.url == currentTrackURL }) {
                        var newQueue = optimizedQueue
                        let currentTrack = newQueue.tracks.remove(at: currentIndex)
                        newQueue.tracks.insert(currentTrack, at: 0)
                        newQueue.currentIndex = 0
                        self.mixQueue = newQueue
                    } else {
                        self.mixQueue = optimizedQueue
                    }

                    self.analysisProgress = 1.0
                    self.analyzedTrackCount = self.totalTrackCount

                    let analyzedCount = analyzedTracks.filter { $0.analysis != nil }.count
                    let currentAnalysis = self.mixQueue?.currentTrack?.analysis
                    print("[PlayerViewModel] Analysis done: \(analyzedCount)/\(analyzedTracks.count) tracks analyzed")
                    print("[PlayerViewModel] Current track analysis: \(currentAnalysis != nil ? "YES" : "NO"), bpm=\(String(describing: currentAnalysis?.bpm))")

                    // Restart animation loop with mood from analyzed track
                    if self.playerState == .playing {
                        self.stopAnimationLoop()
                        self.startAnimationLoop()
                    }

                } catch {
                    self.importError = "Analysis failed: \(error.localizedDescription)"
                    print("[PlayerViewModel] Analysis FAILED: \(error)")
                }
                print("[PlayerViewModel] Analysis Task finished")
            }

        } // Task.detached
    }

    // MARK: - Track End Handling

    private func handleTrackEnd() {
        cancelPendingMoodTransition()
        guard var queue = mixQueue, !queue.isEmpty else {
            print("[PlayerViewModel] handleTrackEnd: no queue or empty")
            return
        }

        let currentName = queue.currentTrack?.fileName ?? "?"
        print("[PlayerViewModel] Track ended: \(currentName)")

        // Crossfade to next track automatically
        if let nextTrack = queue.nextTrack,
           let outgoingTrack = queue.currentTrack {
            let nextName = nextTrack.fileName
            print("[PlayerViewModel] Crossfading to: \(nextName)")

            playerState = .autoMix

            let params = crossfader.computeCrossfadeParams(
                outgoing: outgoingTrack,
                incoming: nextTrack
            )

            let started = audioEngine.crossfadeToNext(
                outgoingURL: outgoingTrack.url,
                incomingURL: nextTrack.url,
                crossfader: crossfader,
                params: params,
                outgoingAnalysis: outgoingTrack.analysis,
                incomingAnalysis: nextTrack.analysis
            )
            guard started else { return }

            queue.advanceToNext()
            mixQueue = queue

            DispatchQueue.main.asyncAfter(deadline: .now() + params.duration) { [weak self] in
                if self?.playerState == .autoMix {
                    self?.playerState = .playing
                    self?.stopAnimationLoop()
                    self?.startAnimationLoop()
                    print("[PlayerViewModel] Crossfade complete — now playing: \(nextName)")
                }
            }
        } else {
            // No more tracks — loop back to first
            print("[PlayerViewModel] End of queue — looping to first track")
            queue.currentIndex = 0
            mixQueue = queue

            if let firstTrack = queue.currentTrack {
                do {
                    try loadTrackAndRestore(
                        url: firstTrack.url,
                        barTimestamps: firstTrack.analysis?.barTimestamps ?? []
                    )
                    playerState = .playing
                    startAnimationLoop()
                } catch {
                    importError = "Failed to loop: \(error.localizedDescription)"
                }
            }
        }

        updateNowPlayingInfo()
    }

    // MARK: - Temporary Pattern Display

    private func showTemporaryPattern(_ pattern: [[Bool]]) {
        temporaryPattern = pattern
        temporaryPatternTimer?.invalidate()
        temporaryPatternTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            self?.temporaryPattern = nil
        }
    }

    // MARK: - Now Playing / Control Center Integration

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            if self?.playerState != .playing {
                self?.togglePlayPause()
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            if self?.playerState == .playing {
                self?.togglePlayPause()
            }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.skipForward()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.skipBackward()
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let queue = mixQueue, let track = queue.currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }

        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = track.fileName

        if let analysis = track.analysis {
            if let bpm = analysis.bpm {
                nowPlayingInfo[MPMediaItemPropertyBeatsPerMinute] = bpm
            }
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = analysis.duration
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = audioEngine.isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = audioEngine.currentTime

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        MPNowPlayingInfoCenter.default().playbackState = (playerState == .playing) ? .playing : .paused
    }

    // MARK: - Animation Loop

    private func startAnimationLoop() {
        guard animationTimer == nil else { return }

        currentMood = MusicMood.from(analysis: mixQueue?.currentTrack?.analysis)
        let speed = currentMood.animationSpeed
        animationFrame = 0

        animationTimer = Timer.scheduledTimer(withTimeInterval: speed, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            let frames: [[[Bool]]]

            switch self.currentMood {
            case .energeticHappy: frames = MatrixPatterns.moodEnergeticHappy
            case .energeticAngry:  frames = MatrixPatterns.moodEnergeticAngry
            case .calmHappy:       frames = MatrixPatterns.moodCalmHappy
            case .calmSad:         frames = MatrixPatterns.moodCalmSad
            case .neutral:
                let rand = Int.random(in: 0...100)
                if rand < 5 {
                    self.animatedPattern = MatrixPatterns.smileyBlink
                } else if rand < 40 {
                    self.animatedPattern = MatrixPatterns.smileySing1
                } else if rand < 70 {
                    self.animatedPattern = MatrixPatterns.smileySing2
                } else {
                    self.animatedPattern = MatrixPatterns.smileyFace
                }
                return
            }

            self.animatedPattern = frames[self.animationFrame]
            self.animationFrame = (self.animationFrame + 1) % frames.count
        }
    }

    private func stopAnimationLoop() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationFrame = 0
        animatedPattern = MatrixPatterns.smileyFace
    }

    // MARK: - Phase-Aligned Mood Transition

    /// Schedules mood change at the next bar boundary for smooth visual transition.
    private func scheduleMoodTransition(mood: MusicMood, analysis: TrackAnalysis) {
        moodTransitionTimer?.invalidate()
        pendingMood = mood

        guard !analysis.barTimestamps.isEmpty else {
            applyPendingMood()
            return
        }

        let currentTime = audioEngine.currentTime
        let barTimestamps = analysis.barTimestamps

        // Find next bar boundary after current position
        var nextBar: Double?
        for barTime in barTimestamps {
            if barTime > currentTime + 0.1 {
                nextBar = barTime
                break
            }
        }

        // If no future bar found, use the last bar + bar interval
        if nextBar == nil, let lastBar = barTimestamps.last, let bpm = analysis.bpm, bpm > 0 {
            let barInterval = 240.0 / bpm
            nextBar = lastBar + barInterval
        }

        guard let targetTime = nextBar else {
            applyPendingMood()
            return
        }

        let delay = targetTime - currentTime
        print("[PlayerViewModel] Mood transition scheduled in \(String(format: "%.2f", delay))s (at bar \(String(format: "%.2f", targetTime))s)")

        moodTransitionTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.applyPendingMood()
        }
    }

    /// Applies the pending mood change immediately.
    private func applyPendingMood() {
        moodTransitionTimer?.invalidate()
        moodTransitionTimer = nil

        guard let mood = pendingMood else { return }
        pendingMood = nil

        currentMood = mood
        stopAnimationLoop()
        startAnimationLoop()
        print("[PlayerViewModel] Mood applied: \(mood.rawValue)")
    }

    /// Cancels any pending mood transition (called when switching tracks).
    private func cancelPendingMoodTransition() {
        moodTransitionTimer?.invalidate()
        moodTransitionTimer = nil
        pendingMood = nil
    }

}
