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
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

/// Isolated background container — only re-renders when video identity changes,
/// not on volume / currentTime ticks. Prevents scroll from stuttering video.
struct CmaBackgroundLayer: View {
    let videoPlayer: AVPlayer?
    let artistImage: NSImage?
    let isActive: Bool
    var unblur: Bool = false

    var body: some View {
        Group {
            if isActive {
                if let player = videoPlayer {
                    baseContent {
                        VideoBackgroundView(player: player)
                    }
                } else if let image = artistImage {
                    baseContent {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(21.0 / 9.0, contentMode: .fill)
                            .clipped()
                    }
                }
            }
        }
    }

    // Blur radius doesn't interpolate smoothly (perceptual pop), so crossfade
    // a blurred copy against a sharp copy via opacity instead.
    @ViewBuilder
    private func baseContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            content()
                .opacity(unblur ? 0 : 0.35)
                .blur(radius: 4)
                .animation(.easeInOut(duration: 0.9), value: unblur)
            content()
                .opacity(unblur ? 0.35 : 0)
                .blur(radius: 0)
                .animation(.easeInOut(duration: 0.9), value: unblur)
        }
        .transition(.opacity)
    }
}

struct CellaScreenView: View {
    let pattern: [[Bool]]
    var viewModel: PlayerViewModel?
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("displayMode") private var displayMode: String = "matrix"

    @State private var isHoveringBar = false
    @State private var isDragging = false
    @State private var dragProgress: CGFloat?
    @State private var frozenLyricIndex = -1
    @State private var isHoveringScreen = false
    @State private var scrollMonitor: Any?
    @State private var lyricPulseActive = false
    @State private var lyricPulseTask: Task<Void, Never>?
    @State private var prevLyricIndex = -1
    @State private var lyricReveal: Double = 0
    @State private var revealTask: Task<Void, Never>?
    @State private var lastVolumeScroll = CFAbsoluteTime(0) // kept for compat, now throttled in viewModel
    @State private var swipeProgress: CGFloat = 0
    @State private var swipeTask: Task<Void, Never>?
    @State private var swipeActive: Bool = false

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
            && vm.currentLyricsTrackURL == vm.mixQueue?.currentTrack?.url
    }

    private var showSlimLyrics: Bool {
        guard let vm = viewModel else { return false }
        return lyricsMode == .slim && !vm.currentLyrics.isEmpty
            && vm.currentLyricsTrackURL == vm.mixQueue?.currentTrack?.url
    }

    private var lyricsReady: Bool {
        guard let vm = viewModel else { return false }
        return !vm.playerState.isTransitioning
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

    private var currentLyricIndex: Int {
        guard let vm = viewModel, !vm.currentLyrics.isEmpty else { return -1 }
        for i in stride(from: vm.currentLyrics.count - 1, through: 0, by: -1) {
            if vm.currentTime >= vm.currentLyrics[i].time - 0.1 {
                return i
            }
        }
        return -1
    }

    private var isBorderPulsing: Bool {
        lyricPulseActive || viewModel?.playerState == .autoMix
    }

    private var isMixing: Bool {
        viewModel?.playerState == .autoMix
    }

    /// Last stable (non-mixing) track = outgoing song while mixing.
    /// mixQueue.currentTrack already points at the incoming target during autoMix.
    @State private var lastStableTrack: TrackAsset?

    private var mixLeftTrack: TrackAsset? {
        guard isMixing, let right = viewModel?.mixQueue?.currentTrack else { return nil }
        if let s = lastStableTrack, s.url != right.url { return s }
        return nil
    }

    private var mixRightTrack: TrackAsset? {
        guard isMixing else { return nil }
        return viewModel?.mixQueue?.currentTrack
    }

    // MARK: - Sub-layers

    @ViewBuilder
    private var placeholderBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(theme.dotInactiveDeep)
            .transition(.opacity)

        // Artist image background — only when playing (isolated so volume scrub doesn't re-render video)
        CmaBackgroundLayer(
            videoPlayer: viewModel?.videoPlayer,
            artistImage: viewModel?.currentArtistImage,
            isActive: viewModel?.playerState.isPlaying == true || viewModel?.playerState == .autoMix,
            unblur: currentLyricIsPlaceholder
        )
        .animation(.smooth, value: viewModel?.currentArtistImage?.hash)
        .transition(.opacity)
    }

    @ViewBuilder
    private var motionLayer: some View {
        mainContent
            .blur(radius: showFullLyrics && !currentLyricIsPlaceholder ? 8 : 0)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.9), value: showFullLyrics)
            .animation(.easeInOut(duration: 0.9), value: currentLyricIsPlaceholder)
    }

    @ViewBuilder
    private var fullLyricsLayer: some View {
        if showFullLyrics, let vm = viewModel {
            LyricsView(
                lyrics: vm.currentLyrics,
                currentTime: vm.currentTime,
                isPlaying: vm.playerState.isPlaying || vm.playerState == .autoMix,
                nextLyrics: vm.nextLyrics,
                isTransitioning: vm.isTransitioning,
                frozenIndex: frozenLyricIndex,
                textAlignment: vm.albumPickerVisible ? .leading : (currentLyricIsPlaceholder ? .trailing : .center),
                revealProgress: lyricReveal,
                highlightIndex: vm.highlightLyricIndex
            )
            .animation(.smooth, value: vm.albumPickerVisible)
            .opacity(lyricsReady ? 1 : 0)
            .offset(y: lyricsReady ? 0 : 16)
            .blur(radius: lyricsReady ? 0 : 6)
            .scaleEffect(lyricsReady ? 1 : 0.985)
            .animation(.spring(response: 0.7, dampingFraction: 0.82), value: lyricsReady)
            .onChange(of: lyricsReady) { _, ready in
                if ready, let vm = viewModel {
                    print("[LYRIC] reveal ready time=\(String(format: "%.2f", vm.currentTime)) lrcTrack=\(vm.currentLyricsTrackURL?.lastPathComponent ?? "nil") curTrack=\(vm.mixQueue?.currentTrack?.url.lastPathComponent ?? "nil") lines=\(vm.currentLyrics.count)")
                }
            }
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
    }

    @ViewBuilder
    private var pausedOverlay: some View {
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

    // MARK: - Mixing Overlay (21:9: outgoing left, orb center, incoming right)

    @ViewBuilder
    private var mixOverlay: some View {
        if isMixing, let right = mixRightTrack {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.black.opacity(0.38))
                HStack(spacing: 22) {
                    if let left = mixLeftTrack {
                        mixTrackChip(track: left, caption: "CURRENT", leading: false)
                    }
                    mixOrbLarge
                    mixTrackChip(track: right, caption: "NEXT", leading: true)
                }
                .padding(.horizontal, 36)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }

    private func mixTrackChip(track: TrackAsset, caption: String, leading: Bool) -> some View {
        VStack(alignment: leading ? .leading : .trailing, spacing: 3) {
            Text(caption)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
            Text(track.trackTitle)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            if !track.displayArtist.isEmpty {
                Text(track.displayArtist)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 230, alignment: leading ? .leading : .trailing)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(.ultraThinMaterial))
        .background(
            Capsule().fill(
                LinearGradient(
                    colors: [
                        AeroAqua.washTop.opacity(0.14),
                        theme.dotActive.opacity(0.10),
                        AeroAqua.washDeep.opacity(0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        )
        .overlay(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .allowsHitTesting(false)
        )
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
    }

    /// Mixing orb copied from the pill badge, sized up for the 21:9 screen.
    /// Same tempo family (0.35 / -0.25 rev/s) so pill and screen stay in sync.
    private var mixOrbLarge: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = reduceMotion ? 0 : sin(t * 2 * .pi * 0.35)
            let heroD: CGFloat = 46 * (1 + pulse * 0.06)
            let a1 = reduceMotion ? 0.8 : (t * 0.35 * 2 * .pi)
            let a2 = reduceMotion ? 2.4 : (-t * 0.25 * 2 * .pi + 2.1)
            let cx: CGFloat = 48
            let cy: CGFloat = 30
            let s1 = CGPoint(x: cx + cos(a1) * 36, y: cy + sin(a1) * 21)
            let s2 = CGPoint(x: cx + cos(a2) * 25, y: cy + sin(a2) * 15)

            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(theme.dotActive.opacity(0.30))
                        .frame(width: 66, height: 66)
                        .blur(radius: 8)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    .white.opacity(0.95),
                                    theme.dotActive.opacity(0.9),
                                    theme.haloSecondary.opacity(0.55)
                                ],
                                center: .init(x: 0.35, y: 0.3),
                                startRadius: 0,
                                endRadius: heroD * 0.7
                            )
                        )
                        .frame(width: heroD, height: heroD)
                        .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1.2))
                        .overlay(
                            Ellipse()
                                .fill(.white.opacity(0.9))
                                .frame(width: heroD * 0.34, height: heroD * 0.22)
                                .offset(x: -heroD * 0.12, y: -heroD * 0.22)
                        )
                        .shadow(color: theme.dotActive.opacity(0.6), radius: 10)
                    Circle()
                        .fill(.white.opacity(0.95))
                        .frame(width: 8, height: 8)
                        .shadow(color: theme.dotActive.opacity(0.8), radius: 4)
                        .position(s1)
                    Circle()
                        .fill(theme.haloSecondary.opacity(0.9))
                        .frame(width: 6, height: 6)
                        .shadow(color: theme.haloSecondary.opacity(0.7), radius: 3)
                        .position(s2)
                }
                .frame(width: 96, height: 60)
                Text("Mixing")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
            }
        }
    }

    static func isPlaceholderLyric(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == "..." || t == "…" || t == ".." || t.isEmpty
    }

    /// True when the currently-playing lyric line is a placeholder ("..."), so
    /// the motion area can stay sharp/unblurred during instrumental gaps.
    private var currentLyricIsPlaceholder: Bool {
        guard let vm = viewModel, !vm.currentLyrics.isEmpty else { return false }
        for i in stride(from: vm.currentLyrics.count - 1, through: 0, by: -1) {
            if vm.currentTime >= vm.currentLyrics[i].time - 0.1 {
                return Self.isPlaceholderLyric(vm.currentLyrics[i].text)
            }
        }
        return false
    }

    private func checkLyricTransition() {
        let idx = currentLyricIndex
        guard idx != prevLyricIndex else { return }
        defer { prevLyricIndex = idx }

        // Need both indices valid
        guard idx >= 0, prevLyricIndex >= 0,
              let vm = viewModel,
              idx < vm.currentLyrics.count,
              prevLyricIndex < vm.currentLyrics.count else { return }

        let prevText = vm.currentLyrics[prevLyricIndex].text
        let newText = vm.currentLyrics[idx].text

        if Self.isPlaceholderLyric(prevText) && !Self.isPlaceholderLyric(newText) {
            triggerLyricPulse()
            triggerLyricReveal()
        }
    }

    private func triggerLyricReveal() {
        revealTask?.cancel()
        lyricReveal = 0
        withAnimation(.smooth(duration: 0.8)) {
            lyricReveal = 1
        }
        revealTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.smooth(duration: 0.5)) {
                    lyricReveal = 0
                }
            }
        }
    }

    private func triggerLyricPulse() {
        lyricPulseTask?.cancel()
        withAnimation(.smooth(duration: 0.6)) {
            lyricPulseActive = true
        }
        lyricPulseTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.smooth(duration: 0.6)) {
                    lyricPulseActive = false
                }
            }
        }
    }

    @State private var modeSwap: Double = 0

    // Split so the type-checker sees small expressions, not one giant body.
    private var coreStack: some View {
        ZStack {
            placeholderBackground
            motionLayer
                // Blur morph on Aqua ↔ Line ↔ Static switch: starts blurred, sharpens.
                .blur(radius: modeSwap * 10)
                .opacity(1 - modeSwap * 0.5)
            fullLyricsLayer
            pausedOverlay
            mixOverlay
            if swipeActive {
                lyricSwipeOverlay
            }
        }
        .animation(.smooth(duration: 0.35), value: isMixing)
        .onChange(of: displayMode) { _, _ in
            modeSwap = 1
            withAnimation(.easeOut(duration: 0.45)) { modeSwap = 0 }
        }
        .onChange(of: viewModel?.showLyricSwipe ?? false) { _, show in
            if show { startSwipeAnimation() }
        }
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
    }

    private var borderGlow: some View {
        RoundedRectangle(cornerRadius: 18)
            .stroke(
                LinearGradient(
                    colors: [
                        theme.haloPrimary.opacity(0.0),
                        theme.haloPrimary.opacity(0.6),
                        theme.haloSecondary.opacity(0.8),
                        theme.haloPrimary.opacity(0.6),
                        theme.haloPrimary.opacity(0.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 2
            )
            .shadow(color: theme.haloPrimary.opacity(isBorderPulsing ? 0.6 : 0), radius: 12)
            .shadow(color: theme.haloSecondary.opacity(isBorderPulsing ? 0.4 : 0), radius: 20)
            .opacity(isBorderPulsing ? 1 : 0)
            .animation(.smooth(duration: 0.6), value: isBorderPulsing)
    }

    private var bottomBar: some View {
        TimelineView(.animation) { _ in
            ambientBar
        }
    }

    // Overlays + frame kept off body so each chain stays type-check cheap.
    private var framedStack: some View {
        AnyView(coreStack)
            .overlay(AnyView(slimLyricsOverlay), alignment: .bottom)
            .overlay(alignment: .bottom) {
                AnyView(bottomBar)
            }
            .overlay(AnyView(borderGlow))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .aspectRatio(21.0 / 9.0, contentMode: .fit)
    }

    var body: some View {
        AnyView(framedStack)
            .onChange(of: viewModel?.currentTime ?? 0.0) { _, _ in
                checkLyricTransition()
            }
            .onChange(of: viewModel?.currentLyrics.count ?? 0) { _, _ in
                prevLyricIndex = currentLyricIndex
                lyricPulseTask?.cancel()
                lyricPulseActive = false
                revealTask?.cancel()
                lyricReveal = 0
            }
            .onChange(of: viewModel?.mixQueue?.currentTrack?.url) { _, _ in
                prevLyricIndex = currentLyricIndex
                lyricPulseTask?.cancel()
                lyricPulseActive = false
                revealTask?.cancel()
                lyricReveal = 0
                if viewModel?.playerState != .autoMix {
                    lastStableTrack = viewModel?.mixQueue?.currentTrack
                }
            }
            .onChange(of: isMixing) { _, mixing in
                if !mixing {
                    lastStableTrack = viewModel?.mixQueue?.currentTrack
                }
            }
            .onAppear {
                if lastStableTrack == nil {
                    lastStableTrack = viewModel?.mixQueue?.currentTrack
                }
            }
    }

    // MARK: - Volume Scroll Monitor

    private func startScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let handled = self.handleScrollWheel(event)
            // Swallow event when we handle volume so AVPlayerView doesn't scrub/pause
            return handled ? nil : event
        }
    }

    private func stopScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    @discardableResult
    private func handleScrollWheel(_ event: NSEvent) -> Bool {
        guard let vm = viewModel else { return false }
        // Only handle vertical scroll with meaningful delta
        let raw = event.scrollingDeltaY
        guard abs(raw) > 0.1 else { return false }
        let newVolume = max(0, min(1, vm.currentVolume + Float(raw) * 0.001))
        vm.setVolumeForScroll(newVolume)
        return true
    }

    // MARK: - Slim Lyrics (single line above progress bar)

    private var slimLyricsOverlay: some View {
        Group {
            if showSlimLyrics && !currentLyricLine.isEmpty {
                Text(currentLyricLine)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.dotActive)
                    .shadow(color: .white.opacity(0.35), radius: 1, x: 0, y: -1)
                    .shadow(color: theme.dotActive.opacity(0.45), radius: 10)
                    .shadow(color: theme.haloSecondary.opacity(0.28), radius: 18)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 28)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
                    .opacity(lyricsReady ? 1 : 0)
                    .offset(y: lyricsReady ? 0 : 12)
                    .blur(radius: lyricsReady ? 0 : 5)
                    .animation(.smooth, value: currentLyricLine)
                    .animation(.spring(response: 0.7, dampingFraction: 0.82), value: lyricsReady)
            }
        }
    }

    // MARK: - Lyric Break Orb (insertBreak / insertInit confirm)

    @State private var breakOrbOpacity = 0.0

    private var lyricSwipeOverlay: some View {
        // Calm confirm, like the mixing orb: hero bubble + "Break Inserted"
        // pill. Visibility pinned by breakOrbOpacity (fast in, 1.2s hold,
        // soft out) — independent of the eased sweep clock.
        let p = swipeProgress
        let orbit = (reduceMotion ? 0.4 : p) * Double.pi
        let s1 = CGPoint(x: cos(orbit) * 30, y: sin(orbit) * 18)
        let s2 = CGPoint(x: cos(-orbit + 2.1) * 24, y: sin(-orbit + 2.1) * 15)
        let heroD: CGFloat = 40
        return VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(theme.dotActive.opacity(0.28))
                    .frame(width: 80, height: 80)
                    .blur(radius: 10)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                .white.opacity(0.95),
                                theme.dotActive.opacity(0.9),
                                theme.haloSecondary.opacity(0.55)
                            ],
                            center: .init(x: 0.35, y: 0.3),
                            startRadius: 0,
                            endRadius: heroD * 0.7
                        )
                    )
                    .frame(width: heroD, height: heroD)
                    .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1.2))
                    .overlay(
                        Ellipse()
                            .fill(.white.opacity(0.9))
                            .frame(width: heroD * 0.34, height: heroD * 0.22)
                            .offset(x: -heroD * 0.12, y: -heroD * 0.22)
                    )
                    .shadow(color: theme.dotActive.opacity(0.6), radius: 10)
                Circle()
                    .fill(.white.opacity(0.95))
                    .frame(width: 7, height: 7)
                    .shadow(color: theme.dotActive.opacity(0.8), radius: 4)
                    .offset(x: s1.x, y: s1.y)
                Circle()
                    .fill(theme.haloSecondary.opacity(0.9))
                    .frame(width: 5, height: 5)
                    .shadow(color: theme.haloSecondary.opacity(0.7), radius: 3)
                    .offset(x: s2.x, y: s2.y)
            }
            .frame(width: 96, height: 60)
            Text("Break Inserted")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(.ultraThinMaterial))
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [
                                AeroAqua.washTop.opacity(0.28),
                                theme.dotActive.opacity(0.22),
                                AeroAqua.washDeep.opacity(0.32)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .background(Capsule().fill(theme.screenBackground.opacity(0.35)))
                .overlay(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.38), .white.opacity(0.03)],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .allowsHitTesting(false)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.45), .white.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: theme.dotActive.opacity(0.5), radius: 10)
                .shadow(color: theme.haloSecondary.opacity(0.3), radius: 18)
        }
        .opacity(breakOrbOpacity)
        .allowsHitTesting(false)
    }

    private func startSwipeAnimation() {
        swipeTask?.cancel()
        swipeActive = true
        swipeProgress = 0
        breakOrbOpacity = 0
        swipeTask = Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.8)) {
                swipeProgress = 1.0
            }
            withAnimation(.easeOut(duration: 0.25)) {
                breakOrbOpacity = 1.0
            }
            try? await Task.sleep(for: .seconds(2.2))
            viewModel?.showLyricSwipe = false
            withAnimation(.easeInOut(duration: 0.5)) {
                breakOrbOpacity = 0.0
            }
            withAnimation(.easeOut(duration: 0.3)) {
                swipeProgress = 0
            }
            try? await Task.sleep(for: .seconds(0.5))
            swipeActive = false
            viewModel?.highlightLyricIndex = nil
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
            // "matrix"/"liquid" are legacy — maps to aqua.
            AquaView(viewModel: viewModel)
        }
    }

    // MARK: - Progress Bar (Frutiger Aero glass)

    private func barTrack(active: Bool, barHeight: CGFloat) -> some View {
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
                .frame(height: barHeight)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            AeroAqua.washTop.opacity(active ? 0.22 : 0.12),
                            theme.dotActive.opacity(active ? 0.18 : 0.10),
                            AeroAqua.washDeep.opacity(active ? 0.26 : 0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: barHeight)
            Capsule()
                .fill(theme.screenBackground.opacity(active ? 0.35 : 0.45))
                .frame(height: barHeight)
                .allowsHitTesting(false)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(active ? 0.28 : 0.18), .white.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .frame(height: barHeight)
                .allowsHitTesting(false)
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(active ? 0.38 : 0.22), .white.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .frame(height: barHeight)
        }
    }

    private func barFillBase(active: Bool, barHeight: CGFloat, fillWidth: CGFloat) -> some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [theme.dotActive, theme.haloSecondary, theme.haloPrimary],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: fillWidth, height: barHeight)
            .overlay(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.42), .white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .frame(height: barHeight * 0.52),
                alignment: .top
            )
    }

    private func barSweep(isPlaying: Bool, spotWidth: CGFloat) -> some View {
        Group {
            if isPlaying && !reduceMotion {
                TimelineView(.animation) { timeline in
                    GeometryReader { geo in
                        let fw = max(geo.size.width, 1)
                        let cycle: TimeInterval = 3
                        let raw = (timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: cycle)) / cycle
                        let eased = raw * raw * (3 - 2 * raw)
                        let fade = min(1, eased / 0.15) * min(1, (1 - eased) / 0.15)
                        Capsule()
                            .fill(.white.opacity(fade * 0.55))
                            .frame(width: spotWidth, height: geo.size.height)
                            .offset(x: -spotWidth / 2 + eased * (fw + spotWidth))
                    }
                }
            }
        }
        .mask(Capsule())
        .allowsHitTesting(false)
    }

    private func barKnob(knobD: CGFloat, active: Bool, visible: Bool) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(0.95),
                            theme.dotActive.opacity(0.9),
                            theme.haloSecondary.opacity(0.55)
                        ],
                        center: .init(x: 0.35, y: 0.3),
                        startRadius: 0,
                        endRadius: knobD * 0.7
                    )
                )
                .frame(width: knobD, height: knobD)
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.65), lineWidth: 1)
                )
                .overlay(
                    Ellipse()
                        .fill(.white.opacity(0.9))
                        .frame(width: knobD * 0.34, height: knobD * 0.22)
                        .offset(x: -knobD * 0.12, y: -knobD * 0.22),
                    alignment: .center
                )
                .shadow(color: theme.dotActive.opacity(active ? 0.7 : 0.4), radius: active ? 8 : 4)
        }
        .frame(width: knobD, height: knobD)
        .opacity(visible ? 1 : 0)
        .scaleEffect(active ? 1 : 0.9)
        .animation(.snappy, value: active)
        .allowsHitTesting(false)
    }

    private var ambientBar: some View {
        let active = isHoveringBar || isDragging
        let barHeight: CGFloat = active ? 10 : 6
        let bw = Self.barWidth
        let spotWidth: CGFloat = 44
        let isPlaying = viewModel?.playerState.isPlaying == true || viewModel?.playerState == .autoMix
        let knobD: CGFloat = active ? 14 : 8
        let mapD: CGFloat = 14
        let p = max(0, min(1, currentProgress))
        let fillWidth = mapD / 2 + p * (bw - mapD)
        let knobVisible = currentProgress > 0.001 || active

        return HStack {
            Spacer()
            ZStack(alignment: .leading) {
                barTrack(active: active, barHeight: barHeight)
                barFillBase(active: active, barHeight: barHeight, fillWidth: fillWidth)
                    .overlay(barSweep(isPlaying: isPlaying, spotWidth: spotWidth), alignment: .leading)
                    .shadow(color: theme.dotActive.opacity(active ? 0.55 : 0.30), radius: active ? 8 : 5)
                    .animation(.snappy, value: barHeight)
                    .overlay(alignment: .trailing) {
                        barKnob(knobD: knobD, active: active, visible: knobVisible)
                            .offset(x: knobD / 2)
                    }
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
                        let raw = (value.location.x - mapD / 2) / (bw - mapD)
                        dragProgress = max(0, min(1, raw))
                    }
                    .onEnded { value in
                        let raw = (value.location.x - mapD / 2) / (bw - mapD)
                        let clamped = max(0, min(1, raw))
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
            .sensoryFeedback(.selection, trigger: isDragging)
            Spacer()
        }
        .frame(height: 36)
    }
}
