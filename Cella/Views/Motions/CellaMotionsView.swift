//
//  CellaMotionsView.swift
//  Cella
//
//  Cella Motions — create Instagram boomerang videos.
//  Mark-based trimmer: scrub to the moment, tap to mark in/out.
//  Precision from the big video frame, not tiny filmstrip handles.
//

import SwiftUI
import AVKit

/// Preset boomerang clip durations (seconds).
private let presetDurations: [Double] = [0.3, 0.5, 1.0, 2.0]

struct CellaMotionsView: View {
    @Environment(\.theme) private var theme

    @State private var sourceURL: URL?
    @State private var outputURL: URL?
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var errorMessage: String?
    @State private var successMessage: String?

    @State private var player: AVPlayer?
    @State private var videoDuration: Double = 0
    @State private var frameRate: Double = 30
    @State private var timeObserver: Any?

    // Selection
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 1.0
    @State private var targetDuration: Double = 1.0
    @State private var currentTime: Double = 0

    // Filmstrip (full video, static — always aligned)
    @State private var overviewThumbs: [NSImage] = []

    // UI
    @State private var isPlaying = false
    @State private var isLoopPreviewing = false
    @State private var loopCount: Int = 3
    @State private var playbackTimer: Timer?

    var body: some View {
        VStack(spacing: 18) {
            Text("Cella Motions")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)

            if sourceURL != nil {
                editor
            } else {
                dropZone
            }

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(spacing: 14) {
            videoPlayer
            scrubBar

            if videoDuration > 0 {
                timeReadout
                markControls
                filmStrip
                presetRow
                nudgeRow
                exportRow

                if let error = errorMessage {
                    Text(error).font(.system(size: 13, design: .rounded)).foregroundStyle(.red)
                }
                if let msg = successMessage {
                    Text(msg).font(.system(size: 13, design: .rounded)).foregroundStyle(.green)
                }
            }
        }
        .frame(maxWidth: 640)
    }

    // MARK: - Video Player

    private var videoPlayer: some View {
        VideoPlayer(player: player)
            .aspectRatio(16/9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 560)
            .overlay(alignment: .topTrailing) {
                // Live time badge
                Text(now)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.tabBarBackground))
                    .padding(8)
            }
    }

    private var now: String {
        formatTime(currentTime)
    }

    // MARK: - Scrub Bar

    private var scrubBar: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { currentTime },
                    set: { seekTo($0) }
                ),
                in: 0...max(0, videoDuration),
                onEditingChanged: { editing in
                    if editing { player?.pause(); isPlaying = false }
                }
            )
            .frame(maxWidth: 560)

            HStack {
                Text(formatTime(0))
                Spacer()
                Text("/ \(formatTime(videoDuration))")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(theme.textSecondary.opacity(0.6))
            .frame(maxWidth: 560)
        }
    }

    // MARK: - Time Readout

    private var timeReadout: some View {
        HStack(spacing: 14) {
            readoutCell("In", formatTime(trimStart))
            readoutCell("Dur", String(format: "%.2fs", trimEnd - trimStart))
            readoutCell("Out", formatTime(trimEnd))
        }
        .frame(maxWidth: 560)
    }

    private func readoutCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textSecondary.opacity(0.7))
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.tabBarBackground))
    }

    // MARK: - Mark Controls

    private var markControls: some View {
        HStack(spacing: 12) {
            Button {
                markIn()
            } label: {
                Label("Mark In", systemImage: "arrow.left.to.line")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.dotActive)
            .help("Set clip start to current playhead")

            Button {
                markOut()
            } label: {
                Label("Mark Out", systemImage: "arrow.right.to.line")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.dotActive)

            Button {
                toggleLoopPreview()
            } label: {
                Label(isLoopPreviewing ? "Stop Preview" : "Loop Preview",
                      systemImage: isLoopPreviewing ? "stop.fill" : "repeat")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.bordered)
            .tint(isLoopPreviewing ? theme.dotActive : theme.textSecondary)
            .help("Preview the selection as a loop")
        }
        .frame(maxWidth: 560)
    }

    // MARK: - Filmstrip

    private var filmStrip: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Drag the white playhead or tap to scrub")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(theme.textSecondary.opacity(0.8))
                Spacer()
                Text("\(formatTime(trimStart)) — \(formatTime(trimEnd))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.dotActive)
            }
            .frame(maxWidth: 600)

            FilmstripBar(
                duration: videoDuration,
                trimStart: $trimStart,
                trimEnd: $trimEnd,
                currentTime: currentTime,
                thumbnails: overviewThumbs,
                theme: theme,
                onScrub: { position in
                    seekTo(position)
                },
                onMoveSelectionTo: { position in
                    placeClip(at: position, keepDuration: true)
                }
            )
            .frame(maxWidth: 600)
            .frame(height: 64)
        }
    }

    // MARK: - Presets

    private var presetRow: some View {
        HStack(spacing: 8) {
            Text("Length:")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textSecondary)

            ForEach(presetDurations, id: \.self) { secs in
                Button("\(formatPreset(secs))s") {
                    setTargetDuration(secs)
                }
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .buttonStyle(.bordered)
                .tint(targetDuration == secs ? theme.dotActive : theme.textSecondary)
            }
        }
        .frame(maxWidth: 560)
    }

    // MARK: - Nudge Row

    private var nudgeRow: some View {
        HStack(spacing: 10) {
            Text("Fine:")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.textSecondary)

            Button { nudgeTrimStart(-0.1) } label: { Text("◀◀ 0.1").font(.system(size: 10, design: .monospaced)) }
                .buttonStyle(.bordered).tint(theme.textSecondary)
            Button { nudgeTrimStart(0.1) } label: { Text("0.1 ▶").font(.system(size: 10, design: .monospaced)) }
                .buttonStyle(.bordered).tint(theme.textSecondary)

            Spacer()

            Button { stepFrame(by: -1) } label: { Text("◀ frame").font(.system(size: 10, design: .monospaced)) }
                .buttonStyle(.bordered).tint(theme.textSecondary)
            Button { stepFrame(by: 1) } label: { Text("frame ▶").font(.system(size: 10, design: .monospaced)) }
                .buttonStyle(.bordered).tint(theme.textSecondary)
        }
        .frame(maxWidth: 560)
    }

    // MARK: - Export

    private var exportRow: some View {
        HStack(spacing: 12) {
            Button("Clear") { clearVideo() }
                .buttonStyle(.bordered)
                .tint(theme.textSecondary)

            if !isExporting {
                Button("Create Boomerang") { createBoomerang() }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.dotActive)
                    .disabled(videoDuration <= 0)
            } else {
                ProgressView(value: exportProgress).frame(width: 160)
                Text("\(Int(exportProgress * 100))%")
                    .font(.system(size: 13, design: .monospaced))
            }

            if outputURL != nil {
                Button("Show in Finder") {
                    if let url = outputURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .buttonStyle(.bordered)
                .tint(theme.dotActive)
            }
        }
        .frame(maxWidth: 560)
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(theme.dotActive.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .frame(maxWidth: 560, minHeight: 280)
            .overlay(
                VStack(spacing: 12) {
                    Image(systemName: "film").font(.system(size: 48)).foregroundStyle(theme.dotActive.opacity(0.6))
                    Text("Drop video here").font(.system(size: 16, weight: .medium, design: .rounded)).foregroundStyle(theme.textSecondary)
                    Text("MP4, MOV").font(.system(size: 12, design: .rounded)).foregroundStyle(theme.textSecondary.opacity(0.6))
                }
            )
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url as? URL {
                        DispatchQueue.main.async { loadVideo(url) }
                    }
                }
                return true
            }
    }

    // MARK: - Video Loading

    private func loadVideo(_ url: URL) {
        sourceURL = url
        outputURL = nil
        errorMessage = nil
        successMessage = nil
        overviewThumbs = []
        stopPlaybackTimer()

        let asset = AVURLAsset(url: url)
        Task {
            let dur = try await asset.load(.duration)
            let secs = CMTimeGetSeconds(dur)
            await MainActor.run {
                videoDuration = secs
                trimStart = 0
                trimEnd = min(targetDuration, secs)
            }

            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let fr = try? await track.load(.nominalFrameRate) {
                let f = Double(fr)
                await MainActor.run { if f > 0 { frameRate = f } }
            }

            let thumbs = await FilmstripGenerator.generateThumbnails(
                from: url, count: 30, height: 64
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
        ) { time in
            currentTime = CMTimeGetSeconds(time)
        }
    }

    // MARK: - Mark Selection

    /// Set start = playhead; end = playhead + target duration (clamped).
    private func markIn() {
        let dur = min(targetDuration, videoDuration)
        let s = min(currentTime, videoDuration - dur)
        trimStart = s
        trimEnd = s + dur
        playSelection()
    }

    /// Set end = playhead; start = playhead - target duration (clamped).
    private func markOut() {
        let dur = min(targetDuration, videoDuration)
        let e = max(currentTime, dur)
        trimStart = e - dur
        trimEnd = e
        playSelection()
    }

    private func setTargetDuration(_ secs: Double) {
        targetDuration = secs
        placeClip(at: currentTime, keepDuration: false)
    }

    /// Move a clip (of current or target duration) to start at `position`.
    private func placeClip(at position: Double, keepDuration: Bool) {
        let dur = keepDuration ? (trimEnd - trimStart) : min(targetDuration, videoDuration)
        let s = min(max(0, position), videoDuration - dur)
        trimStart = s
        trimEnd = s + dur
        seekTo(trimStart)
    }

    private func nudgeTrimStart(_ delta: Double) {
        trimStart = max(0, min(trimStart + delta, trimEnd - 0.05))
        seekTo(trimStart)
    }

    private func nudgeTrimEnd(_ delta: Double) {
        trimEnd = min(videoDuration, max(trimEnd + delta, trimStart + 0.05))
    }

    // MARK: - Playback

    private func playSelection() {
        guard let player = player else { return }
        let start = CMTime(seconds: trimStart, preferredTimescale: 60000)
        player.seek(to: start)
        player.play()
        isPlaying = true
        startPlaybackTimer()
    }

    private func toggleLoopPreview() {
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

    private func seekTo(_ position: Double) {
        guard let player = player else { return }
        let p = max(0, min(position, videoDuration))
        let time = CMTime(seconds: p, preferredTimescale: 60000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = p
    }

    private func stepFrame(by direction: Int) {
        player?.pause()
        isPlaying = false
        stopPlaybackTimer()
        let frameDur = 1.0 / frameRate
        seekTo(max(0, min(videoDuration, currentTime + frameDur * Double(direction))))
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            guard let player = player else { return }
            let t = CMTimeGetSeconds(player.currentTime())
            currentTime = t
            if t >= trimEnd {
                if isLoopPreviewing {
                    player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 60000))
                    player.play()
                } else {
                    player.pause()
                    isPlaying = false
                    stopPlaybackTimer()
                }
            }
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    /// Cleanly tear down the current player: remove observer, stop timer, pause.
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

    // MARK: - Export

    private func createBoomerang() {
        guard let source = sourceURL else { return }
        let outName = source.deletingPathExtension().lastPathComponent + ".cma"
        let outURL = source.deletingLastPathComponent().appendingPathComponent(outName)

        isExporting = true
        exportProgress = 0
        errorMessage = nil
        successMessage = nil

        BoomerangMaker.createBoomerang(
            from: source, outputURL: outURL,
            trimStart: trimStart, trimEnd: trimEnd,
            loopCount: loopCount,
            progress: { p in
                DispatchQueue.main.async { exportProgress = p }
            },
            completion: { result in
                DispatchQueue.main.async { handleExportResult(result) }
            }
        )
    }

    private func handleExportResult(_ result: Result<URL, Error>) {
        isExporting = false
        switch result {
        case .success(let url):
            outputURL = url
            successMessage = "Saved: \(url.lastPathComponent)"
            let tmpPreview = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "_preview.mp4")
            try? FileManager.default.copyItem(at: url, to: tmpPreview)
            teardownPlayer()
            let previewPlayer = AVPlayer(url: tmpPreview)
            previewPlayer.pause()
            player = previewPlayer
            startTimeObserver(on: previewPlayer)
        case .failure(let err):
            errorMessage = err.localizedDescription
        }
    }

    private func clearVideo() {
        teardownPlayer()
        sourceURL = nil
        outputURL = nil
        player = nil
        overviewThumbs = []
        errorMessage = nil
        successMessage = nil
        videoDuration = 0
        stopPlaybackTimer()
    }

    // MARK: - Formatting

    private func formatTime(_ s: Double) -> String {
        let m = Int(s) / 60
        let sec = Int(s) % 60
        let ms = Int((s - Double(Int(s))) * 10)
        return String(format: "%d:%02d.%d", m, sec, ms)
    }

    private func formatPreset(_ secs: Double) -> String {
        secs == 0.3 ? "0.3" : secs == 0.5 ? "0.5" : "\(Int(secs))"
    }
}

// MARK: - Filmstrip Bar

/// Full-video filmstrip for scrubbing and selection visual.
/// Drag playhead to scrub; grab selection band middle to move a placed clip.
struct FilmstripBar: View {
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let currentTime: Double
    let thumbnails: [NSImage]
    let theme: Theme
    var onScrub: ((Double) -> Void)?
    var onMoveSelectionTo: ((Double) -> Void)?

    @State private var dragOrigin: Double?

    private let handleWidth: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let sx = x(trimStart, w)
            let ex = x(trimEnd, w)
            let px = x(currentTime, w)

            ZStack(alignment: .leading) {
                // Filmstrip
                if thumbnails.isEmpty {
                    RoundedRectangle(cornerRadius: 4).fill(theme.dotInactive.opacity(0.3))
                } else {
                    HStack(spacing: 0) {
                        ForEach(thumbnails.indices, id: \.self) { i in
                            Image(nsImage: thumbnails[i])
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: max(1, w / CGFloat(thumbnails.count)), height: h)
                                .clipped()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                // Dim outside selection
                if sx > 0 {
                    Rectangle().fill(.black.opacity(0.55)).frame(width: sx, height: h)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if ex < w {
                    Rectangle().fill(.black.opacity(0.55)).frame(width: w - ex, height: h)
                        .offset(x: ex)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                // Selection band (normal + larger hit area)
                RoundedRectangle(cornerRadius: 4)
                    .stroke(theme.dotActive, lineWidth: 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.dotActive.opacity(0.1)))
                    .frame(width: max(8, ex - sx), height: h)
                    .position(x: (sx + ex) / 2, y: h / 2)

                // Left edge marker
                edgeMarker(x: sx, h: h)
                // Right edge marker
                edgeMarker(x: ex, h: h)

                // Whole-selection move (large hit area)
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .frame(width: max(8, ex - sx), height: h)
                    .position(x: (sx + ex) / 2, y: h / 2)
                    .gesture(moveDrag(width: w))

                // Playhead — draggable for scrubbing, taller than strip
                Rectangle()
                    .fill(.white)
                    .frame(width: 3, height: h + 12)
                    .position(x: px, y: h / 2)
                    .shadow(color: .black.opacity(0.7), radius: 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let p = Double(value.location.x / w) * duration
                                onScrub?(max(0, min(p, duration)))
                            }
                    )
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { location in
                let p = Double(location.x / w) * duration
                onScrub?(max(0, min(p, duration)))
            }
        }
    }

    private func edgeMarker(x: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(theme.dotActive)
            .frame(width: 3, height: h)
            .position(x: x, y: h / 2)
    }

    private func moveDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = trimStart
                }
                let secsPerPx = duration / max(Double(width), 1)
                let delta = Double(value.translation.width) * secsPerPx
                let sel = trimEnd - trimStart
                let s = max(0, min((dragOrigin ?? 0) + delta, duration - sel))
                trimStart = s
                trimEnd = s + sel
            }
            .onEnded { _ in
                dragOrigin = nil
                onMoveSelectionTo?(trimStart)
            }
    }

    private func x(_ time: Double, _ w: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * w
    }
}
