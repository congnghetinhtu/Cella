//
//  ClusterView.swift
//  Cella
//
//  Cluster — Apple Photos-style library. First open asks the user to choose a
//  .cluster library folder; the choice is remembered. Lists .cella packs with
//  their Cella Structured / OpenCella classification. Click a pack to browse
//  its albums and tracks; the Play button loads that playlist into Cella.
//

import SwiftUI
import AppKit
import AVFoundation

// MARK: - Cella-style context menu (floating panel)

/// A single selectable item in a CellaContextMenu.
struct CellaMenuAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    var isDestructive = false
    let action: () -> Void
}

/// Shows a Cella-themed menu panel at a screen point (replaces system context menus).
enum CellaContextMenu {
    private static var panel: CellaContextMenuPanel?
    private static var monitor: Any?
    private static var keyMonitor: Any?

    static func show(at screenPoint: NSPoint, theme: Theme, actions: [CellaMenuAction]) {
        close()

        let panel = CellaContextMenuPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true

        let hosting = NSHostingView(
            rootView: CellaContextMenuView(actions: actions) {
                close()
            }
            .environment(\.theme, theme)
        )
        panel.contentView = hosting

        let size = hosting.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: screenPoint.x, y: screenPoint.y - size.height + 3))
        panel.orderFrontRegardless()

        self.panel = panel
        installClickAwayMonitor()
    }

    static func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        monitor = nil
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private static func installClickAwayMonitor() {
        // Close when clicking outside the panel; let inside-clicks reach the buttons.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { event in
            guard let panel, let content = panel.contentView else { return event }
            let pointInPanel = content.convert(event.locationInWindow, from: nil)
            if content.bounds.contains(pointInPanel) {
                return event
            }
            close()
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                close()
                return nil
            }
            return event
        }
    }
}

/// Nonactivating, non-key borderless panel that hosts the menu.
final class CellaContextMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The Cella-styled menu content.
struct CellaContextMenuView: View {
    let actions: [CellaMenuAction]
    var onClose: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 2) {
            ForEach(actions) { action in
                menuRow(action)
                if action.id != actions.last?.id {
                    Divider()
                        .overlay(theme.textSecondary.opacity(CardStyle.borderOpacity))
                        .padding(.horizontal, 8)
                }
            }
        }
        .padding(6)
        .frame(width: 210)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.textSecondary.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    private func menuRow(_ action: CellaMenuAction) -> some View {
        MenuRowView(action: action) {
            onClose()
            action.action()
        }
    }
}

/// One menu item row with hover highlight.
private struct MenuRowView: View {
    let action: CellaMenuAction
    var onTap: () -> Void
    @Environment(\.theme) private var theme
    @State private var isHovering = false

    private var tint: Color {
        action.isDestructive ? Color.red : theme.dotActive
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(tint.opacity(isHovering ? 0.22 : 0.12))
                    .frame(width: 26, height: 26)
                Image(systemName: action.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }

            Text(action.title)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(isHovering ? theme.textPrimary : (action.isDestructive ? Color.red : theme.textPrimary))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? theme.textSecondary.opacity(0.1) : .clear)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            onTap()
        }
    }
}

/// Transparent NSView that overlays a row and reports left/right clicks + hover.
/// Lives on TOP of SwiftUI content so right-clicks reach it (a `.background` is
/// underneath the row and is never hit-tested).
struct RightClickCatcher: NSViewRepresentable {
    var onLeftClick: () -> Void
    var onRightClick: (NSPoint, NSWindow?) -> Void
    var onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> RightClickCatcherView {
        let view = RightClickCatcherView()
        view.onLeftClick = onLeftClick
        view.onRightClick = onRightClick
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ nsView: RightClickCatcherView, context: Context) {
        nsView.onLeftClick = onLeftClick
        nsView.onRightClick = onRightClick
        nsView.onHoverChange = onHoverChange
    }
}

final class RightClickCatcherView: NSView {
    var onLeftClick: (() -> Void)?
    var onRightClick: ((NSPoint, NSWindow?) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseDown(with event: NSEvent) {
        onLeftClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event.locationInWindow, window)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}

enum PackSort: String, CaseIterable {
    case name = "Name"
    case tracks = "Tracks"
    case cached = "Cached"
}

enum ClusterMode: String, CaseIterable {
    case playlists = "Playlists"
    case artists = "Artists"
}

struct ClusterView: View {
    var viewModel: PlayerViewModel?
    var onPlay: (() -> Void)? = nil
    var onOpenDetail: ((CellaPack) -> Void)? = nil
    var onOpenLRC: ((URL) -> Void)? = nil
    @AppStorage("clusterLibraryPath") private var libraryPath: String = ""
    @State private var library: ClusterLibrary?
    @State private var loadingPackURL: URL?
    @State private var searchText = ""
    @State private var sortMode: PackSort = .name
    @State private var showNewPack = false
    @State private var newPackName = ""
    @State private var packToRename: CellaPack?
    @State private var renameText = ""
    @State private var packToDelete: CellaPack?
    @State private var libraryArtists: [LibraryArtist] = []
    @State private var artistThumbs: [String: NSImage] = [:]
    @State private var loadingArtistKey: String?
    @State private var clusterMode: ClusterMode = .playlists
    @State private var artistSearch = ""
    @State private var selectedArtistKey: String?
    @State private var collapsedPacks: Set<String> = []
    @State private var collapsedAlbums: Set<String> = []
    @State private var packArtistsCache: [String: [PackArtist]] = [:]
    @State private var expandedArtistPacks: Set<String> = []
    @State private var activeRailPack: String?
    @State private var artistPackFilter: String?
    @State private var showAllArtists = false
    @State private var openedPackPath: String?
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cardRadius: CGFloat = CardStyle.radius

    var body: some View {
        ZStack {
            theme.appBackground.ignoresSafeArea()

            if let library {
                libraryContent(library)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if library == nil, !libraryPath.isEmpty, FileManager.default.fileExists(atPath: libraryPath) {
                withAnimation(.snappy) {
                    library = ClusterLibrary.scan(URL(fileURLWithPath: libraryPath))
                }
            }
            if library == nil, autoLoadDefault() {}
            // Refresh cache counts in case analysis ran while away
            if var lib = library {
                lib.refreshCacheCounts()
                library = lib
            }
            reloadLibraryArtists()
        }
        .onChange(of: library?.url) { _, _ in reloadLibraryArtists() }
    }

    // MARK: - Library

    private var filteredPacks: [CellaPack] {
        guard let lib = library else { return [] }
        var packs = lib.packs
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            packs = packs.filter {
                $0.name.lowercased().contains(q)
                || $0.url.lastPathComponent.lowercased().contains(q)
            }
        }
        switch sortMode {
        case .name:
            packs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .tracks:
            packs.sort { $0.trackCount > $1.trackCount }
        case .cached:
            packs.sort {
                let a = $0.trackCount > 0 ? Double($0.cachedTrackCount) / Double($0.trackCount) : 0
                let b = $1.trackCount > 0 ? Double($1.cachedTrackCount) / Double($1.trackCount) : 0
                return a > b
            }
        }
        return packs
    }

    private var libraryStats: (packs: Int, albums: Int, tracks: Int, cached: Int) {
        guard let lib = library else { return (0, 0, 0, 0) }
        let albums = lib.packs.reduce(0) { $0 + $1.albumCount }
        let tracks = lib.packs.reduce(0) { $0 + $1.trackCount }
        let cached = lib.packs.reduce(0) { $0 + $1.cachedTrackCount }
        return (lib.packs.count, albums, tracks, cached)
    }

    private func libraryContent(_ lib: ClusterLibrary) -> some View {
        VStack(spacing: 0) {
            header(lib)
            statsBar
            discoveryBar

            if clusterMode == .playlists {
                ScrollView {
                    if filteredPacks.isEmpty {
                        Text(searchText.isEmpty ? "No playlists yet" : "No matches for \"\(searchText)\"")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .padding(.top, 40)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 280), spacing: 20)],
                            spacing: 20
                        ) {
                            ForEach(filteredPacks) { pack in
                                packCard(pack)
                            }
                        }
                        .padding(.horizontal, CardStyle.horizontalPadding)
                        .padding(.top, 8)
                        .padding(.bottom, 40)
                    }
                }
            } else {
                artistsTimeline(lib)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("New Playlist", isPresented: $showNewPack) {
            TextField("Name", text: $newPackName)
            Button("Create") { createPack(named: newPackName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Playlist", isPresented: Binding(get: { packToRename != nil }, set: { if !$0 { packToRename = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let p = packToRename { renamePack(p, to: renameText) } }
            Button("Cancel", role: .cancel) { packToRename = nil }
        }
        .alert("Delete Playlist?", isPresented: Binding(get: { packToDelete != nil }, set: { if !$0 { packToDelete = nil } })) {
            Button("Delete", role: .destructive) { if let p = packToDelete { deletePack(p) } }
            Button("Cancel", role: .cancel) { packToDelete = nil }
        } message: {
            Text("Move \(packToDelete?.name ?? "") to Trash? Cannot undo.")
        }
    }

    private var statsBar: some View {
        let s = libraryStats
        return HStack(spacing: 14) {
            statChip("\(s.packs)", "playlists")
            statChip("\(s.albums)", "albums")
            statChip("\(s.tracks)", "tracks")
            if s.tracks > 0 {
                let pct = Int(Double(s.cached) / Double(max(1, s.tracks)) * 100)
                statChip("\(pct)%", "cached")
            }
            Spacer()
        }
        .padding(.horizontal, CardStyle.horizontalPadding)
        .padding(.bottom, 10)
    }

    private func statChip(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(theme.textPrimary)
            Text(label).font(.system(size: 11)).foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.textSecondary.opacity(0.08)))
    }

    private var discoveryBar: some View {
        HStack(spacing: 12) {
            ClusterModeSwitch(mode: $clusterMode)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                TextField(clusterMode == .playlists ? "Search playlists" : "Search artists", text: clusterMode == .playlists ? $searchText : $artistSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textPrimary)
                if !(clusterMode == .playlists ? searchText.isEmpty : artistSearch.isEmpty) {
                    Button { if clusterMode == .playlists { searchText = "" } else { artistSearch = "" } } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(theme.textSecondary) }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.screenBackground))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.textSecondary.opacity(0.2), lineWidth: 1))
            .frame(maxWidth: 280)

            if clusterMode == .playlists {
                Menu {
                    ForEach(PackSort.allCases, id: \.self) { s in
                        Button(s.rawValue) { withAnimation(.snappy) { sortMode = s } }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .semibold))
                        Text(sortMode.rawValue).font(.system(size: 12, weight: .semibold, design: .rounded))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.6)
                    }
                    .foregroundStyle(theme.tabSelectedText)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(theme.tabBarBackground))
                    .overlay(Capsule().stroke(theme.textSecondary.opacity(0.2), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 150, alignment: .leading)
            } else {
                Text("\(libraryArtists.count) artists")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 150, alignment: .leading)
            }

            Spacer()

            Button {
                newPackName = ""
                showNewPack = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    Text("New").font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(theme.tabSelectedText)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.tabSelectedBackground))
            }
            .buttonStyle(.plain)

            Button { rescan() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .padding(7)
                    .background(Circle().fill(theme.textSecondary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Rescan library")
        }
        .padding(.horizontal, CardStyle.horizontalPadding)
        .padding(.bottom, 12)
    }

    // MARK: - Artists (clean redo): pack chips top + deduped big circles. No rail, no repeats.
    private var displayedArtists: [LibraryArtist] {
        var list = filteredLibraryArtists
        if let filter = artistPackFilter,
           let packArtists = packArtistsCache[filter] {
            let keys = Set(packArtists.map { $0.key })
            list = list.filter { keys.contains($0.key) }
        }
        return list
    }

    private var visibleArtists: [LibraryArtist] {
        if showAllArtists { return displayedArtists }
        return Array(displayedArtists.prefix(24))
    }

    // Android app folder style: packs as folders with stacked preview, tap opens folder.
    private func artistsTimeline(_ lib: ClusterLibrary) -> some View {
        let packs = lib.packs.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        return ZStack {
            ScrollView {
                if packs.isEmpty {
                    artistsEmptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 20)], spacing: 22) {
                        ForEach(packs) { pack in
                            packFolderCell(pack, libraryURL: lib.url)
                        }
                    }
                    .padding(.horizontal, CardStyle.horizontalPadding)
                    .padding(.vertical, 18)
                    .padding(.bottom, 30)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Folder open overlay (Android folder expand)
            if let path = openedPackPath,
               let pack = packs.first(where: { $0.url.path == path }) {
                Color.black.opacity(0.45).ignoresSafeArea()
                    .onTapGesture { withAnimation(.snappy) { openedPackPath = nil } }
                packFolderOpen(pack, libraryURL: lib.url)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: openedPackPath)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func packFolderCell(_ pack: CellaPack, libraryURL: URL) -> some View {
        let artists = filteredPackArtists(pack)
        return VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(theme.screenBackground)
                    .frame(width: 150, height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.textSecondary.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 10)
                // Stacked preview 2x2 (top 4 artists)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(artists.prefix(4)) { pa in
                        if let libArtist = libraryArtists.first(where: { $0.key == pa.key }) {
                            ZStack {
                                Circle().fill(theme.textSecondary.opacity(0.12)).frame(width: 56, height: 56)
                                if let thumb = artistThumbs[libArtist.key] {
                                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 56, height: 56).clipShape(Circle())
                                } else {
                                    Text(String(libArtist.name.prefix(1)).uppercased())
                                        .font(.system(size: 20, weight: .bold, design: .rounded))
                                        .foregroundStyle(theme.dotActive)
                                }
                            }
                            .onAppear { loadArtistThumb(libArtist) }
                        }
                    }
                }
                .frame(width: 120, height: 120)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy) { openedPackPath = pack.url.path }
            }
            Text(pack.name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary).lineLimit(1).frame(width: 150)
            Text("\(artists.count) artists")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textSecondary)
        }
        .frame(width: 150)
    }

    private func filteredPackArtists(_ pack: CellaPack) -> [PackArtist] {
        let all = packArtistsCache[pack.url.path] ?? []
        let q = ArtistMatcher.normKey(artistSearch)
        if q.isEmpty { return all }
        return all.filter { $0.key.contains(q) || $0.name.lowercased().contains(artistSearch.lowercased()) }
    }

    private func packFolderOpen(_ pack: CellaPack, libraryURL: URL) -> some View {
        let artists = filteredPackArtists(pack)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(pack.name)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary).lineLimit(1)
                Spacer()
                Button { withAnimation(.snappy) { openedPackPath = nil } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider().background(theme.textSecondary.opacity(0.12))
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 18) {
                    ForEach(artists) { pa in
                        if let libArtist = libraryArtists.first(where: { $0.key == pa.key }) {
                            bigLibraryCircle(libArtist, libraryURL: libraryURL)
                        }
                    }
                }
                .padding(20)
            }
            .frame(width: 560, height: 420)
        }
        .frame(width: 560)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.textSecondary.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30)
    }

    private var artistsEmptyState: some View {
        VStack(spacing: 12) {
            if libraryArtists.isEmpty && packArtistsCache.isEmpty {
                ProgressView().controlSize(.large).tint(theme.dotActive)
                Text("Loading artists…")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                HStack(spacing: 14) {
                    ForEach(0..<6, id: \.self) { _ in
                        Circle().fill(theme.textSecondary.opacity(0.12)).frame(width: 88, height: 88)
                    }
                }
                .opacity(0.7)
            } else {
                Image(systemName: "person.2.slash").font(.system(size: 28)).foregroundStyle(theme.textSecondary.opacity(0.6))
                Text("No artists match \"\(artistSearch)\"")
                    .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(theme.textPrimary)
                Button("Clear search") { artistSearch = "" }
                    .buttonStyle(.bordered).tint(theme.dotActive)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var filteredLibraryArtists: [LibraryArtist] {
        let q = ArtistMatcher.normKey(artistSearch)
        if q.isEmpty { return libraryArtists }
        return libraryArtists.filter {
            $0.key.contains(q) || $0.name.lowercased().contains(artistSearch.lowercased())
        }
    }

    private func bigLibraryCircle(_ artist: LibraryArtist, libraryURL: URL) -> some View {
        let isLoading = loadingArtistKey == artist.key
        let isNowPlaying = viewModel?.activeArtistFilter.map { ArtistMatcher.normKey($0) == artist.key } ?? false
        return ArtistCircleCell(
            name: artist.name,
            thumb: artistThumbs[artist.key],
            theme: theme,
            isLoading: isLoading,
            isNowPlaying: isNowPlaying
        )
        .onAppear { loadArtistThumb(artist) }
        .opacity(isLoading ? 0.6 : 1)
        .allowsHitTesting(!isLoading)
        .onTapGesture { playLibraryArtist(artist, libraryURL: libraryURL) }
    }

    private func reloadLibraryArtists() {
        guard let lib = library else { libraryArtists = []; packArtistsCache = [:]; return }
        let url = lib.url
        let packs = lib.packs
        DispatchQueue.global(qos: .utility).async {
            let artists = ClusterLibrary.libraryArtists(in: url)
            var perPack: [String: [PackArtist]] = [:]
            for pack in packs {
                perPack[pack.url.path] = ClusterLibrary.artists(in: pack.url)
            }
            DispatchQueue.main.async {
                // Stale check
                guard library?.url == url else { return }
                libraryArtists = artists
                packArtistsCache = perPack
                // Preload first snapshots
                for a in artists.prefix(12) { loadArtistThumb(a) }
            }
        }
    }

    private func loadArtistThumb(_ artist: LibraryArtist) {
        guard artistThumbs[artist.key] == nil else { return }
        guard let videoURL = artist.videoURL else { return }
        // Snapshot from cma video (current source; AI analysis hook later)
        DispatchQueue.global(qos: .utility).async {
            let img = ArtistSnapshot.snapshot(videoURL: videoURL)
            if let img {
                DispatchQueue.main.async { artistThumbs[artist.key] = img }
            }
        }
    }

    private func playLibraryArtist(_ artist: LibraryArtist, libraryURL: URL) {
        guard let viewModel, loadingArtistKey == nil else { return }
        loadingArtistKey = artist.key
        selectedArtistKey = artist.key
        viewModel.playLibraryArtist(artist, libraryURL: libraryURL)
        viewModel.log("Playing \(artist.name) — \(artist.trackCount) songs")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            loadingArtistKey = nil
        }
        onPlay?()
    }

    private func revealArtistVideos(_ artist: LibraryArtist) {
        guard let videoURL = artist.videoURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([videoURL])
    }

    private func header(_ lib: ClusterLibrary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(libraryTitle(lib))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                HStack(spacing: 6) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                    Text("\(lib.packs.count) playlists")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            Spacer()
            ChangeLibraryButton {
                chooseLibrary()
            }
        }
        .padding(.horizontal, CardStyle.horizontalPadding)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }

    // MARK: - Pack Card

    private func packCard(_ pack: CellaPack) -> some View {
        let index = library?.packs.firstIndex(where: { $0.id == pack.id }) ?? 0
        return PackCardView(
            pack: pack,
            cardRadius: cardRadius,
            isLoading: loadingPackURL == pack.url,
            index: index,
            reduceMotion: reduceMotion,
            onPlay: { playPack(pack) },
            onTap: { onOpenDetail?(pack) }
        )
        .animation(.snappy, value: loadingPackURL)
        .contextMenu {
            Button("Open") { onOpenDetail?(pack) }
            Button("Play") { playPack(pack) }
            Divider()
            Button("Reveal in Finder") { revealPack(pack) }
            Button("Rename…") {
                renameText = pack.name
                packToRename = pack
            }
            Button("Rescan") { rescan() }
            Divider()
            Button("Move to Trash…", role: .destructive) { packToDelete = pack }
        }
    }

    private func playArtist(_ pack: CellaPack, artist: PackArtist) {
        guard let viewModel else { return }
        loadingPackURL = pack.url
        viewModel.importViaOpenMix(url: pack.url, startFileName: artist.files.first, blend: false, artistFilter: artist.name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            loadingPackURL = nil
        }
        onPlay?()
    }

    // MARK: - Empty state (first open)

    @State private var emptyIconScale: CGFloat = 0.85

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(theme.dotActive.opacity(0.12))
                    .frame(width: 140, height: 140)
                    .scaleEffect(emptyIconScale)
                    .animation(
                        reduceMotion ? .none : .easeInOut(duration: 2.5).repeatForever(autoreverses: true),
                        value: emptyIconScale
                    )
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(theme.dotActive)
                    .transition(.scale.combined(with: .opacity))
            }
            Text("Welcome to Cella")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .transition(.move(edge: .top).combined(with: .opacity))
            Text("Choose a music library to get started.\nYou can switch libraries anytime.")
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .transition(.move(edge: .top).combined(with: .opacity))

            Button {
                chooseLibrary()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 14))
                    Text("Choose Library")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.dotActive)
                )
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if !reduceMotion {
                emptyIconScale = 1.0
            }
        }
    }

    // MARK: - Actions

    private func playPack(_ pack: CellaPack) {
        guard let viewModel else { return }
        loadingPackURL = pack.url
        // Pass first track so background cache only analyzes that album
        let firstTrack = ClusterLibrary.albums(in: pack.url).first?.tracks.first?.file
        viewModel.importViaOpenMix(url: pack.url, startFileName: firstTrack)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            loadingPackURL = nil
        }
        onPlay?()
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Library"
        panel.message = "Select a .cluster library folder"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension.lowercased() == "cluster" else { return }

        libraryPath = url.path
        withAnimation(.snappy) {
            library = ClusterLibrary.scan(url)
        }
    }

    private func libraryTitle(_ lib: ClusterLibrary) -> String {
        lib.url.deletingPathExtension().lastPathComponent
    }

    private func rescan() {
        guard !libraryPath.isEmpty else { return }
        let url = URL(fileURLWithPath: libraryPath)
        withAnimation(.snappy) {
            var lib = ClusterLibrary.scan(url)
            lib.refreshCacheCounts()
            library = lib
        }
        reloadLibraryArtists()
    }

    private func createPack(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !libraryPath.isEmpty else { return }
        let libURL = URL(fileURLWithPath: libraryPath)
        let packURL = libURL.appendingPathComponent(trimmed + ".cella")
        do {
            try FileManager.default.createDirectory(at: packURL, withIntermediateDirectories: true)
            rescan()
        } catch {
            print("[Cluster] create pack failed: \(error)")
        }
    }

    private func renamePack(_ pack: CellaPack, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { packToRename = nil; return }
        let dest = pack.url.deletingLastPathComponent().appendingPathComponent(trimmed + ".cella")
        do {
            try FileManager.default.moveItem(at: pack.url, to: dest)
            packToRename = nil
            rescan()
        } catch {
            print("[Cluster] rename failed: \(error)")
            packToRename = nil
        }
    }

    private func deletePack(_ pack: CellaPack) {
        do {
            try FileManager.default.trashItem(at: pack.url, resultingItemURL: nil)
            packToDelete = nil
            rescan()
        } catch {
            print("[Cluster] delete failed: \(error)")
            packToDelete = nil
        }
    }

    private func revealPack(_ pack: CellaPack) {
        NSWorkspace.shared.activateFileViewerSelecting([pack.url])
    }

    private func autoLoadDefault() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Downloads/Cella Projects/musicLiblary.cluster"),
            home.appendingPathComponent("Downloads/musicLiblary.cluster"),
            home.appendingPathComponent("Music/musicLiblary.cluster"),
        ]
        var defaultURL: URL?
        for url in candidates where fm.fileExists(atPath: url.path) { defaultURL = url; break }
        if defaultURL == nil {
            let downloads = home.appendingPathComponent("Downloads")
            if let contents = try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil),
               let found = contents.first(where: { $0.pathExtension.lowercased() == "cluster" && fm.fileExists(atPath: $0.path) }) {
                defaultURL = found
            } else {
                for sub in (try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? [] where sub.hasDirectoryPath {
                    guard let subContents = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) else { continue }
                    if let found = subContents.first(where: { $0.pathExtension.lowercased() == "cluster" && fm.fileExists(atPath: $0.path) }) {
                        defaultURL = found; break
                    }
                }
            }
        }
        guard let url = defaultURL else { return false }
        libraryPath = url.path
        withAnimation(.snappy) {
            library = ClusterLibrary.scan(url)
        }
        return true
    }
}

// MARK: - Pack Card (hover lift, press feedback, staggered entrance)

private struct PackCardView: View {
    let pack: CellaPack
    let cardRadius: CGFloat
    let isLoading: Bool
    let index: Int
    let reduceMotion: Bool
    var onPlay: () -> Void
    var onTap: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovering = false
    @State private var isPressed = false
    @State private var hasAppeared = false
    @State private var loadedImages: [URL: NSImage] = [:]
    @State private var topArtists: [PackArtist] = []

    private let entranceDelay: Double = Double.random(in: 0...0.12)
    private let joySpring: Animation = .spring(response: 0.35, dampingFraction: 0.65)
    private let popSpring: Animation = .spring(response: 0.25, dampingFraction: 0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                coverCollage
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                // Play overlay — reveals on hover
                Circle()
                    .fill(.black.opacity(isHovering ? 0.5 : 0))
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                            .offset(x: 1.5)
                            .scaleEffect(isHovering ? 1.1 : 0.5)
                            .rotationEffect(.degrees(isHovering ? 0 : -15))
                            .opacity(isHovering ? 1.0 : 0)
                    )
                    .animation(reduceMotion ? .none : joySpring, value: isHovering)
                    .onTapGesture {
                        onPlay()
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(pack.name)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 8) {
                    typeBadge

                    Spacer()

                    Text("\(pack.trackCount) tracks")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.textSecondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "square.stack.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                    Text("\(pack.albumCount) albums")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    if pack.cachedTrackCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.dotActive)
                            Text("\(pack.cachedTrackCount)/\(pack.trackCount)")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.dotActive)
                        }
                    }
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textSecondary.opacity(0.6))
                }

                if !topArtists.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(topArtists.prefix(4)) { a in
                                HStack(spacing: 4) {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 8))
                                    Text(a.name)
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .lineLimit(1)
                                    Text("\(a.trackCount)")
                                        .font(.system(size: 9, design: .monospaced))
                                        .opacity(0.7)
                                }
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(theme.textSecondary.opacity(0.08)))
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(
                    isHovering
                        ? theme.dotActive.opacity(0.3)
                        : theme.textSecondary.opacity(CardStyle.borderOpacity),
                    lineWidth: isHovering ? 1.5 : 1
                )
        )
        .scaleEffect(isPressed ? 0.92 : (isHovering ? 1.04 : 1.0))
        .opacity(isLoading ? 0.4 : 1)
        .offset(y: hasAppeared ? 0 : 24)
        .opacity(hasAppeared ? 1 : 0)
        .rotation3DEffect(.degrees(hasAppeared ? 0 : 3), axis: (x: 1, y: 0, z: 0))
        .animation(reduceMotion ? .none : joySpring.delay(entranceDelay), value: hasAppeared)
        .animation(reduceMotion ? .none : joySpring, value: isHovering)
        .animation(reduceMotion ? .none : popSpring, value: isPressed)
        .contentShape(RoundedRectangle(cornerRadius: cardRadius))
        .onTapGesture {
            onTap()
        }
        .onHover { hovering in
            withAnimation(reduceMotion ? .none : joySpring) {
                isHovering = hovering
            }
            if !hovering {
                isPressed = false
            }
        }
        .onAppear {
            loadImages()
            DispatchQueue.global(qos: .utility).async {
                let artists = ClusterLibrary.artists(in: pack.url)
                DispatchQueue.main.async {
                    topArtists = Array(artists.prefix(4))
                }
            }
            guard !reduceMotion else {
                hasAppeared = true
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + entranceDelay) {
                hasAppeared = true
            }
        }
    }

    @ViewBuilder
    private var coverCollage: some View {
        switch pack.coverURLs.count {
        case 0:
            LinearGradient(
                colors: [theme.dotActive.opacity(0.35), theme.dotInactiveDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(
                Image(systemName: pack.type.icon)
                    .font(.system(size: 46))
                    .foregroundStyle(theme.dotActive.opacity(0.9))
            )
        case 1:
            coverImage(pack.coverURLs[0])
        case 2:
            HStack(spacing: 0) {
                coverImage(pack.coverURLs[0])
                coverImage(pack.coverURLs[1])
            }
        default:
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)], spacing: 0) {
                ForEach(Array(pack.coverURLs.prefix(4).enumerated()), id: \.offset) { _, url in
                    coverImage(url)
                }
            }
        }
    }

    private func coverImage(_ url: URL) -> some View {
        ZStack {
            Rectangle()
                .fill(theme.dotInactiveDeep.opacity(0.6))
            if let image = loadedImages[url] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 28))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func loadImages() {
        for url in pack.coverURLs.prefix(4) {
            guard loadedImages[url] == nil else { continue }
            if let image = NSImage(contentsOf: url) {
                loadedImages[url] = image
            }
        }
    }

    private var typeBadge: some View {
        let accent = pack.type == .structured ? theme.dotActive : theme.textSecondary
        return HStack(spacing: 5) {
            Image(systemName: pack.type.icon)
                .font(.system(size: 10))
            Text(pack.type.label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(accent.opacity(0.14))
        )
    }
}

// MARK: - Hoverable Buttons

private struct ChangeLibraryButton: View {
    var action: () -> Void
    @Environment(\.theme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                Text("Change Library")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(isHovering ? theme.textPrimary : theme.tabSelectedText)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovering ? theme.tabSelectedBackground.opacity(1.2) : theme.tabSelectedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovering ? theme.textSecondary.opacity(0.2) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct PlayActionButton: View {
    var label: String
    var action: () -> Void
    @Environment(\.theme) private var theme
    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13))
                Text(label)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.dotActive)
            )
            .scaleEffect(isPressed ? 0.95 : (isHovering ? 1.03 : 1.0))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .animation(.spring(response: 0.2, dampingFraction: 0.9), value: isHovering)
        .animation(.spring(response: 0.15, dampingFraction: 0.7), value: isPressed)
    }
}

// MARK: - Pack Detail (drill-down)

struct PackDetailView: View {
    let pack: CellaPack
    var viewModel: PlayerViewModel?
    var onPlay: (_ startFileName: String?) -> Void
    var onAutoMix: (_ startFileName: String?, _ album: CellaAlbum) -> Void = { _, _ in }
    var onPlayArtist: ((PackArtist) -> Void)? = nil
    var onClose: () -> Void = {}
    var onOpenLRC: ((URL) -> Void)? = nil
    @Environment(\.theme) private var theme

    @State private var albums: [CellaAlbum] = []
    @State private var expandedAlbum: CellaAlbum.ID?
    @State private var loadedCovers: [URL: NSImage] = [:]

    private let cardRadius: CGFloat = CardStyle.radius

    var body: some View {
        VStack(spacing: 0) {
            detailHeader

            if albums.isEmpty {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                    .tint(theme.dotActive)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(albums) { album in
                            albumCard(album)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 26)
                }
            }
        }
        .frame(width: 860, height: 620)
        .background(theme.appBackground.ignoresSafeArea())
        .clipShape(RoundedRectangle(cornerRadius: CardStyle.radius))
        .contentShape(RoundedRectangle(cornerRadius: CardStyle.radius))
        .overlay(
            RoundedRectangle(cornerRadius: CardStyle.radius)
                .stroke(theme.textSecondary.opacity(CardStyle.borderOpacity), lineWidth: 1)
        )
        .task(id: pack.url) {
            guard !pack.url.path.isEmpty else { return }
            albums = []
            expandedAlbum = nil
            loadedCovers = [:]
            albums = ClusterLibrary.albums(in: pack.url)
            loadAlbumCovers()
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 16) {
            Button {
                onClose()
            } label: {
                Circle()
                    .fill(theme.screenBackground)
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                    )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(pack.name)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                }
                HStack(spacing: 10) {
                    Text(pack.type.label)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(pack.type == .structured ? theme.dotActive : theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill((pack.type == .structured
                                    ? theme.dotActive
                                    : theme.textSecondary).opacity(0.14))
                        )
                    Text("\(pack.albumCount) albums · \(pack.trackCount) tracks")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
            }

            Spacer()

            PlayActionButton(label: "Play This Playlist") {
                onPlay(nil)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
    }

    private var albumList: some View {
        EmptyView()
    }

    private func albumCard(_ album: CellaAlbum) -> some View {
        let isExpanded = expandedAlbum == album.id
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                HStack(spacing: 12) {
                    albumCover(album)
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(album.name)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let artist = album.artist {
                            Text(artist)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            Text("\(album.trackCount) tracks")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary.opacity(0.7))
                            if album.cachedTrackCount > 0 {
                                Text("·")
                                    .foregroundStyle(theme.textSecondary.opacity(0.5))
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(theme.dotActive)
                                Text("\(album.cachedTrackCount)/\(album.trackCount)")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(theme.dotActive)
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(isExpanded ? theme.dotActive : theme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(isExpanded
                                    ? theme.tabSelectedBackground
                                    : theme.textSecondary.opacity(0.1))
                        )
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .scaleEffect(isExpanded ? 1.1 : 1.0)
                        .animation(.spring(response: 0.35, dampingFraction: 0.65), value: isExpanded)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.snappy) {
                        expandedAlbum = isExpanded ? nil : album.id
                    }
                }

                Button {
                    onPlay(album.tracks.first?.file)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                        Text("Play")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.dotActive)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                        trackRow(index: index, track: track, album: album)
                        if index < album.tracks.count - 1 {
                            Divider()
                                .overlay(theme.textSecondary.opacity(0.1))
                                .padding(.leading, 64)
                        }
                    }
                }
                .padding(.bottom, 8)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -8)),
                    removal: .opacity.combined(with: .offset(y: -4))
                ))
            }
        }
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(isExpanded ? theme.tabSelectedBackground : theme.textSecondary.opacity(0.12), lineWidth: isExpanded ? 1.5 : 1)
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.65), value: isExpanded)
    }

    private func trackRow(index: Int, track: CellaTrack, album: CellaAlbum) -> some View {
        HStack(spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 22)
                .padding(.leading, 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title ?? track.file)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let artist = track.artist {
                    Text(artist)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "play.circle")
                .font(.system(size: 14))
                .foregroundStyle(theme.dotActive.opacity(0.7))
                .padding(.trailing, 18)
                .onTapGesture {
                    // Pulse to the current position animation on the row
                }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(
            hoveredTrackAlbumID == album.id && hoveredTrackIndex == index
                ? theme.textSecondary.opacity(0.07)
                : .clear
        )
        .overlay(
            RightClickCatcher(
                onLeftClick: {
                    onPlay(track.file)
                },
                onRightClick: { windowPoint, window in
                    presentRowMenu(at: windowPoint, window: window, track: track, album: album)
                },
                onHoverChange: { hovering in
                    hoveredTrackIndex = hovering ? index : nil
                    hoveredTrackAlbumID = hovering ? album.id : nil
                }
            )
        )
    }

    private func presentRowMenu(at windowPoint: NSPoint, window: NSWindow?, track: CellaTrack, album: CellaAlbum) {
        guard let window else { return }
        let screenPoint = window.convertToScreen(
            NSRect(origin: windowPoint, size: .zero)
        ).origin

        CellaContextMenu.show(at: screenPoint, theme: theme, actions: [
            CellaMenuAction(title: "AutoMix to", systemImage: "arrow.triangle.merge") {
                autoMixTo(track, in: album)
            },
            CellaMenuAction(title: "Add LRC…", systemImage: "doc.badge.plus") {
                if let audioURL = audioURL(for: track, in: album) {
                    onOpenLRC?(audioURL)
                }
            }
        ])
    }

    private func audioURL(for track: CellaTrack, in album: CellaAlbum) -> URL? {
        let audioURL = pack.url.appendingPathComponent(album.folderName)
            .appendingPathComponent(track.file)
        return FileManager.default.fileExists(atPath: audioURL.path) ? audioURL : nil
    }

    private func autoMixTo(_ track: CellaTrack, in album: CellaAlbum) {
        if let viewModel,
           let queue = viewModel.mixQueue,
           let audioURL = audioURL(for: track, in: album),
           let index = queue.tracks.firstIndex(where: { $0.url == audioURL }),
           index != queue.currentIndex,
           queue.currentTrack != nil {
            viewModel.crossfadeToTrack(at: index)
            onClose()
        } else {
            onAutoMix(track.file, album)
            onClose()
        }
    }

    @State private var hoveredTrackIndex: Int?
    @State private var hoveredTrackAlbumID: CellaAlbum.ID?

    @ViewBuilder
    private func albumCover(_ album: CellaAlbum) -> some View {
        if let coverURL = album.coverURL, let image = loadedCovers[coverURL] {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .clipped()
        } else {
            Rectangle()
                .fill(LinearGradient(
                    colors: [theme.dotActive.opacity(0.25), theme.dotInactiveDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 18))
                        .foregroundStyle(theme.dotActive.opacity(0.8))
                )
        }
    }

    private func loadAlbumCovers() {
        for album in albums {
            guard let coverURL = album.coverURL, loadedCovers[coverURL] == nil else { continue }
            if let image = NSImage(contentsOf: coverURL) {
                loadedCovers[coverURL] = image
            }
        }
    }

}

// MARK: - Polished Artist Circle (hover play, now-playing ring, fade-in thumb)

private struct ArtistCircleCell: View {
    let name: String
    let thumb: NSImage?
    let theme: Theme
    let isLoading: Bool
    let isNowPlaying: Bool
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(theme.screenBackground)
                    .frame(width: 88, height: 88)
                    .overlay(
                        Circle().stroke(
                            isNowPlaying ? theme.dotActive : theme.textSecondary.opacity(0.15),
                            lineWidth: isNowPlaying ? 2.5 : 1
                        )
                    )
                    .shadow(
                        color: isNowPlaying ? theme.dotActive.opacity(0.4) : (isHovering ? theme.dotActive.opacity(0.25) : .clear),
                        radius: isNowPlaying ? 10 : 8
                    )
                    .scaleEffect(isHovering && !isLoading ? 1.05 : 1.0)
                    .animation(reduceMotion ? .none : .snappy, value: isHovering)
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 88, height: 88).clipShape(Circle())
                        .transition(.opacity)
                } else {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.dotActive)
                }
                if isLoading {
                    Circle().fill(.black.opacity(0.35)).frame(width: 88, height: 88)
                    ProgressView().controlSize(.small).tint(.white)
                } else if isHovering {
                    Circle().fill(.black.opacity(0.35)).frame(width: 88, height: 88)
                    Image(systemName: "play.fill").font(.system(size: 20)).foregroundStyle(.white)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
                if isNowPlaying && !isLoading {
                    HStack(spacing: 3) {
                        Circle().fill(.white).frame(width: 4, height: 4)
                        Text("PLAYING").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(theme.dotActive))
                    .offset(y: 34)
                }
            }
            .contentShape(Circle())
            .onHover { isHovering = $0 }
            Text(name)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(isNowPlaying ? theme.dotActive : theme.textPrimary)
                .lineLimit(1).frame(width: 100).truncationMode(.tail)
        }
        .frame(width: 100)
        .contentShape(Rectangle())
    }
}

// MARK: - Cluster Mode Switch (Cella capsule, not original segmented)

private struct ClusterModeSwitch: View {
    @Binding var mode: ClusterMode
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var anim

    private let spring: Animation = .spring(response: 0.35, dampingFraction: 0.8)

    var body: some View {
        HStack(spacing: 0) {
            modeButton(.playlists, icon: "books.vertical.fill")
            modeButton(.artists, icon: "person.2.fill")
        }
        .padding(4)
        .background(theme.tabBarBackground)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(theme.textSecondary.opacity(0.15), lineWidth: 1))
    }

    private func modeButton(_ m: ClusterMode, icon: String) -> some View {
        let active = mode == m
        return Button {
            withAnimation(reduceMotion ? .none : spring) { mode = m }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(m.rawValue)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(active ? theme.tabSelectedText : theme.tabUnselectedText)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                ZStack {
                    if active {
                        Capsule()
                            .fill(theme.tabSelectedBackground)
                            .matchedGeometryEffect(id: "clusterMode", in: anim)
                    }
                }
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show \(m.rawValue.lowercased())")
    }
}

// MARK: - Artist Snapshot (cma video frame; AI hook later)

/// Current source: first cma video frame for artist.
/// Later: replace with AI-analyzed portrait / best frame.
enum ArtistSnapshot {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    static func snapshot(videoURL: URL) -> NSImage? {
        let key = videoURL.path
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        // Resolve .cma → temp .mp4 for AVFoundation
        let playURL: URL
        if videoURL.pathExtension.lowercased() == "cma" {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("cella_\(videoURL.deletingPathExtension().lastPathComponent)_\(abs(videoURL.path.hashValue)).mp4")
            if !FileManager.default.fileExists(atPath: tmp.path) {
                try? FileManager.default.copyItem(at: videoURL, to: tmp)
            }
            playURL = tmp
        } else {
            playURL = videoURL
        }
        let asset = AVURLAsset(url: playURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 256, height: 256)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        do {
            let cg = try gen.copyCGImage(at: time, actualTime: nil)
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            lock.lock()
            cache[key] = img
            lock.unlock()
            return img
        } catch {
            return nil
        }
    }
}

#Preview {
    ClusterView()
        .frame(width: 1000, height: 700)
}