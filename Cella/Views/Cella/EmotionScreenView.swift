import SwiftUI
import AVFoundation
import AVKit

// MARK: - Video Background (NSViewRepresentable for AVPlayerLayer)

struct VideoBackgroundView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspectFill
        view.layer?.cornerRadius = 16
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

struct EmotionScreenView: View {
    let pattern: [[Bool]]
    var viewModel: PlayerViewModel?
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("displayMode") private var displayMode: String = "matrix"

    @State private var isHoveringBar = false
    @State private var isDragging = false
    @State private var dragProgress: CGFloat?
    @State private var frozenLyricIndex = -1
    @State private var isHoveringScreen = false
    @State private var scrollMonitor: Any?
    @State private var lastActiveLine = ""
    @State private var borderPulseStart: Date = .distantPast

    private static let barWidth: CGFloat =
        CGFloat(MatrixPatterns.columns) * 36 + CGFloat(MatrixPatterns.columns - 1) * 24

    private var currentProgress: CGFloat {
        if let drag = dragProgress { return drag }
        guard let vm = viewModel, vm.currentDuration > 0 else { return 0 }
        return CGFloat(vm.currentTime / vm.currentDuration)
    }

    private var lyricsMode: LyricsMode {
        viewModel?.lyricsMode ?? .off
    }

    private var showFullLyrics: Bool {
        guard let vm = viewModel else { return false }
        return lyricsMode == .full && !vm.currentLyrics.isEmpty
    }

    private var showSlimLyrics: Bool {
        guard let vm = viewModel else { return false }
        return lyricsMode == .slim && !vm.currentLyrics.isEmpty
    }

    private var currentLyricLine: String {
        guard let vm = viewModel, !vm.currentLyrics.isEmpty else { return "" }
        for i in stride(from: vm.currentLyrics.count - 1, through: 0, by: -1) {
            if vm.currentTime >= vm.currentLyrics[i].time - 0.1 {
                return vm.currentLyrics[i].text
            }
        }
        return vm.currentLyrics.first?.text ?? ""
    }

    /// Index of the currently active lyric line, or -1 when none.
    private var currentLyricIndex: Int {
        guard let vm = viewModel, !vm.currentLyrics.isEmpty else { return -1 }
        for i in stride(from: vm.currentLyrics.count - 1, through: 0, by: -1) {
            if vm.currentTime >= vm.currentLyrics[i].time - 0.1 {
                return i
            }
        }
        return vm.currentLyrics.isEmpty ? -1 : 0
    }

    /// True if given text is a pure "..." placeholder (not inline line-ending).
    private func isEllipsisPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed == "..." || trimmed.allSatisfy { $0 == "." }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.dotInactiveDeep)

            // Artist image background — only when playing
            if let vm = viewModel,
               vm.playerState.isPlaying || vm.playerState == .autoMix {
                if let player = vm.videoPlayer {
                    // Video boomerang background
                    VideoBackgroundView(player: player)
                        .opacity(0.35)
                        .blur(radius: 4)
                        .transition(.opacity)
                } else if let image = vm.currentArtistImage {
                    // Static/GIF image background
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(21.0 / 9.0, contentMode: .fill)
                        .opacity(0.35)
                        .blur(radius: 4)
                        .clipped()
                        .transition(.opacity)
                        .animation(.smooth, value: vm.currentArtistImage?.hash)
                }
            }

            // Main content (matrix / line / static)
            mainContent
                .blur(radius: showFullLyrics ? 8 : 0)
                .animation(.smooth, value: showFullLyrics)

            // Full lyrics overlay (centered in 21:9)
            if showFullLyrics, let vm = viewModel {
                LyricsView(
                    lyrics: vm.currentLyrics,
                    currentTime: vm.currentTime,
                    isPlaying: vm.playerState.isPlaying || vm.playerState == .autoMix,
                    nextLyrics: vm.nextLyrics,
                    isTransitioning: vm.isTransitioning,
                    frozenIndex: frozenLyricIndex
                )
                .transition(.opacity)
                .onChange(of: vm.isTransitioning) { _, transitioning in
                    if transitioning && frozenLyricIndex < 0 {
                        for i in stride(from: vm.currentLyrics.count - 1, through: 0, by: -1) {
                            if vm.currentTime >= vm.currentLyrics[i].time - 0.1 {
                                frozenLyricIndex = i
                                break
                            }
                        }
                    } else if !transitioning {
                        frozenLyricIndex = -1
                    }
                }
            }

            if viewModel?.isAnimationPaused == true {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Text("Paused")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.textPrimary.opacity(0.7))
                    )
                    .onTapGesture {
                        viewModel?.isAnimationPaused = false
                    }
            }
        }
        .overlay(slimLyricsOverlay, alignment: .bottom)
        .overlay(alignment: .bottom) {
            TimelineView(.animation) { _ in
                ambientBar
            }
        }
        .overlay(
            TimelineView(.animation) { timeline in
                let pulse = pulseAmount(at: timeline.date)
                let isAutoMix = (viewModel?.playerState == .autoMix)
                let base = isAutoMix ? 1.0 : 0.0
                let glow = min(1.0, base + pulse)

                RoundedRectangle(cornerRadius: 18)
                    .stroke(
                        LinearGradient(
                            colors: [
                                .green.opacity(0.0),
                                .green.opacity(0.6 * glow),
                                .mint.opacity(0.8 * glow),
                                .green.opacity(0.6 * glow),
                                .green.opacity(0.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2
                    )
                    .shadow(color: .green.opacity(0.6 * glow), radius: 12)
                    .shadow(color: .mint.opacity(0.4 * glow), radius: 20)
                    .opacity(glow)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .aspectRatio(21.0 / 9.0, contentMode: .fit)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHoveringScreen = true
                startScrollMonitor()
            case .ended:
                isHoveringScreen = false
                stopScrollMonitor()
            }
        }
        .onChange(of: currentLyricIndex) { _, newIndex in
            detectLyricTransition(to: newIndex)
        }
        .onChange(of: viewModel?.currentLyrics ?? []) { _, _ in
            lastActiveLine = ""
        }
    }

    // MARK: - Lyric Transition Pulse

    /// Pulse envelope (0..1) based on time since last lyric-triggered pulse.
    private func pulseAmount(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(borderPulseStart)
        // No pulse yet
        guard borderPulseStart != .distantPast else { return 0 }
        // Rise fast (0.12s), hold, fall over total ~1.0s
        let total: TimeInterval = 1.0
        guard elapsed >= 0 && elapsed <= total else { return 0 }
        let rise: TimeInterval = 0.15
        if elapsed < rise {
            let t = elapsed / rise
            return t * t * (3 - 2 * t)   // easeInOut
        }
        let fall = total - rise
        let t = (elapsed - rise) / fall
        return 1.0 - t * t                 // easeOut fall
    }

    private func detectLyricTransition(to index: Int) {
        guard let vm = viewModel, index >= 0, index < vm.currentLyrics.count else { return }
        let currentText = vm.currentLyrics[index].text
        // Only pulse when the line BEFORE was a pure "..." placeholder
        // and the current line is a real lyric.
        if isEllipsisPlaceholder(lastActiveLine) && !isEllipsisPlaceholder(currentText) {
            borderPulseStart = Date()
        }
        // Update running "previous line" — but ignore repeated identical lines
        // (keep the ellipsis marker until a genuinely different anchor arrives).
        if currentText != lastActiveLine {
            lastActiveLine = currentText
        }
    }

    // MARK: - Volume Scroll Monitor

    private func startScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            self.handleScrollWheel(event)
            return event
        }
    }

    private func stopScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    private func handleScrollWheel(_ event: NSEvent) {
        guard let vm = viewModel else { return }
        let raw = event.scrollingDeltaY
        let newVolume = max(0, min(1, vm.currentVolume + Float(raw) * 0.001))
        vm.setVolumeImmediate(newVolume)
    }

    // MARK: - Slim Lyrics (single line above progress bar)

    private var slimLyricsOverlay: some View {
        Group {
            if showSlimLyrics && !currentLyricLine.isEmpty {
                Text(currentLyricLine)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.dotActive)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 28)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
                    .animation(.smooth, value: currentLyricLine)
            }
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        if displayMode == "static" {
            EmptyView()
        } else if displayMode == "line", let vm = viewModel {
            LineAnimationView(viewModel: vm)
        } else {
            DotMatrixView(pattern: pattern)
        }
    }

    // MARK: - Progress Bar

    private var ambientBar: some View {
        let barHeight: CGFloat = isHoveringBar || isDragging ? 4 : 2
        let bw = Self.barWidth
        let spotWidth: CGFloat = 40
        let isLight = colorScheme == .light

        let baseOpac: Double = isLight ? 0.7 : 0.35
        let hoverOpac: Double = isLight ? 1.0 : 0.9
        let trackOpac: Double = isLight ? 0.6 : (isHoveringBar || isDragging ? 0.35 : 0.2)
        let sweepMax: Double = isLight ? 0.7 : 0.5

        return HStack {
            Spacer()
            ZStack(alignment: .bottomLeading) {
                Capsule()
                    .fill(theme.dotInactive.opacity(trackOpac))
                    .frame(height: barHeight)

                Capsule()
                    .fill(theme.dotActive.opacity(isHoveringBar || isDragging ? hoverOpac : baseOpac))
                    .frame(
                        width: max(barHeight, bw * currentProgress),
                        height: barHeight
                    )
                    .overlay(
                        Group {
                            if viewModel?.playerState.isPlaying == true || viewModel?.playerState == .autoMix {
                                TimelineView(.animation) { timeline in
                                    GeometryReader { geo in
                                        let fw = geo.size.width
                                        let cycle: TimeInterval = 3
                                        let raw = (timeline.date.timeIntervalSinceReferenceDate
                                                  .truncatingRemainder(dividingBy: cycle)) / cycle
                                        let eased = { t in t * t * (3 - 2 * t) }(raw)
                                        let fadeIn = min(1, eased / 0.15)
                                        let fadeOut = min(1, (1 - eased) / 0.15)
                                        let fade = min(fadeIn, fadeOut)

                                        Capsule()
                                            .fill(theme.dotActive.opacity(Double(fade * sweepMax)))
                                            .frame(width: spotWidth, height: geo.size.height)
                                            .offset(x: -spotWidth / 2 + eased * (fw + spotWidth))
                                    }
                                }
                            }
                        }
                        .mask(Capsule())
                        .allowsHitTesting(false),
                        alignment: .leading
                    )
            }
            .frame(width: bw, height: 36)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                withAnimation(.snappy) {
                    if case .active = phase { isHoveringBar = true } else { isHoveringBar = false }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let progress = value.location.x / bw
                        dragProgress = max(0, min(1, progress))
                    }
                    .onEnded { value in
                        let progress = value.location.x / bw
                        let clamped = max(0, min(1, progress))
                        if let vm = viewModel {
                            vm.seekTo(time: Double(clamped) * vm.currentDuration)
                        }
                        isDragging = false
                        dragProgress = nil
                        withAnimation(.snappy) {
                            isHoveringBar = false
                        }
                    }
            )
            Spacer()
        }
        .frame(height: 36)
    }
}
