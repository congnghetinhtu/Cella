import SwiftUI

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

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.dotInactiveDeep)

            // Main content (matrix / line / static)
            mainContent
                .blur(radius: showFullLyrics ? 8 : 0)
                .animation(.easeInOut(duration: 0.3), value: showFullLyrics)

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
        .overlay(ambientBar, alignment: .bottom)
        .aspectRatio(21.0 / 9.0, contentMode: .fit)
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
                    .animation(.easeInOut(duration: 0.3), value: currentLyricLine)
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
                withAnimation(.easeInOut(duration: 0.2)) {
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
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isHoveringBar = false
                        }
                    }
            )
            Spacer()
        }
        .frame(height: 36)
    }
}
