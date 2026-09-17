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
        let outName = source.deletingPathExtension().lastPathComponent + ".cma"
        let outURL = source.deletingLastPathComponent().appendingPathComponent(outName)

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
            outputURL = url
            showToast("Saved: \(url.lastPathComponent)", isError: false)
            // Keep the source video playing — do NOT replace player.
            // Seek back to trimStart so user can make another CMA.
            seekTo(trimStart)
            commitSavedBaseline()
        case .failure(let err):
            showToast(err.localizedDescription, isError: true)
        }
    }

    // MARK: - Clear

    func clearVideo() {
        teardownPlayer()
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