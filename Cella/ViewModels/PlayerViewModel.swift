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
    private var playbackTimer: Timer?
    private var currentMood: MusicMood = .neutral
    private var animationFrame: Int = 0
    private var moodTransitionTimer: Timer?
    private var pendingMood: MusicMood?
    private let powerManager = PowerManager.shared

    var currentPreset: OrquestaPreset = .natural

    // MARK: - Automix Components

    var mixQueue: MixQueue?
    private let audioEngine: MixAudioEngine
    private let trackAnalyzer: TrackAnalyzer
    private let crossfader: Crossfader
    private let config: AudioConfig

    // MARK: - Import State

    private var requestedStartFileName: String?
    private var cacheTask: Task<Void, Never>?

    /// Blend (smooth crossfade to) state. When set, the currently playing track
    /// keeps playing while the target pack is prepared; we crossfade directly
    /// into the requested track.
    private var blendSourceTrack: TrackAsset?
    private var blendPending = false

    // MARK: - Engine Log

    var engineLog: [String] = []
    private let maxLogLines = 30

    // MARK: - Lyrics

    var currentLyrics: [LrcLine] = []
    var nextLyrics: [LrcLine] = []
    var lyricsMode: LyricsMode = .off
    var currentLyricsTrackURL: URL?
    var highlightLyricIndex: Int? = nil
    var showLyricSwipe: Bool = false
    var lastLyricBadgeTrackID: String?
    var lastQualityTrackID: String?

    // Album pill state — owned by the view model so it survives tab switches.
    var albumPillVisible: Bool = false
    var albumPillTitle: String = ""
    var albumPillSourceName: String = ""
    var albumPillCover: NSImage?
    var albumPillHiRes: Bool = false
    var albumPillHiSoVisible: Bool = false
    var albumPillHiSoAlbumDir: String?
    var albumPillAlbumDir: String?
    var albumPillRevealTick: Int = 0
    private(set) var albumPillDelayPending: Bool = false
    private var albumPillDelayTask: Task<Void, Never>?
    var albumPickerVisible: Bool = false

    // Quality / bitrate pill state — survives tab switches.
    var qualityPillsVisible: Bool = false
    var currentAudioMetadata: AudioFileMetadata?
    var currentAudioMetadataURL: URL?
    private var playlistFolderURL: URL?
    private var cueSheet: CueSheet?
    private var cueTracksByFile: [String: CueTrack] = [:]
    private var cueAlbumNames: [String: String] = [:]
    private var albumCueArtists: [String: String] = [:]

    /// Artist mode: non-nil when queue filtered to single artist via Cluster Artist tab.
    /// Cella tab shows flat artist songs + Artist pill instead of albums.
    var activeArtistFilter: String?
    var activeArtistPackURL: URL?

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
            if soloMode { text = "Solo: \(trackName)" }
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
            return soloMode ? "Solo paused: \(trackName)" : "Paused: \(trackName)"
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
        playbackTimer?.invalidate()
        moodTransitionTimer?.invalidate()
        gifTimer?.invalidate()
        if let obs = videoObservation {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Setup

    private func setupTrackEndHandler() {
        audioEngine.onTrackEnd = { [weak self] in
            print("[PlayerViewModel] onTrackEnd callback fired")
            self?.handleTrackEnd()
        }
        audioEngine.onCrossfadeCompleted = { [weak self] in
            self?.completePendingSwitch()
        }
    }

    /// Runs the pending track-switch completion only once the engine has actually
    /// swapped players. Without this, the wall-clock asyncAfter could fire before
    /// the swap and index the new song's lyrics against the outgoing clock.
    private var pendingSwitchCompletion: (() -> Void)?

    private func completePendingSwitch() {
        guard let pending = pendingSwitchCompletion else { return }
        pendingSwitchCompletion = nil
        // Force-sync clock BEFORE state flip so lyrics index the new song immediately.
        syncPlaybackTime()
        pending()
    }

    private func startNowPlayingTimer() {
        nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateNowPlayingInfo()
        }
        // Fast playback-time sync (drives lyric lines, progress bar) — 20Hz
        // instead of the old 1Hz, so lyric changes appear immediately.
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.syncPlaybackTime()
        }
    }

    private func syncPlaybackTime() {
        let newTime = audioEngine.currentTime
        let newDuration = audioEngine.duration
        if abs(newTime - currentTime) > 2.0 {
            print("[TICK] currentTime jump \(String(format: "%.1f", currentTime)) -> \(String(format: "%.1f", newTime)) dur=\(String(format: "%.1f", newDuration)) state=\(playerState)")
        }
        currentTime = newTime
        currentDuration = newDuration
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

    // MARK: - LRC Insert

    private func resolveLrcURL(for trackURL: URL) -> URL? {
        guard let folder = playlistFolderURL else { return nil }
        let lrcName = trackURL.deletingPathExtension().lastPathComponent + ".lrc"
        let albumDir = trackURL.deletingLastPathComponent()
        let candidates = [
            albumDir.appendingPathComponent("lrc").appendingPathComponent(lrcName),
            folder.appendingPathComponent("lrc").appendingPathComponent(lrcName),
            folder.appendingPathComponent(lrcName)
        ]
        for lrcURL in candidates where FileManager.default.fileExists(atPath: lrcURL.path) {
            return lrcURL
        }
        return nil
    }

    private func resolveOrCreateLrcURL(for trackURL: URL) -> URL? {
        if let existing = resolveLrcURL(for: trackURL) { return existing }
        guard let folder = playlistFolderURL else { return nil }
        let albumDir = trackURL.deletingLastPathComponent()
        let lrcName = trackURL.deletingPathExtension().lastPathComponent + ".lrc"
        let lrcDir = albumDir.appendingPathComponent("lrc")
        if !FileManager.default.fileExists(atPath: lrcDir.path) {
            try? FileManager.default.createDirectory(at: lrcDir, withIntermediateDirectories: true)
        }
        return lrcDir.appendingPathComponent(lrcName)
    }

    private func lrcTimestamp(_ time: TimeInterval) -> String {
        let ms = Int((time * 100).truncatingRemainder(dividingBy: 100))
        let totalSec = Int(time)
        let sec = totalSec % 60
        let min = totalSec / 60
        return String(format: "%02d:%02d.%02d", min, sec, ms)
    }

    func insertBreak(at time: TimeInterval) -> Bool {
        return insertLyricLine(at: time, text: "...")
    }

    /// Palette command: drops a lyric line at the current time.
    /// `text` is what the user quoted in `addLy "…"`; empty falls back to the
    /// placeholder so a bare `addLy` still marks a spot to fill in later.
    func addLyric(at time: TimeInterval, text: String = "") -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return insertLyricLine(at: time, text: trimmed.isEmpty ? Self.lyricPlaceholder : trimmed)
    }

    static let lyricPlaceholder = "lyricGoeshere"

    private func insertLyricLine(at time: TimeInterval, text: String) -> Bool {
        guard let trackURL = mixQueue?.currentTrack?.url,
              let lrcURL = resolveOrCreateLrcURL(for: trackURL) else { return false }
        var lines = (try? String(contentsOf: lrcURL))?.components(separatedBy: .newlines) ?? []
        let newLine = "[\(lrcTimestamp(time))]\(text)"
        lines.append(newLine)
        let sorted = sortLrcLines(lines)
        try? sorted.joined(separator: "\n").write(to: lrcURL, atomically: true, encoding: .utf8)
        loadLyrics(for: trackURL)

        let insertedIndex = currentLyrics.firstIndex { abs($0.time - time) < 0.01 }
        highlightLyricIndex = insertedIndex
        showLyricSwipe = true
        return true
    }

    func insertInit() -> Bool {
        return insertBreak(at: 0)
    }

    private func sortLrcLines(_ lines: [String]) -> [String] {
        let parsed: [(String, TimeInterval)] = lines.map { line in
            let time = extractLrcTime(line)
            return (line, time)
        }
        return parsed.sorted { $0.1 < $1.1 }.map { $0.0 }
    }

    private func extractLrcTime(_ line: String) -> TimeInterval {
        guard let range = line.range(of: #"^\[[0-9:.]+\]"#, options: .regularExpression) else {
            return -1
        }
        let tag = String(line[range]).dropFirst().dropLast()
        let parts = tag.components(separatedBy: ":")
        guard parts.count == 2 else { return -1 }
        let minParts = parts[1].components(separatedBy: ".")
        guard let m = Double(parts[0]) else { return -1 }
        guard let s = Double(minParts[0]) else { return -1 }
        var ms: Double = 0
        if minParts.count > 1, let msVal = Double(minParts[1]) {
            ms = msVal / pow(10.0, Double(minParts[1].count))
        }
        return m * 60 + s + ms
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
            soloMode = false
            preSoloTracks = nil
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

    /// Solo Mode (S key in Cella): queue isolated to the current track only.
    /// At track end playback stops and the queue clears. Second S restores.
    var soloMode: Bool = false
    private var preSoloTracks: [TrackAsset]?
    private var preSoloIndex: Int = 0

    /// Isolate the current track (enter solo) or restore the stashed queue (exit solo).
    func toggleSolo() {
        guard playerState == .playing || playerState == .paused else { return }
        guard var queue = mixQueue, !queue.isEmpty, let current = queue.currentTrack else { return }
        if !soloMode {
            preSoloTracks = queue.tracks
            preSoloIndex = queue.currentIndex
            queue.tracks = [current]
            queue.currentIndex = 0
            mixQueue = queue
            soloMode = true
            // Play to the true end — no early crossfade trigger.
            audioEngine.playThroughToEnd()
            log("Solo on: \(current.fileName)")
        } else {
            if let saved = preSoloTracks, !saved.isEmpty {
                let url = current.url
                queue.tracks = saved
                queue.currentIndex = saved.firstIndex(where: { $0.url == url }) ?? min(preSoloIndex, saved.count - 1)
                mixQueue = queue
            }
            preSoloTracks = nil
            soloMode = false
            if playerState == .playing {
                audioEngine.resumeAutoCrossfade()
            } else {
                audioEngine.cancelSoloPlayThrough()
            }
            log("Solo off — queue restored")
        }
    }

    /// True when queue filtered to single artist (Cluster Artist play).
    var isArtistMode: Bool { activeArtistFilter != nil }

    /// Flat artist songs in pack order (queue already filtered, same order).
    var artistSongs: [TrackAsset] { mixQueue?.tracks ?? [] }

    /// Exit artist mode: re-import full pack. Auto-called on full pack play,
    /// manual via clear chip in Cella (both, per user choice).
    /// Library-wide (.cluster) mode just clears flag — queue stays, pill returns to album.
    func clearArtistFilter() {
        guard let url = activeArtistPackURL ?? playlistFolderURL else {
            activeArtistFilter = nil
            activeArtistPackURL = nil
            return
        }
        if url.pathExtension.lowercased() == "cluster" {
            activeArtistFilter = nil
            activeArtistPackURL = nil
            syncAlbumPillState()
            return
        }
        let currentURL = mixQueue?.currentTrack?.url
        let startFile = currentURL?.lastPathComponent
        importViaOpenMix(url: url, startFileName: startFile, blend: false, artistFilter: nil)
    }

    /// Library-wide artist play: all songs by artist across all packs, pack order.
    /// Builds TrackAssets with per-file pack context (cue → lrc → filename), no filename collision.
    func playLibraryArtist(_ artist: LibraryArtist, libraryURL: URL) {
        cancelPendingMoodTransition()
        stopAnimationLoop()
        audioEngine.stop()
        cacheTask?.cancel()
        importError = nil
        analysisProgress = 0
        activeArtistFilter = artist.name
        activeArtistPackURL = libraryURL
        playlistFolderURL = libraryURL
        albumPillSourceName = libraryURL.deletingPathExtension().lastPathComponent
        artistImages = []
        currentArtistImage = nil

        var tracks: [TrackAsset] = []
        for fileURL in artist.trackURLs {
            // Owning pack = nearest parent *.cella, fallback library root
            var packURL = fileURL.deletingLastPathComponent()
            while packURL.pathExtension.lowercased() != "cella" && packURL.path != libraryURL.path && packURL.path != "/" {
                packURL = packURL.deletingLastPathComponent()
            }
            if packURL.pathExtension.lowercased() != "cella" { packURL = libraryURL }
            var t = TrackAsset(url: fileURL)
            // Per-file cue lookup (album folder first, then pack root)
            let albumDir = fileURL.deletingLastPathComponent()
            var foundTitle: String?
            var foundPerformer: String?
            var foundAlbum: String?
            let fm = FileManager.default
            let albumContents = (try? fm.contentsOfDirectory(at: albumDir, includingPropertiesForKeys: nil)) ?? []
            if let cueURL = albumContents.first(where: { $0.pathExtension.lowercased() == "cue" }),
               let sheet = CueParser.load(from: cueURL) {
                if let c = sheet.tracks.first(where: { $0.fileName.lowercased() == fileURL.lastPathComponent.lowercased() }) {
                    if !c.title.isEmpty { foundTitle = c.title }
                    if !c.performer.isEmpty { foundPerformer = c.performer }
                }
                if !sheet.title.isEmpty { foundAlbum = sheet.title }
            }
            if (foundTitle == nil || foundPerformer == nil),
               let packContents = try? fm.contentsOfDirectory(at: packURL, includingPropertiesForKeys: nil),
               let rootCueURL = packContents.first(where: { $0.pathExtension.lowercased() == "cue" }),
               let sheet = CueParser.load(from: rootCueURL),
               let c = sheet.tracks.first(where: { $0.fileName.lowercased() == fileURL.lastPathComponent.lowercased() }) {
                if foundTitle == nil && !c.title.isEmpty { foundTitle = c.title }
                if foundPerformer == nil && !c.performer.isEmpty { foundPerformer = c.performer }
            }
            if let t1 = foundTitle { t.title = t1 }
            if let p1 = foundPerformer { t.artist = p1 }
            if let a1 = foundAlbum { t.albumName = a1 }
            // LRC fallback
            let meta = LrcParser.metadata(for: fileURL, in: packURL)
            if (t.title == nil || t.title!.isEmpty) && !meta.title.isEmpty { t.title = meta.title }
            if (t.artist == nil || t.artist!.isEmpty) && !meta.artist.isEmpty { t.artist = meta.artist }
            if (t.albumName == nil || t.albumName!.isEmpty) && !meta.album.isEmpty { t.albumName = meta.album }
            if t.albumName == nil || t.albumName!.isEmpty {
                t.albumName = albumDir.lastPathComponent
            }
            tracks.append(t)
        }
        guard !tracks.isEmpty else {
            importError = "No tracks found for artist \(artist.name)"
            return
        }
        // Validate playable
        tracks = tracks.filter { (try? AudioHelpers.readAudio(url: $0.url)) != nil }
        guard !tracks.isEmpty else {
            importError = "No playable tracks for \(artist.name)"
            return
        }
        totalTrackCount = tracks.count
        analyzedTrackCount = 0
        mixQueue = MixQueue(tracks: tracks, transitions: Array(repeating: nil, count: max(0, tracks.count - 1)), currentIndex: 0)
        loadArtistImages(from: libraryURL)
        do {
            try loadTrackAndRestore(url: tracks[0].url, barTimestamps: [], analysis: nil)
            audioEngine.play()
            playerState = .playing
            startAnimationLoop()
            startVideoPlayback()
            log("Playing artist \(artist.name): \(tracks.count) tracks")
        } catch {
            importError = "Failed to play \(artist.name): \(error.localizedDescription)"
        }
    }

    /// Library subset play: same as playLibraryArtist but with explicit URLs
    /// (pack/album/song level from timeline). Preserves pack order of input.
    func playLibraryTrackURLs(_ name: String, urls: [URL], libraryURL: URL, startURL: URL? = nil) {
        guard !urls.isEmpty else { return }
        // Reuse per-file enrichment by faking an Artist
        let fake = Artist(name: name, key: ArtistMatcher.normKey(name), trackCount: urls.count, packCount: 0, albumCount: 0, trackURLs: urls, files: urls.map { $0.lastPathComponent }, videoURL: nil, coverURL: nil)
        // Temporarily swap to play subset starting at startURL
        let savedFirst = fake.trackURLs
        playLibraryArtist(fake, libraryURL: libraryURL)
        if let s = startURL,
           let idx = mixQueue?.tracks.firstIndex(where: { $0.url == s }) {
            mixQueue?.currentIndex = idx
            if let track = mixQueue?.currentTrack {
                try? loadTrackAndRestore(url: track.url, barTimestamps: [], analysis: nil)
                audioEngine.play()
                playerState = .playing
            }
        }
        _ = savedFirst
    }

    /// Crossfade from the current track straight to a chosen album song.
    func crossfadeToTrack(at index: Int) {
        guard var queue = mixQueue, index >= 0, index < queue.tracks.count else {
            print("[PlayerViewModel] crossfadeToTrack GUARD FAIL idx=\(index)")
            return
        }
        guard index != queue.currentIndex, let outgoing = queue.currentTrack else {
            print("[PlayerViewModel] crossfadeToTrack SAME/NO-TRACK idx=\(index) current=\(queue.currentIndex)")
            return
        }
        print("[PlayerViewModel] crossfadeToTrack → \(queue.tracks[index].fileName) (idx \(index), current \(queue.currentIndex))")
        cancelPendingMoodTransition()

        let incoming = queue.tracks[index]
        playerState = .autoMix

        let params = crossfader.computeCrossfadeParams(
            outgoing: outgoing,
            incoming: incoming
        )

        print("[PlayerViewModel] CROSSFADE-SRC=crossfadeToTrack out=\(outgoing.fileName) in=\(incoming.fileName)")
        let started = audioEngine.crossfadeToNext(
            outgoingURL: outgoing.url,
            incomingURL: incoming.url,
            crossfader: crossfader,
            params: params,
            outgoingAnalysis: outgoing.analysis,
            incomingAnalysis: incoming.analysis
        )
        guard started else {
            print("[PlayerViewModel] crossfadeToTrack ENGINE REFUSED (crossfade in progress?)")
            return
        }

queue.currentIndex = index
        mixQueue = queue

        pendingSwitchCompletion = { [weak self] in
            if self?.playerState == .autoMix {
                self?.playerState = .playing
                self?.stopAnimationLoop()
                self?.startAnimationLoop()
                self?.loadLyrics(for: queue.currentTrack?.url ?? incoming.url)
            }
        }
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
    /// Hidden while crossfade or no track is loaded.
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

    // MARK: - LRC Editor Auto Fade

    private var editorFadeGen = 0

    /// Fade the engine out, then pause. currentVolume (user level) untouched.
    func fadeOutForEditor(duration: TimeInterval = 1.0) {
        guard playerState == .playing else { return }
        editorFadeGen += 1
        let gen = editorFadeGen
        audioEngine.smoothVolume(to: 0, duration: duration)
        log("Fading out for LRC editor")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, gen == self.editorFadeGen, self.playerState == .playing else { return }
            self.playerState = .paused
            self.audioEngine.pause()
            self.stopVideoPlayback()
            self.stopAnimationLoop()
            self.syncPlaybackTime()
            self.updateNowPlayingInfo()
            self.log("Paused for LRC editor")
        }
    }

    /// Abort a pending fade and restore the user volume level.
    func cancelEditorFade() {
        editorFadeGen += 1
        audioEngine.setVolumeImmediate(currentVolume)
    }

    /// Resume after leaving the editor. Only resumes if still paused —
    /// a manual resume inside (remote/airpods) is left alone.
    func resumeFromEditor() {
        cancelEditorFade()
        guard playerState == .paused, let queue = mixQueue, !queue.isEmpty else { return }
        playerState = .playing
        audioEngine.play()
        startVideoPlayback()
        syncPlaybackTime()
        if pendingMood != nil {
            applyPendingMood()
        } else {
            startAnimationLoop()
        }
        updateNowPlayingInfo()
        log("Resumed from LRC editor")
    }

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

    func selectPreset(_ preset: OrquestaPreset) {
        currentPreset = preset
        audioEngine.applyProfileEQ(preset)
    }

    /// Re-applies the in-flight EQ without touching the selected preset —
    /// used while dragging a band on the Orquesta custom curve.
    func refreshProfileEQ() {
        audioEngine.applyProfileEQ(currentPreset)
    }

    var surroundMode: SurroundMode = .off

    func applySurround(_ mode: SurroundMode) {
        surroundMode = mode
        audioEngine.setSurroundMode(mode)
    }

    /// Solo a single EQ band (0–9). Pass nil to unsolo. Masking applies on the
    /// next profile application.
    func setSoloBand(_ index: Int?) {
        audioEngine.setSoloBand(index)
        audioEngine.applyProfileEQ(currentPreset)
    }

    private func restoreAudioSettings() {
        let storedPreset = OrquestaPreset.resolve(
            UserDefaults.standard.string(forKey: OrquestaPreset.storageKey)
        )
        currentPreset = storedPreset
        audioEngine.applyProfileEQ(storedPreset)
        if let raw = UserDefaults.standard.string(forKey: SurroundMode.storageKey),
           let stored = SurroundMode(rawValue: raw) {
            applySurround(stored)
        } else {
            audioEngine.setSurroundMode(.off)
        }
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

        // Follow cella playlist structure: owning pack for second fallback
        // (library mode folder is *.cluster, LRCs live in pack/lrc).
        let effectiveFolder: URL
        if folder.pathExtension.lowercased() == "cluster" {
            effectiveFolder = owningPack(for: trackURL, fallback: folder)
        } else {
            effectiveFolder = folder
        }
        // Find lrc file: try album's lrc/ subfolder first, then pack lrc/, then legacy (same dir)
        let albumDir = trackURL.deletingLastPathComponent()
        let candidates = [
            albumDir.appendingPathComponent("lrc").appendingPathComponent(lrcName),
            effectiveFolder.appendingPathComponent("lrc").appendingPathComponent(lrcName),
            effectiveFolder.appendingPathComponent(lrcName)
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
        if let nextTrack = mixQueue?.nextTrack {
            let nextLrcName = nextTrack.url.deletingPathExtension().lastPathComponent + ".lrc"
            let nextAlbumDir = nextTrack.url.deletingLastPathComponent()
            let nextEffective: URL = folder.pathExtension.lowercased() == "cluster" ? owningPack(for: nextTrack.url, fallback: folder) : folder
            let nextCandidates = [
                nextAlbumDir.appendingPathComponent("lrc").appendingPathComponent(nextLrcName),
                nextEffective.appendingPathComponent("lrc").appendingPathComponent(nextLrcName),
                nextEffective.appendingPathComponent(nextLrcName)
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

    /// Owning .cella pack for a track (walks up to nearest *.cella). Falls back to folder.
    private func owningPack(for trackURL: URL, fallback: URL) -> URL {
        var dir = trackURL.deletingLastPathComponent()
        // Check track dir itself (flat pack root is .cella)
        if dir.pathExtension.lowercased() == "cella" { return dir }
        // Walk up max 4 levels (album → pack → library)
        for _ in 0..<4 {
            if dir.pathExtension.lowercased() == "cella" { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return fallback
    }

    private func loadArtistImages(from folder: URL) {
        // Library artist mode: folder is *.cluster → resolve owning *.cella pack
        // so structure follows cella playlist (pack/cma/<Artist>/...).
        var cmaRoots: [URL] = []
        if folder.pathExtension.lowercased() == "cluster",
           let trackURL = mixQueue?.currentTrack?.url {
            let pack = owningPack(for: trackURL, fallback: folder)
            cmaRoots = [pack.appendingPathComponent("cma")]
        } else if folder.pathExtension.lowercased() == "cluster" {
            // No current track yet (initial library play): collect all packs' cma
            // so first-frame CMA still shows. Filtered per-track on next songs.
            let packs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.filter { $0.hasDirectoryPath && $0.pathExtension.lowercased() == "cella" } ?? []
            cmaRoots = packs.map { $0.appendingPathComponent("cma") }
        } else {
            cmaRoots = [folder.appendingPathComponent("cma")]
        }
        // Use first existing cma dir as primary; library mode aggregates across packs below
        let cmaDir = cmaRoots.first(where: { FileManager.default.fileExists(atPath: $0.path) }) ?? folder.appendingPathComponent("cma")
        guard FileManager.default.fileExists(atPath: cmaDir.path) || folder.pathExtension.lowercased() == "cluster" else {
            // No visuals here — full teardown so the previous pack's
            // video/image can't keep showing.
            resetPackVisuals()
            return
        }

        let allExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "tiff", "bmp", "mp4", "mov", "cma"])
        let animatedExtensions = Set(["gif", "mp4", "mov", "cma"])
        let staticExtensions = Set(["jpg", "jpeg", "png", "webp", "tiff", "bmp"])

        // Get artist names from cue metadata, then filename parsing
        var trackArtists: [String] = []

        if let track = mixQueue?.currentTrack, !track.artists.isEmpty {
            trackArtists = track.artists.map { $0.lowercased() }
        } else if let trackURL = mixQueue?.currentTrack?.url {
            let fileName = trackURL.lastPathComponent
            if let artist = albumCueArtists[fileName.lowercased()], !artist.isEmpty {
                trackArtists.append(artist)
            } else if let cue = cueTracksByFile[fileName.lowercased()], !cue.performer.isEmpty {
                trackArtists.append(cue.performer.lowercased())
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

        print("[PlayerViewModel] CMA artists: \(trackArtists) roots=\(cmaRoots.map { $0.path })")

        // Scan cma/ directories (library mode aggregates across packs, primary first)
        var scanDirs: [URL] = []
        scanDirs.append(cmaDir)
        for r in cmaRoots where r.path != cmaDir.path {
            if FileManager.default.fileExists(atPath: r.path) { scanDirs.append(r) }
        }
        var allFiles: [URL] = []
        var animatedFiles: [URL] = []
        var staticFiles: [URL] = []
        for dir in scanDirs {
            let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let files = contents.filter { allExtensions.contains($0.pathExtension.lowercased()) }
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            allFiles.append(contentsOf: files)
            animatedFiles.append(contentsOf: files.filter { animatedExtensions.contains($0.pathExtension.lowercased()) })
            staticFiles.append(contentsOf: files.filter { staticExtensions.contains($0.pathExtension.lowercased()) })
        }

        // Match artist names to video/image files in cma/<artist>/ subfolders
        // Primary (owning pack) first so structure follows cella playlist.
        artistVideoURLs = []
        let videoExtensions = Set(["mp4", "mov", "cma"])

        for artist in trackArtists {
            // Filesystem stores accented names in NFD; normalize candidates so NFC artist
            // strings (e.g. from .lrc) still match the on-disk folder.
            let nfd = artist.precomposedStringWithCanonicalMapping
                .decomposedStringWithCanonicalMapping
            let titleCase = nfd.split(separator: " ").map(\.capitalized).joined(separator: " ")
            for baseDir in scanDirs {
                // Try various folder name formats: "artist", "Artist", "artist-name"
                let candidates = [
                    baseDir.appendingPathComponent(nfd),
                    baseDir.appendingPathComponent(titleCase),
                    baseDir.appendingPathComponent(nfd.replacingOccurrences(of: " ", with: "-")),
                    baseDir.appendingPathComponent(nfd.replacingOccurrences(of: " ", with: "_"))
                ]
                for dir in candidates where FileManager.default.fileExists(atPath: dir.path) {
                    let subContents = (try? FileManager.default.contentsOfDirectory(
                        at: dir, includingPropertiesForKeys: nil
                    )) ?? []
                    let videos = subContents.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
                        .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                    // Primary pack wins; other packs only fill if primary empty
                    if baseDir.path == cmaDir.path {
                        artistVideoURLs.append(contentsOf: videos)
                    } else if artistVideoURLs.isEmpty {
                        artistVideoURLs.append(contentsOf: videos)
                    }
                    // Also grab static images from artist subfolder (primary first)
                    let images = subContents.filter { staticExtensions.contains($0.pathExtension.lowercased()) }
                        .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                    if !images.isEmpty && artistImages.isEmpty {
                        artistImages = images.compactMap { NSImage(contentsOf: $0) }
                    }
                }
                if !artistVideoURLs.isEmpty && baseDir.path == cmaDir.path { break }
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

        // Fallback: if no match, use primary pack videos (not library-wide mix)
        if artistVideoURLs.isEmpty {
            let primaryAnimated: [URL]
            let primaryContents = (try? FileManager.default.contentsOfDirectory(at: cmaDir, includingPropertiesForKeys: nil)) ?? []
            primaryAnimated = primaryContents.filter {
                let e = $0.pathExtension.lowercased()
                return animatedExtensions.contains(e) && e != "gif"
            }
            artistVideoURLs = primaryAnimated
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

    /// Clears every pack-visual state (video, GIF frames, images) so a
    /// playlist switch never shows the previous pack's CMA.
    func resetPackVisuals() {
        destroyVideoPlayback()
        stopGifAnimation()
        gifFrames = []
        gifFrameDurations = []
        gifFrameIndex = 0
        artistImages = []
        currentArtistImage = nil
        artistImageIndex = 0
        artistVideoURLs = []
        artistVideoIndex = 0
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
            stopVideoPlayback()
            stopAnimationLoop()
            syncPlaybackTime()

        case .paused:
            guard let queue = mixQueue, !queue.isEmpty else { return }
            playerState = .playing
            // Self-heal: an editor fade may have left the master down.
            audioEngine.setVolumeImmediate(currentVolume)
            audioEngine.play()
            startVideoPlayback()
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

        // Solo Mode: skipping ends the solo now (stop + clear), never mixes.
        if soloMode {
            finishSolo(endReason: "skipped")
            updateNowPlayingInfo()
            return
        }

        guard var queue = mixQueue, !queue.isEmpty else { return }

        if let nextTrack = queue.nextTrack,
           let outgoingTrack = queue.currentTrack {
            playerState = .autoMix

            let params = crossfader.computeCrossfadeParams(
                outgoing: outgoingTrack,
                incoming: nextTrack
            )

            print("[PlayerViewModel] CROSSFADE-SRC=skipForward out=\(outgoingTrack.fileName) in=\(nextTrack.fileName)")
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

            pendingSwitchCompletion = { [weak self] in
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
                    if soloMode { audioEngine.playThroughToEnd() }
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

    /// Builds a TrackAsset, attaching title / artist / album name from per-album .cue sheets
    /// when the audio file has a matching entry. Falls back to .lrc metadata tags,
    /// then to filename parsing (cue → lrc → filename).
    private func makeTrackAsset(from url: URL, playlistFolder: URL? = nil) -> TrackAsset {
        var track = TrackAsset(url: url)

        // 1. Try per-album cue metadata
        let fileKey = url.lastPathComponent.lowercased()
        if let cueTrack = cueTracksByFile[fileKey] {
            if !cueTrack.title.isEmpty { track.title = cueTrack.title }
            if !cueTrack.performer.isEmpty { track.artist = cueTrack.performer }
        }
        let albumKey = url.deletingLastPathComponent().lastPathComponent.lowercased()
        let packKey = url.deletingLastPathComponent().path.lowercased()
        if let albumName = cueAlbumNames[albumKey] ?? cueAlbumNames[packKey], !albumName.isEmpty {
            track.albumName = albumName
        }

        // 2. Fall back to .lrc metadata for any still-empty fields
        if let folder = playlistFolder {
            let meta = LrcParser.metadata(for: url, in: folder)
            if !meta.isEmpty {
                if track.title == nil || track.title!.isEmpty { track.title = meta.title }
                if track.artist == nil || track.artist!.isEmpty { track.artist = meta.artist }
                if track.albumName == nil || track.albumName!.isEmpty { track.albumName = meta.album }
            }
        }

        return track
    }

    func importFolder(url: URL) {
        // Only accept .cella folders
        guard url.pathExtension.lowercased() == "cella" else {
            importError = "Not a .cella playlist. Rename folder with .cella extension."
            return
        }

        // Cancel any running background cache task
        cacheTask?.cancel()

        importError = nil
        analysisProgress = 0
        playlistFolderURL = url
        albumPillSourceName = url.deletingPathExtension().lastPathComponent
        soloMode = false
        preSoloTracks = nil
        // Fresh switch: tear down old pack visuals now; correct visuals
        // load with the first track below (loadTrackAndRestore → loadLyrics).
        resetPackVisuals()

        print("[PlayerViewModel] importFolder called: \(url.path)")

        let audioExtensions = ["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"]

        // Move directory listing + validation off main thread
        Task.detached { [weak self] in
            guard let self else { return }
            let fileManager = FileManager.default
            let contents = (try? fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil
            )) ?? []

            // Collect audio files via per-album .cue sheets (cue → lrc → filename)
            var parsedCueTracks: [String: CueTrack] = [:]
            var parsedCueAlbumNames: [String: String] = [:]
            var parsedCueSheets: [String: CueSheet] = [:]
            var audioFiles: [URL] = []

            let sortedSubfolders = contents.filter { $0.hasDirectoryPath }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

            for subfolder in sortedSubfolders {
                let subContents = (try? fileManager.contentsOfDirectory(at: subfolder, includingPropertiesForKeys: nil)) ?? []
                let subAudioAll = subContents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                guard !subAudioAll.isEmpty || subContents.contains(where: { $0.pathExtension.lowercased() == "cue" }) else { continue }
                if let cueURL = subContents.first(where: { $0.pathExtension.lowercased() == "cue" }),
                   let sheet = CueParser.load(from: cueURL) {
                    let keyFolder = subfolder.lastPathComponent.lowercased()
                    let keyPath = subfolder.path.lowercased()
                    parsedCueSheets[keyFolder] = sheet
                    parsedCueSheets[keyPath] = sheet
                    let albumName = sheet.title.isEmpty ? subfolder.lastPathComponent : sheet.title
                    parsedCueAlbumNames[keyFolder] = albumName
                    parsedCueAlbumNames[keyPath] = albumName
                    for track in sheet.tracks {
                        parsedCueTracks[track.fileName.lowercased()] = track
                    }
                    let ordered = sheet.trackOrder(for: subAudioAll)
                    audioFiles.append(contentsOf: ordered)
                } else {
                    let sortedAudio = subAudioAll.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
                    audioFiles.append(contentsOf: sortedAudio)
                }
            }

            // Root-level audio (flat packs like english.cella / nhactre.cella)
            let rootAudioAll = contents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            var parsedRootCue: CueSheet?
            if !rootAudioAll.isEmpty {
                if let rootCueURL = contents.first(where: { $0.pathExtension.lowercased() == "cue" }),
                   let sheet = CueParser.load(from: rootCueURL) {
                    parsedRootCue = sheet
                    let albumName = sheet.title.isEmpty ? url.lastPathComponent : sheet.title
                    parsedCueAlbumNames[url.path.lowercased()] = albumName
                    parsedCueAlbumNames[url.lastPathComponent.lowercased()] = albumName
                    for track in sheet.tracks {
                        parsedCueTracks[track.fileName.lowercased()] = track
                    }
                    audioFiles.append(contentsOf: sheet.trackOrder(for: rootAudioAll))
                } else {
                    audioFiles.append(contentsOf: rootAudioAll)
                }
            }

            var parsedAlbumCueArtists: [String: String] = [:]
            for (file, track) in parsedCueTracks {
                parsedAlbumCueArtists[file] = track.performer.lowercased()
                parsedAlbumCueArtists[file.lowercased()] = track.performer.lowercased()
            }
            print("[PlayerViewModel] Per-album cue tracks: \(parsedCueTracks.count), album names: \(parsedCueAlbumNames.count)")
            let parsedCue = parsedRootCue
            let orderedFiles = audioFiles

            print("[PlayerViewModel] Audio files found: \(orderedFiles.count)")

            guard !orderedFiles.isEmpty else {
                await MainActor.run {
                    self.importError = "No audio files found in folder"
                    print("[PlayerViewModel] ERROR: No audio files found")
                }
                return
            }

            // Validate off main thread — reads audio headers, not full files
            // Build TrackAsset using local cue maps (cue → lrc → filename) to avoid MainActor hop
            var validTracks: [TrackAsset] = []
            for rawURL in orderedFiles {
                var track = TrackAsset(url: rawURL)
                let fileKey = rawURL.lastPathComponent.lowercased()
                if let cueTrack = parsedCueTracks[fileKey] {
                    if !cueTrack.title.isEmpty { track.title = cueTrack.title }
                    if !cueTrack.performer.isEmpty { track.artist = cueTrack.performer }
                }
                let albumKey = rawURL.deletingLastPathComponent().lastPathComponent.lowercased()
                let packKey = rawURL.deletingLastPathComponent().path.lowercased()
                if let albumName = parsedCueAlbumNames[albumKey] ?? parsedCueAlbumNames[packKey], !albumName.isEmpty {
                    track.albumName = albumName
                }
                // LRC fallback
                let meta = LrcParser.metadata(for: rawURL, in: url)
                if !meta.isEmpty {
                    if track.title == nil || track.title!.isEmpty { track.title = meta.title }
                    if track.artist == nil || track.artist!.isEmpty { track.artist = meta.artist }
                    if track.albumName == nil || track.albumName!.isEmpty { track.albumName = meta.album }
                }
                do {
                    _ = try AudioHelpers.readAudio(url: track.url)
                    validTracks.append(track)
                } catch {
                    print("[PlayerViewModel] Skipping unplayable: \(track.fileName) — \(error.localizedDescription)")
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
                self.cueTracksByFile = parsedCueTracks
                self.cueAlbumNames = parsedCueAlbumNames
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

    // MARK: - Blend

    /// Crossfades the still-playing source track straight into the requested
    /// target track (queued by `importViaOpenMix(blend: true)`).
    private func blendIntoRequested() {
        guard blendPending else { return }
        blendPending = false
        guard let source = blendSourceTrack,
              var queue = mixQueue,
              let incoming = queue.currentTrack else {
            // Nothing to blend from — hard-switch into the target.
            if let fallback = mixQueue?.currentTrack {
                try? loadTrackAndRestore(
                    url: fallback.url,
                    barTimestamps: fallback.analysis?.barTimestamps ?? []
                )
                audioEngine.play()
            }
            playerState = .playing
            startAnimationLoop()
            return
        }
        blendSourceTrack = nil
        let index = queue.currentIndex
        print("[PlayerViewModel] CROSSFADE-SRC=blendIntoRequested out=\(source.fileName) in=\(incoming.fileName) idx=\(index)")

        playerState = .autoMix
        let params = crossfader.computeCrossfadeParams(
            outgoing: source,
            incoming: incoming
        )
        let started = audioEngine.crossfadeToNext(
            outgoingURL: source.url,
            incomingURL: incoming.url,
            crossfader: crossfader,
            params: params,
            outgoingAnalysis: source.analysis,
            incomingAnalysis: incoming.analysis
        )
        guard started else {
            log("Blend refused by engine — hard switch to \(incoming.fileName)")
            try? loadTrackAndRestore(
                url: incoming.url,
                barTimestamps: incoming.analysis?.barTimestamps ?? []
            )
            audioEngine.play()
            playerState = .playing
            startAnimationLoop()
            return
        }

        queue.currentIndex = index
        mixQueue = queue

        pendingSwitchCompletion = { [weak self] in
            guard let self else { return }
            if self.playerState == .autoMix {
                self.playerState = .playing
                self.stopAnimationLoop()
                self.startAnimationLoop()
                self.startVideoPlayback()
                self.log("Now playing: \(incoming.fileName)")
                self.loadLyrics(for: self.mixQueue?.currentTrack?.url ?? incoming.url)
            }
        }

        updateNowPlayingInfo()
    }

    // MARK: - Track End Handling

    /// Shared solo finish: stop playback and clear the queue.
    private func finishSolo(endReason: String) {
        log("Solo \(endReason) — clearing queue")
        soloMode = false
        preSoloTracks = nil
        mixQueue = nil
        playerState = .idle
        audioEngine.stop()
        stopAnimationLoop()
        updateNowPlayingInfo()
    }

    private func handleTrackEnd() {
        cancelPendingMoodTransition()

        // Solo Mode first: nothing may crossfade or blend out of a solo track.
        if soloMode {
            let soloName = mixQueue?.currentTrack?.fileName ?? "?"
            log("Track ended: \(soloName)")
            finishSolo(endReason: "ended: \(soloName)")
            return
        }

        // If a blend into an "OpenMix to" target is pending, the old track just
        // ended — crossfade into the requested track now.
        if blendPending {
            blendIntoRequested()
            return
        }

        guard var queue = mixQueue, !queue.isEmpty else {
            print("[PlayerViewModel] handleTrackEnd: no queue or empty")
            return
        }

        // Single-song playlist: play once, then stop. (nextTrack wraps to
        // itself, so without this the song would crossfade into itself forever.)
        if queue.count <= 1 {
            let onlyName = queue.currentTrack?.fileName ?? "?"
            log("Single track ended: \(onlyName) — stopping")
            playerState = .idle
            audioEngine.stop()
            stopAnimationLoop()
            updateNowPlayingInfo()
            return
        }

        let currentName = queue.currentTrack?.fileName ?? "?"
        log("Track ended: \(currentName)")
        print("[PlayerViewModel] CROSSFADE-SRC=handleTrackEnd blendPending=\(blendPending) track=\(currentName)")

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

            pendingSwitchCompletion = { [weak self] in
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

    // MARK: - Import

    func importViaOpenMix(url: URL, startFileName: String? = nil, blend: Bool = false, artistFilter: String? = nil) {
        // Only accept .cella folders
        guard url.pathExtension.lowercased() == "cella" else {
            importError = "Not a .cella playlist. Rename folder with .cella extension."
            return
        }

        // Capture the source track for a smooth blend into the requested song.
        if blend, let source = mixQueue?.currentTrack {
            blendSourceTrack = source
            blendPending = true
        } else {
            blendSourceTrack = nil
            blendPending = false
        }

        // Stop any existing playback and clear old state
        cancelPendingMoodTransition()
        if !blend {
            stopAnimationLoop()
            audioEngine.stop()
        }
        playlistFolderURL = url
        albumPillSourceName = url.deletingPathExtension().lastPathComponent
        if let f = artistFilter?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty {
            activeArtistFilter = f
            activeArtistPackURL = url
        } else {
            activeArtistFilter = nil
            activeArtistPackURL = nil
        }
        soloMode = false
        preSoloTracks = nil
        if blend {
            loadArtistImages(from: url)
        } else {
            // Fresh switch: tear down old pack visuals now so the previous
            // playlist's video/image can't linger. Correct visuals load with
            // the first track below (loadTrackAndRestore → loadLyrics).
            resetPackVisuals()
        }

        importError = nil
        analysisProgress = 0
        requestedStartFileName = startFileName

        print("[PlayerViewModel] Import: \(url.path) blend=\(blend) blendPending=\(blendPending) artist=\(activeArtistFilter ?? "nil") thread=\(Thread.isMainThread ? "main" : "bg")")

        // Capture start file for background cache task (before it's cleared)
        let capturedStartFile = startFileName

        // Cancel previous background cache task
        cacheTask?.cancel()

        let audioExtensions = ["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"]
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )) ?? []

        // Collect audio files via per-album .cue sheets (cue → lrc → filename)
        cueTracksByFile = [:]
        cueAlbumNames = [:]
        albumCueArtists = [:]
        var audioFiles: [URL] = []
        var cueSheetsByAlbum: [String: CueSheet] = [:]

        let sortedSubfolders = contents.filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        for subfolder in sortedSubfolders {
            let subContents = (try? fileManager.contentsOfDirectory(at: subfolder, includingPropertiesForKeys: nil)) ?? []
            let subAudioAll = subContents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            guard !subAudioAll.isEmpty || subContents.contains(where: { $0.pathExtension.lowercased() == "cue" }) else { continue }
            if let cueURL = subContents.first(where: { $0.pathExtension.lowercased() == "cue" }),
               let sheet = CueParser.load(from: cueURL) {
                let keyFolder = subfolder.lastPathComponent.lowercased()
                let keyPath = subfolder.path.lowercased()
                cueSheetsByAlbum[keyFolder] = sheet
                cueSheetsByAlbum[keyPath] = sheet
                let albumName = sheet.title.isEmpty ? subfolder.lastPathComponent : sheet.title
                cueAlbumNames[keyFolder] = albumName
                cueAlbumNames[keyPath] = albumName
                cueAlbumNames[subfolder.path.lowercased()] = albumName
                for track in sheet.tracks {
                    cueTracksByFile[track.fileName.lowercased()] = track
                    albumCueArtists[track.fileName.lowercased()] = track.performer.lowercased()
                }
                let ordered = sheet.trackOrder(for: subAudioAll)
                audioFiles.append(contentsOf: ordered)
            } else {
                let sortedAudio = subAudioAll.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
                audioFiles.append(contentsOf: sortedAudio)
            }
        }

        let rootAudioAll = contents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        var rootCue: CueSheet?
        if !rootAudioAll.isEmpty {
            if let rootCueURL = contents.first(where: { $0.pathExtension.lowercased() == "cue" }),
               let sheet = CueParser.load(from: rootCueURL) {
                rootCue = sheet
                let albumName = sheet.title.isEmpty ? url.lastPathComponent : sheet.title
                cueAlbumNames[url.path.lowercased()] = albumName
                cueAlbumNames[url.lastPathComponent.lowercased()] = albumName
                for track in sheet.tracks {
                    cueTracksByFile[track.fileName.lowercased()] = track
                    albumCueArtists[track.fileName.lowercased()] = track.performer.lowercased()
                }
                audioFiles.append(contentsOf: sheet.trackOrder(for: rootAudioAll))
            } else {
                audioFiles.append(contentsOf: rootAudioAll)
            }
        }
        cueSheet = rootCue
        print("[PlayerViewModel] Per-album cue tracks: \(cueTracksByFile.count), album names: \(cueAlbumNames.count)")

        // Ordered files already reflect per-album cue ordering
        var orderedFiles = audioFiles

        // Artist filter via unified ArtistMatcher (single source).
        if let filter = artistFilter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
            let needle = ArtistMatcher.normKey(filter)
            let allTracks = orderedFiles.map { makeTrackAsset(from: $0, playlistFolder: url) }
            let matched = allTracks.filter { t in
                ArtistMatcher.matches(trackArtist: t.artist, file: t.url.lastPathComponent, needleKey: needle, displayArtist: t.displayArtist, rawArtist: t.artistName)
                || {
                    let fileKey = t.url.lastPathComponent.lowercased()
                    if let cue = cueTracksByFile[fileKey], !cue.performer.isEmpty {
                        return ArtistMatcher.splitNames(trackArtist: cue.performer, file: t.url.lastPathComponent).map { ArtistMatcher.normKey($0) }.contains(needle)
                    }
                    return false
                }()
            }
            if matched.isEmpty {
                importError = "No tracks found for artist \(filter)"
                print("[PlayerViewModel] Artist filter '\(filter)' needle='\(needle)' → 0/\(audioFiles.count) MISS")
                return
            }
            orderedFiles = matched.map { $0.url }
            print("[PlayerViewModel] Artist filter '\(filter)' needle='\(needle)' → \(orderedFiles.count)/\(audioFiles.count)")
        }

        guard orderedFiles.count >= 1 else {
            importError = "Need at least 1 audio file"
            return
        }

        totalTrackCount = orderedFiles.count
        analyzedTrackCount = 0

        let tracks = orderedFiles.map { makeTrackAsset(from: $0, playlistFolder: url) }
        var startIndex = 0
        if let requestedStartFileName {
            // Match by full filename (with extension) or by base name.
            let base = URL(fileURLWithPath: requestedStartFileName)
                .deletingPathExtension().lastPathComponent
            if let match = tracks.firstIndex(where: {
                $0.url.lastPathComponent == requestedStartFileName || $0.fileName == base
            }) {
                startIndex = match
            }
            print("[PlayerViewModel] startFileName='\(requestedStartFileName)' base='\(base)' → startIndex=\(startIndex) of \(tracks.count)")
        }
        requestedStartFileName = nil

        mixQueue = MixQueue(
            tracks: tracks,
            transitions: Array(repeating: nil, count: max(0, tracks.count - 1)),
            currentIndex: startIndex
        )

        // Play first track immediately
        if !blend {
            do {
                try loadTrackAndRestore(
                    url: tracks[startIndex].url,
                    barTimestamps: tracks[startIndex].analysis?.barTimestamps ?? []
                )
                audioEngine.play()
                playerState = .playing
                startAnimationLoop()
                startVideoPlayback()
                print("[PlayerViewModel] Now playing: \(tracks[startIndex].fileName)")
            } catch {
                print("[PlayerViewModel] Failed to start playback: \(error)")
            }
        } else {
            print("[PlayerViewModel] Blend mode: keeping current track, target '\(tracks[startIndex].fileName)' (idx \(startIndex))")
            blendIntoRequested()
        }

        // Background: generate .cellax cache files for the played album only
        cacheTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let audioExtensions = Set(["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"])
            let fm = FileManager.default
            let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []

            // Find the album directory containing the played track
            let startFile = capturedStartFile
            var targetAlbumDir: URL?

            if let startFile {
                // Search subfolders for the track
                let subfolders = contents.filter { $0.hasDirectoryPath && $0.pathExtension.lowercased() != "cluster" }
                for sub in subfolders {
                    let subContents = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
                    if subContents.contains(where: { $0.lastPathComponent == startFile }) {
                        targetAlbumDir = sub
                        break
                    }
                }
                // Check root
                if targetAlbumDir == nil {
                    let rootAudio = contents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                    if rootAudio.contains(where: { $0.lastPathComponent == startFile }) {
                        targetAlbumDir = url
                    }
                }
            }

            // Fallback: if no start file or not found, analyze all albums
            var albumDirs: [URL] = []
            if let target = targetAlbumDir {
                albumDirs = [target]
            } else {
                let subfolders = contents.filter { $0.hasDirectoryPath && $0.pathExtension.lowercased() != "cluster" }
                for sub in subfolders {
                    let subContents = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
                    if subContents.contains(where: { audioExtensions.contains($0.pathExtension.lowercased()) }) {
                        albumDirs.append(sub)
                    }
                }
                let rootAudio = contents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                if !rootAudio.isEmpty {
                    albumDirs.insert(url, at: 0)
                }
            }

            let albumName = targetAlbumDir?.lastPathComponent ?? "all albums"
            print("[PlayerViewModel] Background cache: \(albumDirs.count) album(s) in \(url.lastPathComponent) (target: \(albumName))")
            let analyzer = TrackAnalyzer()
            var totalAnalyzed = 0

            for albumDir in albumDirs {
                if Task.isCancelled {
                    print("[PlayerViewModel] Background cache cancelled — switching album")
                    return
                }
                let albumContents = (try? fm.contentsOfDirectory(at: albumDir, includingPropertiesForKeys: nil)) ?? []
                let audioFiles = albumContents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                let uncached = audioFiles.filter { !fm.fileExists(atPath: AnalysisCache.cacheURL(for: $0).path) }

                let name = albumDir.lastPathComponent
                if uncached.isEmpty {
                    print("[PlayerViewModel] [\(name)] all \(audioFiles.count) cached — skip")
                    continue
                }

                print("[PlayerViewModel] [\(name)] \(uncached.count) uncached of \(audioFiles.count)")
                for audioURL in uncached {
                    if Task.isCancelled {
                        print("[PlayerViewModel] Background cache cancelled — switching album")
                        return
                    }
                    do {
                        let analysis = try await analyzer.analyze(url: audioURL)
                        AnalysisCache.save(analysis, for: audioURL)
                        totalAnalyzed += 1
                        // Yield UI + throttle: 200ms between tracks
                        try? await Task.sleep(for: .milliseconds(200))
                    } catch {
                        print("[PlayerViewModel] [\(name)] skip \(audioURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }

            print("[PlayerViewModel] Background cache done: \(totalAnalyzed) analyzed")
        }
    }

}