//
//  CellaMotionsView.swift
//  Cella
//
//  Cella Motions — create Instagram boomerang videos.
//

import SwiftUI
import AVKit

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
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var isPlaying = false
    @State private var loopCount: Int = 3
    @State private var filmstripImages: [NSImage] = []
    @State private var currentTime: Double = 0
    @State private var playbackTimer: Timer?

    var body: some View {
        VStack(spacing: 24) {
            Text("Cella Motions")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)

            Text("Create Instagram boomerang from any video")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(theme.textSecondary)

            if let player = player {
                videoPreview(player)
            } else {
                dropZone
            }

            // Action buttons
            HStack(spacing: 16) {
                if sourceURL != nil {
                    Button("Clear") {
                        sourceURL = nil
                        outputURL = nil
                        player = nil
                        filmstripImages = []
                        errorMessage = nil
                        successMessage = nil
                        stopPlaybackTimer()
                    }
                    .buttonStyle(.bordered)
                    .tint(theme.textSecondary)
                }

                if sourceURL != nil && !isExporting {
                    Button("Create Boomerang") {
                        createBoomerang()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.dotActive)
                }

                if isExporting {
                    ProgressView(value: exportProgress)
                        .frame(width: 150)
                    Text("\(Int(exportProgress * 100))%")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if let msg = successMessage {
                Text(msg)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.center)
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

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Video Preview

    private func videoPreview(_ player: AVPlayer) -> some View {
        VStack(spacing: 16) {
            VideoPlayer(player: player)
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 500)
                .onAppear {
                    player.play()
                    isPlaying = true
                    startPlaybackTimer()
                }
                .onDisappear {
                    player.seek(to: .zero)
                    isPlaying = false
                    stopPlaybackTimer()
                }

            if videoDuration > 0 {
                // Trim bar with filmstrip
                FilmstripTrimBar(
                    duration: videoDuration,
                    trimStart: $trimStart,
                    trimEnd: $trimEnd,
                    currentTime: currentTime,
                    thumbnails: filmstripImages,
                    theme: theme,
                    onSeek: { position in
                        let time = CMTime(seconds: position, preferredTimescale: 60000)
                        $player.wrappedValue?.seek(to: time)
                        currentTime = position
                    }
                )
                .frame(maxWidth: 500)
                .frame(height: 80)

                // Time info + preset buttons
                HStack {
                    // Current / selected time
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("Selection:")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.textSecondary)
                            Text("\(formatTime(trimStart)) → \(formatTime(trimEnd))")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.textPrimary)
                        }
                        HStack(spacing: 4) {
                            Text("Duration:")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.textSecondary)
                            Text(formatTime(trimEnd - trimStart))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.dotActive)
                            Text("  |  Output:")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.textSecondary)
                            Text("\(formatTime((trimEnd - trimStart) * Double(loopCount * 2)))")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.textPrimary)
                        }
                    }

                    Spacer()

                    // Preset duration buttons
                    HStack(spacing: 6) {
                        Text("Quick:")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.textSecondary)
                        ForEach([1.0, 2.0, 3.0, 5.0], id: \.self) { secs in
                            Button("\(Int(secs))s") {
                                applyPreset(secs)
                            }
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .buttonStyle(.bordered)
                            .tint(abs((trimEnd - trimStart) - secs) < 0.05 ? theme.dotActive : theme.textSecondary)
                        }
                    }
                }
                .frame(maxWidth: 500)

                // Loop count selector
                HStack(spacing: 12) {
                    Text("Loops:")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(theme.textSecondary)

                    ForEach([1, 2, 3, 5, 8], id: \.self) { n in
                        Button("\(n)x") {
                            loopCount = n
                        }
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .buttonStyle(.bordered)
                        .tint(loopCount == n ? theme.dotActive : theme.textSecondary)
                    }

                    Spacer()
                }
                .frame(maxWidth: 500)

                // Playback controls
                HStack(spacing: 16) {
                    Button {
                        seekToStart()
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.bordered)
                    .tint(theme.textSecondary)

                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.bordered)
                    .tint(theme.textPrimary)

                    // Frame step buttons
                    Button {
                        stepFrame(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(.bordered)
                    .tint(theme.textSecondary)

                    Button {
                        stepFrame(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(.bordered)
                    .tint(theme.textSecondary)
                }
            }
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(theme.dotActive.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .frame(maxWidth: 500, minHeight: 280)
            .overlay(
                VStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.system(size: 48))
                        .foregroundStyle(theme.dotActive.opacity(0.6))
                    Text("Drop video here")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.textSecondary)
                    Text("MP4, MOV")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.textSecondary.opacity(0.6))
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

    // MARK: - Actions

    private func loadVideo(_ url: URL) {
        sourceURL = url
        outputURL = nil
        errorMessage = nil
        successMessage = nil
        filmstripImages = []

        let asset = AVURLAsset(url: url)
        Task {
            let dur = try await asset.load(.duration)
            let secs = CMTimeGetSeconds(dur)
            videoDuration = secs
            trimStart = 0
            trimEnd = secs

            // Generate filmstrip
            let images = await FilmstripGenerator.generateThumbnails(from: url, count: 30, height: 60)
            await MainActor.run { filmstripImages = images }
        }
        player = AVPlayer(url: url)
    }

    private func togglePlayback() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            stopPlaybackTimer()
        } else {
            let start = CMTime(seconds: trimStart, preferredTimescale: 60000)
            player.seek(to: start)
            player.play()
            isPlaying = true
            startPlaybackTimer()

            // Auto-pause at trim end
            let remaining = trimEnd - trimStart
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [player] in
                player.pause()
                isPlaying = false
                stopPlaybackTimer()
            }
        }
    }

    private func seekToStart() {
        guard let player = player else { return }
        player.pause()
        isPlaying = false
        stopPlaybackTimer()
        let start = CMTime(seconds: trimStart, preferredTimescale: 60000)
        player.seek(to: start)
        currentTime = trimStart
    }

    private func stepFrame(by direction: Int) {
        guard let player = player else { return }
        player.pause()
        isPlaying = false
        stopPlaybackTimer()
        let frameDuration = 1.0 / 30.0
        let newTime = max(0, min(videoDuration, currentTime + frameDuration * Double(direction)))
        let time = CMTime(seconds: newTime, preferredTimescale: 60000)
        player.seek(to: time)
        currentTime = newTime
    }

    private func applyPreset(_ seconds: Double) {
        let center = (trimStart + trimEnd) / 2
        let half = seconds / 2
        trimStart = max(0, center - half)
        trimEnd = min(videoDuration, center + half)
        if trimEnd - trimStart < seconds {
            if trimStart == 0 { trimEnd = min(seconds, videoDuration) }
            else { trimStart = max(0, videoDuration - seconds) }
        }
        let time = CMTime(seconds: trimStart, preferredTimescale: 60000)
        player?.seek(to: time)
        currentTime = trimStart
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            guard let player = player else { return }
            let time = CMTimeGetSeconds(player.currentTime())
            currentTime = time
            if time >= trimEnd {
                player.pause()
                isPlaying = false
                stopPlaybackTimer()
            }
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

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
            progress: { exportProgress = $0 },
            completion: { result in
                isExporting = false
                switch result {
                case .success(let url):
                    outputURL = url
                    successMessage = "Saved: \(url.lastPathComponent)"
                    let tmpPreview = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "_preview.mp4")
                    try? FileManager.default.copyItem(at: url, to: tmpPreview)
                    player = AVPlayer(url: tmpPreview)
                case .failure(let err):
                    errorMessage = err.localizedDescription
                }
            }
        )
    }

    private func formatTime(_ s: Double) -> String {
        let m = Int(s) / 60
        let sec = Int(s) % 60
        let ms = Int((s - Double(Int(s))) * 10)
        return String(format: "%d:%02d.%d", m, sec, ms)
    }
}

// MARK: - Filmstrip Trim Bar

struct FilmstripTrimBar: View {
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let currentTime: Double
    let thumbnails: [NSImage]
    let theme: Theme
    var onSeek: ((Double) -> Void)?

    @State private var dragMode: DragMode = .none
    @State private var dragStartValue: Double = 0
    @State private var dragStartTime: Double = 0

    private enum DragMode {
        case none, resizeLeft, resizeRight, move
    }

    private let handleWidth: CGFloat = 12
    private let minTrimDuration: Double = 0.1

    var body: some View {
        VStack(spacing: 0) {
            // Timestamp markers
            timestampBar
                .frame(height: 14)

            // Filmstrip + trim area
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let sx = timeToPixel(trimStart, width: w)
                let ex = timeToPixel(trimEnd, width: w)
                let px = timeToPixel(currentTime, width: w)

                ZStack(alignment: .leading) {
                    // Filmstrip thumbnails
                    if thumbnails.isEmpty {
                        // No thumbnails — solid bar
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.dotInactive.opacity(0.3))
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

                    // Dim outside selection — left
                    if sx > 0 {
                        Rectangle()
                            .fill(.black.opacity(0.55))
                            .frame(width: max(0, sx), height: h)
                    }

                    // Dim outside selection — right
                    if ex < w {
                        let rightW = max(0, w - ex)
                        Rectangle()
                            .fill(.black.opacity(0.55))
                            .frame(width: rightW, height: h)
                            .offset(x: w - rightW)
                    }

                    // Selection border
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(theme.dotActive, lineWidth: 2.5)
                        .frame(width: max(4, ex - sx), height: h)
                        .position(x: (sx + ex) / 2, y: h / 2)

                    // Left handle
                    dragHandle(side: .left, x: sx, height: h)
                        .gesture(handleDrag(side: .left, width: w, height: h))

                    // Right handle
                    dragHandle(side: .right, x: ex, height: h)
                        .gesture(handleDrag(side: .right, width: w, height: h))

                    // Move area (middle of selection)
                    Rectangle()
                        .fill(.clear)
                        .frame(width: max(0, ex - sx - handleWidth * 2), height: h)
                        .position(x: (sx + ex) / 2, y: h / 2)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if dragMode == .none {
                                        dragMode = .move
                                        dragStartValue = trimStart
                                    }
                                    guard dragMode == .move else { return }
                                    let secsPerPx = duration / max(Double(w), 1)
                                    let delta = Double(value.translation.width) * secsPerPx
                                    let selDur = trimEnd - trimStart
                                    let newStart = dragStartValue + delta
                                    let clamped = max(0, min(newStart, duration - selDur))
                                    trimStart = clamped
                                    trimEnd = clamped + selDur
                                    onSeek?(trimStart)
                                }
                                .onEnded { _ in dragMode = .none }
                        )

                    // Playhead
                    if currentTime >= 0 && currentTime <= duration {
                        Rectangle()
                            .fill(.white)
                            .frame(width: 2, height: h + 8)
                            .position(x: px, y: h / 2)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                    }
                }
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .onTapGesture { location in
                    let tappedTime = Double(location.x / w) * duration
                    let clamped = max(0, min(tappedTime, duration))
                    onSeek?(clamped)
                }
            }
            .frame(height: 66)
        }
    }

    // MARK: - Handle View

    private func dragHandle(side: Side, x: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(theme.dotActive)
            .frame(width: handleWidth, height: height)
            .overlay(
                // Grab bars
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(.white.opacity(0.7))
                            .frame(width: 4, height: 2)
                    }
                }
            )
            .position(x: x, y: height / 2)
            .shadow(color: .black.opacity(0.3), radius: 2)
    }

    // MARK: - Handle Drag

    private func handleDrag(side: Side, width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragMode == .none {
                    dragMode = side == .left ? .resizeLeft : .resizeRight
                    dragStartTime = side == .left ? trimStart : trimEnd
                }
                guard dragMode == (side == .left ? DragMode.resizeLeft : DragMode.resizeRight) else { return }
                let secsPerPx = duration / max(Double(width), 1)
                let delta = Double(value.translation.width) * secsPerPx

                if side == .left {
                    let newStart = dragStartTime + delta
                    trimStart = max(0, min(newStart, trimEnd - minTrimDuration))
                    onSeek?(trimStart)
                } else {
                    let newEnd = dragStartTime + delta
                    trimEnd = min(duration, max(newEnd, trimStart + minTrimDuration))
                    onSeek?(trimEnd)
                }
            }
            .onEnded { _ in dragMode = .none }
    }

    // MARK: - Timestamp Bar

    private var timestampBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let markerCount = max(2, Int(w / 60))
            let interval = duration / Double(markerCount)

            ZStack {
                ForEach(0...markerCount, id: \.self) { i in
                    let time = Double(i) * interval
                    let x = CGFloat(Double(i) / Double(markerCount)) * w

                    Text(formatTimeShort(time))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(theme.textSecondary.opacity(0.7))
                        .position(x: x, y: 7)

                    if i > 0 {
                        Rectangle()
                            .fill(theme.textSecondary.opacity(0.2))
                            .frame(width: 1, height: 4)
                            .position(x: x, y: 12)
                        }
                }
            }
        }
    }

    // MARK: - Helpers

    private func timeToPixel(_ time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }

    private func formatTimeShort(_ s: Double) -> String {
        let m = Int(s) / 60
        let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }

    private enum Side { case left, right }
}
