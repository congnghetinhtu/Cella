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
                        errorMessage = nil
                        successMessage = nil
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
                }
                .onDisappear {
                    player.seek(to: .zero)
                    isPlaying = false
                }

            if videoDuration > 0 {
                // Time labels
                HStack {
                    Text(formatTime(trimStart))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 50, alignment: .leading)
                    Spacer()
                    Text("\(formatTime(trimEnd - trimStart))")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text(formatTime(trimEnd))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 50, alignment: .trailing)
                }
                .frame(maxWidth: 500)

                // Trim bar
                VideoTrimBar(
                    duration: videoDuration,
                    trimStart: $trimStart,
                    trimEnd: $trimEnd,
                    theme: theme,
                    onTrimChanged: { position in
                        let time = CMTime(seconds: position, preferredTimescale: 60000)
                        $player.wrappedValue?.seek(to: time)
                    }
                )
                .frame(maxWidth: 500)
                .frame(height: videoDuration > 30 ? 110 : 80)
                .onChange(of: trimStart) { _, val in
                    let time = CMTime(seconds: val, preferredTimescale: 60000)
                    $player.wrappedValue?.seek(to: time)
                }
                .onChange(of: trimEnd) { _, val in
                    let time = CMTime(seconds: val, preferredTimescale: 60000)
                    $player.wrappedValue?.seek(to: time)
                }

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

                    Text("\(formatTime(trimEnd - trimStart) ) × \(loopCount) = \(formatTime((trimEnd - trimStart) * Double(loopCount * 2)))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
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

        let asset = AVURLAsset(url: url)
        Task {
            let dur = try await asset.load(.duration)
            let secs = CMTimeGetSeconds(dur)
            videoDuration = secs
            trimStart = 0
            trimEnd = secs
        }
        player = AVPlayer(url: url)
    }

    private func togglePlayback() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            let start = CMTime(seconds: trimStart, preferredTimescale: 60000)
            player.seek(to: start)
            player.play()
            isPlaying = true

            // Auto-pause at trim end
            let remaining = trimEnd - trimStart
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [player] in
                player.pause()
                isPlaying = false
            }
        }
    }

    private func seekToStart() {
        guard let player = player else { return }
        player.pause()
        isPlaying = false
        let start = CMTime(seconds: trimStart, preferredTimescale: 60000)
        player.seek(to: start)
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
                    // Preview via temp .mp4 copy (AVPlayer doesn't recognize .cma)
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

// MARK: - Trim Bar (zoom + pan)

struct VideoTrimBar: View {
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let theme: Theme
    var onTrimChanged: ((Double) -> Void)?

    @State private var dragMode: DragMode = .none
    @State private var dragStartTime: Double = 0
    @State private var dragStartValue: Double = 0

    @State private var zoomLevel: Double = 1.0
    @State private var panOffset: Double = 0.0

    private enum DragMode {
        case none, move, resizeLeft, resizeRight, pan
    }

    private let edgeThreshold: CGFloat = 30
    private let minZoom: Double = 1.0
    private let maxZoom: Double = 200.0

    private var visibleDuration: Double {
        guard zoomLevel > 1.0 else { return duration }
        return duration / zoomLevel
    }

    private var visibleStart: Double {
        guard zoomLevel > 1.0 else { return 0 }
        let maxPan = max(0, duration - visibleDuration)
        return panOffset * maxPan
    }

    private var visibleEnd: Double {
        visibleStart + visibleDuration
    }

    var body: some View {
        VStack(spacing: 4) {
            // Zoom slider
            if duration > 30 {
                HStack(spacing: 8) {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)

                    Slider(value: $zoomLevel, in: minZoom...maxZoom)
                        .controlSize(.small)

                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)

                    Text("\(Int(zoomLevel))x")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 28, alignment: .trailing)
                }
                .frame(maxWidth: 300)
            }

            // Trim bar
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let trackY = h / 2
                let sx = timeToPixel(trimStart, width: w)
                let ex = timeToPixel(trimEnd, width: w)
                let selW = max(2, ex - sx)
                let midX = (sx + ex) / 2

                ZStack {
                    // Full track bar
                    Capsule()
                        .fill(theme.dotInactive.opacity(0.3))
                        .frame(height: 6)
                        .position(x: w / 2, y: trackY)

                    // Left dim (visible outside range)
                    if visibleStart > 0 {
                        Rectangle()
                            .fill(.black.opacity(0.5))
                            .frame(width: max(0, sx), height: h)
                    }

                    // Right dim (visible outside range)
                    if visibleEnd < duration {
                        let rightDimW = max(0, w - ex)
                        Rectangle()
                            .fill(.black.opacity(0.5))
                            .frame(width: rightDimW, height: h)
                            .offset(x: w - rightDimW)
                    }

                    // Dim outside visible range (when zoomed)
                    if zoomLevel > 1.0 {
                        // Left edge dim for pan area
                        let leftEdge = max(0, -CGFloat(visibleStart / duration) * w)
                        if leftEdge > 0 {
                            Rectangle()
                                .fill(.black.opacity(0.6))
                                .frame(width: leftEdge, height: h)
                        }
                        // Right edge dim for pan area
                        let rightEdgeStart = CGFloat((duration - visibleStart - visibleDuration) / duration) * w + CGFloat(visibleDuration / duration) * w
                        if rightEdgeStart < w {
                            Rectangle()
                                .fill(.black.opacity(0.6))
                                .frame(width: max(0, w - rightEdgeStart), height: h)
                                .offset(x: rightEdgeStart - w + max(0, w - rightEdgeStart))
                        }
                    }

                    // Selected region
                    Capsule()
                        .fill(theme.dotActive.opacity(0.35))
                        .frame(width: selW, height: 6)
                        .position(x: midX, y: trackY)

                    // Selection border
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.dotActive, lineWidth: 2)
                        .frame(width: selW, height: h)
                        .position(x: midX, y: trackY)

                    // Left handle
                    Capsule()
                        .fill(theme.dotActive)
                        .frame(width: 10, height: h - 4)
                        .position(x: sx, y: trackY)

                    // Right handle
                    Capsule()
                        .fill(theme.dotActive)
                        .frame(width: 10, height: h - 4)
                        .position(x: ex, y: trackY)

                    // Center time marker when zoomed
                    if zoomLevel > 2.0 {
                        Text(formatTime((visibleStart + visibleEnd) / 2))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(theme.textSecondary.opacity(0.6))
                            .position(x: w / 2, y: h - 8)
                    }
                }
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let loc = value.location.x

                            if dragMode == .none {
                                if abs(loc - sx) < edgeThreshold {
                                    dragMode = .resizeLeft
                                    dragStartTime = trimStart
                                } else if abs(loc - ex) < edgeThreshold {
                                    dragMode = .resizeRight
                                    dragStartTime = trimEnd
                                } else if zoomLevel > 1.0 {
                                    dragMode = .pan
                                    dragStartValue = panOffset
                                } else {
                                    dragMode = .move
                                    dragStartTime = trimStart
                                    dragStartValue = trimStart
                                }
                            }

                            let secsPerPx = visibleDuration / max(Double(w), 1)
                            let delta = Double(value.translation.width) * secsPerPx

                            switch dragMode {
                            case .resizeLeft:
                                let newStart = dragStartTime + delta
                                trimStart = max(0, min(newStart, trimEnd - 0.1))
                                onTrimChanged?(trimStart)
                            case .resizeRight:
                                let newEnd = dragStartTime + delta
                                trimEnd = min(duration, max(newEnd, trimStart + 0.1))
                                onTrimChanged?(trimEnd)
                            case .move:
                                let selDur = trimEnd - trimStart
                                let newStart = dragStartTime + delta
                                let clamped = max(0, min(newStart, duration - selDur))
                                trimStart = clamped
                                trimEnd = clamped + selDur
                                onTrimChanged?(trimStart)
                            case .pan:
                                let maxPan = max(0, duration - visibleDuration)
                                let panDelta = Double(value.translation.width) / max(Double(w), 1)
                                let newPan = dragStartValue - panDelta
                                panOffset = max(0, min(1.0, newPan))
                            case .none:
                                break
                            }
                        }
                        .onEnded { _ in
                            dragMode = .none
                        }
                )
                .onTapGesture(count: 2) {
                    zoomToSelection()
                }
            }
        }
        .onChange(of: trimStart) { _, _ in
            clampPanToSelection()
        }
        .onChange(of: trimEnd) { _, _ in
            clampPanToSelection()
        }
    }

    // MARK: - Helpers

    private func timeToPixel(_ time: Double, width: CGFloat) -> CGFloat {
        guard visibleDuration > 0 else { return 0 }
        return CGFloat((time - visibleStart) / visibleDuration) * width
    }

    private func zoomToSelection() {
        let selDur = trimEnd - trimStart
        guard selDur > 0, duration > 0 else { return }

        if zoomLevel > 1.5 {
            // Already zoomed — zoom out to full
            withAnimation(.smooth) {
                zoomLevel = 1.0
                panOffset = 0.0
            }
        } else {
            // Zoom to show selection + 20% padding on each side
            let paddedDur = selDur * 1.4
            let newZoom = min(maxZoom, max(minZoom, duration / max(paddedDur, 0.5)))
            let center = (trimStart + trimEnd) / 2
            let newVisDur = duration / newZoom
            let maxPan = max(0, duration - newVisDur)
            let targetPan = maxPan > 0 ? (center - newVisDur / 2) / maxPan : 0

            withAnimation(.smooth) {
                zoomLevel = newZoom
                panOffset = max(0, min(1.0, targetPan))
            }
        }
    }

    private func clampPanToSelection() {
        guard zoomLevel > 1.0 else { return }
        if trimStart < visibleStart || trimEnd > visibleEnd {
            let center = (trimStart + trimEnd) / 2
            let newVisDur = duration / zoomLevel
            let maxPan = max(0, duration - newVisDur)
            let targetPan = maxPan > 0 ? (center - newVisDur / 2) / maxPan : 0
            withAnimation(.snappy) {
                panOffset = max(0, min(1.0, targetPan))
            }
        }
    }

    private func formatTime(_ s: Double) -> String {
        let m = Int(s) / 60
        let sec = Int(s) % 60
        let ms = Int((s - Double(Int(s))) * 10)
        return String(format: "%d:%02d.%d", m, sec, ms)
    }
}
