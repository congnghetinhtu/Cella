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
    @State private var showCueLab = false
    @State private var pendingDropURLs: [URL] = []
    @State private var showPlaylistChooser = false
    @State private var pendingDrop: PendingDrop?
    @State private var dropNotice: String?
    @State private var dropNoticeGen = 0
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
            // Repair stale persisted path (e.g. library moved) before trusting it.
            if !libraryPath.isEmpty, !FileManager.default.fileExists(atPath: libraryPath) {
                libraryPath = ""
            }
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
        .onChange(of: libraryPath) { _, path in
            // External library switch (Finder double-click on .cluster package).
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
            if library?.url.path != path { rescan() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clusterLibraryDidRescan)) { note in
            // Pack detail moved files around — refresh counts (no re-notify, no loop).
            if let url = note.object as? URL, url == library?.url {
                rescan(notify: false)
            }
        }
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
                // Drop on gaps/empty area → choose playlist. Drops on cards add directly.
                .onDrop(of: [.fileURL], isTargeted: .constant(false), perform: { providers in
                    loadDroppedFileURLs(providers) { urls in
                        routeDroppedSongs(urls)
                    }
                    return true
                })
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
        .sheet(isPresented: $showCueLab) {
            if let lib = library {
                CueLabView(libraryURL: lib.url, packs: lib.packs) {
                    rescan()
                }
                .environment(\.theme, theme)
            }
        }
        .modifier(ClusterDropOverlays(
            pendingDropURLs: $pendingDropURLs,
            showPlaylistChooser: $showPlaylistChooser,
            dropNotice: $dropNotice,
            pendingDrop: $pendingDrop,
            packs: library?.packs ?? [],
            theme: theme,
            onChoosePack: { pack in
                let urls = pendingDropURLs
                pendingDropURLs = []
                stageDrop(urls, into: pack)
            },
            onCommitDrop: { pack, rows in commitDrop(pack: pack, rows: rows) }
        ))
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
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.screenBackground.opacity(0.55)))
            .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.14), .white.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.14), lineWidth: 1))
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
                showCueLab = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle.fill").font(.system(size: 12, weight: .semibold))
                    Text("CueLab").font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(theme.tabSelectedText)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.tabSelectedBackground))
                .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial.opacity(0.4)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.25), .white.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .allowsHitTesting(false)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("Create a .cue sheet")

            HStack(spacing: 8) {
                Button {
                    newPackName = ""
                    showNewPack = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 11, weight: .semibold))
                        Text("Playlist").font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(theme.tabSelectedText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(theme.tabSelectedBackground))
                    .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial.opacity(0.4)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.25), .white.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .allowsHitTesting(false)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Create a new playlist")
                Button {
                    pickSongs()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "music.note.list").font(.system(size: 11, weight: .semibold))
                        Text("Songs").font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(theme.tabSelectedText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(theme.tabSelectedBackground))
                    .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial.opacity(0.4)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.25), .white.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .allowsHitTesting(false)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Add songs to a playlist")
            }

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
                    .fill(theme.screenBackground.opacity(0.55))
                    .frame(width: 150, height: 150)
                    .background(
                        RoundedRectangle(cornerRadius: 22)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.22), .white.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .allowsHitTesting(false)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.18), lineWidth: 1))
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
        .background(theme.screenBackground.opacity(0.6))
        .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.18), .white.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.18), lineWidth: 1))
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
            onTap: { onOpenDetail?(pack) },
            onDropFiles: { urls in stageDrop(urls, into: pack) }
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
        // .cluster is a package — present as a selectable file, not a traversable folder.
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Library"
        panel.message = "Select a Cella Music Library (.cluster)"
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

    private func rescan(notify: Bool = true) {
        guard !libraryPath.isEmpty else { return }
        let url = URL(fileURLWithPath: libraryPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        withAnimation(.snappy) {
            var lib = ClusterLibrary.scan(url)
            lib.refreshCacheCounts()
            library = lib
        }
        reloadLibraryArtists()
        if notify {
            // Open pack detail caches albums by pack URL — tell it to reload.
            NotificationCenter.default.post(name: .clusterLibraryDidRescan, object: url)
        }
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

    // MARK: - Add Song picker (New → Add Song…)

    /// File picker for audio files/folders, routed like a background drop.
    private func pickSongs() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Songs"
        panel.message = "Choose audio files or album folders to add"
        panel.allowedContentTypes = Self.dropAudioExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        routeDroppedSongs(panel.urls)
    }

    /// Shared routing for picked/dropped songs: single pack → sheet,
    /// no packs → nag, many packs → playlist chooser.
    private func routeDroppedSongs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if (library?.packs.count ?? 0) <= 1, let only = library?.packs.first {
            stageDrop(urls, into: only)
        } else if library?.packs.isEmpty == true {
            flashDropNotice("Create a playlist first")
        } else {
            pendingDropURLs = urls
            showPlaylistChooser = true
        }
    }

    // MARK: - Drop songs into playlist

    private static let dropAudioExtensions = Set(["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"])

    /// Stages dropped audio files (or album folders, shallow) for the info sheet.
    private func stageDrop(_ urls: [URL], into pack: CellaPack) {
        let fm = FileManager.default
        var sources: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let kids = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                sources.append(contentsOf: kids.filter { Self.dropAudioExtensions.contains($0.pathExtension.lowercased()) })
            } else if Self.dropAudioExtensions.contains(url.pathExtension.lowercased()) {
                sources.append(url)
            }
        }
        guard !sources.isEmpty else {
            flashDropNotice("No audio files in drop")
            return
        }
        pendingDropURLs = []
        showPlaylistChooser = false
        pendingDrop = PendingDrop(pack: pack, files: sources)
    }

    /// Commits the info sheet: routes each song to its album folder
    /// (existing match or newly created — structured style), copies audio,
    /// imports/writes .lrc, then rescans.
    private func commitDrop(pack: CellaPack, rows: [SongRow]) {
        var added = 0
        for row in rows {
            let destDir = albumDir(for: row.album, in: pack)
            guard let dest = copyAudioIntoPack(row.source, into: destDir) else { continue }
            if let lrcSrc = row.lrcSource {
                importChosenLrc(lrcSrc, for: dest)
            } else {
                writeLrc(for: dest, row: row)
            }
            added += 1
        }
        pendingDrop = nil
        rescan()
        flashDropNotice(added > 0 ? "Added \(added) song\(added == 1 ? "" : "s") to \(pack.name)" : "Nothing added to \(pack.name)")
    }

    /// Resolves the album folder for a staged song: matches an existing album
    /// (folder name or .cue title, case-insensitive), creates one when the
    /// album is new, or falls back to the pack root when blank.
    private func albumDir(for album: String, in pack: CellaPack) -> URL {
        let fm = FileManager.default
        let key = album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return pack.url }
        let skipDirs = Set(["lrc", "cma"])
        let subfolders = ((try? fm.contentsOfDirectory(at: pack.url, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath && !skipDirs.contains($0.lastPathComponent.lowercased()) }
        for folder in subfolders {
            if folder.lastPathComponent.lowercased() == key { return folder }
            let contents = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            if let cueURL = contents.first(where: { $0.pathExtension.lowercased() == "cue" }),
               let sheet = CueParser.load(from: cueURL),
               sheet.title.lowercased() == key {
                return folder
            }
        }
        // New album — create the folder so the pack gains structure.
        let safe = album.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let dir = pack.url.appendingPathComponent(safe)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies a user-chosen .lrc next to the added song (`<dir>/lrc/<song>.lrc`).
    /// Explicit choice wins over any existing file.
    private func importChosenLrc(_ src: URL, for audioURL: URL) {
        let fm = FileManager.default
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let lrcDir = audioURL.deletingLastPathComponent().appendingPathComponent("lrc")
        try? fm.createDirectory(at: lrcDir, withIntermediateDirectories: true)
        let base = audioURL.deletingPathExtension().lastPathComponent
        let dest = lrcDir.appendingPathComponent(base + ".lrc")
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: src, to: dest)
        } catch {
            print("[Cluster] lrc import failed: \(src.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    /// Collision-safe copy of one audio file into a destination dir. Returns the dest URL.
    private func copyAudioIntoPack(_ src: URL, into destDir: URL) -> URL? {
        let fm = FileManager.default
        var dest = destDir.appendingPathComponent(src.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            let base = src.deletingPathExtension().lastPathComponent
            let ext = src.pathExtension
            var n = 2
            while fm.fileExists(atPath: dest.path), n <= 100 {
                dest = destDir.appendingPathComponent("\(base) \(n).\(ext)")
                n += 1
            }
            guard !fm.fileExists(atPath: dest.path) else { return nil }
        }
        do {
            try fm.copyItem(at: src, to: dest)
            return dest
        } catch {
            print("[Cluster] drop copy failed: \(src.lastPathComponent) — \(error.localizedDescription)")
            return nil
        }
    }

    /// Writes `[ti/ar/al/length]` tags next to the added song (`<dir>/lrc/`).
    private func writeLrc(for audioURL: URL, row: SongRow) {
        var meta = LrcMetadata()
        meta.title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        meta.artist = row.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        meta.album = row.album.trimmingCharacters(in: .whitespacesAndNewlines)
        meta.length = row.length.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !meta.isEmpty else { return }
        let fm = FileManager.default
        let lrcDir = audioURL.deletingLastPathComponent().appendingPathComponent("lrc")
        try? fm.createDirectory(at: lrcDir, withIntermediateDirectories: true)
        let base = audioURL.deletingPathExtension().lastPathComponent
        let content = meta.toLrcString() + "\n"
        try? content.write(to: lrcDir.appendingPathComponent(base + ".lrc"), atomically: true, encoding: .utf8)
    }

    private func flashDropNotice(_ text: String) {
        dropNoticeGen += 1
        let gen = dropNoticeGen
        withAnimation(.snappy) { dropNotice = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if gen == dropNoticeGen {
                withAnimation(.smooth(duration: 0.3)) { dropNotice = nil }
            }
        }
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
    var onDropFiles: ([URL]) -> Void = { _ in }

    @Environment(\.theme) private var theme
    @State private var isHovering = false
    @State private var isPressed = false
    @State private var hasAppeared = false
    @State private var loadedImages: [URL: NSImage] = [:]
    @State private var topArtists: [PackArtist] = []
    @State private var dropTargeted = false

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
        .aeroCard(radius: cardRadius, wash: 0.08)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(
                    isHovering
                        ? theme.dotActive.opacity(0.45)
                        : .white.opacity(0.14),
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
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(theme.dotActive, lineWidth: dropTargeted ? 2.5 : 0)
                .shadow(color: theme.dotActive.opacity(dropTargeted ? 0.6 : 0), radius: 10)
        )
        .onTapGesture {
            onTap()
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadDroppedFileURLs(providers) { urls in
                if !urls.isEmpty { onDropFiles(urls) }
            }
            return true
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
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.ultraThinMaterial.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.25), .white.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.16), lineWidth: 1)
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
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.25), .white.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovering ? theme.textSecondary.opacity(0.25) : .white.opacity(0.16), lineWidth: 1)
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
                    .fill(theme.dotActive.opacity(0.9))
            )
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.32), .white.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.white.opacity(0.32), lineWidth: 1)
            )
            .shadow(color: theme.dotActive.opacity(0.35), radius: 8)
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
    @State private var siblingPacks: [(name: String, url: URL)] = []
    @State private var moveRequest: MoveRequest?
    @State private var deleteRequest: MoveRequest?
    @State private var albumEditRequest: AlbumEditRequest?
    @State private var songEditRequest: SongEditRequest?
    @State private var moveNotice: String?
    @State private var moveNoticeGen = 0

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
            } else if pack.type == .openCella {
                // OpenCella: flat song list, no album cards.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(flatTracks.enumerated()), id: \.element.track.id) { n, entry in
                            trackRow(index: n, track: entry.track, album: entry.album, subtitle: flatShowsAlbum ? entry.album.folderName : nil)
                            if n < flatTracks.count - 1 {
                                Divider()
                                    .overlay(theme.textSecondary.opacity(0.1))
                                    .padding(.leading, 64)
                            }
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 26)
                }
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
        .background(theme.appBackground.opacity(0.72).ignoresSafeArea())
        .background(.ultraThinMaterial)
        .aeroGloss(radius: CardStyle.radius, opacity: 0.10)
        .clipShape(RoundedRectangle(cornerRadius: CardStyle.radius))
        .contentShape(RoundedRectangle(cornerRadius: CardStyle.radius))
        .overlay(
            RoundedRectangle(cornerRadius: CardStyle.radius)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .task(id: pack.url) {
            guard !pack.url.path.isEmpty else { return }
            reloadAlbums()
            refreshSiblings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clusterLibraryDidRescan)) { note in
            // Same pack rescanned (e.g. CueLab added an album) → reload live.
            if let url = note.object as? URL, url == pack.url.deletingLastPathComponent() || url == pack.url {
                reloadAlbums(keepExpanded: true)
                refreshSiblings()
            } else if note.object == nil {
                reloadAlbums(keepExpanded: true)
                refreshSiblings()
            }
        }
        .confirmationDialog(
            "Move “\(moveRequest?.track.title ?? moveRequest?.track.file ?? "")” to playlist",
            isPresented: Binding(get: { moveRequest != nil }, set: { if !$0 { moveRequest = nil } }),
            titleVisibility: .visible
        ) {
            ForEach(siblingPacks, id: \.url) { sib in
                Button(sib.name) {
                    if let req = moveRequest {
                        moveRequest = nil
                        moveTrackToPlaylist(req.track, in: req.album, destPackURL: sib.url, destName: sib.name)
                    }
                }
            }
            Button("Cancel", role: .cancel) { moveRequest = nil }
        }
        .confirmationDialog(
            "Remove “\(deleteRequest?.track.title ?? deleteRequest?.track.file ?? "")” from \(pack.name)?",
            isPresented: Binding(get: { deleteRequest != nil }, set: { if !$0 { deleteRequest = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move Audio + Lyrics to Trash", role: .destructive) {
                if let req = deleteRequest {
                    deleteRequest = nil
                    deleteTrack(req.track, in: req.album)
                }
            }
            Button("Cancel", role: .cancel) { deleteRequest = nil }
        }
        .sheet(item: $albumEditRequest) { request in
            EditAlbumSheet(
                pack: pack,
                album: request.album,
                hasCue: request.hasCue,
                isPackRoot: request.isPackRoot,
                theme: theme,
                onCancel: { albumEditRequest = nil },
                // Returns nil on success (caller dismisses), or a message to keep the sheet open.
                onSave: { draft in saveAlbumEdit(request, draft: draft) }
            )
        }
        .sheet(item: $songEditRequest) { request in
            EditSongSheet(
                track: request.track,
                album: request.album,
                hasCue: albumDir(for: request.album).flatMap(cueURLIn) != nil,
                theme: theme,
                onCancel: { songEditRequest = nil },
                onSave: { draft in saveSongEdit(request, draft: draft) }
            )
        }
        .overlay(alignment: .bottom) {
            if let notice = moveNotice {
                Text(notice)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(theme.tabBarBackground.opacity(0.9)))
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: moveNotice)
    }

    private func reloadAlbums(keepExpanded: Bool = false) {
        guard !pack.url.path.isEmpty else { return }
        albums = []
        if !keepExpanded { expandedAlbum = nil }
        loadedCovers = [:]
        albums = ClusterLibrary.albums(in: pack.url)
        loadAlbumCovers()
    }

    /// All tracks flattened for OpenCella packs (playlist order, no album split).
    private var flatTracks: [(album: CellaAlbum, track: CellaTrack)] {
        albums.flatMap { album in album.tracks.map { (album: album, track: $0) } }
    }

    /// Show the album folder as subtitle only when the pack actually spans albums.
    private var flatShowsAlbum: Bool {
        albums.filter { !$0.tracks.isEmpty }.count > 1
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
                    Text("\(albums.count) albums · \(albums.reduce(0) { $0 + $1.trackCount }) tracks")
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
        // OpenCella flat playlists: no dropdown, songs always visible A-Z.
        let flat = pack.type == .openCella
        let isExpanded = flat || expandedAlbum == album.id
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

                    if !flat {
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
                }
                .overlay(
                    RightClickCatcher(
                        onLeftClick: {
                            guard !flat else { return }
                            withAnimation(.snappy) {
                                expandedAlbum = isExpanded ? nil : album.id
                            }
                        },
                        onRightClick: { windowPoint, window in
                            presentAlbumMenu(at: windowPoint, window: window, album: album)
                        },
                        onHoverChange: { hovering in
                            hoveredAlbumID = hovering ? album.id : nil
                        }
                    )
                )

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
                            .fill(theme.dotActive.opacity(0.9))
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.ultraThinMaterial.opacity(0.35))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.32), .white.opacity(0.03)],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .allowsHitTesting(false)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.32), lineWidth: 1)
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
        .background(theme.screenBackground.opacity(0.55))
        .background(RoundedRectangle(cornerRadius: cardRadius).fill(.ultraThinMaterial))
        .aeroGloss(radius: cardRadius, opacity: 0.12)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(isExpanded ? theme.tabSelectedBackground : .white.opacity(0.13), lineWidth: isExpanded ? 1.5 : 1)
        )
        .shadow(
            color: hoveredAlbumID == album.id ? theme.dotActive.opacity(0.2) : .clear,
            radius: 10
        )
        .scaleEffect(hoveredAlbumID == album.id ? 1.01 : 1.0)
        .animation(.spring(response: 0.35, dampingFraction: 0.65), value: isExpanded)
        .animation(.snappy, value: hoveredAlbumID == album.id)
        .onHover { _ in }
    }

    private func presentAlbumMenu(at windowPoint: NSPoint, window: NSWindow?, album: CellaAlbum) {
        guard let window else { return }
        let screenPoint = window.convertToScreen(
            NSRect(origin: windowPoint, size: .zero)
        ).origin
        CellaContextMenu.show(at: screenPoint, theme: theme, actions: [
            CellaMenuAction(title: "Play Album", systemImage: "play.fill") {
                onPlay(album.tracks.first?.file)
            },
            CellaMenuAction(title: "AutoMix Album", systemImage: "arrow.triangle.merge") {
                onAutoMix(album.tracks.first?.file, album)
            },
            CellaMenuAction(title: "Edit Album…", systemImage: "pencil") {
                albumEditRequest = AlbumEditRequest(
                    album: album,
                    hasCue: albumDir(for: album).flatMap(cueURLIn) != nil,
                    isPackRoot: album.folderName.isEmpty
                )
            }
        ])
    }

    private struct AlbumEditRequest: Identifiable {
        let id = UUID()
        let album: CellaAlbum
        let hasCue: Bool
        let isPackRoot: Bool
    }

    private func trackRow(index: Int, track: CellaTrack, album: CellaAlbum, subtitle: String? = nil) -> some View {
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
                let sub: String = {
                    switch (track.artist, subtitle) {
                    case let (a?, s?) where !s.isEmpty: return "\(a) · \(s)"
                    case let (a?, _): return a
                    case let (nil, s?) where !s.isEmpty: return s
                    default: return ""
                    }
                }()
                if !sub.isEmpty {
                    Text(sub)
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

        var actions = [
            CellaMenuAction(title: "AutoMix to", systemImage: "arrow.triangle.merge") {
                autoMixTo(track, in: album)
            },
            CellaMenuAction(title: "Add LRC…", systemImage: "doc.badge.plus") {
                if let audioURL = audioURL(for: track, in: album) {
                    onOpenLRC?(audioURL)
                }
            },
            CellaMenuAction(title: "Edit Song…", systemImage: "pencil") {
                songEditRequest = SongEditRequest(track: track, album: album)
            }
        ]
        if !siblingPacks.isEmpty {
            actions.append(CellaMenuAction(title: "Move to Playlist…", systemImage: "folder.arrow.right") {
                moveRequest = MoveRequest(track: track, album: album)
            })
        }
        actions.append(CellaMenuAction(title: "Remove from Playlist…", systemImage: "trash", isDestructive: true) {
            deleteRequest = MoveRequest(track: track, album: album)
        })
        CellaContextMenu.show(at: screenPoint, theme: theme, actions: actions)
    }

    private struct MoveRequest: Identifiable {
        let id = UUID()
        let track: CellaTrack
        let album: CellaAlbum
    }

    private struct SongEditRequest: Identifiable {
        let id = UUID()
        let track: CellaTrack
        let album: CellaAlbum
    }

    /// Other .cella packs in the same library, sorted by name.
    private func refreshSiblings() {
        guard !pack.url.path.isEmpty else { siblingPacks = []; return }
        let parent = pack.url.deletingLastPathComponent()
        let dirs = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        siblingPacks = dirs
            .filter { $0.hasDirectoryPath && $0.pathExtension.lowercased() == "cella" && $0 != pack.url }
            .map { (name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Moves one track (audio + sibling .lrc + .cellax cache) into another
    /// playlist, merging into the same album folder when present.
    private func moveTrackToPlaylist(_ track: CellaTrack, in album: CellaAlbum, destPackURL: URL, destName: String) {
        let fm = FileManager.default
        guard let srcAudio = audioURL(for: track, in: album) else {
            flashMoveNotice("File not found")
            return
        }
        if viewModel?.mixQueue?.currentTrack?.url == srcAudio {
            flashMoveNotice("Playing now — move after it ends")
            return
        }
        // Destination album dir: merge into same-name folder, else create it
        // when the source lived in one, else the pack root.
        let srcAlbumName = album.folderName
        let destAlbumDir: URL?
        if srcAlbumName.isEmpty {
            destAlbumDir = nil
        } else if let match = ((try? fm.contentsOfDirectory(at: destPackURL, includingPropertiesForKeys: nil)) ?? [])
            .first(where: { $0.hasDirectoryPath && $0.lastPathComponent.lowercased() == srcAlbumName.lowercased() }) {
            destAlbumDir = match
        } else {
            let created = destPackURL.appendingPathComponent(srcAlbumName)
            try? fm.createDirectory(at: created, withIntermediateDirectories: true)
            destAlbumDir = created
        }
        let destDir = destAlbumDir ?? destPackURL
        guard let destAudio = uniqueDest(in: destDir, for: track.file) else {
            flashMoveNotice("Name clash in \(destName)")
            return
        }
        do {
            try fm.moveItem(at: srcAudio, to: destAudio)
        } catch {
            flashMoveNotice("Move failed: \(error.localizedDescription)")
            return
        }
        // Sibling .lrc/.elrc: mirror each slot that exists at the source.
        let base = srcAudio.deletingPathExtension().lastPathComponent
        let srcDir = srcAudio.deletingLastPathComponent()
        let srcSlots: [(from: URL, toDir: URL)] = [
            (srcDir.appendingPathComponent("lrc").appendingPathComponent(base + ".lrc"), (destAlbumDir ?? destPackURL).appendingPathComponent("lrc")),
            (srcDir.appendingPathComponent("lrc").appendingPathComponent(base + ".elrc"), (destAlbumDir ?? destPackURL).appendingPathComponent("lrc")),
            (pack.url.appendingPathComponent("lrc").appendingPathComponent(base + ".lrc"), destPackURL.appendingPathComponent("lrc")),
            (pack.url.appendingPathComponent("lrc").appendingPathComponent(base + ".elrc"), destPackURL.appendingPathComponent("lrc")),
            (srcDir.appendingPathComponent(base + ".lrc"), destDir),
            (srcDir.appendingPathComponent(base + ".elrc"), destDir)
        ]
        for slot in srcSlots where fm.fileExists(atPath: slot.from.path) {
            try? fm.createDirectory(at: slot.toDir, withIntermediateDirectories: true)
            let dest = slot.toDir.appendingPathComponent(destAudio.deletingPathExtension().lastPathComponent + "." + slot.from.pathExtension)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.moveItem(at: slot.from, to: dest)
            }
        }
        // .cellax analysis cache follows the audio.
        let srcCache = AnalysisCache.cacheURL(for: srcAudio)
        if fm.fileExists(atPath: srcCache.path) {
            let destCache = AnalysisCache.cacheURL(for: destAudio)
            try? fm.createDirectory(at: destCache.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: destCache.path) {
                try? fm.moveItem(at: srcCache, to: destCache)
            }
        }
        reloadAlbums(keepExpanded: true)
        refreshSiblings()
        NotificationCenter.default.post(name: .clusterLibraryDidRescan, object: pack.url.deletingLastPathComponent())
        flashMoveNotice("Moved to \(destName)")
    }

    /// Trashes a track's audio + sibling .lrc/.elrc + .cellax cache, then refreshes.
    private func deleteTrack(_ track: CellaTrack, in album: CellaAlbum) {
        let fm = FileManager.default
        guard let srcAudio = audioURL(for: track, in: album) else {
            flashMoveNotice("File not found")
            return
        }
        if viewModel?.mixQueue?.currentTrack?.url == srcAudio {
            flashMoveNotice("Playing now — delete after it ends")
            return
        }
        let base = srcAudio.deletingPathExtension().lastPathComponent
        let srcDir = srcAudio.deletingLastPathComponent()
        var candidates = [
            srcAudio,
            srcDir.appendingPathComponent("lrc").appendingPathComponent(base + ".lrc"),
            srcDir.appendingPathComponent("lrc").appendingPathComponent(base + ".elrc"),
            pack.url.appendingPathComponent("lrc").appendingPathComponent(base + ".lrc"),
            pack.url.appendingPathComponent("lrc").appendingPathComponent(base + ".elrc"),
            srcDir.appendingPathComponent(base + ".lrc"),
            srcDir.appendingPathComponent(base + ".elrc"),
            AnalysisCache.cacheURL(for: srcAudio)
        ]
        // De-dupe (root-level tracks repeat the same-dir slot).
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0.path).inserted }
        var trashed = 0
        for url in candidates where fm.fileExists(atPath: url.path) {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                if url == srcAudio { trashed += 1 }
            } catch {
                print("[Cluster] trash failed: \(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        guard trashed > 0 else {
            flashMoveNotice("Nothing removed")
            return
        }
        reloadAlbums(keepExpanded: true)
        refreshSiblings()
        NotificationCenter.default.post(name: .clusterLibraryDidRescan, object: pack.url.deletingLastPathComponent())
        flashMoveNotice("Removed \(track.title ?? track.file)")
    }

    /// Collision-free destination for a filename inside a dir. Nil when exhausted.
    private func uniqueDest(in dir: URL, for fileName: String) -> URL? {
        let fm = FileManager.default
        var dest = dir.appendingPathComponent(fileName)
        if fm.fileExists(atPath: dest.path) {
            let url = URL(fileURLWithPath: fileName)
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var n = 2
            while fm.fileExists(atPath: dest.path), n <= 100 {
                dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            guard !fm.fileExists(atPath: dest.path) else { return nil }
        }
        return dest
    }

    private func flashMoveNotice(_ text: String) {
        moveNoticeGen += 1
        let gen = moveNoticeGen
        withAnimation(.snappy) { moveNotice = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if gen == moveNoticeGen {
                withAnimation(.smooth(duration: 0.3)) { moveNotice = nil }
            }
        }
    }

    private func audioURL(for track: CellaTrack, in album: CellaAlbum) -> URL? {
        let audioURL = pack.url.appendingPathComponent(album.folderName)
            .appendingPathComponent(track.file)
        return FileManager.default.fileExists(atPath: audioURL.path) ? audioURL : nil
    }

    // MARK: - Edit album (title / artist / cover)

    /// Pack root for album-dir style URLs (empty folderName) — nil when pack.url is empty.
    private func albumDir(for album: CellaAlbum) -> URL? {
        guard !pack.url.path.isEmpty else { return nil }
        return album.folderName.isEmpty ? pack.url : pack.url.appendingPathComponent(album.folderName)
    }

    private func cueURLIn(_ dir: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        return contents.first { $0.pathExtension.lowercased() == "cue" }
    }

    /// Cover basenames ClusterLibrary.findCover recognizes. A new image must land
    /// on one of these or the scanner won't see it.
    private static let coverNames = ["cover", "folder", "artwork", "front", "album"]
    private static let coverExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp"]

    /// Prefers the extension of the cover already in place so replacing art
    /// doesn't orphan the old file.
    private func coverDest(in dir: URL, replacing existing: URL?) -> URL {
        let ext: String
        if let existing,
           Self.coverExtensions.contains(existing.pathExtension.lowercased()) {
            ext = existing.pathExtension.lowercased()
        } else {
            ext = "jpg"
        }
        return dir.appendingPathComponent("cover.\(ext)")
    }

    private func applyCover(_ chosen: URL?, to album: CellaAlbum, removing: Bool) -> String? {
        let fm = FileManager.default
        guard let dir = albumDir(for: album) else { return "Pack unavailable" }
        let existing = album.coverURL

        if removing {
            if let existing, fm.fileExists(atPath: existing.path) {
                do { try fm.trashItem(at: existing, resultingItemURL: nil) }
                catch { return "Could not remove cover: \(error.localizedDescription)" }
            }
            return nil
        }

        guard let chosen else { return nil }
        let dest = coverDest(in: dir, replacing: existing)
        if fm.fileExists(atPath: dest.path) {
            do { try fm.trashItem(at: dest, resultingItemURL: nil) }
            catch { return "Could not replace cover: \(error.localizedDescription)" }
        }
        do {
            try fm.copyItem(at: chosen, to: dest)
        } catch {
            return "Could not copy cover: \(error.localizedDescription)"
        }
        return nil
    }

    /// Persists the sheet. Returns nil on success (dismisses), or a message on failure.
    private func saveAlbumEdit(_ request: AlbumEditRequest, draft: AlbumEditDraft) -> String? {
        let fm = FileManager.default
        let album = request.album
        guard let dir = albumDir(for: album) else { return "Pack unavailable" }

        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = draft.artist.trimmingCharacters(in: .whitespacesAndNewlines)

        if title.isEmpty { return "Album title cannot be empty" }

        if request.hasCue {
            // Structured album: rewrite album-level TITLE/PERFORMER, tracks untouched.
            guard let cueURL = cueURLIn(dir),
                  let content = try? String(contentsOf: cueURL, encoding: .utf8) else {
                return "Could not read cue file"
            }
            let updated = CueParser.updatingMetadata(in: content, title: title, performer: artist)
            do {
                try updated.write(to: cueURL, atomically: true, encoding: .utf8)
            } catch {
                return "Could not write cue file: \(error.localizedDescription)"
            }
        } else if !request.isPackRoot {
            // No cue: display name IS the folder name, so rename it.
            let dest = pack.url.appendingPathComponent(title)
            if dest.standardizedFileURL != dir.standardizedFileURL {
                if fm.fileExists(atPath: dest.path) { return "An album named “\(title)” already exists" }
                do {
                    try fm.moveItem(at: dir, to: dest)
                } catch {
                    return "Could not rename album folder: \(error.localizedDescription)"
                }
            }
        }

        if let coverError = applyCover(draft.cover, to: album, removing: draft.removeCover) {
            return coverError
        }

        albumEditRequest = nil
        reloadAlbums(keepExpanded: true)
        NotificationCenter.default.post(
            name: .clusterLibraryDidRescan,
            object: pack.url.deletingLastPathComponent()
        )
        flashMoveNotice("Album updated")
        return nil
    }

    // MARK: - Edit song (title / artist / album / filename)

    /// Where this track's lyrics already live, or nil. Mirrors the candidate
    /// order the player and LRC editor both search.
    private func existingLrcURL(for audioURL: URL) -> URL? {
        let fm = FileManager.default
        let albumDir = audioURL.deletingLastPathComponent()
        let base = audioURL.deletingPathExtension().lastPathComponent
        let candidates = [
            albumDir.appendingPathComponent("lrc").appendingPathComponent(base + ".lrc"),
            albumDir.appendingPathComponent("lrc").appendingPathComponent(base + ".elrc"),
            pack.url.appendingPathComponent("lrc").appendingPathComponent(base + ".lrc"),
            pack.url.appendingPathComponent("lrc").appendingPathComponent(base + ".elrc"),
            albumDir.appendingPathComponent(base + ".lrc"),
            albumDir.appendingPathComponent(base + ".elrc")
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    /// Filenames are single path components — flatten anything that would create
    /// a directory or an illegal name.
    private func sanitizedFileName(_ input: String) -> String {
        input
            .components(separatedBy: CharacterSet.controlCharacters)
            .joined()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns nil on success (dismisses), or a message on failure.
    private func saveSongEdit(_ request: SongEditRequest, draft: SongEditDraft) -> String? {
        let fm = FileManager.default
        let track = request.track
        let album = request.album
        guard let srcAudio = audioURL(for: track, in: album) else { return "File not found" }

        let ext = srcAudio.pathExtension
        let srcDir = srcAudio.deletingLastPathComponent()
        let oldBase = srcAudio.deletingPathExtension().lastPathComponent

        // The real audio extension always wins — renaming must not change format.
        var typed = sanitizedFileName(draft.fileName)
        guard !typed.isEmpty else { return "Filename cannot be empty" }
        if (typed as NSString).pathExtension.lowercased() != ext.lowercased() {
            typed = (typed as NSString).deletingPathExtension + "." + ext
        }
        let newBase = (typed as NSString).deletingPathExtension
        guard !newBase.isEmpty, newBase != ".", newBase != ".." else { return "Invalid filename" }

        let renamed = newBase != oldBase
        let destAudio = srcDir.appendingPathComponent(typed)
        let isPlaying = viewModel?.mixQueue?.currentTrack?.url == srcAudio
        if renamed, fm.fileExists(atPath: destAudio.path) {
            return "A file named “\(typed)” already exists"
        }
        if renamed, isPlaying {
            return "Playing now — rename it after this song ends"
        }

        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = draft.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumName = draft.album.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Inside a structured album the cue is authoritative for title/artist.
        if let dir = albumDir(for: album),
           let cueURL = cueURLIn(dir),
           let content = try? String(contentsOf: cueURL, encoding: .utf8) {
            let updated = CueParser.updatingTrack(
                in: content,
                fileName: track.file,
                newFileName: renamed ? typed : nil,
                title: title,
                performer: artist
            )
            do { try updated.write(to: cueURL, atomically: true, encoding: .utf8) }
            catch { return "Could not write cue: \(error.localizedDescription)" }
        }

        // 2. Lyrics carry [ti:]/[ar:]/[al:] for the rest. Timestamped lines untouched.
        if let lrcURL = existingLrcURL(for: srcAudio) {
            let content = (try? String(contentsOf: lrcURL, encoding: .utf8)) ?? ""
            let updated = LrcParser.updatingMetadata(
                in: content, title: title, artist: artist, album: albumName
            )
            do { try updated.write(to: lrcURL, atomically: true, encoding: .utf8) }
            catch { return "Could not write lyrics: \(error.localizedDescription)" }
        } else if !title.isEmpty || !artist.isEmpty || !albumName.isEmpty {
            // No lyrics file yet — create a header-only one to hold the metadata.
            let lrcDir = srcDir.appendingPathComponent("lrc")
            var meta = LrcMetadata()
            meta.title = title
            meta.artist = artist
            meta.album = albumName
            do {
                if !fm.fileExists(atPath: lrcDir.path) {
                    try fm.createDirectory(at: lrcDir, withIntermediateDirectories: true)
                }
                try meta.toLrcString().write(
                    to: lrcDir.appendingPathComponent(oldBase + ".lrc"),
                    atomically: true, encoding: .utf8
                )
            } catch {
                return "Could not create lyrics file: \(error.localizedDescription)"
            }
        }

        // 3. Rename the audio file; lyrics and analysis cache follow the base name.
        if renamed {
            do { try fm.moveItem(at: srcAudio, to: destAudio) }
            catch { return "Could not rename file: \(error.localizedDescription)" }

            if let oldLrc = existingLrcURL(for: srcAudio) {
                let newLrc = oldLrc.deletingLastPathComponent()
                    .appendingPathComponent(newBase + oldLrc.pathExtension)
                if !fm.fileExists(atPath: newLrc.path) {
                    try? fm.moveItem(at: oldLrc, to: newLrc)
                }
            }
            let oldCache = AnalysisCache.cacheURL(for: srcAudio)
            let newCache = AnalysisCache.cacheURL(for: destAudio)
            if fm.fileExists(atPath: oldCache.path), !fm.fileExists(atPath: newCache.path) {
                try? fm.moveItem(at: oldCache, to: newCache)
            }
        }

        songEditRequest = nil
        reloadAlbums(keepExpanded: true)
        NotificationCenter.default.post(
            name: .clusterLibraryDidRescan,
            object: pack.url.deletingLastPathComponent()
        )
        flashMoveNotice(renamed ? "Song updated and renamed" : "Song updated")
        return nil
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
    @State private var hoveredAlbumID: CellaAlbum.ID?

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
        .background(theme.tabBarBackground.opacity(0.55))
        .background(Capsule().fill(.ultraThinMaterial))
        .aeroGloss(radius: 999, opacity: 0.20)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
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
                            .shadow(color: theme.tabSelectedText.opacity(0.45), radius: 8)
                    }
                }
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show \(m.rawValue.lowercased())")
    }
}

extension Notification.Name {
    static let clusterLibraryDidRescan = Notification.Name("clusterLibraryDidRescan")
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

// MARK: - Drop staging types

private struct PendingDrop: Identifiable {
    let id = UUID()
    let pack: CellaPack
    let files: [URL]
}

private struct SongRow: Identifiable {
    let id = UUID()
    let source: URL
    var fileName: String
    var title = ""
    var artist = ""
    var album = ""
    var length = ""
    var lrcSource: URL?
    var loaded = false
}

// MARK: - Drop overlays (chooser + info sheet + notice)

private struct ClusterDropOverlays: ViewModifier {
    @Binding var pendingDropURLs: [URL]
    @Binding var showPlaylistChooser: Bool
    @Binding var dropNotice: String?
    @Binding var pendingDrop: PendingDrop?
    var packs: [CellaPack]
    var theme: Theme
    var onChoosePack: (CellaPack) -> Void
    var onCommitDrop: (CellaPack, [SongRow]) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Add \(pendingDropURLs.count) song\(pendingDropURLs.count == 1 ? "" : "s") to playlist",
                isPresented: $showPlaylistChooser,
                titleVisibility: .visible
            ) {
                ForEach(packs) { pack in
                    Button(pack.name) { onChoosePack(pack) }
                }
                Button("Cancel", role: .cancel) { pendingDropURLs = [] }
            }
            .sheet(item: $pendingDrop) { drop in
                AddSongsSheet(
                    pack: drop.pack,
                    files: drop.files,
                    theme: theme,
                    onCancel: { pendingDrop = nil },
                    onCommit: { rows in onCommitDrop(drop.pack, rows) }
                )
            }
            .overlay(alignment: .bottom) {
                if let notice = dropNotice {
                    Text(notice)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(theme.tabBarBackground.opacity(0.9)))
                        .background(Capsule().fill(.ultraThinMaterial))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                        .shadow(color: theme.dotActive.opacity(0.3), radius: 8)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: dropNotice)
    }
}

// MARK: - Add-songs info sheet (ar / ti / album / length, metadata-autofilled)

private struct AlbumEditDraft {
    var title: String
    var artist: String
    var cover: URL?
    var removeCover: Bool
}

private struct EditAlbumSheet: View {
    let pack: CellaPack
    let album: CellaAlbum
    let hasCue: Bool
    let isPackRoot: Bool
    let theme: Theme
    var onCancel: () -> Void
    /// Returns nil on success, or a message to keep the sheet open.
    var onSave: (AlbumEditDraft) -> String?

    @State private var title: String = ""
    @State private var artist: String = ""
    @State private var cover: URL?
    @State private var removeCover = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            fields
            coverRow
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            footer
        }
        .padding(20)
        .frame(width: 460)
        .background(theme.appBackground.opacity(0.6))
        .background(.ultraThinMaterial)
        .aeroGloss(radius: CardStyle.radius, opacity: 0.12)
        .clipShape(RoundedRectangle(cornerRadius: CardStyle.radius))
        .overlay(RoundedRectangle(cornerRadius: CardStyle.radius).stroke(.white.opacity(0.14), lineWidth: 1))
        .task {
            if title.isEmpty {
                title = album.name
                artist = album.artist ?? ""
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Edit Album")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            Text("\(album.trackCount) track\(album.trackCount == 1 ? "" : "s") · saves to \(pack.name)")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Title", text: $title, enabled: titleEditable, hint: titleEditable ? nil : "Playlist root")
            field("Artist", text: $artist, enabled: hasCue, hint: hasCue ? nil : "Needs a cue file")
            if isPackRoot && !hasCue {
                Text("No cue file here, so the playlist name comes from its folder — rename it from the playlist card.")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary.opacity(0.75))
            } else if !hasCue {
                Text("No cue file, so the title renames the album folder.")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary.opacity(0.75))
            }
        }
    }

    /// A cue can rename the pack root; without one the name is the folder itself.
    private var titleEditable: Bool { hasCue || !isPackRoot }

    private func field(_ label: String, text: Binding<String>, enabled: Bool = true, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                if let hint {
                    Text(hint)
                        .font(.system(size: 9))
                        .foregroundStyle(theme.textSecondary.opacity(0.7))
                }
            }
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .disabled(!enabled)
        }
    }

    private var coverRow: some View {
        HStack(spacing: 12) {
            coverPreview
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            VStack(alignment: .leading, spacing: 5) {
                Text("COVER")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                if removeCover {
                    Text("Will be removed")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.textSecondary)
                } else if let cover {
                    Text(cover.lastPathComponent)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.dotActive)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if album.coverURL != nil {
                    Text("Unchanged")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                } else {
                    Text("None")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary.opacity(0.7))
                }
                HStack(spacing: 8) {
                    Button("Choose…") { pickCover() }
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.dotActive)
                        .buttonStyle(.plain)
                    if album.coverURL != nil || cover != nil {
                        Button(removeCover ? "Undo Remove" : "Remove") {
                            removeCover.toggle()
                            if removeCover { cover = nil }
                        }
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textSecondary)
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.textSecondary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }

    @ViewBuilder
    private var coverPreview: some View {
        if removeCover {
            Rectangle()
                .fill(theme.textSecondary.opacity(0.12))
                .overlay(
                    Image(systemName: "photo.badge.minus")
                        .font(.system(size: 16))
                        .foregroundStyle(theme.textSecondary)
                )
        } else if let image = chosenImage ?? existingImage {
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
                        .font(.system(size: 16))
                        .foregroundStyle(theme.dotActive.opacity(0.8))
                )
        }
    }

    private var existingImage: NSImage? {
        guard let url = album.coverURL else { return nil }
        return NSImage(contentsOf: url)
    }

    private var chosenImage: NSImage? {
        guard let cover else { return nil }
        return NSImage(contentsOf: cover)
    }

    private func pickCover() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose cover"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        cover = url
        removeCover = false
        error = nil
    }

    private var footer: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .buttonStyle(AeroButtonStyle())
            Spacer()
            Button("Save") {
                error = onSave(AlbumEditDraft(
                    title: title,
                    artist: artist,
                    cover: cover,
                    removeCover: removeCover
                ))
            }
            .buttonStyle(AeroButtonStyle(prominent: true))
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private struct SongEditDraft {
    var fileName: String
    var title: String
    var artist: String
    var album: String
}

private struct EditSongSheet: View {
    let track: CellaTrack
    let album: CellaAlbum
    let hasCue: Bool
    let theme: Theme
    var onCancel: () -> Void
    /// Returns nil on success, or a message to keep the sheet open.
    var onSave: (SongEditDraft) -> String?

    @State private var fileName: String = ""
    @State private var title: String = ""
    @State private var artist: String = ""
    @State private var albumName: String = ""
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            fileNameField
            VStack(alignment: .leading, spacing: 10) {
                field("Title", text: $title)
                field("Artist", text: $artist)
                field("Album", text: $albumName)
            }
            hint
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(20)
        .frame(width: 480)
        .background(theme.appBackground.opacity(0.6))
        .background(.ultraThinMaterial)
        .aeroGloss(radius: CardStyle.radius, opacity: 0.12)
        .clipShape(RoundedRectangle(cornerRadius: CardStyle.radius))
        .overlay(RoundedRectangle(cornerRadius: CardStyle.radius).stroke(.white.opacity(0.14), lineWidth: 1))
        .onAppear {
            guard !loaded else { return }
            loaded = true
            fileName = track.file
            title = track.title ?? ""
            artist = track.artist ?? ""
            albumName = album.name
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Edit Song")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            Text("\(album.name) · \(album.trackCount) track\(album.trackCount == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private var fileNameField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("FILENAME")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
            TextField("", text: $fileName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hasCue
                 ? "Title and artist are saved to the album cue."
                 : "Title and artist are saved to the lyrics file header.")
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary.opacity(0.75))
            Text("Renaming moves the file on disk; lyrics and analysis cache follow it.")
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary.opacity(0.75))
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .buttonStyle(AeroButtonStyle())
            Spacer()
            Button("Save") {
                error = onSave(SongEditDraft(
                    fileName: fileName,
                    title: title,
                    artist: artist,
                    album: albumName
                ))
            }
            .buttonStyle(AeroButtonStyle(prominent: true))
            .disabled(sanitizedFileName.isEmpty)
        }
    }

    private var sanitizedFileName: String {
        fileName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AddSongsSheet: View {
    let pack: CellaPack
    let files: [URL]
    let theme: Theme
    var onCancel: () -> Void
    var onCommit: ([SongRow]) -> Void

    @State private var rows: [SongRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            songSheetHeader
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach($rows) { $row in
                        songRowEditor(row: $row)
                    }
                }
                .padding(.vertical, 2)
            }
            songSheetFooter
        }
        .padding(20)
        .frame(width: 540, height: 500)
        .task {
            if rows.isEmpty {
                rows = files.map { SongRow(source: $0, fileName: $0.lastPathComponent) }
                await autofillAll()
            }
        }
    }

    private var songSheetHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Add to \(pack.name)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            Text("\(files.count) song\(files.count == 1 ? "" : "s") · album folders matched or created · lrc next to audio")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private var songSheetFooter: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .buttonStyle(AeroButtonStyle())
            Spacer()
            Button("Add \(rows.count) song\(rows.count == 1 ? "" : "s")") {
                onCommit(rows)
            }
            .buttonStyle(AeroButtonStyle(prominent: true))
            .disabled(rows.isEmpty)
        }
    }

    private func songRowEditor(row: Binding<SongRow>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.dotActive)
                Text(row.wrappedValue.fileName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if !row.wrappedValue.loaded {
                    Text("Reading…")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            HStack(spacing: 8) {
                songField(title: "Title", text: row.title)
                songField(title: "Artist", text: row.artist)
            }
            HStack(spacing: 8) {
                songField(title: "Album", text: row.album)
                songField(title: "Length", text: row.length)
            }
            HStack(spacing: 6) {
                Text("LRC")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                if let lrc = row.wrappedValue.lrcSource {
                    Text(lrc.lastPathComponent)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.dotActive)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        row.wrappedValue.lrcSource = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove chosen LRC (fall back to tags)")
                } else {
                    Text("Auto (tags only)")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary.opacity(0.7))
                    Spacer()
                    Button("Choose…") {
                        pickLrc(for: row)
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.dotActive)
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.textSecondary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }

    private func songField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }

    private func pickLrc(for row: Binding<SongRow>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["lrc", "elrc"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Choose LRC"
        panel.message = "Pick a lyric file for \(row.wrappedValue.fileName)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        row.wrappedValue.lrcSource = url
    }

    private func autofillAll() async {
        for i in rows.indices {
            await autofillRow(i)
        }
    }

    private func autofillRow(_ i: Int) async {
        guard rows.indices.contains(i) else { return }
        let url = rows[i].source
        var title = ""
        var artist = ""
        var album = ""
        var length = ""
        do {
            let asset = AVURLAsset(url: url)
            if let dur = try? await asset.load(.duration), dur.seconds.isFinite, dur.seconds > 0 {
                let total = Int(dur.seconds)
                length = "\(total / 60):\(String(format: "%02d", total % 60))"
            }
            if let items = try? await asset.load(.commonMetadata) {
                for item in items {
                    guard let key = item.commonKey?.rawValue else { continue }
                    guard let value = try? await item.load(.value) as? String, !value.isEmpty else { continue }
                    switch key {
                    case "title": if title.isEmpty { title = value }
                    case "artist": if artist.isEmpty { artist = value }
                    case "albumName": if album.isEmpty { album = value }
                    default: break
                    }
                }
            }
        }
        // Filename fallback: "Artist - Title"
        if title.isEmpty || artist.isEmpty {
            let base = url.deletingPathExtension().lastPathComponent
            if let sep = base.range(of: " - ") {
                if artist.isEmpty { artist = String(base[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces) }
                if title.isEmpty { title = String(base[sep.upperBound...]).trimmingCharacters(in: .whitespaces) }
            } else if title.isEmpty {
                title = base.trimmingCharacters(in: .whitespaces)
            }
        }
        await MainActor.run {
            guard rows.indices.contains(i) else { return }
            if rows[i].title.isEmpty { rows[i].title = title }
            if rows[i].artist.isEmpty { rows[i].artist = artist }
            if rows[i].album.isEmpty { rows[i].album = album }
            if rows[i].length.isEmpty { rows[i].length = length }
            rows[i].loaded = true
        }
    }
}

// MARK: - Drop helpers

/// Loads `.fileURL` drag providers into URLs on main (shared by pack cards
/// and the background playlist chooser). File-private to this file.
private func loadDroppedFileURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    var urls: [URL] = []
    let lock = NSLock()
    let group = DispatchGroup()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url = url as? URL {
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}