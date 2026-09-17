//
//  MotionsViewModel.swift
//  Cella
//
//  Editor state for Cella Motions. Owns the AVPlayer and clip/export state so it
//  survives tab switches, tracks unsaved changes for the nav bar pill, and can be
//  paused from anywhere (e.g. when the user leaves the Motion tab).
//

import AVFoundation
import AppKit
import Combine
import SwiftUI

@MainActor
final class MotionsViewModel: ObservableObject {
    // MARK: - Source / Export

    @Published var sourceURL: URL?
    @Published var outputURL: URL?
    @Published var isExporting = false
    @Published var exportProgress: Double = 0

    /// Finished boomerang waiting for the user to pick album + artist.
    @Published var pendingExportURL: URL?

    /// Default .cluster library scanned for album choice at export time.
    @Published var libraryURL: URL? = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads")
        .appendingPathComponent("musicLiblary.cluster")

    // MARK: - Playback

    private(set) var player: AVPlayer?
    @Published var videoDuration: Double = 0
    @Published var frameRate: Double = 30
    private var timeObserver: Any?

    // MARK: - Selection

    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 1.0
    @Published var targetDuration: Double = 1.0
    @Published var currentTime: Double = 0

    // MARK: - Filmstrip / Zoom

    @Published var overviewThumbs: [NSImage] = []
    @Published var zoomed = false
    @Published var zoomThumbs: [NSImage] = []

    // MARK: - UI

    @Published var isPlaying = false
    @Published var isLoopPreviewing = false
    @Published var loopCount = 3
    @Published var toast: ToastMessage?

    // MARK: - Unsaved changes

    @Published var hasUnsavedChanges = false

    private var playbackTimer: Timer?

    // Saved snapshot — the last state that was exported (or the default on load).
    // Changes away from this baseline surface as "Unsaved" in the nav bar.
    private var baselineTrimStart: Double = 0
    private var baselineTrimEnd: Double = 1.0
    private var baselineLoopCount: Int = 3
    private var baselineTargetDuration: Double = 1.0

    // MARK: - Zoom helpers

    var zoomRange: ClosedRange<Double> {
        let halfWindow = min(2.5, videoDuration / 2)
        let center = (trimStart + trimEnd) / 2
        let lo = max(0, center - halfWindow)
        let hi = min(videoDuration, center + halfWindow)
        guard lo < hi else { return 0...0 }
        return lo...hi
    }

    var zoomDuration: Double {
        let r = zoomRange
        return r.upperBound - r.lowerBound
    }

    // MARK: - Unsaved changes

    /// Recompute the unsaved flag against the saved snapshot. Called whenever the
    /// trim / clip settings change (internal edits, filmstrip drags, steppers).
    func noteClipChanged() {
        guard sourceURL != nil else {
            hasUnsavedChanges = false
            return
        }
        hasUnsavedChanges =
            abs(trimStart - baselineTrimStart) > 0.001
            || abs(trimEnd - baselineTrimEnd) > 0.001
            || loopCount != baselineLoopCount
            || abs(targetDuration - baselineTargetDuration) > 0.001
    }

    func setLoopCount(_ count: Int) {
        loopCount = min(8, max(1, count))
        noteClipChanged()
    }

    private func commitSavedBaseline() {
        baselineTrimStart = trimStart
        baselineTrimEnd = trimEnd
        baselineLoopCount = loopCount
        baselineTargetDuration = targetDuration
        hasUnsavedChanges = false
    }

    // MARK: - Pause (called when leaving the Motion tab)

    /// Pause the editing section — freezes playback and the loop preview so work
    /// keeps its place. Call from anywhere (tab switch, app resigning active).
    func pauseEditing() {
        player?.pause()
        currentTime = playerTime()
        isPlaying = false
        isLoopPreviewing = false
        stopPlaybackTimer()
    }

    // MARK: - Video Loading

    func loadVideo(_ url: URL) {
        sourceURL = url
        outputURL = nil
        discardExport()
        toast = nil
        overviewThumbs = []
        zoomThumbs = []
        zoomed = false
        stopPlaybackTimer()

        let asset = AVURLAsset(url: url)
        Task {
            let dur = try await asset.load(.duration)
            let secs = CMTimeGetSeconds(dur)
            await MainActor.run {
                videoDuration = secs
                trimStart = 0
                trimEnd = min(targetDuration, secs)
                commitSavedBaseline()
                // Imported but not yet exported — flag as unsaved.
                hasUnsavedChanges = true
            }

            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let fr = try? await track.load(.nominalFrameRate) {
                let f = Double(fr)
                await MainActor.run { if f > 0 { frameRate = f } }
            }

            let thumbs = await FilmstripGenerator.generateThumbnails(
                from: url, count: 40, height: 64
            )
            await MainActor.run { overviewThumbs = thumbs }
        }
        player = AVPlayer(url: url)
        startTimeObserver(on: player!)
    }

    private func startTimeObserver(on avPlayer: AVPlayer) {
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 60000),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = CMTimeGetSeconds(time)
            }
        }
    }

    // MARK: - Mark Selection

    func markIn() {
        guard videoDuration > 0 else { return }
        let dur = min(targetDuration, videoDuration)
        let s = min(playerTime(), videoDuration)
        trimStart = s
        trimEnd = min(s + dur, videoDuration)
        playSelection()
        if zoomed { loadZoomThumbs() }
        noteClipChanged()
    }

    func markOut() {
        guard videoDuration > 0 else { return }
        let dur = min(targetDuration, videoDuration)
        let e = min(playerTime(), videoDuration)
        trimEnd = e
        trimStart = max(0, e - dur)
        playSelection()
        if zoomed { loadZoomThumbs() }
        noteClipChanged()
    }

    func setTargetDuration(_ secs: Double) {
        targetDuration = secs
        placeClip(at: playerTime(), keepDuration: false)
        noteClipChanged()
    }

    func placeClip(at position: Double, keepDuration: Bool) {
        guard videoDuration > 0 else { return }
        let dur = keepDuration ? (trimEnd - trimStart) : min(targetDuration, videoDuration)
        let s = min(max(0, position), videoDuration - dur)
        trimStart = s
        trimEnd = s + dur
        seekTo(trimStart)
        if zoomed { loadZoomThumbs() }
        noteClipChanged()
    }

    /// Ground truth playback position from the player. Falls back to the
    /// sampled `currentTime` when the player isn't ready so markers always
    /// land on what the user actually sees.
    private func playerTime() -> Double {
        guard let player else { return currentTime }
        let t = CMTimeGetSeconds(player.currentTime())
        guard t.isFinite, t >= 0 else { return currentTime }
        return t
    }

    func nudgeTrimStart(_ delta: Double) {
        trimStart = max(0, min(trimStart + delta, trimEnd - 0.05))
        seekTo(trimStart)
        noteClipChanged()
    }

    func nudgeTrimEnd(_ delta: Double) {
        trimEnd = min(videoDuration, max(trimEnd + delta, trimStart + 0.05))
        noteClipChanged()
    }

    // MARK: - Playback

    func beginScrub() {
        player?.pause()
        isPlaying = false
    }

    func playPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            stopPlaybackTimer()
            currentTime = playerTime()
        } else {
            player.play()
            isPlaying = true
            startPlaybackTimer()
        }
    }

    func playSelection() {
        guard let player = player else { return }
        let start = CMTime(seconds: trimStart, preferredTimescale: 60000)
        player.seek(to: start)
        player.play()
        isPlaying = true
        startPlaybackTimer()
    }

    func toggleLoopPreview() {
        guard player != nil else { return }
        isLoopPreviewing.toggle()
        if isLoopPreviewing {
            playSelection()
        } else {
            player?.pause()
            isPlaying = false
            stopPlaybackTimer()
        }
    }

    func seekTo(_ position: Double) {
        guard let player = player else { return }
        let p = max(0, min(position, videoDuration))
        let time = CMTime(seconds: p, preferredTimescale: 60000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = p
    }

    func stepFrame(by direction: Int) {
        guard let player else { return }
        player.pause()
        isPlaying = false
        stopPlaybackTimer()
        let fps = frameRate > 0 ? frameRate : 30
        let base = CMTimeGetSeconds(player.currentTime())
        seekTo(max(0, min(videoDuration, base + (1.0 / fps) * Double(direction))))
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                let t = CMTimeGetSeconds(player.currentTime())
                self.currentTime = t
                if t >= self.trimEnd {
                    if self.isLoopPreviewing {
                        player.seek(to: CMTime(seconds: self.trimStart, preferredTimescale: 60000))
                        player.play()
                    } else {
                        player.pause()
                        self.isPlaying = false
                        self.stopPlaybackTimer()
                    }
                }
            }
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func teardownPlayer() {
        if let player = player, let obs = timeObserver {
            player.removeTimeObserver(obs)
        }
        timeObserver = nil
        stopPlaybackTimer()
        isPlaying = false
        isLoopPreviewing = false
        player?.pause()
    }

    // MARK: - Zoom

    func toggleZoom() {
        withAnimation(.smooth) { zoomed.toggle() }
        if zoomed { loadZoomThumbs() }
    }

    private func loadZoomThumbs() {
        guard let url = sourceURL else { return }
        let range = zoomRange
        Task {
            let thumbs = await FilmstripGenerator.generateThumbnails(
                from: url, count: 40, height: 64,
                start: range.lowerBound, end: range.upperBound
            )
            await MainActor.run { zoomThumbs = thumbs }
        }
    }

    // MARK: - Export

    func createBoomerang() {
        guard let source = sourceURL else { return }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".cma")

        isExporting = true
        exportProgress = 0
        toast = nil

        BoomerangMaker.createBoomerang(
            from: source, outputURL: outURL,
            trimStart: trimStart, trimEnd: trimEnd,
            loopCount: loopCount,
            progress: { [weak self] p in
                DispatchQueue.main.async { self?.exportProgress = p }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async { self?.handleExportResult(result) }
            }
        )
    }

    private func handleExportResult(_ result: Result<URL, Error>) {
        isExporting = false
        switch result {
        case .success(let url):
            // Keep the source video playing — do NOT replace player.
            // Seek back to trimStart so user can make another CMA.
            seekTo(trimStart)
            // Hold in temp until the user chooses album + artist.
            pendingExportURL = url
        case .failure(let err):
            showToast(err.localizedDescription, isError: true)
        }
    }

    // MARK: - Export Destination

    /// Packs discovered in the default library, for the save sheet.
    var exportPacks: [CellaPack] {
        guard let libraryURL else { return [] }
        return ClusterLibrary.scan(libraryURL).packs
    }

    /// Artist to pre-fill: album's `lrc/<song>.lrc` `[ar:]` tag first, then the
    /// `Artist - Title` filename pattern. Nil when neither yields a name.
    func suggestedArtist(for packURL: URL) -> String? {
        guard let source = sourceURL else { return nil }
        let base = source.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        let lrcDir = packURL.appendingPathComponent("lrc")
        let entries = (try? fm.contentsOfDirectory(at: lrcDir, includingPropertiesForKeys: nil)) ?? []

        if let exact = entries.first(where: {
            $0.pathExtension.lowercased() == "lrc"
                && $0.deletingPathExtension().lastPathComponent == base
        }), let artist = parseArtistTag(in: exact) {
            return artist
        }

        for entry in entries where entry.pathExtension.lowercased() == "lrc" {
            let name = entry.deletingPathExtension().lastPathComponent
            guard let sep = name.range(of: " - ") else { continue }
            let title = String(name[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            let artist = String(name[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            if title == base, !artist.isEmpty {
                return artist
            }
        }

        if let sep = base.range(of: " - ") {
            let artist = String(base[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty { return artist }
        }
        return nil
    }

    /// Artist folders already present under `<pack>/cma/` — quick-pick options.
    func existingArtists(in packURL: URL) -> [String] {
        let cma = packURL.appendingPathComponent("cma")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: cma, includingPropertiesForKeys: nil
        )) ?? []
        return entries
            .filter { $0.hasDirectoryPath }
            .map { $0.lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Move the completed export into `<pack>/cma/<artist>/videoN.cma`.
    @discardableResult
    func saveExport(to packURL: URL, artist raw: String) -> Bool {
        guard let temp = pendingExportURL else { return false }
        let artist = cleanedArtist(raw)
        guard !artist.isEmpty else { return false }

        let albumName = packURL.deletingPathExtension().lastPathComponent
        let dir = packURL.appendingPathComponent("cma").appendingPathComponent(artist)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileName = nextVideoName(in: dir)
            let dest = dir.appendingPathComponent(fileName)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: temp, to: dest)
            outputURL = dest
            pendingExportURL = nil
            commitSavedBaseline()
            showToast("Saved: \(albumName) / cma / \(artist) / \(fileName)", isError: false)
            return true
        } catch {
            showToast(error.localizedDescription, isError: true)
            return false
        }
    }

    /// User cancelled the save sheet — drop the temp export.
    func discardExport() {
        if let url = pendingExportURL {
            try? FileManager.default.removeItem(at: url)
        }
        pendingExportURL = nil
    }

    private func cleanedArtist(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private func nextVideoName(in dir: URL) -> String {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        var maxN = 0
        for entry in entries {
            let base = entry.deletingPathExtension().lastPathComponent
            guard base.hasPrefix("video"), base.count > 5,
                  let n = Int(base.dropFirst(5)) else { continue }
            maxN = max(maxN, n)
        }
        return "video\(maxN + 1).cma"
    }

    private func parseArtistTag(in lrcURL: URL) -> String? {
        guard let content = try? String(contentsOf: lrcURL, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[ar:"), let end = trimmed.firstIndex(of: "]") else { continue }
            let start = trimmed.index(trimmed.startIndex, offsetBy: 4)
            let value = String(trimmed[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Clear

    func clearVideo() {
        teardownPlayer()
        discardExport()
        sourceURL = nil
        outputURL = nil
        player = nil
        overviewThumbs = []
        zoomThumbs = []
        zoomed = false
        toast = nil
        videoDuration = 0
        stopPlaybackTimer()
        commitSavedBaseline()
    }

    // MARK: - Toast

    func showToast(_ text: String, isError: Bool) {
        toast = ToastMessage(text: text, isError: isError)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.toast?.text == text { self?.toast = nil }
        }
    }

    // MARK: - Formatting

    func formatTime(_ s: Double) -> String {
        let m = Int(s) / 60
        let sec = Int(s) % 60
        let ms = Int((s - Double(Int(s))) * 10)
        return String(format: "%d:%02d.%d", m, sec, ms)
    }
}

// MARK: - Toast Message

struct ToastMessage {
    let text: String
    let isError: Bool
}