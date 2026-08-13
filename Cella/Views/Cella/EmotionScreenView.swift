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

    private static let barWidth: CGFloat =
        CGFloat(MatrixPatterns.columns) * 36 + CGFloat(MatrixPatterns.columns - 1) * 24

    private var currentProgress: CGFloat {
        if let drag = dragProgress { return drag }
        guard let vm = viewModel, vm.currentDuration > 0 else { return 0 }
        return CGFloat(vm.currentTime / vm.currentDuration)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.dotInactiveDeep)

            if displayMode == "static" {
                EmptyView()
            } else if displayMode == "line", let vm = viewModel {
                LineAnimationView(viewModel: vm)
            } else {
                DotMatrixView(pattern: pattern)
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
        .overlay(ambientBar, alignment: .bottom)
        .aspectRatio(21.0 / 9.0, contentMode: .fit)
    }

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
