//
//  TopTabBar.swift
//  Cella
//
//  Dual pill-style tab bar — left (Cluster, Cella, Config) and right (Cella Motion, Enhanced LRC).
//  Includes a "Liquid Glass" sliding selection pill, drag-to-switch, and
//  scroll-to-switch when hovering.
//

import SwiftUI
import Combine

// MARK: - Scroll Coordinator

final class ScrollCoordinator: ObservableObject {
    @MainActor @Published var switchSignal = 0

    private var monitor: Any?
    private var accumulatedDeltaX: CGFloat = 0
    private var accumulatedDeltaY: CGFloat = 0
    private var gestureActive = false

    var isHovering = false

    init() {}

    func start() {
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event)
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        reset()
    }

    private func reset() {
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        gestureActive = false
    }

    private func handleScroll(_ event: NSEvent) {
        guard isHovering else { return }

        let isTrackpad = event.phase != [] || event.momentumPhase != []

        if isTrackpad {
            if event.phase.contains(.began) {
                reset()
                gestureActive = true
            }

            guard gestureActive else { return }

            accumulatedDeltaX += event.scrollingDeltaX
            accumulatedDeltaY += event.scrollingDeltaY

            let threshold: CGFloat = 45.0

            if accumulatedDeltaX < -threshold || accumulatedDeltaY < -threshold {
                emit(.next)
                accumulatedDeltaX = 0
                accumulatedDeltaY = 0
            } else if accumulatedDeltaX > threshold || accumulatedDeltaY > threshold {
                emit(.previous)
                accumulatedDeltaX = 0
                accumulatedDeltaY = 0
            }

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                reset()
            }
        } else {
            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            let threshold: CGFloat = 8.0

            if deltaX < -threshold || deltaY < -threshold {
                emit(.next)
            } else if deltaX > threshold || deltaY > threshold {
                emit(.previous)
            }
        }
    }

    private func emit(_ direction: Direction) {
        let value = direction == .next ? 1 : -1
        if Thread.isMainThread {
            MainActor.assumeIsolated { switchSignal = value }
        } else {
            Task { @MainActor [weak self] in
                self?.switchSignal = value
            }
        }
    }

    enum Direction { case next, previous }
}

// MARK: - BottomTabBar (single nav, bottom)

struct BottomTabBar: View {
    @Binding var selectedTab: AppTab
    @StateObject private var coordinator = ScrollCoordinator()
    @Environment(\.theme) private var theme

    @Namespace private var animation
    @State private var dragOffset: CGFloat = 0
    @State private var dragStartIndex: Int = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(theme.tabBarBackground)
        .clipShape(Capsule())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                coordinator.isHovering = true
            case .ended:
                coordinator.isHovering = false
            }
        }
        .onAppear {
            coordinator.start()
        }
        .onDisappear {
            coordinator.stop()
        }
        .onChange(of: coordinator.switchSignal) { _, signal in
            guard signal != 0 else { return }
            let tabs = AppTab.allCases
            guard let idx = tabs.firstIndex(of: selectedTab) else { return }

            if signal == 1, idx < tabs.count - 1 {
                withAnimation(.smooth) {
                    selectedTab = tabs[idx + 1]
                }
            } else if signal == -1, idx > 0 {
                withAnimation(.smooth) {
                    selectedTab = tabs[idx - 1]
                }
            }

            coordinator.switchSignal = 0
        }
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in
                    let tabs = AppTab.allCases
                    if dragOffset == 0 {
                        dragStartIndex = tabs.firstIndex(of: selectedTab) ?? 0
                    }

                    let rawOffset = value.translation.width
                    dragOffset = rawOffset * 0.4

                    let threshold: CGFloat = 30
                    if rawOffset < -threshold && dragStartIndex < tabs.count - 1 {
                        let nextTab = tabs[dragStartIndex + 1]
                        if selectedTab != nextTab {
                            withAnimation(.smooth) {
                                selectedTab = nextTab
                            }
                        }
                    } else if rawOffset > threshold && dragStartIndex > 0 {
                        let prevTab = tabs[dragStartIndex - 1]
                        if selectedTab != prevTab {
                            withAnimation(.smooth) {
                                selectedTab = prevTab
                            }
                        }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
        )
    }

    // MARK: - Tab Button

    @ViewBuilder
    private func tabButton(for tab: AppTab) -> some View {
        Button {
            withAnimation(.smooth) {
                selectedTab = tab
            }
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selectedTab == tab ? theme.tabSelectedText : theme.tabUnselectedText)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    ZStack {
                        if selectedTab == tab {
                            Capsule()
                                .fill(theme.tabSelectedBackground)
                                .matchedGeometryEffect(id: "pill", in: animation)
                                .offset(x: dragOffset)
                        }
                    }
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AlbumPill (album pill, clone of the playing-info pill)

/// Shows which album the playing track is from, with its folder cover image.
/// Slides in from the left (leading) next to the playing-info pill, mimicking
/// the OpenMix / Lyric-Supported badge motion.
struct AlbumPill: View {
    var viewModel: PlayerViewModel
    @Environment(\.theme) private var theme
    @State private var hiSoTask: Task<Void, Never>?
    @State private var crossfadeRevealPending = false

    var body: some View {
        Group {
            if viewModel.albumPillVisible {
                content
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.5), value: viewModel.albumPillVisible)
        .animation(.smooth(duration: 0.5), value: viewModel.albumPillHiSoVisible)
        .onAppear {
            // Show first-song album info on entry; skip while a config-delayed
            // reveal is pending so it still waits its 1s.
            if !viewModel.albumPillDelayPending {
                viewModel.syncAlbumPillState()
            }
            syncHiSo()
        }
        .onChange(of: viewModel.mixQueue?.currentTrack?.url) { _, _ in
            viewModel.syncAlbumPillState()
            syncHiSo()
        }
        .onChange(of: viewModel.playerState) { _, newState in
            viewModel.syncAlbumPillState()
            if newState == .autoMix {
                // Crossfade began — next same-album reveal must re-delay 5s.
                crossfadeRevealPending = true
            }
            syncHiSo()
        }
        .onChange(of: viewModel.albumPillRevealTick) { _, _ in
            viewModel.syncAlbumPillState()
            syncHiSo()
        }
        .onChange(of: viewModel.albumPillVisible) { _, visible in
            if !visible { hideHiSo() } else { syncHiSo() }
        }
        .onChange(of: viewModel.albumPillHiRes) { _, hiRes in
            if hiRes { scheduleHiSo() } else { hideHiSo() }
        }
        .onDisappear {
            // Keep Hi-So visible state persisted in viewModel across tab switches;
            // only cancel the pending reveal timer here.
            hiSoTask?.cancel()
            hiSoTask = nil
        }
    }

    private func syncHiSo() {
        guard viewModel.albumPillVisible, viewModel.albumPillHiRes else {
            hideHiSo()
            return
        }
        // Same album already revealed. On tab re-appear show instantly (no re-delay),
        // but after a crossfade re-delay the 5s reveal.
        if viewModel.albumPillHiSoAlbumDir != nil,
           viewModel.albumPillHiSoAlbumDir == viewModel.albumPillAlbumDir {
            if crossfadeRevealPending {
                crossfadeRevealPending = false
                viewModel.albumPillHiSoAlbumDir = nil
                scheduleHiSo()
            } else if !viewModel.albumPillHiSoVisible {
                withAnimation(.smooth(duration: 0.5)) {
                    viewModel.albumPillHiSoVisible = true
                }
            }
            return
        }
        scheduleHiSo()
    }

    private func scheduleHiSo() {
        hiSoTask?.cancel()
        hiSoTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                viewModel.albumPillHiSoAlbumDir = viewModel.albumPillAlbumDir
                withAnimation(.smooth(duration: 0.5)) {
                    viewModel.albumPillHiSoVisible = true
                }
            }
        }
    }

    private func hideHiSo() {
        hiSoTask?.cancel()
        hiSoTask = nil
        withAnimation(.smooth(duration: 0.5)) {
            viewModel.albumPillHiSoVisible = false
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.dotInactiveDeep)
                if let cover = viewModel.albumPillCover {
                    Image(nsImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    Image(systemName: "square.stack")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.dotActive.opacity(0.8))
                }
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text("Playing from")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                Text(viewModel.albumPillTitle)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if viewModel.albumPillHiSoVisible {
                HStack(spacing: 3) {
                    Circle()
                        .fill(.white)
                        .frame(width: 4, height: 4)
                        .shadow(color: .yellow, radius: 2)
                    Text("Hi-So")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(LinearGradient(colors: [.yellow, .orange, .yellow.opacity(0.85)], startPoint: .leading, endPoint: .trailing)))
                .clipShape(Capsule())
                .shadow(color: .yellow.opacity(0.4), radius: 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Capsule().fill(theme.tabBarBackground))
        .clipShape(Capsule())
        .contentShape(Capsule())
    }
}

// MARK: - NowPlayingBar (top center pill + OpenMix badge)

struct NowPlayingBar: View {
    var viewModel: PlayerViewModel
    @Binding var selectedTab: AppTab
    @Environment(\.theme) private var theme
    @State private var gradientAngle: Double = 0
    @State private var gradientTimer: Timer?
    @State private var isVolumeAdjusting = false
    @State private var volumeGlowTimer: Timer?
    @State private var lyricBadgeVisible = false
    @State private var lyricBadgeTask: Task<Void, Never>?
    @State private var qualityPillsTask: Task<Void, Never>?

    private var currentTrack: TrackAsset? { viewModel.mixQueue?.currentTrack }
    private var isPlaying: Bool { viewModel.playerState == .playing || viewModel.playerState == .autoMix }
    private var isAutoMixing: Bool { viewModel.playerState == .autoMix }
    private var hasLyricSupported: Bool {
        guard let track = viewModel.mixQueue?.currentTrack else { return false }
        if viewModel.hasLyric(for: track) { return true }
        // Fallback: lyrics loaded for this exact track (covers edge where file check misses)
        if let url = viewModel.currentLyricsTrackURL, url == track.url, !viewModel.currentLyrics.isEmpty {
            return true
        }
        return false
    }
    private var hasQualityPills: Bool {
        viewModel.qualityPillsVisible && (viewModel.currentAudioMetadata?.hasData == true)
    }
    private var qualityTrackID: String {
        viewModel.mixQueue?.currentTrack?.id.uuidString
            ?? viewModel.mixQueue?.currentTrack?.url.absoluteString
            ?? "none"
    }
    private var shouldAnimateGradient: Bool { isAutoMixing || lyricBadgeVisible || hasQualityPills }

    var body: some View {
        let currentText: String? = {
            guard selectedTab != .cella, !viewModel.currentLyrics.isEmpty else { return nil }
            for i in stride(from: viewModel.currentLyrics.count - 1, through: 0, by: -1) {
                if viewModel.currentTime >= viewModel.currentLyrics[i].time - 0.1 {
                    return viewModel.currentLyrics[i].text
                }
            }
            return viewModel.currentLyrics.first?.text
        }()

        normalPill(track: currentTrack, lyrics: currentText)
            .animation(.smooth(duration: 0.5), value: isAutoMixing)
            .animation(.smooth(duration: 0.5), value: lyricBadgeVisible)
            .onAppear {
                updateGradientTimer()
                // View may have appeared after track already playing on Cella
                if viewModel.playerState == .playing {
                    if hasLyricSupported {
                        // Badge already shown for this track (tab re-appear) — restore pills
                        // directly instead of hiding them and waiting on a dedup'd badge.
                        if viewModel.lastLyricBadgeTrackID == qualityTrackID {
                            showQualityPills(force: true)
                        } else {
                            hideQualityPills(); triggerLyricBadgeIfNeeded()
                        }
                    } else {
                        showQualityPills(force: true)
                    }
                }
            }
            .onChange(of: shouldAnimateGradient) { _, _ in updateGradientTimer() }
            .onChange(of: viewModel.mixQueue?.currentTrack?.url) { _, _ in
                // During OpenMix, wait until crossfade finishes (state -> playing) to show
                if viewModel.playerState == .autoMix { return }
                if hasLyricSupported { hideQualityPills(); triggerLyricBadgeIfNeeded() }
                else { hideLyricBadge(); scheduleQualityPills() }
            }
            .onChange(of: viewModel.currentLyricsTrackURL) { _, _ in
                if hasLyricSupported && viewModel.playerState == .playing { triggerLyricBadgeIfNeeded() }
            }
            .onChange(of: viewModel.playerState) { old, new in
                if new == .playing && old == .autoMix {
                    // OpenMix crossfade landed on this song — show badge/pills again
                    if hasLyricSupported { triggerLyricBadgeIfNeeded(force: true, forcePillsAfter: true) }
                    else { showQualityPills(force: true) }
                } else if new == .playing && old != .paused && hasLyricSupported {
                    hideQualityPills(); triggerLyricBadgeIfNeeded()
                } else if new == .playing && old != .paused && !hasLyricSupported {
                    // Non-lyric: appear right after the OpenMixing badge (autoMix -> playing)
                    showQualityPills()
                }
                if new == .paused { hideLyricBadgeKeepPills() }
                if new == .autoMix { hideLyricBadge() }
            }
            .onDisappear { stopGradientTimer() }
        .onChange(of: viewModel.currentVolume) { _, _ in
            isVolumeAdjusting = true
            volumeGlowTimer?.invalidate()
            volumeGlowTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in
                withAnimation(.easeOut(duration: 0.4)) {
                    isVolumeAdjusting = false
                }
            }
        }
        .task(id: viewModel.mixQueue?.currentTrack?.url) {
            guard let url = viewModel.mixQueue?.currentTrack?.url else {
                viewModel.currentAudioMetadata = nil
                viewModel.currentAudioMetadataURL = nil
                return
            }
            // Reload metadata only for a new track; keep cached across tab switches.
            if viewModel.currentAudioMetadataURL != url {
                viewModel.currentAudioMetadataURL = url
                viewModel.currentAudioMetadata = await AudioFileMetadataLoader.load(for: url)
            }
            // Metadata loaded async — reveal quality pills now if relevant,
            // but let a url-change lyric badge trigger first so pills never preempt it.
            if viewModel.currentAudioMetadata?.hasData == true, viewModel.playerState == .playing {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, viewModel.playerState == .playing, !hasLyricSupported else { return }
                showQualityPills()
            }
        }
    }

    // MARK: - Normal Pill

    @ViewBuilder
    private func normalPill(track: TrackAsset?, lyrics: String?) -> some View {
        HStack(spacing: 10) {
            // OpenMix badge — left of track info
            if isAutoMixing {
                openMixBadge
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            if let track = track {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isPlaying ? theme.dotActive : theme.textSecondary)
                    .frame(width: 16)

                if let lyricsLine = lyrics {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.trackTitle)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                        Text(lyricsLine)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                    }
                    .id(lyricsLine)
                    .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.trackTitle)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        if let artist = track.artistName {
                            Text(artist)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }

                Text("\(formatTime(viewModel.currentTime))/\(formatTime(viewModel.currentDuration))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)

                volumeIndicator(small: true)
                    .transition(.move(edge: .trailing).combined(with: .opacity))

                if lyricBadgeVisible {
                    lyricSupportedBadge
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if hasQualityPills, let metadata = viewModel.currentAudioMetadata {
                    metadataPill(label: "Quality", value: metadata.qualityLabel)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    if let performance = metadata.bitrateLabel ?? metadata.sampleRateLabel {
                        metadataPill(label: "Bitrate", value: performance)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                Image(systemName: viewModel.lyricsMode.iconName)
                    .font(.system(size: 12))
                    .foregroundStyle(viewModel.lyricsMode != .off ? theme.dotActive : theme.textSecondary)
                    .frame(width: 16)
                    .contentTransition(.symbolEffect(.replace))
                    .onTapGesture {
                        withAnimation(.snappy) {
                            viewModel.lyricsMode.cycle()
                        }
                    }
            } else {
                // Empty state — bigger pill
                Image(systemName: "music.note")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.textSecondary)

                Text("Cella")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textSecondary)

                volumeIndicator(small: false)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Capsule().fill(theme.tabBarBackground))
        .clipShape(Capsule())
        .contentShape(Rectangle())
        .animation(.smooth(duration: 0.4), value: lyrics)
        .animation(.snappy, value: viewModel.currentTime)
        .animation(.smooth(duration: 0.2), value: viewModel.currentVolume)
        .onTapGesture {
            withAnimation(.snappy) {
                viewModel.togglePlayPause()
            }
        }
    }

    // MARK: - OpenMix Badge

    private var openMixBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.white)
                .frame(width: 5, height: 5)
                .shadow(color: .green, radius: 3)

            Text("OpenMixing to")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.green, .mint, .green.opacity(0.85)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(
                    AngularGradient(
                        colors: [
                            .clear, .clear,
                            .white.opacity(0.3),
                            .clear, .clear,
                            .white.opacity(0.2),
                            .clear, .clear
                        ],
                        center: .center,
                        angle: .degrees(gradientAngle)
                    )
                    .blendMode(.overlay)
                )
        )
        .clipShape(Capsule())
        .shadow(color: .green.opacity(0.5), radius: 6)
    }

    // MARK: - Lyric Supported Badge

    private var lyricSupportedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 8))
                .foregroundStyle(.white)
            Text("Lyric Supported")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.green, .mint, .green.opacity(0.85)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(
                    AngularGradient(
                        colors: [
                            .clear, .clear,
                            .white.opacity(0.3),
                            .clear, .clear,
                            .white.opacity(0.2),
                            .clear, .clear
                        ],
                        center: .center,
                        angle: .degrees(gradientAngle)
                    )
                    .blendMode(.overlay)
                )
        )
        .clipShape(Capsule())
        .shadow(color: .green.opacity(0.5), radius: 6)
    }

    // MARK: - Metadata Pill (Quality / Bitrate)

    private func metadataPill(label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(theme.dotActive)
                .frame(width: 5, height: 5)
            Text(label.uppercased())
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
            Text(value)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.screenBackground))
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(theme.dotInactive.opacity(0.4), lineWidth: 1)
        )
    }

    private func updateGradientTimer() {
        if shouldAnimateGradient {
            guard gradientTimer == nil else { return }
            gradientTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                withAnimation(.linear(duration: 0.05)) {
                    gradientAngle += 3
                    if gradientAngle >= 360 { gradientAngle = 0 }
                }
            }
        } else {
            stopGradientTimer()
        }
    }

    private func stopGradientTimer() {
        gradientTimer?.invalidate()
        gradientTimer = nil
    }

    private func triggerLyricBadgeIfNeeded(force: Bool = false, showPillsAfter: Bool = true, forcePillsAfter: Bool = false) {
        guard hasLyricSupported else { return }
        let trackID = viewModel.mixQueue?.currentTrack?.id.uuidString ?? viewModel.mixQueue?.currentTrack?.url.absoluteString ?? "none"
        // Don't re-trigger on tab switch / re-appear for same track (persisted in viewModel)
        if !force, viewModel.lastLyricBadgeTrackID == trackID { return }
        viewModel.lastLyricBadgeTrackID = trackID
        lyricBadgeTask?.cancel()
        withAnimation(.smooth(duration: 0.5)) {
            lyricBadgeVisible = true
        }
        updateGradientTimer()
        lyricBadgeTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.smooth(duration: 0.5)) {
                    lyricBadgeVisible = false
                }
                updateGradientTimer()
                if showPillsAfter {
                    showQualityPills(force: forcePillsAfter)
                }
            }
        }
    }

    private func scheduleQualityPills() {
        guard viewModel.currentAudioMetadata?.hasData == true else { return }
        qualityPillsTask?.cancel()
        qualityPillsTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                showQualityPills()
            }
        }
    }

    private func showQualityPills(force: Bool = false) {
        guard viewModel.currentAudioMetadata?.hasData == true else { return }
        // Never overlap with a showing lyric badge — its tail reveals pills after it hides
        if lyricBadgeVisible { return }
        let trackID = qualityTrackID
        // One-time show per track unless forced (crossfade landing re-shows)
        if !force, viewModel.lastQualityTrackID == trackID { return }
        viewModel.lastQualityTrackID = trackID
        withAnimation(.smooth(duration: 0.5)) {
            viewModel.qualityPillsVisible = true
        }
    }

    private func hideQualityPills() {
        qualityPillsTask?.cancel()
        qualityPillsTask = nil
        withAnimation(.smooth(duration: 0.5)) {
            viewModel.qualityPillsVisible = false
        }
    }

    private func hideLyricBadge() {
        lyricBadgeTask?.cancel()
        lyricBadgeTask = nil
        withAnimation(.smooth(duration: 0.5)) {
            lyricBadgeVisible = false
        }
        updateGradientTimer()
        hideQualityPills()
    }

    private func hideLyricBadgeKeepPills() {
        lyricBadgeTask?.cancel()
        lyricBadgeTask = nil
        withAnimation(.smooth(duration: 0.5)) {
            lyricBadgeVisible = false
        }
        updateGradientTimer()
    }

    // MARK: - Volume Indicator (Apple-style animated)

    @ViewBuilder
    private func volumeIndicator(small: Bool) -> some View {
        let iconSize: CGFloat = small ? 8 : 10
        let textSize: CGFloat = small ? 8 : 10
        let barWidth: CGFloat = small ? 36 : 48
        let barHeight: CGFloat = small ? 3 : 4
        let vol = viewModel.currentVolume
        let iconName = vol == 0 ? "speaker.slash.fill" :
                        vol < 0.33 ? "speaker.wave.1.fill" :
                        vol < 0.66 ? "speaker.wave.2.fill" :
                        "speaker.wave.3.fill"

        HStack(spacing: small ? 3 : 4) {
            Image(systemName: iconName)
                .font(.system(size: iconSize))
                .foregroundStyle(theme.textSecondary)
                .contentTransition(.symbolEffect(.replace))

            // Mini volume bar with glow on adjust
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.textSecondary.opacity(0.2))
                        .frame(height: barHeight)
                    Capsule()
                        .fill(isVolumeAdjusting ?
                            LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing) :
                            LinearGradient(colors: [theme.textSecondary, theme.textSecondary], startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: geo.size.width * CGFloat(vol), height: barHeight)
                        .shadow(color: .green.opacity(isVolumeAdjusting ? 0.8 : 0), radius: isVolumeAdjusting ? 6 : 0)
                        .animation(.smooth(duration: 0.15), value: vol)
                        .animation(.easeOut(duration: 0.4), value: isVolumeAdjusting)
                }
            }
            .frame(width: barWidth, height: barHeight)
            .clipShape(Capsule())

            Text("\(Int(vol * 100))")
                .font(.system(size: textSize, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textSecondary)
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.15), value: vol)
            Text("%")
                .font(.system(size: textSize - 1, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textSecondary.opacity(0.6))
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - ScrollableTabBar (legacy single-bar, kept for compat)

struct TopTabBar: View {
    @Binding var selectedTab: AppTab
    @StateObject private var coordinator = ScrollCoordinator()
    @Environment(\.theme) private var theme

    @Namespace private var animation
    @State private var dragOffset: CGFloat = 0
    @State private var dragStartIndex: Int = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
        .padding(8)
        .background(theme.tabBarBackground)
        .clipShape(Capsule())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                coordinator.isHovering = true
            case .ended:
                coordinator.isHovering = false
            }
        }
        .onAppear {
            coordinator.start()
        }
        .onDisappear {
            coordinator.stop()
        }
        .onChange(of: coordinator.switchSignal) { _, signal in
            guard signal != 0 else { return }
            let tabs = AppTab.allCases
            guard let idx = tabs.firstIndex(of: selectedTab) else { return }

            if signal == 1, idx < tabs.count - 1 {
                withAnimation(.snappy) {
                    selectedTab = tabs[idx + 1]
                }
            } else if signal == -1, idx > 0 {
                withAnimation(.snappy) {
                    selectedTab = tabs[idx - 1]
                }
            }

            coordinator.switchSignal = 0
        }
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in
                    let tabs = AppTab.allCases
                    if dragOffset == 0 {
                        dragStartIndex = tabs.firstIndex(of: selectedTab) ?? 0
                    }

                    let rawOffset = value.translation.width
                    dragOffset = rawOffset * 0.4

                    let threshold: CGFloat = 30
                    if rawOffset < -threshold && dragStartIndex < tabs.count - 1 {
                        let nextTab = tabs[dragStartIndex + 1]
                        if selectedTab != nextTab {
                            withAnimation(.snappy) {
                                selectedTab = nextTab
                            }
                        }
                    } else if rawOffset > threshold && dragStartIndex > 0 {
                        let prevTab = tabs[dragStartIndex - 1]
                        if selectedTab != prevTab {
                            withAnimation(.snappy) {
                                selectedTab = prevTab
                            }
                        }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
        )
    }

    @ViewBuilder
    private func tabButton(for tab: AppTab) -> some View {
        Button {
            withAnimation(.snappy) {
                selectedTab = tab
            }
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selectedTab == tab ? theme.tabSelectedText : theme.tabUnselectedText)
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        if selectedTab == tab {
                            Capsule()
                                .fill(theme.tabSelectedBackground)
                                .matchedGeometryEffect(id: "pill", in: animation)
                                .offset(x: dragOffset)
                        }
                    }
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
