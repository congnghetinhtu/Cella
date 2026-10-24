import SwiftUI
import AVFoundation

struct CellaScreenView: View {
    var viewModel: PlayerViewModel?
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHoveringBar = false
    @State private var isDragging = false
    @State private var dragProgress: CGFloat?
    @State private var frozenLyricIndex = -1

    // Singer caption geometry: active line's text edge + full stage bounds
    // (both global prefs from LyricsView) → the caption docks to the line end.
    @State private var activeLyricLineFrame: CGRect?
    @State private var lyricStageFrame: CGRect = .zero
    @State private var isHoveringScreen = false
    @State private var scrollMonitor: Any?
    @State private var prevLyricIndex = -1
    @State private var lyricReveal: Double = 0
    @State private var revealTask: Task<Void, Never>?
    @State private var lastVolumeScroll = CFAbsoluteTime(0) // kept for compat, now throttled in viewModel
    @State private var swipeProgress: CGFloat = 0
    @State private var swipeTask: Task<Void, Never>?
    @State private var swipeActive: Bool = false

    private static let barWidth: CGFloat = 516 // 9 columns × 36pt + 8 gaps × 24pt (legacy pattern grid metrics)

    /// Song header's visible text-edge inset as a fraction of stage width —
    /// the same in EVERY lyrics mode. The internal `textInset` is
    /// compensated in the leading padding below, so switching lyrics
    /// modes never shifts the header horizontally. (Reference: the lyric
    /// column's right edge sits outside at 89% = 100% − 11%, via
    /// LyricsView's trailing dock.)
    private static let headerInset: CGFloat = 0.09

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

    /// Active line's singers as display names — CLARC [vN] marks mapped
    /// against the track's artist list (artist.N order). During an autoMix
    /// the frozen line index keeps the caption stable inside the swap.
    private var currentSingers: String {
        guard let vm = viewModel, vm.currentLyricsIsClarc, !vm.currentLyrics.isEmpty else { return "" }
        let idx = frozenLyricIndex >= 0 ? frozenLyricIndex : currentLyricIndex
        guard idx >= 0, idx < vm.currentLyrics.count else { return "" }
        let marks = vm.currentLyrics[idx].vocalists
        guard !marks.isEmpty else { return "" }
        let names = vm.mixQueue?.currentTrack?.artists ?? []
        let singers = marks.compactMap { n in
            (1...max(names.count, 1)).contains(n) ? names[n - 1] : nil
        }
        return singers.joined(separator: " & ")
    }

    /// Artists currently marked as singing on the lyric line being displayed
    /// (CLARC [vN] marks mapped through the track's artist list).
    private var currentSingingArtists: Set<String> {
        guard let vm = viewModel, vm.currentLyricsIsClarc, !vm.currentLyrics.isEmpty else { return [] }
        let idx = frozenLyricIndex >= 0 ? frozenLyricIndex : currentLyricIndex
        guard idx >= 0, idx < vm.currentLyrics.count else { return [] }
        let marks = vm.currentLyrics[idx].vocalists
        guard !marks.isEmpty else { return [] }
        let names = vm.mixQueue?.currentTrack?.artists ?? []
        var singers = Set<String>()
        for n in marks where (1...max(names.count, 1)).contains(n) {
            singers.insert(names[n - 1])
        }
        return singers
    }

    /// Horizontal nudge putting the caption's right edge just before the
    /// active lyric line's text end. Coordinates are both in global space,
    /// so the delta transfers straight into the overlay offset.
    private var singerCaptionOffsetX: CGFloat {
        guard let line = activeLyricLineFrame, lyricStageFrame.width > 0 else { return 0 }
        return line.maxX - lyricStageFrame.maxX - 10
    }

    private var singerCaptionView: some View {
        Text(currentSingers)
            .font(.system(size: 24, weight: .light, design: .rounded))
            .foregroundStyle(.white.opacity(0.65))
            .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .offset(x: singerCaptionOffsetX)
            .opacity(currentSingers.isEmpty ? 0 : 1)
            .animation(.smooth(duration: 0.35), value: currentSingers)
            .animation(.smooth(duration: 0.35), value: singerCaptionOffsetX)
            .allowsHitTesting(false)
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
    private var fullLyricsLayer: some View {
        if showFullLyrics, let vm = viewModel {
            // Picker open pulls matched lyrics leading-left (header hides);
            // real lines dock right beside the header, gaps stay centered.
            let align: TextAlignment = vm.albumPickerVisible ? .leading
                : lyricSplitActive ? .trailing : .center
            LyricsView(
                lyrics: vm.currentLyrics,
                currentTime: vm.currentTime,
                isPlaying: vm.playerState.isPlaying || vm.playerState == .autoMix,
                nextLyrics: vm.nextLyrics,
                isTransitioning: vm.isTransitioning,
                frozenIndex: frozenLyricIndex,
                textAlignment: align,
                revealProgress: lyricReveal,
                highlightIndex: vm.highlightLyricIndex,
                // Same font size for current, previous & next lines.
                lineHeight: 56,
                fontSize: 24,
                maxLines: 2, uniformLineSize: true
            )
            // "Who's singing" — bottom-right under the lyric section,
            // light text. Only shows while the active line carries
            // CLARC vocalist marks; unmarked lines leave the stage clean.
            .overlay(alignment: .bottomTrailing) {
                singerCaptionView
            }
            // Picker-shift glide with the original spring (the timed 0.45s
            // replacement ran too fast).
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
            // Caption geometry feeds: stage bounds + active line's text edge.
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: LyricStageFrameKey.self, value: g.frame(in: .global))
                }
            )
            .onPreferenceChange(ActiveLyricFrameKey.self) { activeLyricLineFrame = $0 }
            .onPreferenceChange(LyricStageFrameKey.self) { lyricStageFrame = $0 }
        }
    }

    // MARK: - Mixing Overlay (21:9: outgoing left, orb center, incoming right)

    @ViewBuilder
    private var mixOverlay: some View {
        if isMixing, let right = mixRightTrack {
            ZStack {
                HStack(spacing: 22) {
                    if let left = mixLeftTrack {
                        mixTrackChip(track: left, caption: "CURRENT", leading: false)
                    }
                    mixOrbLarge
                    mixTrackChip(track: right, caption: "NEXT", leading: true)
                }
                .padding(.horizontal, 36)
            }
            // Info-only overlay: never swallow scrub/hover meant for the bar.
            .allowsHitTesting(false)
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
        .background(Capsule().fill(.white.opacity(0.10)))
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
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
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
        text.isLyricPlaceholder
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

        if viewModel?.currentLyricsIsClarc == true,
           Self.isPlaceholderLyric(prevText) && !Self.isPlaceholderLyric(newText) {
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

    // Split so the type-checker sees small expressions, not one giant body.
    private var coreStack: some View {
        ZStack {
            fullLyricsLayer
            songHeader
            mixOverlay
            if swipeActive {
                lyricSwipeOverlay
            }
        }
        .animation(.smooth(duration: 0.35), value: isMixing)
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
        .onDisappear {
            // Tab switch mid-hover never sends .ended — stop here so scroll
            // isn't swallowed on other tabs.
            isHoveringScreen = false
            stopScrollMonitor()
        }
    }

    private var bottomBar: some View {
        GeometryReader { geo in
            TimelineView(.animation) { _ in
                ambientBar(availableWidth: geo.size.width)
            }
        }
        .frame(height: 36)
    }

    // Overlays + frame kept off body so each chain stays type-check cheap.
    private var framedStack: some View {
        AnyView(coreStack)
            .overlay(AnyView(slimLyricsOverlay), alignment: .bottom)
            .overlay(alignment: .bottom) {
                AnyView(bottomBar)
            }
            .overlay(alignment: .top) {
                AnyView(introSkipBadgeView)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .aspectRatio(21.0 / 9.0, contentMode: .fit)
    }

    /// Transient "Intro skipped Ns" pill, top-center. Set when a blend skips
    /// an incoming intro; auto-clears after a few seconds (view model owned).
    private var introSkipBadgeView: some View {
        Group {
            if let text = viewModel?.introSkipBadge {
                Text(text)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .background(Capsule().fill(theme.dotActive.opacity(0.22)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                    .shadow(color: theme.dotActive.opacity(0.35), radius: 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 10)
            }
        }
        .animation(.snappy, value: viewModel?.introSkipBadge)
    }

    var body: some View {
        AnyView(framedStack)
            .onChange(of: viewModel?.currentTime ?? 0.0) { _, _ in
                checkLyricTransition()
            }
            .onChange(of: viewModel?.currentLyrics.count ?? 0) { _, _ in
                prevLyricIndex = currentLyricIndex
                revealTask?.cancel()
                lyricReveal = 0
            }
            .onChange(of: viewModel?.mixQueue?.currentTrack?.url) { _, _ in
                prevLyricIndex = currentLyricIndex
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
            // Swallow event when we handle volume so nothing underneath reacts
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

    // MARK: - Song Header (expressive title/artist, no-lyric + slim)

    /// Split: full mode with a real (non-"..." gap) line current — lyrics
    /// dock right while the header takes the left. During "..." gaps (or
    /// before the first line) the lyric line stays centered and the header
    /// hides.
    /// Gap behavior is CLARC-only: for .lrc lyrics the dots are an ordinary
    /// line — the split stays docked and the header stays put.
    private var lyricSplitActive: Bool {
        guard showFullLyrics else { return false }
        let idx = currentLyricIndex
        guard idx >= 0, let vm = viewModel, idx < vm.currentLyrics.count else { return false }
        let isClarcGap = vm.currentLyricsIsClarc
            && Self.isPlaceholderLyric(vm.currentLyrics[idx].text)
        return !isClarcGap
    }

    /// True when the current track has matched lyrics containing at least one
    /// real (non-"..." gap) line. Instrumental / no-LRC tracks return false.
    private var trackHasRealLyrics: Bool {
        guard let vm = viewModel, let track = vm.mixQueue?.currentTrack,
              !vm.currentLyrics.isEmpty,
              vm.currentLyricsTrackURL == track.url else { return false }
        return vm.currentLyrics.contains { !Self.isPlaceholderLyric($0.text) }
    }

    /// Header visibility: only when the track has NO real lyrics to show
    /// (or lyrics are off — bare stage still names the song). The header
    /// always renders in the left column, never centered.
    /// Lyric songs leave the stage to the lyric line (header hides, except
    /// during "..." gaps where it shares the screen) instead.
    private var lyriclessHeaderActive: Bool {
        guard let vm = viewModel, let track = vm.mixQueue?.currentTrack,
              vm.lyricsResolvedURL == track.url else { return false }
        if lyricsMode == .slim { return !trackHasRealLyrics }
        if lyricsMode == .off { return true }
        return lyricsMode == .full && !showFullLyrics
    }

    private var showSongHeader: Bool {
        // Wait until the transition lands — lyrics (and the header's layout)
        // aren't trustworthy mid-mix, so don't flash anything immediately.
        guard lyricsReady else { return false }
        if pickerOpen {
            // Same as the lyric-less rule below, minus the split: with
            // the picker open the lyrics go full-width leading, so a split
            // header would collide — it hides instead.
            if lyricSplitActive { return false }
            return lyriclessHeaderActive
        }
        return lyricSplitActive || lyriclessHeaderActive
    }

    /// Albums picker open. Drives the gap-split arrangement (header left,
    /// lyrics right) and the instant-hide (no competing animation = no tap
    /// hitch; the return trip stays animated).
    private var pickerOpen: Bool {
        viewModel?.albumPickerVisible == true
    }

    private var songHeader: some View {
        Group {
            if let track = viewModel?.mixQueue?.currentTrack {
                // Always mounted while a track exists — visibility and exit
                // are animated values, so there is no unmount/remount tear.
                // One slot, always the left column: no center pop.
                // Stationary across modes: the text edge sits at
                // `headerInset` whether lyrics are split-docked, at a
                // "..." gap, or absent — mode switches never shift it.
                Group {
                    GeometryReader { geo in
                        // Compensate for SongHeaderContent's internal text
                        // inset so the *visible* text edge lands exactly on
                        // `headerInset` in both split and lyricless states.
                        let leadingPad = geo.size.width * Self.headerInset
                            - SongHeaderContent.textInset
                        SongHeaderContent(track: track, theme: theme, exiting: !showSongHeader, singers: currentSingingArtists)
                            .frame(
                                width: geo.size.width * 0.42,
                                height: geo.size.height,
                                alignment: .leading
                            )
                            .padding(.leading, leadingPad)
                    }
                }
                .id(track.url)
            }
        }
        // Picker open hides/shows the header instantly: the blur/rotate exit
        // animated together with the lyric shift + popover is what hitches
        // the tap. The return trip (picker closes) stays animated.
        .animation(.lyricsSpring, value: showSongHeader)
        .animation(.spring(response: 0.7, dampingFraction: 0.78), value: lyricSplitActive)
    }

    // MARK: - Slim Lyrics (single line above progress bar)

    private var slimLyricsOverlay: some View {
        Group {
            // '...' gap lines render as their dots text like any other line.
            if showSlimLyrics && !currentLyricLine.isEmpty {
                Text(currentLyricLine)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))  // Was 14pt — slightly larger
                    .foregroundStyle(.white)
                    .shadow(color: .white.opacity(0.35), radius: 1, x: 0, y: -1)
                    .lineLimit(2)  // Show 1 line when short, 2 lines when long
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: lyricSplitActive ? .trailing : .center)  // Center at gaps, right when real lyrics
                    .padding(.horizontal, 40)
                    // Increased space between lyric and header/bottom bar.
                    .padding(.bottom, 48)  // Was 72pt — reduced since text is larger
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
                    .opacity(lyricsReady ? 1 : 0)
                    .offset(y: lyricsReady ? 0 : 20)
                    .blur(radius: lyricsReady ? 0 : 5)
                    .animation(.smooth, value: currentLyricLine)
                    .animation(.spring(response: 0.7, dampingFraction: 0.82), value: lyricsReady)
                    // Animate alignment change when split mode activates
                    .animation(.spring(response: 0.7, dampingFraction: 0.78), value: lyricSplitActive)
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
            // Hold fully visible briefly, then smoothly fade out orb while
            // continuing the sweep progress to complete the circle.
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.4)) {
                breakOrbOpacity = 0.0
            }
            // Complete the sweep progress in a matching duration so the
            // orbital motion has no abrupt seam when p goes 1→0.
            withAnimation(.easeInOut(duration: 0.8)) {
                swipeProgress = 0.0
            }
            try? await Task.sleep(for: .seconds(0.5))
            swipeActive = false
            viewModel?.highlightLyricIndex = nil
            viewModel?.showLyricSwipe = false
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

    private func ambientBar(availableWidth: CGFloat) -> some View {
        let active = isHoveringBar || isDragging
        let barHeight: CGFloat = active ? 10 : 6
        // Shrink with narrow windows instead of clipping under the screen mask.
        let bw = min(Self.barWidth, max(200, availableWidth - 48))
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
                    .shadow(color: theme.dotActive.opacity(active ? 0.55 : 0.30), radius: active ? 8 : 5)
                    .animation(.snappy, value: barHeight)
                    .overlay(alignment: .trailing) {
                        barKnob(knobD: knobD, active: active, visible: knobVisible)
                            .offset(x: knobD / 2)
                    }
                // Shine travels the full bar at constant speed, revealed only
                // over the filled region (previously it measured the fill
                // itself, so sweep speed changed with progress).
                barSweep(isPlaying: isPlaying, spotWidth: spotWidth)
                    .frame(width: bw, height: barHeight)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: fillWidth, height: barHeight)
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


// MARK: - Song Header Content (cinematic entrance, rotate in/out)

/// Expressive title block: rises with a slight un-rotate while sharpening
/// from blur on appear; sinks, softens, and tilts away on removal.
private struct SongHeaderContent: View {
    let track: TrackAsset
    let theme: Theme
    /// Exit drive: slides aside + fades while the parent grace-keeps it mounted.
    var exiting: Bool = false
    /// Artists currently marked as singing on the current lyric line — pills.
    let singers: Set<String>
    /// Side padding of the title block — the split layout compensates for
    /// this so the visible text edge lands on the shared stage inset.
    static let textInset: CGFloat = 32
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// Artist pills split around the title (like the quality pills):
    /// larger half above, rest below — extra pills sit above on odd counts,
    /// one or two artists go below so the title leads. Approved rule:
    /// 1: title, pill · 2: title, pill, pill · 3: pills/pills/title/pill ·
    /// 4: two two (the example: [pill][pill] TITLE [pill][pill]).
    private var artistPillSplit: (above: [String], below: [String]) {
        let all = track.artists
        if all.isEmpty, !track.displayArtist.isEmpty {
            // ArtistMatcher split nothing — keep one fallback pill.
            return (above: [], below: [track.displayArtist])
        }
        let aboveCount = all.count > 2 ? (all.count + 1) / 2 : 0
        return (Array(all.prefix(aboveCount)), Array(all.dropFirst(aboveCount)))
    }

    private var titleText: some View {
        Text(track.trackTitle)
            .font(.custom("FzFragrant", size: 36))
            .foregroundStyle(theme.textPrimary)
            .multilineTextAlignment(.leading)  // Left-aligned like lyric
            .lineLimit(2)
    }

    /// Quality-pill capsule look: white 10% fill, aero gloss, thin white
    /// stroke, mono uppercase name — no dot. Static (no tap).
    private func artistPill(_ name: String) -> some View {
        Text(name.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(theme.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 110, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    singers.contains(name)
                        ? LinearGradient(
                            colors: [
                                theme.haloPrimary,
                                theme.haloSecondary,
                                theme.haloPrimary.opacity(0.85)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        : LinearGradient(
                            colors: [
                                Color.white.opacity(0.10),
                                Color.white.opacity(0.10)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                )
                .opacity(singers.contains(name) ? 0.55 : 1)
                .animation(.easeInOut(duration: 0.4), value: singers.contains(name))
            )
            .aeroGloss(radius: 999, opacity: 0.08)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(.white.opacity(0.2), lineWidth: 1)
            )
    }

    var body: some View {
        let pills = artistPillSplit
        VStack(alignment: .leading, spacing: 10) {
            if !pills.above.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(pills.above.enumerated()), id: \.offset) { _, name in
                        artistPill(name)
                    }
                }
            }
            titleText
            if !pills.below.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(pills.below.enumerated()), id: \.offset) { _, name in
                        artistPill(name)
                    }
                }
            }
        }
        .padding(.horizontal, Self.textInset)
        // Cinematic entrance state; exit slides aside via `exiting`.
        .opacity(exiting ? 0 : (appeared ? 1 : 0))
        .blur(radius: exiting ? 6 : (appeared ? 0 : 10))
        .offset(x: exiting ? (reduceMotion ? 0 : -60) : 0, y: exiting ? 0 : (appeared ? 0 : 28))
        .rotationEffect(.degrees(exiting ? -3 : (appeared ? -8 : -12)), anchor: .center)
        .scaleEffect(exiting ? 0.94 : (appeared ? 1 : 0.94))
        .animation(reduceMotion ? .none : .lyricsSpring, value: exiting)
        .animation(.spring(response: 0.7, dampingFraction: 0.78), value: appeared)
        .transition(.asymmetric(
            insertion: .opacity,
            removal: .opacity
                .combined(with: .move(edge: .bottom))
                .combined(with: .scale(scale: 0.92))
        ))
        .onAppear {
            appeared = false
            withAnimation(reduceMotion ? .none : .spring(response: 0.7, dampingFraction: 0.78)) {
                appeared = true
            }
        }
    }
}
