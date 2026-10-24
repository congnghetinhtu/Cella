//
//  TopTabBar.swift
//  Cella
//
//  Dual pill-style tab bar — left (Cluster, Cella, Config) and right (Cella Motion, Enhanced LRC).
//  Includes a "Liquid Glass" sliding selection pill and drag-to-switch.
//

import SwiftUI
import Combine

// MARK: - Album Pill Scroll Coordinator

final class AlbumPillScrollCoordinator: ObservableObject {
    @MainActor @Published var openSignal = 0

    private var monitor: Any?
    private var accumulator: CGFloat = 0
    private var gestureActive = false

    var isHovering = false

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        accumulator = 0
        gestureActive = false
    }

    private func handle(_ event: NSEvent) {
        guard isHovering else { return }

        // Only trigger on a completed, deliberate scroll gesture (trackpad).
        let isTrackpad = event.phase != [] || event.momentumPhase != []

        if isTrackpad {
            if event.phase.contains(.began) {
                accumulator = 0
                gestureActive = true
            }
            guard gestureActive else { return }

            accumulator += event.scrollingDeltaY

            // Fire once a clear directional intent builds up, then wait for
            // the gesture to end before allowing another toggle.
            let threshold: CGFloat = 24
            if abs(accumulator) >= threshold {
                gestureActive = false
                accumulator = 0
                fire()
            }

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                gestureActive = false
                accumulator = 0
            }
        } else {
            // Mouse wheel — needs more turns to avoid over-triggering.
            accumulator += event.scrollingDeltaY
            if abs(accumulator) >= 6 {
                accumulator = 0
                fire()
            }
        }
    }

    private func fire() {
        let value = openSignal + 1
        if Thread.isMainThread {
            MainActor.assumeIsolated { openSignal = value }
        } else {
            Task { @MainActor [weak self] in
                self?.openSignal = value
            }
        }
    }
}

// MARK: - BottomTabBar (single nav, bottom)

struct BottomTabBar: View {
    @Binding var selectedTab: AppTab
    @ObservedObject var lrcViewModel: EnhancedLRCViewModel
    @Environment(\.theme) private var theme

    @Namespace private var animation
    @State private var dragStartIndex: Int = 0
    @State private var hoveredTab: AppTab?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 26) {
            // Current tab as the Start title — thin, bright, crossfades on switch.
            Text(selectedTab.rawValue)
                .font(.system(size: 48, weight: .light, design: .default))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 5)
                .id("start-title-\(selectedTab.rawValue)")
                .transition(.opacity)
            // Every other tab as a dim text link, like "All Apps".
            ForEach(AppTab.allCases.filter { $0 != selectedTab }) { tab in
                tabLink(for: tab)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth, value: selectedTab)
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in
                    let tabs = AppTab.allCases
                    dragStartIndex = tabs.firstIndex(of: selectedTab) ?? 0

                    let rawOffset = value.translation.width

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
        )
    }

    // MARK: - Tab Link

    @ViewBuilder
    private func tabLink(for tab: AppTab) -> some View {
        Button {
            withAnimation(.smooth) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 5) {
                Text(tab.rawValue)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(
                        hoveredTab == tab ? .white : theme.tabUnselectedText
                    )
                    .shadow(color: .black.opacity(0.3), radius: 3)
                if tabDirty(for: tab) {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.72, blue: 0.28))
                        .frame(width: 5, height: 5)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                hoveredTab = hovering ? tab : nil
            }
        }
        .buttonStyle(.plain)
        .animation(.smooth, value: lrcViewModel.hasUnsavedChanges)
    }

    private func tabDirty(for tab: AppTab) -> Bool {
        switch tab {
        case .enhancedLRC: return lrcViewModel.hasUnsavedChanges
        default: return false
        }
    }
}

// MARK: - AlbumPill (album pill, clone of the playing-info pill)

/// Shows which album the playing track is from, with its folder cover image.
/// Slides in from the left (leading) next to the playing-info pill.
struct AlbumPill: View {
    var viewModel: PlayerViewModel
    @Environment(\.theme) private var theme
    @State private var hiSoTask: Task<Void, Never>?
    @State private var crossfadeRevealPending = false
    @State private var showAlbumSongs = false
    @State private var gradientAngle: Double = 0
    @State private var gradientTimer: Timer?
    @StateObject private var scrollCoordinator = AlbumPillScrollCoordinator()

    var body: some View {
        pillContent
            .onAppear {
                // Show first-song album info on entry; skip while a config-delayed
                // reveal is pending so it still waits its 1s.
                if !viewModel.albumPillDelayPending {
                    viewModel.syncAlbumPillState()
                }
                syncHiSo()
                updateGradientTimer()
                scrollCoordinator.start()
            }
            .onDisappear {
                scrollCoordinator.stop()
                stopGradientTimer()
                // Keep Hi-So visible state persisted in viewModel across tab switches;
                // only cancel the pending reveal timer here.
                hiSoTask?.cancel()
                hiSoTask = nil
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
                updateGradientTimer()
            }
            .onChange(of: viewModel.albumPillHiRes) { _, hiRes in
                if hiRes { scheduleHiSo() } else { hideHiSo() }
            }
            .onChange(of: viewModel.soloMode) { _, _ in
                updateGradientTimer()
            }
            .onChange(of: viewModel.albumPillHiSoVisible) { _, _ in
                updateGradientTimer()
            }
    }

    private var pillContent: some View {
        Group {
            if viewModel.albumPillVisible {
                content
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onContinuousHover { phase in
            if case .active = phase {
                scrollCoordinator.isHovering = true
            } else {
                scrollCoordinator.isHovering = false
            }
        }
        .onTapGesture {
            // Open the album→song picker when there are albums to choose.
            guard !viewModel.albums.isEmpty else { return }
            showAlbumSongs.toggle()
        }
        .onChange(of: scrollCoordinator.openSignal) { _, _ in
            withAnimation(.snappy) {
                if showAlbumSongs {
                    showAlbumSongs = false
                } else {
                    guard viewModel.albumPillVisible, !viewModel.albums.isEmpty else { return }
                    showAlbumSongs = true
                }
            }
        }
        .onChange(of: showAlbumSongs) { _, isOpen in
            viewModel.albumPickerVisible = isOpen
            if isOpen {
                // Freeze the Hi-So countdown while the picker is up — popping
                // the badge under an open popover is ugly and piles another
                // animation onto the tap that is already hitching.
                hiSoTask?.cancel()
                hiSoTask = nil
            } else {
                syncHiSo()
            }
        }
        .popover(isPresented: $showAlbumSongs, arrowEdge: .bottom) {
            AlbumSongsPopover(
                viewModel: viewModel,
                initialAlbum: viewModel.albums.first { $0.dir == viewModel.albumPillAlbumDir }
            ) { track in
                showAlbumSongs = false
                guard let queue = viewModel.mixQueue,
                      let index = queue.tracks.firstIndex(where: { $0.url == track.url }) else { return }
                viewModel.crossfadeToTrack(at: index)
            }
        }
        .animation(.smooth(duration: 0.5), value: viewModel.albumPillVisible)
        .animation(.smooth(duration: 0.5), value: viewModel.albumPillHiSoVisible)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: viewModel.soloMode)
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

    // MARK: - Badge sheen (shared with the Lyric Supported badge look)

    /// Shared background for the Solo / Hi-So status badges — the exact
    /// treatment of the Lyric Supported badge: three-stop halo gradient,
    /// spinning angular sheen (driven by `gradientAngle`), top gloss.
    private var statusBadgeBackground: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [theme.haloPrimary, theme.haloSecondary, theme.haloPrimary.opacity(0.85)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .overlay(
                Rectangle()
                    .fill(
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
                    )
                    .blendMode(.overlay)
            )
            .overlay(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.35), .white.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            )
    }

    /// Spin the angular sheen while either status badge is on screen.
    private var badgeSheenActive: Bool {
        viewModel.albumPillVisible && (viewModel.soloMode || viewModel.albumPillHiSoVisible)
    }

    private func updateGradientTimer() {
        if badgeSheenActive {
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

    private var content: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.dotInactiveDeep)
                if viewModel.isArtistMode {
                    Image(systemName: "person.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.dotActive.opacity(0.9))
                } else if let cover = viewModel.albumPillCover {
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
                Text(viewModel.isArtistMode ? "Artist" : "Picked from")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                Text(viewModel.isArtistMode ? (viewModel.activeArtistFilter ?? "") : viewModel.albumPillTitle)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 160, alignment: .leading)
                if !viewModel.albumPillSourceName.isEmpty {
                    Text(viewModel.isArtistMode
                        ? "\(viewModel.mixQueue?.count ?? 0) songs"
                        : "\(viewModel.albumPillSourceName).cella")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.dotActive.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 160, alignment: .leading)
                }
            }
            if viewModel.isArtistMode {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .contentShape(Circle())
                    .highPriorityGesture(
                        TapGesture().onEnded {
                            viewModel.clearArtistFilter()
                        }
                    )
                    .help("Clear artist filter — back to full pack")
            }

            if viewModel.soloMode {
                HStack(spacing: 3) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Solo")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusBadgeBackground)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .shadow(color: theme.haloPrimary.opacity(0.5), radius: 6)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }

            if viewModel.albumPillHiSoVisible && !viewModel.isArtistMode {
                HStack(spacing: 3) {
                    Circle()
                        .fill(.white)
                        .frame(width: 4, height: 4)
                        .shadow(color: theme.haloAccent, radius: 2)
                    Text("Hi-So")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusBadgeBackground)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .shadow(color: theme.haloPrimary.opacity(0.5), radius: 6)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        .frame(height: 36)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Capsule().fill(.white.opacity(0.16)))
        .aeroGloss(radius: 999, opacity: 0.08)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
        .contentShape(Capsule())
    }
}

// MARK: - Album Songs Popover

struct AlbumSongsPopover: View {
    var viewModel: PlayerViewModel
    var initialAlbum: AlbumGroup?
    var onSelect: (TrackAsset) -> Void
    /// When false (multi-pick sheets), selecting stays put instead of
    /// dismissing the host — the owner advances content itself.
    var autoDismiss = true
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAlbum: AlbumGroup?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if viewModel.isArtistMode {
                artistHeader
                Divider().background(theme.dotActive.opacity(0.25))
                artistSongList
            } else {
                // Header
                HStack(spacing: 10) {
                    if selectedAlbum != nil {
                        Button {
                            withAnimation(.snappy) {
                                selectedAlbum = nil
                            }
                        } label: {
                            Label("Albums", systemImage: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(theme.dotActive)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Text(selectedAlbum?.name ?? "Albums")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

                Divider().background(theme.dotActive.opacity(0.25))

                if let selectedAlbum {
                    songList(for: selectedAlbum)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    albumList
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
        }
        .animation(.snappy, value: selectedAlbum?.id)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.12)))
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
        .aeroGloss(radius: 14, opacity: 0.12)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        )
        .onAppear {
            // Open on the current album's songs first (skip in artist mode — flat list).
            if !viewModel.isArtistMode, selectedAlbum == nil {
                selectedAlbum = initialAlbum
            }
        }
    }

    private var artistHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.dotActive)
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.activeArtistFilter ?? "Artist")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text("\(viewModel.mixQueue?.count ?? 0) songs • pack order • \(viewModel.albumPillSourceName).cella")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                viewModel.clearArtistFilter()
                if autoDismiss { dismiss() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    Text("All").font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(theme.textSecondary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Clear artist filter — back to full pack")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var artistSongList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array((viewModel.mixQueue?.tracks ?? []).enumerated()), id: \.element.id) { index, track in
                    let isCurrent = track.url == viewModel.mixQueue?.currentTrack?.url
                    PickerRow(highlighted: isCurrent) {
                        onSelect(track)
                        if autoDismiss { dismiss() }
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.textSecondary)
                                .frame(width: 28, alignment: .trailing)
                            Text(track.trackTitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isCurrent ? theme.dotActive : theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            if isCurrent {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.dotActive)
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
        .scrollIndicators(.hidden)
        .frame(width: 300, height: min(CGFloat(viewModel.mixQueue?.count ?? 0) * 34 + 12, 320))
    }

    // MARK: - Album List

    // Fixed height (matches songList): the popover must never resize between
    // albums ↔ songs, or it visibly jumps on every switch.
    private var albumList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(viewModel.albums) { album in
                    let isCurrentAlbum = album.dir == viewModel.albumPillAlbumDir
                    PickerRow(highlighted: isCurrentAlbum) {
                        withAnimation(.snappy) {
                            selectedAlbum = album
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isCurrentAlbum ? "speaker.wave.2.fill" : "square.stack")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.dotActive.opacity(0.8))
                            Text(album.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isCurrentAlbum ? theme.dotActive : theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text("\(album.songs.count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.textSecondary.opacity(0.1))
                                .clipShape(Capsule())
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(theme.textSecondary.opacity(0.6))
                        }
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 272, height: 272)
    }

    // MARK: - Song List (for a chosen album)

    @ViewBuilder
    private func songList(for album: AlbumGroup) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(Array(album.songs.enumerated()), id: \.element.id) { index, track in
                    let isCurrent = track.url == viewModel.mixQueue?.currentTrack?.url
                    PickerRow(highlighted: isCurrent) {
                        onSelect(track)
                        if autoDismiss { dismiss() }
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.textSecondary)
                                .frame(width: 18, alignment: .trailing)
                            Text(track.fileName)
                                .font(.system(size: 12))
                                .foregroundStyle(isCurrent ? theme.dotActive : theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            if isCurrent {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.dotActive)
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 272, height: 272)
    }
}

// Themed tappable row with hover highlight, matching app list style.
private struct PickerRow<Content: View>: View {
    var highlighted: Bool = false
    var action: () -> Void
    @ViewBuilder var label: Content
    @Environment(\.theme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            highlighted
                                ? theme.tabSelectedBackground
                                : (isHovering ? theme.dotActive.opacity(0.12) : Color.clear)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - NowPlayingBar (top center pill + mix badge)

private struct TextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Fixed-width song title that ping-pong scrolls when the full name
/// overflows, so the pill never grows but nothing stays truncated.
/// Static when it fits or Reduce Motion is on.
private struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textW: CGFloat = 0

    private var overflow: CGFloat { max(0, textW - width) }

    var body: some View {
        Group {
            if overflow <= 0 || reduceMotion {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                TimelineView(.animation) { timeline in
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: offset(at: timeline.date.timeIntervalSinceReferenceDate))
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .clipped()
        .background(
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .hidden()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: TextWidthKey.self, value: geo.size.width)
                    }
                )
        )
        .onPreferenceChange(TextWidthKey.self) { textW = $0 }
    }

    private func offset(at now: TimeInterval) -> CGFloat {
        let speed: CGFloat = 28 // pt per second
        let hold: CGFloat = 1.1
        let dist = overflow
        let leg = dist / speed
        let cycle = hold + leg + hold + leg
        guard cycle > 0 else { return 0 }
        let t = CGFloat(now.truncatingRemainder(dividingBy: Double(cycle)))
        if t < hold { return 0 }
        if t < hold + leg { return -(t - hold) * speed }
        if t < hold + leg + hold { return -dist }
        return -dist + (t - hold - leg - hold) * speed
    }
}

struct NowPlayingBar: View {
    var viewModel: PlayerViewModel
    @Binding var selectedTab: AppTab
    @Environment(\.theme) private var theme
    @State private var gradientAngle: Double = 0
    @State private var gradientTimer: Timer?
    @State private var lyricBadgeVisible = false
    @State private var lyricBadgeTask: Task<Void, Never>?
    @State private var qualityPillsTask: Task<Void, Never>?
    @State private var isPlayPressed = false
    /// Gradient wipe sweep 0→1 after autoMix lands (smooth 1.2s, once). -1 = idle.
    @State private var wipeT: Double = -1

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
                // During crossfade, wait until finishes (state -> playing) to show
                if viewModel.playerState == .autoMix { return }
                if hasLyricSupported { hideQualityPills(); triggerLyricBadgeIfNeeded() }
                else { hideLyricBadge(); scheduleQualityPills() }
            }
            .onChange(of: viewModel.currentLyricsTrackURL) { _, _ in
                if hasLyricSupported && viewModel.playerState == .playing { triggerLyricBadgeIfNeeded() }
            }
            .onChange(of: viewModel.playerState) { old, new in
                if new == .playing && old == .autoMix {
                    triggerWipe()
                    // Crossfade landed on this song — show badge/pills again
                    if hasLyricSupported { triggerLyricBadgeIfNeeded(force: true, forcePillsAfter: true) }
                    else { showQualityPills(force: true) }
                } else if new == .playing && old != .paused && hasLyricSupported {
                    hideQualityPills(); triggerLyricBadgeIfNeeded()
                } else if new == .playing && old != .paused && !hasLyricSupported {
                    // Non-lyric: appear right after the mixing badge (autoMix -> playing)
                    showQualityPills()
                }
                if new == .paused { hideLyricBadgeKeepPills() }
                if new == .autoMix { hideLyricBadge() }
            }
            .onDisappear { stopGradientTimer() }
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
        HStack(spacing: 8) {
            // Mix badge — left of track info
            if isAutoMixing {
                mixBadge
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            if let track = track {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isPlaying ? theme.dotActive : theme.textSecondary)
                    .frame(width: 16)

                if let lyricsLine = lyrics {
                    VStack(alignment: .leading, spacing: 2) {
                        MarqueeText(
                            text: track.trackTitle,
                            font: .system(size: 11, weight: .medium, design: .rounded),
                            color: theme.textSecondary,
                            width: 150
                        )
                        Text(lyricsLine)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .id(lyricsLine)
                    .transition(.opacity)
                    .frame(maxWidth: 150)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        MarqueeText(
                            text: track.trackTitle,
                            font: .system(size: 13, weight: .semibold, design: .rounded),
                            color: theme.textPrimary,
                            width: 150
                        )
                        if let artist = track.artistName, !track.displayArtist.isEmpty {
                            Text(track.displayArtist)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .frame(maxWidth: 150)
                }

                Text("\(formatTime(viewModel.currentTime))/\(formatTime(viewModel.currentDuration))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)

                if lyricBadgeVisible {
                    lyricSupportedBadge
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if hasQualityPills, let metadata = viewModel.currentAudioMetadata {
                    let performance = metadata.bitrateLabel ?? metadata.sampleRateLabel
                    let value = performance.map { "\(metadata.qualityLabel) • \($0)" }
                        ?? metadata.qualityLabel
                    metadataPill(label: "Quality", value: value)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                Image(systemName: viewModel.lyricsMode.iconName)
                    .font(.system(size: 12))
                    .foregroundStyle(viewModel.lyricsMode != .off ? theme.dotActive : theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.white.opacity(0.10)))
                    .overlay(
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.25), .white.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .allowsHitTesting(false)
                    )
                    .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                    .contentTransition(.symbolEffect(.replace))
                    .highPriorityGesture(
                        TapGesture().onEnded {
                            withAnimation(.snappy) {
                                viewModel.lyricsMode.cycle()
                            }
                        }
                    )
            } else {
                // Empty state — bigger pill
                Image(systemName: "music.note")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.textSecondary)

                Text("Cella")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        .frame(height: 40)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(0.16)))
        .overlay(wipeOverlay)
        .aeroGloss(radius: 999, opacity: 0.08)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
        .contentShape(Rectangle())
        .animation(.smooth(duration: 0.4), value: lyrics)
        .scaleEffect(isPlayPressed ? 0.95 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isPlayPressed)
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                isPlayPressed = true
                viewModel.togglePlayPause()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                    isPlayPressed = false
                }
            }
        }
    }

    // MARK: - Post-transition wipe (smooth 1.2s sweep once after autoMix)

    private func triggerWipe() {
        wipeT = 0
        withAnimation(.smooth(duration: 1.2)) { wipeT = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            wipeT = -1
        }
    }

    @ViewBuilder
    private var wipeOverlay: some View {
        if wipeT >= 0 {
            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                let h = geo.size.height
                // Slide fully off: center travels -0.8w → +0.85w so tails clear edge.
                let glow = max(0, min(1, (1 - wipeT) / 0.15))
                let x = -w * 0.8 + wipeT * w * 1.65
                // Aurora curtains: 3 soft theme ribbons trailing each other.
                ZStack {
                    Ellipse()
                        .fill(theme.dotActive.opacity(0.35 * glow))
                        .frame(width: w * 0.5, height: h * 2.2)
                        .blur(radius: 7)
                        .offset(x: x)
                    Ellipse()
                        .fill(theme.haloSecondary.opacity(0.30 * glow))
                        .frame(width: w * 0.38, height: h * 2.6)
                        .blur(radius: 8)
                        .offset(x: x - w * 0.10)
                    Ellipse()
                        .fill(theme.haloPrimary.opacity(0.28 * glow))
                        .frame(width: w * 0.30, height: h * 2.0)
                        .blur(radius: 6)
                        .offset(x: x + w * 0.08)
                    // Faint glass sheen on the leading edge.
                    Capsule()
                        .fill(.white.opacity(0.18 * glow))
                        .frame(width: w * 0.06, height: h)
                        .offset(x: x + w * 0.22)
                }
                .frame(width: w, height: h)
                .allowsHitTesting(false)
            }
            .mask(Capsule())
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    // MARK: - Mix Badge

    private var mixBadge: some View {
        OrbMixBadge(theme: theme)
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
                        colors: [theme.haloPrimary, theme.haloSecondary, theme.haloPrimary.opacity(0.85)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(
                    Rectangle()
                        .fill(
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
                        )
                        .blendMode(.overlay)
                )
                .overlay(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.35), .white.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .allowsHitTesting(false)
                )
        )
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
        .shadow(color: theme.haloPrimary.opacity(0.5), radius: 6)
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
        .background(Capsule().fill(.white.opacity(0.10)))
        .aeroGloss(radius: 999, opacity: 0.08)
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(.white.opacity(0.2), lineWidth: 1)
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

    // MARK: - Volume Indicator (moved to the Cella screen rail)

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - ScrollableTabBar (legacy single-bar, kept for compat)

struct TopTabBar: View {
    @Binding var selectedTab: AppTab
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var animation
    @State private var dragOffset: CGFloat = 0
    @State private var dragStartIndex: Int = 0

    private let pillSpring: Animation = .spring(response: 0.35, dampingFraction: 0.65)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
        .padding(8)
        .background(theme.tabBarBackground.opacity(0.55))
        .aeroGloss(radius: 999, opacity: 0.20)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
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
                            withAnimation(reduceMotion ? .none : pillSpring) {
                                selectedTab = nextTab
                            }
                        }
                    } else if rawOffset > threshold && dragStartIndex > 0 {
                        let prevTab = tabs[dragStartIndex - 1]
                        if selectedTab != prevTab {
                            withAnimation(reduceMotion ? .none : pillSpring) {
                                selectedTab = prevTab
                            }
                        }
                    }
                }
                .onEnded { _ in
                    withAnimation(reduceMotion ? .none : .spring(response: 0.35, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
        )
    }

    @ViewBuilder
    private func tabButton(for tab: AppTab) -> some View {
        let tabIndex = AppTab.allCases.firstIndex(of: tab) ?? 0
        let isActive = selectedTab == tab
        let tabCol = theme.tabColor(for: tabIndex)
        Button {
            withAnimation(reduceMotion ? .none : pillSpring) {
                selectedTab = tab
            }
        } label: {
            TabButtonLabel(
                title: tab.rawValue,
                color: tabCol,
                isActive: isActive,
                unselectedText: theme.tabUnselectedText
            )
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    if isActive {
                        Capsule()
                            .fill(tabCol.opacity(0.22))
                            .matchedGeometryEffect(id: "pill", in: animation)
                            .offset(x: dragOffset)
                            .shadow(color: tabCol.opacity(0.65), radius: 10)
                            .overlay(
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [.white.opacity(0.30), .white.opacity(0.03)],
                                            startPoint: .top,
                                            endPoint: .center
                                        )
                                    )
                                    .allowsHitTesting(false)
                            )
                            .overlay(
                                Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1)
                            )
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tab Button Label (hover + press feedback)

private struct TabButtonLabel: View {
    let title: String
    let color: Color
    let isActive: Bool
    let unselectedText: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isPressed = false

    private let joySpring: Animation = .spring(response: 0.35, dampingFraction: 0.65)
    private let popSpring: Animation = .spring(response: 0.25, dampingFraction: 0.55)

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(foregroundColor)
            .scaleEffect(isPressed ? 0.88 : (isHovering ? 1.06 : (isActive ? 1.02 : 1.0)))
            .opacity(isHovering && !isActive ? 0.85 : 1.0)
            .rotation3DEffect(.degrees(isPressed ? -2 : 0), axis: (x: 0, y: 1, z: 0))
            .animation(reduceMotion ? .none : joySpring, value: isHovering)
            .animation(reduceMotion ? .none : popSpring, value: isPressed)
            .animation(reduceMotion ? .none : popSpring, value: isActive)
            .onHover { hovering in
                isHovering = hovering
            }
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                case .ended:
                    isHovering = false
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in
                        withAnimation(reduceMotion ? .none : popSpring) {
                            isPressed = false
                        }
                    }
            )
    }

    private var foregroundColor: Color {
        if isActive { return color }
        if isHovering { return color.opacity(0.6) }
        return unselectedText
    }
}

// MARK: - Orb Mixing Pill (thinking-orbs rings, Canvas — no MetalForge export needed)

/// Dark pill with slow-orbiting cream dots (depth size + fade), like the reference image.
/// Replaces gradient mixBadge during autoMix.
private struct OrbMixBadge: View {
    let theme: Theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // Same tempo family as old orbs (max 0.35 rev/s, 2.8s shine).
            let pulse = reduceMotion ? 0 : sin(t * 2 * .pi * 0.35)
            let bubbleD: CGFloat = 14 * (1 + pulse * 0.07)
            let a1 = reduceMotion ? 0.8 : (t * 0.35 * 2 * .pi)
            let a2 = reduceMotion ? 2.4 : (-t * 0.25 * 2 * .pi + 2.1)
            let cx: CGFloat = 15
            let cy: CGFloat = 10
            let rx: CGFloat = 10.5
            let ry: CGFloat = 6.5
            let s1 = CGPoint(x: cx + cos(a1) * rx, y: cy + sin(a1) * ry)
            let s2 = CGPoint(x: cx + cos(a2) * rx * 0.7, y: cy + sin(a2) * ry * 0.7)

            HStack(spacing: 7) {
                ZStack {
                    // Soft halo behind hero
                    Circle()
                        .fill(theme.dotActive.opacity(0.30))
                        .frame(width: 20, height: 20)
                        .blur(radius: 4)
                    // Hero gloss bubble (matches progress knob)
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
                                endRadius: bubbleD * 0.7
                            )
                        )
                        .frame(width: bubbleD, height: bubbleD)
                        .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1))
                        .overlay(
                            Ellipse()
                                .fill(.white.opacity(0.9))
                                .frame(width: bubbleD * 0.34, height: bubbleD * 0.22)
                                .offset(x: -bubbleD * 0.12, y: -bubbleD * 0.22)
                        )
                        .shadow(color: theme.dotActive.opacity(0.6), radius: 5)
                    // Two satellite sparks on old orbit tempo
                    Circle()
                        .fill(.white.opacity(0.95))
                        .frame(width: 4, height: 4)
                        .shadow(color: theme.dotActive.opacity(0.8), radius: 3)
                        .position(s1)
                    Circle()
                        .fill(theme.haloSecondary.opacity(0.9))
                        .frame(width: 3, height: 3)
                        .shadow(color: theme.haloSecondary.opacity(0.7), radius: 2)
                        .position(s2)
                }
                .frame(width: 30, height: 20)
                Text("Mixing")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            // Clear glass track (matches playing pill)
            .background(Capsule().fill(.white.opacity(0.16)))
            .overlay(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.24), .white.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                // Same 2.8s diagonal shine sweep as before.
                GeometryReader { geo in
                    let w = max(geo.size.width, 1)
                    let cycle: Double = 2.8
                    let raw = reduceMotion ? 0.5 : (t.truncatingRemainder(dividingBy: cycle)) / cycle
                    let eased = raw * raw * (3 - 2 * raw)
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.22), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: w * 0.35, height: geo.size.height)
                    .offset(x: -w * 0.2 + eased * w * 1.1)
                    .allowsHitTesting(false)
                }
                .allowsHitTesting(false)
            )
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .shadow(color: theme.dotActive.opacity(0.35), radius: 6)
        }
    }
}
