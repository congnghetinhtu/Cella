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
    var isAnimationPaused: Bool = false
    var importError: String?
    var analysisProgress: Double = 0
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
    private let powerManager = PowerManager.shared

    var currentAudioProfile: AudioProfile = .flat

    // MARK: - Automix Components

    var mixQueue: MixQueue?
    private let audioEngine: MixAudioEngine
    private let trackAnalyzer: TrackAnalyzer
    private let crossfader: Crossfader
    private let config: AudioConfig

    // MARK: - OpenMix Integration

    private let openMixBridge = OpenMixBridge()
    private var streamEngine: StreamAudioEngine?
    private var openMixImportURL: URL?

    // MARK: - Engine Log

    var engineLog: [String] = []
    private let maxLogLines = 30

    // MARK: - Lyrics

    var currentLyrics: [LrcLine] = []
    var nextLyrics: [LrcLine] = []
    var lyricsMode: LyricsMode = .off
    var currentLyricsTrackURL: URL?
    var lastLyricBadgeTrackID: String?
    var lastQualityTrackID: String?

    // Album pill state — owned by the view model so it survives tab switches.
    var albumPillVisible: Bool = false
    var albumPillTitle: String = ""
    var albumPillCover: NSImage?
    var albumPillHiRes: Bool = false
    var albumPillHiSoVisible: Bool = false
    var albumPillHiSoAlbumDir: String?
    var albumPillAlbumDir: String?
    var albumPillRevealTick: Int = 0
    private(set) var albumPillDelayPending: Bool = false
    private var albumPillDelayTask: Task<Void, Never>?

    // Quality / bitrate pill state — survives tab switches.
    var qualityPillsVisible: Bool = false
    var currentAudioMetadata: AudioFileMetadata?
    var currentAudioMetadataURL: URL?
    private var playlistFolderURL: URL?
    private var cueSheet: CueSheet?
    private var caPlaylist: CaPlaylist?
    private var albumCueArtists: [String: String] = [:]

    // MARK: - Artist Images

    var artistImages: [NSImage] = []
    var currentArtistImage: NSImage?
    private var artistImageIndex: Int = 0

    // MARK: - Animated Background (GIF / Video)

    var gifFrames: [NSImage] = []
    var gifFrameDurations: [Double] = []
    var isGifPlaying: Bool = false
    private var gifFrameIndex: Int = 0
    private var gifDirection: Int = 1  // 1 = forward, -1 = backward
    private var gifTimer: Timer?

    // MP4/MOV boomerang via AVPlayer
    var videoPlayer: AVPlayer?
    private var videoBoomerangForward = true
    private var videoObservation: Any?

    // Multi-artist video playlist
    var artistVideoURLs: [URL] = []
    private var artistVideoIndex: Int = 0
    private var profileSoundPlayer: AVAudioPlayer?

    var currentTrackHasLrc: Bool {
        guard let url = mixQueue?.currentTrack?.url else { return false }
        return hasLyric(for: url)
    }

    func hasLyric(for url: URL) -> Bool {
        guard let folder = playlistFolderURL else { return false }
        let lrcName = url.deletingPathExtension().lastPathComponent + ".lrc"
        let albumDir = url.deletingLastPathComponent()
        let candidates = [
            albumDir.appendingPathComponent("lrc").appendingPathComponent(lrcName),
            folder.appendingPathComponent("lrc").appendingPathComponent(lrcName),
            folder.appendingPathComponent(lrcName)
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    func hasLyric(for track: TrackAsset) -> Bool {
        hasLyric(for: track.url)
    }

    var isTransitioning: Bool {
        playerState == .autoMix
    }

    // MARK: - Computed Properties

    var playlistCount: Int { mixQueue?.count ?? 0 }
    var hasTracks: Bool { mixQueue?.isEmpty == false }

    var activeEngine: String {
        if streamEngine != nil { return "OpenMix" }
        return "Real-Time"
    }

    func log(_ message: String) {
        let ts = String(format: "%.1f", Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100))
        engineLog.append("[\(ts)] \(message)")
        if engineLog.count > maxLogLines {
            engineLog.removeFirst(engineLog.count - maxLogLines)
        }
    }

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
        startAlbumPillObservation()
    }

    deinit {
        animationTimer?.invalidate()
        temporaryPatternTimer?.invalidate()
        nowPlayingTimer?.invalidate()
        moodTransitionTimer?.invalidate()
        gifTimer?.invalidate()
        if let obs = videoObservation {
            NotificationCenter.default.removeObserver(obs)
        }
        openMixBridge.stop()
        streamEngine?.stop()
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
            self?.syncPlaybackTime()
            self?.updateNowPlayingInfo()
        }
    }

    private func syncPlaybackTime() {
        currentTime = audioEngine.currentTime
        currentDuration = audioEngine.duration
    }

    // MARK: - Playback Info

    var currentTime: TimeInterval = 0
    var currentDuration: TimeInterval = 0

    func seekTo(time: TimeInterval) {
        guard playerState == .playing || playerState == .paused else { return }
        guard let queue = mixQueue, !queue.isEmpty else { return }
        let clamped = max(0, min(time, audioEngine.duration))
        audioEngine.seek(to: clamped)
        syncPlaybackTime()
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

    /// Tracks in the same album folder as the currently playing track.
    var albumSongs: [TrackAsset] {
        guard let dir = albumPillAlbumDir, let queue = mixQueue else { return [] }
        return queue.tracks.filter { $0.url.deletingLastPathComponent().path == dir }
    }

    /// All albums present in the loaded queue, each with its songs.
    var albums: [AlbumGroup] {
        guard let queue = mixQueue else { return [] }
        var order: [String] = []
        var groups: [String: [TrackAsset]] = [:]
        for track in queue.tracks {
            let dir = track.url.deletingLastPathComponent().path
            if groups[dir] == nil { order.append(dir) }
            groups[dir, default: []].append(track)
        }
        return order.map { dir in
            let songs = groups[dir] ?? []
            let name = songs.first?.albumName ?? URL(fileURLWithPath: dir).lastPathComponent
            return AlbumGroup(name: name, dir: dir, songs: songs)
        }
    }

    /// Crossfade (OpenMix) from the current track straight to a chosen album song.
    func crossfadeToTrack(at index: Int) {
        guard var queue = mixQueue, index >= 0, index < queue.tracks.count else { return }
        guard index != queue.currentIndex, let outgoing = queue.currentTrack else { return }
        cancelPendingMoodTransition()

        let incoming = queue.tracks[index]
        playerState = .autoMix

        let params = crossfader.computeCrossfadeParams(
            outgoing: outgoing,
            incoming: incoming
        )

        let started = audioEngine.crossfadeToNext(
            outgoingURL: outgoing.url,
            incomingURL: incoming.url,
            crossfader: crossfader,
            params: params,
            outgoingAnalysis: outgoing.analysis,
            incomingAnalysis: incoming.analysis
        )
        guard started else { return }

        queue.currentIndex = index
        mixQueue = queue

        DispatchQueue.main.asyncAfter(deadline: .now() + params.duration) { [weak self] in
            if self?.playerState == .autoMix {
                self?.playerState = .playing
                self?.stopAnimationLoop()
                self?.startAnimationLoop()
                self?.loadLyrics(for: queue.currentTrack?.url ?? incoming.url)
            }
        }

        updateNowPlayingInfo()
    }

    // MARK: - Album Pill

    /// Observation-based auto-sync: recomputes the pill whenever playback state
    /// or the current track changes, regardless of which view is mounted. This
    /// covers imports that set the track while the Cella tab isn't visible.
    private func registerAlbumPillObservation() {
        withObservationTracking(
            { _ = self.playerState; _ = self.mixQueue?.currentTrack?.url },
            onChange: { [weak self] in
                Task { @MainActor in
                    self?.handleAlbumPillDependencyChange()
                }
            }
        )
    }

    @MainActor
    private func handleAlbumPillDependencyChange() {
        print("[AlbumPill] observation fired: state=\(playerState) track=\(mixQueue?.currentTrack?.fileName ?? "nil") pending=\(albumPillDelayPending)")
        registerAlbumPillObservation()
        syncAlbumPillState()
    }

    func startAlbumPillObservation() {
        registerAlbumPillObservation()
    }

    /// Called when a track is chosen from the Config queue. Hides the album pill
    /// and schedules its reveal 1s later, so it slides in left-to-right once the
    /// user returns to the Cella tab.
    func requestAlbumPillDelayedReveal() {
        albumPillDelayTask?.cancel()
        albumPillDelayPending = true
        withAnimation(.smooth(duration: 0.5)) {
            albumPillVisible = false
        }
        albumPillDelayTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                albumPillDelayPending = false
                albumPillDelayTask = nil
                albumPillRevealTick += 1
                self.syncAlbumPillState()
            }
        }
    }

    /// Recomputes album pill visibility from current playback state.
    /// Hidden while OpenMix is mid-crossfade or no track is loaded.
    func syncAlbumPillState() {
        // A config-queue delayed reveal is in flight — let its tick finish
        // instead of overriding it with an immediate recompute.
        guard albumPillDelayTask == nil else { return }
        guard playerState != .autoMix, let track = mixQueue?.currentTrack else {
            print("[AlbumPill] sync HIDE: state=\(playerState) track=\(mixQueue?.currentTrack?.fileName ?? "nil")")
            withAnimation(.smooth(duration: 0.5)) {
                albumPillVisible = false
            }
            return
        }
        albumPillTitle = track.albumName ?? track.url.deletingLastPathComponent().lastPathComponent
        albumPillCover = Self.albumPillCover(for: track.url.deletingLastPathComponent())
        albumPillHiRes = Self.isAllWavAlbum(for: track.url.deletingLastPathComponent())
        let albumDir = track.url.deletingLastPathComponent().path
        if albumPillAlbumDir != albumDir {
            // New album — reset Hi-So reveal so it waits its 5s again
            albumPillAlbumDir = albumDir
            albumPillHiSoVisible = false
            albumPillHiSoAlbumDir = nil
        }
        print("[AlbumPill] sync SHOW: title=\(albumPillTitle) hiRes=\(albumPillHiRes)")
        withAnimation(.smooth(duration: 0.5)) {
            albumPillVisible = true
        }
    }

    /// Whether every audio file in the album folder is WAV (Hi-Res badge).
    static func isAllWavAlbum(for albumDir: URL) -> Bool {
        let audioExtensions = Set(["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"])
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: albumDir, includingPropertiesForKeys: nil
        )) ?? []
        let audioFiles = contents.filter {
            audioExtensions.contains($0.pathExtension.lowercased())
        }
        guard !audioFiles.isEmpty else { return false }
        return audioFiles.allSatisfy { $0.pathExtension.lowercased() == "wav" }
    }

    /// Locates the album folder image (cover.jpg, folder.jpg, or first image).
    static func albumPillCover(for albumDir: URL) -> NSImage? {
        let names = ["cover", "folder", "front", "album", "art", "default", "small"]
        let exts = ["jpg", "jpeg", "png", "webp", "tiff", "bmp"]
        let capNames = names.map { $0.capitalized }

        var candidates: [URL] = []
        for n in names + capNames {
            for e in exts {
                candidates.append(albumDir.appendingPathComponent("\(n).\(e)"))
            }
        }
        for c in candidates where FileManager.default.fileExists(atPath: c.path) {
            if let img = NSImage(contentsOf: c) { return img }
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: albumDir, includingPropertiesForKeys: nil
        ) else { return nil }
        let images = contents.filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        for f in images {
            if let img = NSImage(contentsOf: f) { return img }
        }
        return nil
    }

    // MARK: - Actions

    func setVolume(_ volume: Float) {
        currentVolume = volume
        audioEngine.smoothVolume(to: volume)
    }

    func setVolumeImmediate(_ volume: Float) {
        currentVolume = volume
        audioEngine.setVolumeImmediate(volume)
    }

    /// Scroll-driven volume: engine updates immediately, UI throttled to 60Hz to avoid stuttering video
    private var pendingScrollVolume: Float?
    private var lastScrollVolumeTime: CFAbsoluteTime = 0

    func setVolumeForScroll(_ volume: Float) {
        let v = min(1, max(0, volume))
        audioEngine.setVolumeImmediate(v)
        let now = CFAbsoluteTimeGetCurrent()
        // Coalesce UI updates to ~30Hz so SwiftUI doesn't thrash every scroll delta
        if now - lastScrollVolumeTime > 0.033 {
            lastScrollVolumeTime = now
            currentVolume = v
            pendingScrollVolume = nil
        } else {
            pendingScrollVolume = v
            // Flush pending on next frame
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard let self, let pending = self.pendingScrollVolume else { return }
                self.pendingScrollVolume = nil
                self.lastScrollVolumeTime = CFAbsoluteTimeGetCurrent()
                self.currentVolume = pending
            }
        }
    }

    func setHallReverb(_ enabled: Bool) {
        audioEngine.setHallReverb(enabled)
    }

    func applyAudioProfile(_ profile: AudioProfile) {
        let isNew = profile != currentAudioProfile
        currentAudioProfile = profile
        audioEngine.applyProfileEQ(profile)
        if profile == .airpodsMax && isNew {
            playProfileSound()
        }
    }

    private func playProfileSound() {
        guard let url = Bundle.main.url(forResource: "airpodsMaxOnline", withExtension: "m4a") else { return }
        profileSoundPlayer = try? AVAudioPlayer(contentsOf: url)
        profileSoundPlayer?.volume = 0.8
        profileSoundPlayer?.play()
    }

    private func restoreAudioSettings() {
        audioEngine.applyProfileEQ(currentAudioProfile)
    }

    private func loadTrackAndRestore(url: URL, rate: Float = 1.0, barTimestamps: [Double] = [], analysis: TrackAnalysis? = nil) throws {
        try audioEngine.loadTrack(url: url, rate: rate, barTimestamps: barTimestamps, analysis: analysis)
        restoreAudioSettings()
        loadLyrics(for: url)
    }

    // MARK: - Lyrics

    private func loadLyrics(for trackURL: URL) {
        guard let folder = playlistFolderURL else {
            currentLyrics = []
            nextLyrics = []
            return
        }

        let lrcName = trackURL.deletingPathExtension().lastPathComponent + ".lrc"

        // Find lrc file: try album's lrc/ subfolder first, then root lrc/, then legacy (same dir)
        let albumDir = trackURL.deletingLastPathComponent()
        let candidates = [
            albumDir.appendingPathComponent("lrc").appendingPathComponent(lrcName),
            folder.appendingPathComponent("lrc").appendingPathComponent(lrcName),
            folder.appendingPathComponent(lrcName)
        ]

        var found = false
        for lrcURL in candidates where FileManager.default.fileExists(atPath: lrcURL.path) {
            let result = LrcParser.load(from: lrcURL)
            currentLyrics = result.lines
            currentLyricsTrackURL = trackURL
            print("[PlayerViewModel] Loaded lyrics: \(currentLyrics.count) lines from \(lrcURL.lastPathComponent)")
            found = true
            break
        }
        if !found {
            currentLyrics = []
            currentLyricsTrackURL = nil
        }

        // Preload next track lyrics for transition fusion
        if let nextTrack = mixQueue?.nextTrack {
            let nextLrcName = nextTrack.url.deletingPathExtension().lastPathComponent + ".lrc"
            let nextAlbumDir = nextTrack.url.deletingLastPathComponent()
            let nextCandidates = [
                nextAlbumDir.appendingPathComponent("lrc").appendingPathComponent(nextLrcName),
                folder.appendingPathComponent("lrc").appendingPathComponent(nextLrcName),
                folder.appendingPathComponent(nextLrcName)
            ]
            var nextFound = false
            for lrcURL in nextCandidates where FileManager.default.fileExists(atPath: lrcURL.path) {
                nextLyrics = LrcParser.load(from: lrcURL).lines
                nextFound = true
                break
            }
            if !nextFound { nextLyrics = [] }
        } else {
            nextLyrics = []
        }

        // Reload artist images/videos for this track's artists
        if let folder = playlistFolderURL {
            loadArtistImages(from: folder)
        }
    }

    // MARK: - Artist Images

    private func loadArtistImages(from folder: URL) {
        let cmaDir = folder.appendingPathComponent("cma")
        guard FileManager.default.fileExists(atPath: cmaDir.path) else {
            artistImages = []
            currentArtistImage = nil
            artistVideoURLs = []
            stopGifAnimation()
            return
        }

        let allExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "tiff", "bmp", "mp4", "mov", "cma"])
        let animatedExtensions = Set(["gif", "mp4", "mov", "cma"])
        let staticExtensions = Set(["jpg", "jpeg", "png", "webp", "tiff", "bmp"])

        // Get artist names from .ca metadata, then album CUE files, then filename parsing
        var trackArtists: [String] = []

        // .ca is authoritative — split "Artist 1 & Artist 2" into separate names
        if let track = mixQueue?.currentTrack, !track.artists.isEmpty {
            trackArtists = track.artists.map { $0.lowercased() }
        } else if let trackURL = mixQueue?.currentTrack?.url {
            let fileName = trackURL.lastPathComponent
            if let artist = albumCueArtists[fileName], !artist.isEmpty {
                trackArtists.append(artist)
            }
        }

        // Fallback: parse from filename
        if trackArtists.isEmpty, let trackName = mixQueue?.currentTrack?.fileName {
            if let separatorIndex = trackName.range(of: " - ")?.lowerBound {
                let mainPart = String(trackName[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
                for name in mainPart.components(separatedBy: " & ") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { trackArtists.append(trimmed.lowercased()) }
                }
            }
        }

        print("[PlayerViewModel] CMA artists: \(trackArtists)")

        // Scan cma/ directory
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: cmaDir, includingPropertiesForKeys: nil
        )) ?? []

        let allFiles = contents.filter {
            allExtensions.contains($0.pathExtension.lowercased())
        }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

        let animatedFiles = allFiles.filter { animatedExtensions.contains($0.pathExtension.lowercased()) }
        let staticFiles = allFiles.filter { staticExtensions.contains($0.pathExtension.lowercased()) }

        // Match artist names to video/image files in cma/<artist>/ subfolders
        artistVideoURLs = []
        let videoExtensions = Set(["mp4", "mov", "cma"])

        for artist in trackArtists {
            // Try various folder name formats: "artist", "Artist", "artist-name"
            let candidates = [
                cmaDir.appendingPathComponent(artist),
                cmaDir.appendingPathComponent(artist.split(separator: " ").map(\.capitalized).joined(separator: " ")),
                cmaDir.appendingPathComponent(artist.replacingOccurrences(of: " ", with: "-")),
                cmaDir.appendingPathComponent(artist.replacingOccurrences(of: " ", with: "_"))
            ]
            for dir in candidates where FileManager.default.fileExists(atPath: dir.path) {
                let subContents = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil
                )) ?? []
                let videos = subContents.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                artistVideoURLs.append(contentsOf: videos)

                // Also grab static images from artist subfolder
                let images = subContents.filter { staticExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                if !images.isEmpty {
                    artistImages = images.compactMap { NSImage(contentsOf: $0) }
                }
            }
        }

        // Fallback: flat files in cma/ matching artist name
        if artistVideoURLs.isEmpty {
            for videoURL in animatedFiles where videoURL.pathExtension.lowercased() != "gif" {
                let videoName = videoURL.deletingPathExtension().lastPathComponent
                    .lowercased()
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                let matched = trackArtists.contains { artist in
                    let normalized = artist.replacingOccurrences(of: "-", with: " ")
                        .replacingOccurrences(of: "_", with: " ")
                    return videoName == normalized
                }
                if matched { artistVideoURLs.append(videoURL) }
            }
        }

        // Fallback: if no match, use all videos
        if artistVideoURLs.isEmpty {
            artistVideoURLs = animatedFiles.filter { $0.pathExtension.lowercased() != "gif" }
        }
        artistVideoIndex = 0

        // Load static images (if not already loaded from subfolder)
        if artistImages.isEmpty {
            artistImages = staticFiles.compactMap { NSImage(contentsOf: $0) }
        }
        artistImageIndex = 0

        // Load animated frames (priority: first matching GIF, then first video)
        stopGifAnimation()
        destroyVideoPlayback()
        gifFrames = []
        gifFrameDurations = []

        if let gifURL = animatedFiles.first(where: { $0.pathExtension.lowercased() == "gif" }) {
            loadGifFrames(from: gifURL)
        } else if let firstVideo = artistVideoURLs.first {
            loadVideoPlayer(from: firstVideo)
        }

        // Set initial image: prefer animated, fallback to static
        if !gifFrames.isEmpty {
            currentArtistImage = gifFrames.first
            startGifAnimation()
            print("[PlayerViewModel] Loaded animated GIF: \(gifFrames.count) frame(s)")
        } else if videoPlayer != nil {
            currentArtistImage = nil
            if playerState == .playing || playerState == .autoMix {
                startVideoPlayback()
            }
            print("[PlayerViewModel] Loaded video background (\(artistVideoURLs.count) artist video(s))")
        } else {
            currentArtistImage = artistImages.first
        }

        let totalStatic = artistImages.count
        let totalAnimated = gifFrames.count
        if totalStatic > 0 || totalAnimated > 0 {
            print("[PlayerViewModel] Loaded \(totalStatic) image(s), \(totalAnimated) animated frame(s)")
        }
    }

    private func cycleArtistImage() {
        // If animated (GIF/video) is playing, don't cycle static images
        guard gifFrames.isEmpty, videoPlayer == nil else { return }
        guard !artistImages.isEmpty else { return }
        currentArtistImage = artistImages[artistImageIndex % artistImages.count]
        artistImageIndex += 1
    }

    // MARK: - GIF Loading & Boomerang

    private func loadGifFrames(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else {
            // Single-frame GIF, treat as static
            if let image = NSImage(contentsOf: url) {
                gifFrames = [image]
                gifFrameDurations = [0.1]
            }
            return
        }

        var frames: [NSImage] = []
        var durations: [Double] = []

        for i in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            frames.append(nsImage)

            // Extract frame duration from GIF metadata
            let duration = gifFrameDuration(source: source, index: i)
            durations.append(duration)
        }

        gifFrames = frames
        gifFrameDurations = durations
        gifFrameIndex = 0
        gifDirection = 1
    }

    private func gifFrameDuration(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let gifDict = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] else {
            return 0.1 // default
        }

        // Try unclamped delay time first, then delay time
        if let unclamped = gifDict[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double, unclamped > 0 {
            return unclamped
        }
        if let delay = gifDict[kCGImagePropertyGIFDelayTime as String] as? Double, delay > 0 {
            return delay
        }
        return 0.1
    }

    // MARK: - Video Playback (MP4/MOV/CMA via AVPlayer)

    /// Resolve .cma files to temp .mp4 copies for AVPlayer compatibility
    private func resolveForPlayer(_ url: URL) -> URL {
        guard url.pathExtension.lowercased() == "cma" else { return url }
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpURL = tmpDir.appendingPathComponent("cella_\(url.lastPathComponent.replacingOccurrences(of: ".cma", with: ""))_\(url.hashValue).mp4")
        if !FileManager.default.fileExists(atPath: tmpURL.path) {
            try? FileManager.default.copyItem(at: url, to: tmpURL)
        }
        return tmpURL
    }

    private func loadVideoPlayer(from url: URL) {
        stopVideoPlayback()

        let resolved = artistVideoURLs.map { resolveForPlayer($0) }

        if resolved.count > 1 {
            // Multi-artist: use AVQueuePlayer for seamless transitions
            let items = resolved.map { AVPlayerItem(url: $0) }
            let queuePlayer = AVQueuePlayer(items: items)
            queuePlayer.isMuted = true
            queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
            self.videoPlayer = queuePlayer

            // Track current item index for looping
            artistVideoIndex = 0

            // Observe when current item ends → advance or loop
            videoObservation = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                self.artistVideoIndex += 1
                if self.artistVideoIndex >= items.count {
                    // All videos played — re-insert all items and restart
                    self.artistVideoIndex = 0
                    for item in items { item.seek(to: .zero) }
                    queuePlayer.removeAllItems()
                    for item in items { queuePlayer.insert(item, after: nil) }
                    queuePlayer.seek(to: .zero)
                    queuePlayer.play()
                }
            }

            print("[PlayerViewModel] Loaded \(items.count) artist videos via queue player")
        } else {
            // Single video: simple AVPlayer with loop
            let resolvedURL = resolved.first ?? url
            let playerItem = AVPlayerItem(url: resolvedURL)
            let player = AVPlayer(playerItem: playerItem)
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            self.videoPlayer = player

            videoObservation = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { [weak self] _ in
                self?.videoPlayer?.seek(to: .zero) { _ in
                    self?.videoPlayer?.play()
                }
            }

            print("[PlayerViewModel] Loaded video: \(url.lastPathComponent)")
        }
    }

    func startVideoPlayback() {
        guard let player = videoPlayer else { return }
        if let queuePlayer = player as? AVQueuePlayer {
            queuePlayer.seek(to: .zero)
            queuePlayer.play()
        } else {
            player.seek(to: .zero)
            player.play()
        }
    }

    func stopVideoPlayback() {
        // Just pause — keep the player alive for next track
        videoPlayer?.pause()
    }

    func destroyVideoPlayback() {
        // Full teardown — only when loading new folder
        if let obs = videoObservation {
            NotificationCenter.default.removeObserver(obs)
            videoObservation = nil
        }
        videoPlayer?.pause()
        videoPlayer = nil
    }

    private func boomerangSeek() {
        guard let player = videoPlayer, let item = player.currentItem else { return }
        let duration = item.duration
        guard duration.isValid, !duration.isIndefinite else { return }

        if videoBoomerangForward {
            // Finished forward → seek to start, play again
            videoBoomerangForward = false
            player.seek(to: CMTime.zero) { [weak self] _ in
                self?.videoBoomerangForward = true
                self?.videoPlayer?.play()
            }
        }
    }

    // MARK: - Boomerang Animation

    func startGifAnimation() {
        guard !gifFrames.isEmpty, gifTimer == nil else { return }
        isGifPlaying = true
        scheduleNextGifFrame()
    }

    func stopGifAnimation() {
        gifTimer?.invalidate()
        gifTimer = nil
        isGifPlaying = false
        gifFrameIndex = 0
        gifDirection = 1
    }

    private func scheduleNextGifFrame() {
        guard !gifFrames.isEmpty else { return }

        let duration = gifFrameDurations[gifFrameIndex]
        gifTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.advanceGifFrame()
        }
    }

    private func advanceGifFrame() {
        guard !gifFrames.isEmpty else { return }

        // Boomerang: go forward then backward
        gifFrameIndex += gifDirection

        if gifFrameIndex >= gifFrames.count {
            // Reached end — reverse direction
            gifDirection = -1
            gifFrameIndex = gifFrames.count - 2
        } else if gifFrameIndex < 0 {
            // Reached start — reverse direction
            gifDirection = 1
            gifFrameIndex = 1
        }

        // Clamp safety
        gifFrameIndex = max(0, min(gifFrameIndex, gifFrames.count - 1))

        currentArtistImage = gifFrames[gifFrameIndex]

        scheduleNextGifFrame()
    }

    func togglePlayPause() {
        switch playerState {
        case .playing:
            playerState = .paused
            audioEngine.pause()
            stopAnimationLoop()
            syncPlaybackTime()

        case .paused:
            guard let queue = mixQueue, !queue.isEmpty else { return }
            playerState = .playing
            audioEngine.play()
            syncPlaybackTime()
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
                    // Load lyrics AFTER transition completes
                    self?.loadLyrics(for: queue.currentTrack?.url ?? nextTrack.url)
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

    /// Builds a TrackAsset, attaching title / artist / album name from the .ca playlist
    /// when the audio file has a matching entry. Falls back to filename parsing otherwise.
    private func makeTrackAsset(from url: URL, playlist: CaPlaylist?) -> TrackAsset {
        var track = TrackAsset(url: url)
        guard let playlist else { return track }
        if let album = CaParser.albumInfo(for: url, playlist: playlist) {
            track.albumName = album.name
        }
        if let info = CaParser.trackInfo(for: url, playlist: playlist) {
            track.title = info.title
            track.artist = info.artist
        }
        return track
    }

    func importFolder(url: URL) {
        // Only accept .cella folders
        guard url.pathExtension.lowercased() == "cella" else {
            importError = "Not a .cella playlist. Rename folder with .cella extension."
            return
        }

        importError = nil
        analysisProgress = 0
        playlistFolderURL = url
        artistImages = []
        currentArtistImage = nil
        loadArtistImages(from: url)

        print("[PlayerViewModel] importFolder called: \(url.path)")

        let audioExtensions = ["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"]

        // Move directory listing + validation off main thread
        Task.detached { [weak self] in
            guard let self else { return }
            let fileManager = FileManager.default
            let contents = (try? fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil
            )) ?? []

            // Read .ca file for album structure
            let caFiles = contents.filter { $0.pathExtension.lowercased() == "ca" }
            var parsedCa: CaPlaylist?
            if let caURL = caFiles.first, let playlist = CaParser.load(from: caURL) {
                print("[PlayerViewModel] .ca playlist: \(playlist.name ?? "?"), \(playlist.albums.count) albums")
                parsedCa = playlist
            }

            // Collect audio files
            var audioFiles: [URL] = []

            if let playlist = parsedCa {
                audioFiles = CaParser.audioFiles(from: playlist, in: url)
            }

            if audioFiles.isEmpty {
                audioFiles = contents.filter {
                    audioExtensions.contains($0.pathExtension.lowercased())
                }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

                if audioFiles.isEmpty {
                    let subfolders = contents.filter { $0.hasDirectoryPath }
                    for subfolder in subfolders {
                        let subContents = (try? fileManager.contentsOfDirectory(
                            at: subfolder, includingPropertiesForKeys: nil
                        )) ?? []
                        let subAudio = subContents.filter {
                            audioExtensions.contains($0.pathExtension.lowercased())
                        }
                        audioFiles.append(contentsOf: subAudio)
                    }
                }
            }

            // Scan album subfolders for CUE files and build artist mapping
            var parsedAlbumCueArtists: [String: String] = [:]
            let subfolders = contents.filter { $0.hasDirectoryPath }
            for subfolder in subfolders {
                let subContents = (try? fileManager.contentsOfDirectory(
                    at: subfolder, includingPropertiesForKeys: nil
                )) ?? []
                let subCueFiles = subContents.filter { $0.pathExtension.lowercased() == "cue" }
                for cueURL in subCueFiles {
                    if let sheet = CueParser.load(from: cueURL) {
                        for track in sheet.tracks {
                            parsedAlbumCueArtists[track.fileName] = track.performer.lowercased()
                        }
                    }
                }
            }
            print("[PlayerViewModel] Album CUE artists: \(parsedAlbumCueArtists)")

            // Also check root CUE
            let cueFiles = contents.filter { $0.pathExtension.lowercased() == "cue" }
            var orderedFiles = audioFiles
            var parsedCue: CueSheet?
            if let cueURL = cueFiles.first, let sheet = CueParser.load(from: cueURL) {
                print("[PlayerViewModel] CUE sheet: \(sheet.trackCount) tracks")
                parsedCue = sheet
                for track in sheet.tracks {
                    parsedAlbumCueArtists[track.fileName] = track.performer.lowercased()
                }
                orderedFiles = sheet.trackOrder(for: audioFiles)
            }

            print("[PlayerViewModel] Audio files found: \(orderedFiles.count)")

            guard !orderedFiles.isEmpty else {
                await MainActor.run {
                    self.importError = "No audio files found in folder"
                    print("[PlayerViewModel] ERROR: No audio files found")
                }
                return
            }

            // Validate off main thread — reads audio headers, not full files
            var validTracks: [TrackAsset] = []
            for rawURL in orderedFiles {
                let rawTrack = self.makeTrackAsset(from: rawURL, playlist: parsedCa)
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
                self.cueSheet = parsedCue
                self.caPlaylist = parsedCa
                self.albumCueArtists = parsedAlbumCueArtists
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
                    self.audioEngine.play()
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
        log("Track ended: \(currentName)")

        // Crossfade to next track automatically
        if let nextTrack = queue.nextTrack,
           let outgoingTrack = queue.currentTrack {
            let nextName = nextTrack.fileName
            log("Crossfading to: \(nextName)")

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
                    self?.log("Now playing: \(nextName)")
                    // Load lyrics AFTER transition completes
                    self?.loadLyrics(for: queue.currentTrack?.url ?? nextTrack.url)
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
        let baseSpeed = currentMood.animationSpeed
        let speed = powerManager.isPluggedIn ? baseSpeed * 0.5 : baseSpeed
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

        startGifAnimation()
        startVideoPlayback()
    }

    private func stopAnimationLoop() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationFrame = 0
        animatedPattern = MatrixPatterns.smileyFace
        stopGifAnimation()
        stopVideoPlayback()
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

    // MARK: - OpenMix Streaming Integration

    func importViaOpenMix(url: URL) {
        // Only accept .cella folders
        guard url.pathExtension.lowercased() == "cella" else {
            importError = "Not a .cella playlist. Rename folder with .cella extension."
            return
        }

        // Stop any existing playback and clear old state
        cancelPendingMoodTransition()
        stopAnimationLoop()
        audioEngine.stop()
        openMixBridge.stop()
        streamEngine?.stop()
        streamEngine = nil
        playlistFolderURL = url
        artistImages = []
        currentArtistImage = nil
        loadArtistImages(from: url)

        importError = nil
        analysisProgress = 0
        openMixImportURL = url

        print("[PlayerViewModel] Import via OpenMix: \(url.path)")

        let audioExtensions = ["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"]
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )) ?? []

        // Read .ca file for album structure
        let caFiles = contents.filter { $0.pathExtension.lowercased() == "ca" }
        if let caURL = caFiles.first, let playlist = CaParser.load(from: caURL) {
            print("[PlayerViewModel] .ca playlist: \(playlist.name ?? "?"), \(playlist.albums.count) albums")
            caPlaylist = playlist
        } else {
            caPlaylist = nil
        }

        // Collect audio files: from .ca album folders, or scan subfolders, or root
        var audioFiles: [URL] = []

        if let playlist = caPlaylist {
            // Use .ca structure: scan each album subfolder
            audioFiles = CaParser.audioFiles(from: playlist, in: url)
            print("[PlayerViewModel] Found \(audioFiles.count) tracks from .ca albums")
        }

        if audioFiles.isEmpty {
            // Fallback: scan root for audio files (flat structure)
            audioFiles = contents.filter {
                audioExtensions.contains($0.pathExtension.lowercased())
            }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

            // Also scan one-level-deep subfolders for audio (album folders)
            if audioFiles.isEmpty {
                let subfolders = contents.filter { $0.hasDirectoryPath }
                for subfolder in subfolders {
                    let subContents = (try? fileManager.contentsOfDirectory(
                        at: subfolder, includingPropertiesForKeys: nil
                    )) ?? []
                    let subAudio = subContents.filter {
                        audioExtensions.contains($0.pathExtension.lowercased())
                    }
                    audioFiles.append(contentsOf: subAudio)
                }
            }
        }

        // Scan album subfolders for CUE files and build artist mapping
        albumCueArtists = [:]

        // Use .ca to know which albums exist, otherwise scan all subfolders
        var albumFolders: [URL] = []
        if let playlist = caPlaylist {
            for album in playlist.albums {
                let albumDir = url.appendingPathComponent(album.folder)
                if FileManager.default.fileExists(atPath: albumDir.path) {
                    albumFolders.append(albumDir)
                }
            }
        } else {
            albumFolders = contents.filter { $0.hasDirectoryPath }.map { url.appendingPathComponent($0.lastPathComponent) }
        }

        for albumDir in albumFolders {
            let subContents = (try? fileManager.contentsOfDirectory(
                at: albumDir, includingPropertiesForKeys: nil
            )) ?? []
            let cueFiles = subContents.filter { $0.pathExtension.lowercased() == "cue" }
            for cueURL in cueFiles {
                if let sheet = CueParser.load(from: cueURL) {
                    for track in sheet.tracks {
                        albumCueArtists[track.fileName] = track.performer.lowercased()
                    }
                }
            }
        }
        print("[PlayerViewModel] Album CUE artists: \(albumCueArtists)")

        // Also check root CUE
        let rootCueFiles = contents.filter { $0.pathExtension.lowercased() == "cue" }
        if let cueURL = rootCueFiles.first, let sheet = CueParser.load(from: cueURL) {
            cueSheet = sheet
            for track in sheet.tracks {
                albumCueArtists[track.fileName] = track.performer.lowercased()
            }
        } else {
            cueSheet = nil
        }

        // Order tracks using root CUE if available
        var orderedFiles = audioFiles
        if let sheet = cueSheet {
            orderedFiles = sheet.trackOrder(for: audioFiles)
        }

        guard orderedFiles.count >= 2 else {
            importError = "Need at least 2 audio files"
            return
        }

        totalTrackCount = orderedFiles.count
        analyzedTrackCount = 0

        let tracks = orderedFiles.map { makeTrackAsset(from: $0, playlist: caPlaylist) }
        mixQueue = MixQueue(
            tracks: tracks,
            transitions: [nil] + Array(repeating: nil, count: max(0, tracks.count - 1))
        )

        // Play first track immediately while OpenMix analyzes
        do {
            try loadTrackAndRestore(
                url: tracks[0].url,
                barTimestamps: tracks[0].analysis?.barTimestamps ?? []
            )
            audioEngine.play()
            playerState = .playing
            startAnimationLoop()
            print("[PlayerViewModel] Now playing: \(tracks[0].fileName)")
        } catch {
            print("[PlayerViewModel] Failed to start playback: \(error)")
        }

        openMixBridge.onStatus = { [weak self] status in
            self?.handleOpenMixStatus(status)
        }
        openMixBridge.onChunkReady = { [weak self] data in
            self?.handleOpenMixChunk(data)
        }

        streamEngine = StreamAudioEngine()

        openMixBridge.start()
        openMixBridge.analyze(tracks: audioFiles)
    }

    private func handleOpenMixStatus(_ status: OpenMixStatus) {
        switch status {
        case .ready:
            log("OpenMix ready")

        case .analyzingProgress(let current, let total, let file):
            analyzedTrackCount = current
            totalTrackCount = total
            analysisProgress = Double(current) / Double(total)
            playerState = .analyzing(progress: analysisProgress)
            log("Analyzing \(current)/\(total): \(file)")

        case .mixingProgress(let current, let total, let file):
            log("Mixing \(current)/\(total): \(file)")

        case .chunkReady(let index, let bytes, let progress):
            log("Chunk \(index) ready (\(bytes)B, \(Int(progress * 100))%)")
            if index == 2 {
                playerState = .playing
                streamEngine?.startPlayback()
            }

        case .analysisDone(let tracks):
            log("Analysis done: \(tracks.count) tracks")
            applyOpenMixAnalysis(tracks)
            // Now trigger mix with auto-order
            let order = Array(0..<tracks.count)
            openMixBridge.mix(order: order)

        case .done(let duration):
            log("Mix done — \(String(format: "%.1f", duration))s")
            playerState = .playing

        case .error(let message):
            log("Error: \(message)")
            openMixBridge.stop()
            streamEngine?.stop()
            streamEngine = nil

            if let url = openMixImportURL {
                log("Falling back to real-time engine")
                openMixImportURL = nil
                importFolder(url: url)
            } else {
                importError = message
            }

        case .cancelled:
            log("Cancelled")
        }
    }

    private func handleOpenMixChunk(_ data: Data) {
        streamEngine?.scheduleChunk(data)
    }

    func cancelOpenMix() {
        openMixBridge.stop()
        streamEngine?.stop()
        streamEngine = nil
    }

    // MARK: - OpenMix Analysis Sync

    private func applyOpenMixAnalysis(_ tracks: [[String: Any]]) {
        guard var queue = mixQueue else { return }

        for trackData in tracks {
            guard let path = trackData["path"] as? String,
                  let fileName = trackData["file"] as? String else { continue }

            let fileNameNoExt = (fileName as NSString).deletingPathExtension

            guard let index = queue.tracks.firstIndex(where: { $0.url.path == path || $0.fileName == fileNameNoExt }) else { continue }

            let tempo = trackData["tempo"] as? Double ?? 120.0
            let keyName = trackData["key"] as? String ?? "C"
            let duration = trackData["duration"] as? Double ?? 0
            let energyArray = trackData["energy"] as? [Double] ?? []
            let introEnd = trackData["intro_end"] as? Double ?? 0
            let outroStart = trackData["outro_start"] as? Double ?? duration

            let energyFloat = energyArray.map { Float($0) }

            let analysis = TrackAnalysis(
                bpm: tempo,
                beatTimestamps: [],
                barTimestamps: [],
                keySignature: TrackAnalysis.KeySignature(tonic: keyName, mode: "major"),
                loudnessIntegrated: nil,
                structureSections: [],
                energyProfile: energyFloat,
                hasVocals: false,
                vocalActivity: [],
                duration: duration,
                spectralCentroid: 0,
                spectralRolloff: 0,
                spectralBandwidth: 0,
                spectralFlatness: 0,
                averageRMS: Float(trackData["energy_avg"] as? Double ?? 0),
                peakAmplitude: 0,
                introRegion: introEnd > 0 ? (start: 0, end: introEnd) : nil,
                outroRegion: outroStart < duration ? (start: outroStart, end: duration) : nil,
                vocalOnsetTimestamps: [],
                vocalOffsetTimestamps: []
            )

            queue.tracks[index].analysis = analysis
        }

        mixQueue = queue

        log("Analysis synced to \(queue.tracks.filter { $0.analysis != nil }.count) tracks")
    }

}
