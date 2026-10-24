//
//  ContentView.swift
//  Cella
//
//  Root view — manages tab navigation and keyboard input.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var selectedTab: AppTab = .cluster
    @State private var savedVolume: Float = 1.0
    @State private var lrcAutoPaused = false
    @State private var lrcHasAudio = false
    @State private var viewModel = PlayerViewModel()
    @StateObject private var lrcViewModel = EnhancedLRCViewModel()
    @StateObject private var commandInput = CommandInputController()
    @State private var detailPack: CellaPack?
    @State private var displayedPack: CellaPack?
    @State private var pendingLRCAudioURL: URL?
    @State private var showCommandPalette = false
    @State private var commandText = ""
    @State private var commandOrigin: CGPoint = .zero
    @State private var mouseMonitor: Any?
    @State private var keyMonitor: Any?
    @FocusState private var isFocused: Bool
    @FocusState private var isCommandFocused: Bool
    @State private var selectedSuggestion = 0
    @State private var bloomAnchor: UnitPoint = UnitPoint(x: 0.5, y: 0.6)
    @State private var bloomOnNextTabChange = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("themeOverride") private var themeOverride: String = "seafoam"

    private var preferredScheme: ColorScheme? {
        .dark
    }

    /// True while a text field (artist name, rename, etc.) owns the field editor.
    /// Prevents global player shortcuts from firing mid-typing.
    private var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    private var theme: Theme {
        switch themeOverride {
        case "seafoam": return .seafoam
        case "bipolar": return .bipolar
        case "mint": return .mint
        case "frutiger": return .frutiger
        default: return .dark
        }
    }

    // MARK: - Command palette suggestions

    private var suggestionCount: Int {
        commandSuggestions(for: commandText).count
    }

    private var effectiveSuggestion: Int {
        let count = suggestionCount
        if count == 0 { return 0 }
        return min(max(0, selectedSuggestion), count - 1)
    }

    private func commandSuggestions(for text: String) -> [CommandSuggestion] {
        var out: [CommandSuggestion] = []
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let lyrics = viewModel.currentLyrics
        if !lyrics.isEmpty && query.hasPrefix("lyric ") {
            let search = String(query.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if !search.isEmpty {
                let upper = search.uppercased()
                var found = 0
                for line in lyrics where found < 5 {
                    if line.text.uppercased().contains(upper) {
                        out.append(.lyric(line.time, line.text))
                        found += 1
                    }
                }
            }
        }

        if !query.isEmpty, !query.hasPrefix("lyric "), let queue = viewModel.mixQueue {
            let tracks = queue.tracks
            let upper = query.uppercased()
            var found = 0
            for (index, track) in tracks.enumerated() {
                if track.trackTitle.uppercased().contains(upper)
                    || track.displayArtist.uppercased().contains(upper)
                    || track.fileName.uppercased().contains(upper) {
                    out.append(.track(index, track))
                    found += 1
                    if found >= 4 { break }
                }
            }
        }

        if !query.isEmpty {
            let tabs = AppTab.allCases.filter {
                $0.rawValue.localizedCaseInsensitiveContains(query)
            }
            out += tabs.map { .tab($0) }
        }

        let commands: [(String, String, String)] = [
            ("insertInit", "insertInit", "Break at 00:00.00"),
            ("insertBreak", "insertBreak", "Break at current time"),
            ("addLy", "addLy", "Add lyric at current time")
        ]
        if !query.isEmpty {
            // "addLy " with text after it still shows the command; the quoted
            // text is the argument, not part of the match.
            let head = query.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? query
            out += commands.filter { $0.0.localizedCaseInsensitiveContains(head) }
                .map { .command($0.1, $0.2) }
        }

        return Array(out.prefix(5))
    }

    /// Quote pairs that wrap a lyric argument. macOS smart quotes substitute
    /// “ ” / ‘ ’, so open and close are different characters — matching only
    /// identical characters left the quotes in the inserted lyric.
    private static let lyricQuotePairs: [(Character, Character)] = [
        ("\"", "\""),
        ("'", "'"),
        ("\u{201C}", "\u{201D}"), // “ ”
        ("\u{2018}", "\u{2019}")  // ‘ ’,
    ]

    /// Matches `addLy "Oh we here in the jungle"`, `addLy 'same'`, or bare `addLy`.
    /// Returns the lyric text (empty for a bare or empty-quoted call), or nil when
    /// this isn't an addLy command at all.
    private func parseLyricCommand(_ input: String) -> String? {
        let parts = input.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let head = parts.first, head == "addLy" else { return nil }
        guard parts.count > 1 else { return "" }
        return stripLyricQuotes(String(parts[1]))
    }

    /// Lenient lyric extraction for the addLy command row. Exact `addLy "…"`
    /// first; then near-miss command words (`add …`, `addly …`) so a typo
    /// inserts the trailing text instead of silently dropping it into the
    /// `lyricGoeshere` placeholder. Nil only when this isn't an add-lyric
    /// invocation at all.
    private func addLyricText(from input: String) -> String? {
        if let exact = parseLyricCommand(input) { return exact }
        let parts = input.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let head = parts[0].lowercased()
        let nearMiss = ["add", "addl", "addly", "adly", "addlyric", "addlyrics", "lyr", "lyric", "lyrics"]
        guard nearMiss.contains(String(head)) else { return nil }
        return stripLyricQuotes(String(parts[1]))
    }

    private func stripLyricQuotes(_ rest: String) -> String {
        var text = rest.trimmingCharacters(in: .whitespaces)
        if let open = text.first, let close = text.last, text.count >= 2,
           Self.lyricQuotePairs.contains(where: { $0.0 == open && $0.1 == close }) {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private func moveSuggestionSelection(_ delta: Int) {
        let count = suggestionCount
        guard count > 0 else { return }
        selectedSuggestion = ((effectiveSuggestion + delta) % count + count) % count
    }

    private func selectSuggestion(_ suggestion: CommandSuggestion) {
        bloomOnNextTabChange = true
        switch suggestion {
        case .tab(let tab):
            selectedTab = tab
        case .track(let index, _):
            if selectedTab != .cella { selectedTab = .cella }
            viewModel.jumpToTrack(at: index)
        case .lyric(let time, _):
            if selectedTab != .cella { selectedTab = .cella }
            if viewModel.lyricsMode == .off {
                withAnimation(.snappy) { viewModel.lyricsMode = .full }
            }
            viewModel.seekTo(time: time)
        case .command(let id, _):
            if selectedTab != .cella { selectedTab = .cella }
            switch id {
            case "insertInit":
                _ = viewModel.insertInit()
            case "insertBreak":
                _ = viewModel.insertBreak(at: viewModel.currentTime)
            case "addLy":
                // Tapping the row must use the quoted text already in the field
                // (lenient: near-miss command words keep their trailing text).
                _ = viewModel.addLyric(
                    at: viewModel.currentTime,
                    text: addLyricText(from: commandText) ?? ""
                )
            default:
                break
            }
        }
        withAnimation(.snappy) {
            showCommandPalette = false
        }
        commandText = ""
        stopMouseTracking()
        restoreMainFocus()
    }

    private func restoreMainFocus() {
        isCommandFocused = false
        DispatchQueue.main.async {
            guard !self.showCommandPalette else { return }
            self.isFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard !self.showCommandPalette else { return }
                self.isFocused = true
            }
        }
    }

    private var bloomTransition: AnyTransition {
        if bloomOnNextTabChange {
            return .asymmetric(
                insertion: .scale(scale: 0.82, anchor: bloomAnchor)
                    .combined(with: .opacity),
                removal: .scale(scale: 1.08, anchor: bloomAnchor)
                    .combined(with: .opacity)
            )
        }
        return .asymmetric(
            insertion: .opacity,
            removal: .opacity
        )
    }

    private func paletteBloomAnchor() -> UnitPoint {
        let mouse = NSEvent.mouseLocation
        guard let window = NSApp.keyWindow, let content = window.contentView else {
            return UnitPoint(x: 0.5, y: 0.55)
        }
        let bounds = content.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            return UnitPoint(x: 0.5, y: 0.55)
        }
        let x = mouse.x - window.frame.minX
        let y = mouse.y - window.frame.minY
        return UnitPoint(
            x: max(0, min(1, x / bounds.width)),
            y: max(0, min(1, 1 - y / bounds.height))
        )
    }

    // MARK: - Palette key monitor (focus-independent)

    private func installPaletteKeyMonitor() {
        removePaletteKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if showCommandPalette {
                switch event.keyCode {
                case 126: // Up — suggestions up
                    moveSuggestionSelection(-1)
                    return nil
                case 125: // Down — suggestions down
                    moveSuggestionSelection(1)
                    return nil
                case 123, 124: // Left / Right — move text caret in command input
                    let delta = event.keyCode == 124 ? 1 : -1
                    if !commandInput.moveCaret(delta) {
                        moveSuggestionSelection(delta)
                    }
                    return nil
                default:
                    break
                }
            }
            guard event.charactersIgnoringModifiers == "/" else { return event }
            if event.isARepeat { return nil }
            if selectedTab == .enhancedLRC {
                return event
            }
            if showCommandPalette {
                withAnimation(.snappy) {
                    showCommandPalette = false
                    commandText = ""
                }
                stopMouseTracking()
                restoreMainFocus()
                return nil
            }
            // Typing in any text field (artist name, save sheet, LRC bulk
            // paste): let the "/" type instead of stealing it for the palette.
            if NSApp.keyWindow?.firstResponder is NSTextView {
                return event
            }
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first {
                commandOrigin = CGPoint(x: mouse.x, y: screen.frame.height - mouse.y)
            }
            bloomAnchor = paletteBloomAnchor()
            selectedSuggestion = 0
            commandInput.reset()
            withAnimation(.snappy) {
                showCommandPalette = true
                commandText = ""
            }
            startMouseTracking()
            DispatchQueue.main.async { isCommandFocused = true }
            return nil
        }
    }

    private func removePaletteKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Mouse tracking for command palette

    private func startMouseTracking() {
        stopMouseTracking()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            guard self.commandText.isEmpty else { return event }
            if let screen = NSScreen.screens.first {
                let mouseLoc = NSEvent.mouseLocation
                let screenY = screen.frame.height - mouseLoc.y
                let screenX = mouseLoc.x
                DispatchQueue.main.async {
                    commandOrigin = CGPoint(x: screenX, y: screenY)
                }
            }
            return event
        }
    }

    private func stopMouseTracking() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    // MARK: - Body

    /// Bottom toast for app-wide .lrc drops.
    private var dropToast: some View {
        Group {
            if let notice = viewModel.dropNotice {
                HStack(spacing: 6) {
                    Image(systemName: "text.badge.checkmark")
                    Text(notice)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(.ultraThinMaterial))
                .background(Capsule().fill(theme.dotActive.opacity(0.18)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    var body: some View {
        ZStack {
            MetroBackgroundView()

            VStack(spacing: 0) {
                // Top: Nav bar
                BottomTabBar(selectedTab: $selectedTab, lrcViewModel: lrcViewModel)
                    .padding(.horizontal, 48)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                // Content
                ZStack {
                    switch selectedTab {
                    case .cluster:
                        ClusterView(viewModel: viewModel, onPlay: {
                            selectedTab = .cella
                        }, onOpenDetail: { pack in
                            displayedPack = pack
                            detailPack = pack
                        }, onOpenLRC: { audioURL in
                            pendingLRCAudioURL = audioURL
                            selectedTab = .enhancedLRC
                        })
                        .transition(bloomTransition)
                    case .cella:
                        CellaView(viewModel: viewModel)
                            .transition(bloomTransition)
                    case .enhancedLRC:
                        EnhancedLRCView(viewModel: lrcViewModel, pendingAudioURL: $pendingLRCAudioURL, hasAudio: $lrcHasAudio)
                            .transition(bloomTransition)
                    case .config:
                        ConfigView(viewModel: viewModel)
                            .transition(bloomTransition)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.spring(response: 0.45, dampingFraction: 0.88), value: selectedTab)
            }

            // Detail overlay — above nav bar, tap outside to dismiss.
            Color.black.opacity(detailPack != nil ? 0.55 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(detailPack != nil)
                .onTapGesture {
                    detailPack = nil
                }

            PackDetailView(
                pack: displayedPack ?? CellaPack(url: URL(fileURLWithPath: ""), type: .openCella, name: "", coverURLs: [], albumCount: 0, trackCount: 0, cachedTrackCount: 0),
                viewModel: viewModel,
                onPlay: { startFile in
                    if let detailPack {
                        selectedTab = .cella
                        viewModel.importViaOpenMix(url: detailPack.url, startFileName: startFile)
                    }
                    detailPack = nil
                },
                onAutoMix: { startFile, _ in
                    if let detailPack {
                        selectedTab = .cella
                        viewModel.importViaOpenMix(url: detailPack.url, startFileName: startFile, blend: true)
                    }
                    detailPack = nil
                },
                onPlayArtist: { artist in
                    if let detailPack {
                        selectedTab = .cella
                        viewModel.importViaOpenMix(url: detailPack.url, startFileName: artist.files.first, blend: false, artistFilter: artist.name)
                    }
                    detailPack = nil
                },
                onClose: {
                    detailPack = nil
                },
                onOpenLRC: { audioURL in
                    pendingLRCAudioURL = audioURL
                    selectedTab = .enhancedLRC
                    detailPack = nil
                }
            )
            .environment(\.theme, theme)
            .opacity(detailPack != nil ? 1 : 0)
            .allowsHitTesting(detailPack != nil)

            // Command palette — minimal input bar at cursor
            if showCommandPalette {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.snappy) {
                            showCommandPalette = false
                        }
                        commandText = ""
                        restoreMainFocus()
                    }

                CommandPaletteBar(
                    text: $commandText,
                    theme: theme,
                    focus: $isCommandFocused,
                    origin: commandOrigin,
                    input: commandInput,
                    suggestions: { commandSuggestions(for: $0) },
                    selectedSuggestion: effectiveSuggestion,
                    onHoverSelect: { selectedSuggestion = $0 },
                    placeholder: viewModel.currentLyrics.isEmpty
                        ? "jump to lyric"
                        : {
                            let current = viewModel.currentLyrics
                                .last(where: { $0.time <= viewModel.currentTime })
                                ?? viewModel.currentLyrics.first
                            return current.map { "jump to lyric: \($0.text)" }
                                ?? "jump to lyric"
                        }(),
                    onSuggestionTap: selectSuggestion,
                    onSubmit: {
                        let trimmed = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed == "insertInit" {
                            if selectedTab != .cella { selectedTab = .cella }
                            _ = viewModel.insertInit()
                            withAnimation(.snappy) { showCommandPalette = false }
                            commandText = ""
                            stopMouseTracking()
                            restoreMainFocus()
                        } else if trimmed == "insertBreak" {
                            if selectedTab != .cella { selectedTab = .cella }
                            _ = viewModel.insertBreak(at: viewModel.currentTime)
                            withAnimation(.snappy) { showCommandPalette = false }
                            commandText = ""
                            stopMouseTracking()
                            restoreMainFocus()
                        } else if let command = addLyricText(from: trimmed) {
                            if selectedTab != .cella { selectedTab = .cella }
                            _ = viewModel.addLyric(at: viewModel.currentTime, text: command)
                            withAnimation(.snappy) { showCommandPalette = false }
                            commandText = ""
                            stopMouseTracking()
                            restoreMainFocus()
                        } else {
                            let suggestions = commandSuggestions(for: commandText)
                            if !suggestions.isEmpty {
                                let index = min(max(0, selectedSuggestion), suggestions.count - 1)
                                selectSuggestion(suggestions[index])
                            } else {
                                withAnimation(.snappy) { showCommandPalette = false }
                                commandText = ""
                                stopMouseTracking()
                                restoreMainFocus()
                            }
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.9)),
                    removal: .opacity.combined(with: .scale(scale: 1.06))
                ))
            }

            // Dropped-lyric toast (app-wide .lrc drops).
            dropToast
        }
        .onDrop(of: [.fileURL], delegate: LrcDropDelegate(
            viewModel: viewModel,
            editor: selectedTab == .enhancedLRC ? lrcViewModel : nil))
        .sheet(isPresented: Binding(
            get: { !viewModel.pendingLrcQueue.isEmpty },
            set: { if !$0 { viewModel.pendingLrcQueue = [] } }
        )) {
            if let url = viewModel.pendingLrcQueue.first {
                LrcSongPickerSheet(
                    viewModel: viewModel,
                    url: url,
                    remaining: viewModel.pendingLrcQueue.count,
                    theme: theme
                )
            }
        }
        .animation(.smooth, value: detailPack != nil)
        .animation(.smooth, value: themeOverride)
        .animation(.snappy, value: showCommandPalette)
        .animation(.snappy, value: viewModel.dropNotice)
        .environment(\.theme, theme)
        .preferredColorScheme(preferredScheme)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.space) {
            if showCommandPalette { return .ignored }
            if isEditingText { return .ignored }
            if selectedTab != .cella {
                return .ignored
            }
            viewModel.togglePlayPause()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            if showCommandPalette {
                if !commandInput.moveCaret(-1) { moveSuggestionSelection(-1) }
                return .handled
            }
            if isEditingText { return .ignored }
            if selectedTab != .cella {
                return .ignored
            }
            viewModel.skipBackward()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if showCommandPalette {
                if !commandInput.moveCaret(1) { moveSuggestionSelection(1) }
                return .handled
            }
            if isEditingText { return .ignored }
            if selectedTab != .cella {
                return .ignored
            }
            viewModel.skipForward()
            return .handled
        }
        .onKeyPress(.init("l")) {
            if showCommandPalette { return .ignored }
            if isEditingText { return .ignored }
            if selectedTab != .cella {
                return .ignored
            }
            withAnimation(.snappy) {
                viewModel.lyricsMode.cycle()
            }
            return .handled
        }
        .onKeyPress(.init("s")) {
            if showCommandPalette { return .ignored }
            if isEditingText { return .ignored }
            if selectedTab != .cella {
                return .ignored
            }
            viewModel.toggleSolo()
            return .handled
        }
        .onKeyPress(.upArrow) {
            if showCommandPalette {
                moveSuggestionSelection(-1)
                return .handled
            }
            if isEditingText { return .ignored }
            return .ignored
        }
        .onKeyPress(.downArrow) {
            if showCommandPalette {
                moveSuggestionSelection(1)
                return .handled
            }
            if isEditingText { return .ignored }
            return .ignored
        }
        .onKeyPress(.escape) {
            if showCommandPalette {
                withAnimation(.snappy) {
                    showCommandPalette = false
                    commandText = ""
                }
                stopMouseTracking()
                restoreMainFocus()
                return .handled
            }
            if isEditingText { return .ignored }
            return .ignored
        }
        .onAppear {
            isFocused = true
            installPaletteKeyMonitor()
            #if DEBUG
            if let path = ProcessInfo.processInfo.environment["CELLA_TEST_PLAYLIST"] {
                viewModel.importViaOpenMix(url: URL(fileURLWithPath: path))
            }
            if ProcessInfo.processInfo.environment["CELLA_AUTOTEST"] != nil {
                Task { @MainActor in
                    for _ in 0..<60 {
                        if viewModel.mixQueue != nil { break }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    viewModel.jumpToTrack(at: 0)
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    viewModel.applySurround(.ampliado)
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    viewModel.applySurround(.teatro)
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            #endif
        }
        .onDisappear {
            removePaletteKeyMonitor()
        }
        .onOpenURL { url in
            // Finder double-click on packages: .cluster opens library, .cella imports pack.
            switch url.pathExtension.lowercased() {
            case "cluster":
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                UserDefaults.standard.set(url.path, forKey: "clusterLibraryPath")
                selectedTab = .cluster
            case "cella":
                selectedTab = .cella
                viewModel.importViaOpenMix(url: url)
            default:
                break
            }
        }
        .onChange(of: commandText) { _, _ in
            selectedSuggestion = 0
        }
        .onChange(of: showCommandPalette) { _, visible in
            if !visible {
                bloomOnNextTabChange = false
                restoreMainFocus()
            }
        }
        .onChange(of: selectedTab) { oldTab, tab in
            // Leaving the LRC Editor pauses its audio (keeps position).
            if oldTab == .enhancedLRC, lrcViewModel.isPlaying {
                lrcViewModel.togglePlayback()
            }
            bloomOnNextTabChange = false
            if tab == .enhancedLRC {
                // Edit timing in quiet — but only when the editor holds audio.
                // Empty editor: Cella keeps playing.
                if lrcHasAudio && (viewModel.playerState == .playing || viewModel.playerState == .autoMix) {
                    lrcAutoPaused = true
                    if viewModel.playerState == .playing {
                        viewModel.fadeOutForEditor()
                    } else {
                        // Mid-blend: hold the fade until it lands, then fade.
                        viewModel.editorFadePending = true
                    }
                }
            } else {
                viewModel.editorFadePending = false
                if lrcAutoPaused {
                    lrcAutoPaused = false
                    viewModel.resumeFromEditor()
                }
            }
        }
        .onChange(of: viewModel.playerState) { _, state in
            // Held LRC-editor fade: the blend landed while editing.
            if selectedTab == .enhancedLRC, viewModel.editorFadePending, state == .playing {
                viewModel.editorFadePending = false
                viewModel.fadeOutForEditor()
            }
        }
        .onTapGesture {
            isFocused = true
        }
    }
}

// MARK: - Dropped-lyric catcher (tabs without their own drop zone)

/// Root drop delegate for app-wide .lrc/.clarc drops (Cella, Config,
/// LRC Editor tabs). Only lyric files are consumed — audio/video drops are
/// ignored here so tab handlers own them. Cluster/Motion tabs route lyric
/// files to the same handler from their own (deeper) drop zones; delivery
/// is idempotent (attach is a no-op once the source is moved).
private struct LrcDropDelegate: DropDelegate {
    var viewModel: PlayerViewModel
    /// Non-nil while the Clarc tab is active: lyric drops route to the
    /// editor instead (— .clarc opens, .lrc enters conversion).
    var editor: EnhancedLRCViewModel?

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        // Batch all providers first: a multi-file drop must arrive as one
        // plural call, or each file would attach to the playing song solo.
        let group = DispatchGroup()
        var lrcs: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                if let url = url as? URL,
                   PlayerViewModel.droppedLrcExtensions.contains(url.pathExtension.lowercased()) {
                    lrcs.append(url)
                }
            }
        }
        group.notify(queue: .main) {
            guard !lrcs.isEmpty else { return }
            if let editor {
                editor.handleConverterDrop(lrcs)
            } else {
                viewModel.handleDroppedLrcs(lrcs)
            }
        }
        return true
    }
}

/// Song picker shown when dropped .lrc files need targets (one pick per
/// file, in order). Dismissing mid-queue abandons the rest — nothing has
/// moved yet, so no files are lost.
private struct LrcSongPickerSheet: View {
    var viewModel: PlayerViewModel
    let url: URL
    let remaining: Int
    let theme: Theme

    private var caption: String {
        if remaining > 1 {
            "Attach “\(url.lastPathComponent)” (\(remaining) left) to…"
        } else {
            "Attach “\(url.lastPathComponent)” to…"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(caption)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            AlbumSongsPopover(viewModel: viewModel, initialAlbum: nil, autoDismiss: false) { track in
                viewModel.attachDroppedLrc(url, to: track)
                if !viewModel.pendingLrcQueue.isEmpty {
                    viewModel.pendingLrcQueue.removeFirst()
                }
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    // Abandon the rest — nothing moved yet, so no files lost.
                    viewModel.pendingLrcQueue = []
                }
                .buttonStyle(.bordered)
                .tint(theme.textSecondary)
            }
        }
        .padding(20)
        .environment(\.theme, theme)
    }
}

// MARK: - Command palette suggestions

private enum CommandSuggestion: Identifiable {
    case tab(AppTab)
    case track(Int, TrackAsset)
    case lyric(Double, String)
    case command(String, String) // id, title

    var id: String {
        switch self {
        case .tab(let tab): return "tab-\(tab.rawValue)"
        case .track(let index, let track): return "track-\(index)-\(track.url.path)"
        case .lyric(let time, let text): return "lyric-\(time)-\(text)"
        case .command(let id, _): return "cmd-\(id)"
        }
    }

    var title: String {
        switch self {
        case .tab(let tab): return tab.rawValue
        case .track(_, let track): return track.trackTitle
        case .lyric(_, let text): return text
        case .command(_, let title): return title
        }
    }

    var subtitle: String {
        switch self {
        case .tab(let tab):
            return tab == .cella ? "Go to player" : "Open tab"
        case .track(_, let track):
            return track.displayArtist
        case .lyric(let time, _):
            let total = Int(time)
            return String(format: "%02d:%02d", total / 60, total % 60)
        case .command(let id, _):
            switch id {
            case "insertInit": return "At 00:00.00"
            case "addLy": return "addLy \"line\" at playhead"
            default: return "At current time"
            }
        }
    }
}

// MARK: - Command palette bar

private struct CommandPaletteBar: View {
    @Binding var text: String
    let theme: Theme
    let focus: FocusState<Bool>.Binding
    let origin: CGPoint
    let input: CommandInputController
    let suggestions: (String) -> [CommandSuggestion]
    let selectedSuggestion: Int
    let onHoverSelect: (Int) -> Void
    let placeholder: String
    let onSuggestionTap: (CommandSuggestion) -> Void
    let onSubmit: () -> Void

    @State private var hoveredSuggestion: Int?

    private static let barTopHeight: CGFloat = 60

    var body: some View {
        let items = suggestions(text)
        let hasItems = !items.isEmpty
        VStack(alignment: .leading, spacing: 6) {
            Text("Command Palette")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(theme.textSecondary.opacity(0.5))
                .padding(.leading, 4)

            HStack(spacing: 6) {
                Text("/")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.dotActive)
                SmoothCommandInput(
                    text: $text,
                    theme: theme,
                    focus: focus,
                    input: input,
                    placeholder: placeholder,
                    onSubmit: onSubmit
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.dotActive.opacity(0.22),
                                theme.tabBarBackground.opacity(0.55)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .background(
                Capsule().fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.34), .white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.30), lineWidth: 1.2)
            )
        }
        .overlay(alignment: .topLeading) {
            CommandSuggestionMenu(
                suggestions: items,
                theme: theme,
                selectedSuggestion: hoveredSuggestion ?? selectedSuggestion,
                onTap: onSuggestionTap,
                onHover: {
                    hoveredSuggestion = $0
                    // Hover moves the real selection too, so Enter runs the
                    // row the mouse is on — not a stale keyboard index.
                    if let index = $0 { onHoverSelect(index) }
                }
            )
            .offset(y: Self.barTopHeight + 6)
            .opacity(hasItems ? 1 : 0)
            .allowsHitTesting(hasItems)
            .frame(height: hasItems ? nil : 0)
            .scaleEffect(hasItems ? 1 : 0.96, anchor: .top)
            .animation(.smooth(duration: 0.18), value: hasItems)
            .onChange(of: text) { _, _ in
                // Fresh query invalidates the old mouse highlight.
                hoveredSuggestion = nil
            }
        }
        .position(x: origin.x + 200, y: origin.y + Self.barTopHeight / 2)
    }
}

// MARK: - Command suggestion menu

private struct CommandSuggestionMenu: View {
    let suggestions: [CommandSuggestion]
    let theme: Theme
    let selectedSuggestion: Int
    let onTap: (CommandSuggestion) -> Void
    let onHover: (Int?) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                CommandSuggestionRow(
                    suggestion: suggestion,
                    theme: theme,
                    isSelected: index == selectedSuggestion
                )
                .onTapGesture { onTap(suggestion) }
                .onHover { hovering in
                    onHover(hovering ? index : nil)
                }
            }
        }
        .padding(4)
        .frame(width: 264, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.tabBarBackground.opacity(0.45))
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        )
    }
}

private struct CommandSuggestionRow: View {
    let suggestion: CommandSuggestion
    let theme: Theme
    let isSelected: Bool

    private var icon: String {
        switch suggestion {
        case .tab: return "arrow.up.left.and.arrow.down.right"
        case .track: return "music.note"
        case .lyric: return "quote.opening"
        case .command: return "plus.circle"
        }
    }

    private var tint: Color {
        switch suggestion {
        case .tab: return theme.dotActive
        case .track: return theme.haloSecondary
        case .lyric: return theme.haloAccent
        case .command: return theme.haloWarm
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(suggestion.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? theme.dotActive.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSelected ? theme.dotActive.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Smooth input (Word-like caret, char reveal, gliding)

private struct SmoothCommandInput: View {
    @Binding var text: String
    let theme: Theme
    let focus: FocusState<Bool>.Binding
    let input: CommandInputController
    let placeholder: String
    let onSubmit: () -> Void

    @State private var chars: [CharCell] = []
    @State private var nextID = 0
    @State private var contentWidth: CGFloat = 0

    struct CharCell: Identifiable, Equatable {
        let id: Int
        var ch: String
    }

    private static let fieldWidth: CGFloat = 180

    private var glideOffset: CGFloat {
        min(0, Self.fieldWidth - contentWidth - 2)
    }

    private var cursor: Int {
        min(input.cursorIndex, chars.count)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    charRow(at: timeline.date.timeIntervalSinceReferenceDate)
                        .fixedSize()
                        // caret moves instantly — no ease, prevents text push jitter
                        .animation(nil, value: cursor)
                }
                .offset(x: glideOffset)
                .animation(nil, value: glideOffset)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { contentWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, w in
                                // no spring for width — prevents jump, glide is instant
                                contentWidth = w
                            }
                    }
                )
            }
            .frame(width: Self.fieldWidth, alignment: .leading)
            .clipped()
            // layout must not animate — only opacity fades
            .animation(nil, value: chars.count)
            .animation(nil, value: contentWidth)
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = true }
        .overlay(alignment: .trailing) {
            // Real input surface. Kept near-invisible but MUST have a real width:
            // a 1×1 NSTextField drops keystrokes, which loses characters typed
            // mid-string (e.g. inside addLy "…").
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .opacity(0.01)
                .frame(width: Self.fieldWidth, height: 20)
                .focused(focus)
                .onSubmit(onSubmit)
        }
        .onChange(of: text) { _, newValue in
            syncChars(to: newValue)
            if newValue.isEmpty {
                input.reset()
                return
            }
            syncCursorFromEditor()
        }
        .onChange(of: focus.wrappedValue) { _, isOpen in
            if isOpen {
                input.placeCaretAtEnd()
            }
        }
    }

    // MARK: - Caret sync

    private func syncCursorFromEditor() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
                input.cursorIndex = chars.count
                return
            }
            input.cursorIndex = max(0, min(editor.selectedRange.location, chars.count))
        }
    }

    @ViewBuilder
    private func charRow(at time: TimeInterval) -> some View {
        HStack(spacing: 0) {
            if chars.isEmpty {
                Text(placeholder)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(theme.textSecondary.opacity(0.45))
            } else {
                ForEach(chars.indices, id: \.self) { index in
                    let cell = chars[index]
                    if index == cursor {
                        caret(at: time)
                            .transition(.opacity)
                    }
                    Text(cell.ch)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(theme.textPrimary)
                        .transition(.opacity.animation(.linear(duration: 0.08)))
                }
            }
            if chars.isEmpty || cursor == chars.count {
                caret(at: time)
            }
        }
    }

    private func caret(at time: TimeInterval) -> some View {
        let phase = time.truncatingRemainder(dividingBy: 1.0)
        let o: Double
        if phase < 0.15 {
            o = phase / 0.15
        } else if phase < 0.55 {
            o = 1.0
        } else {
            o = max(0, (1.0 - phase) / 0.45)
        }
        return RoundedRectangle(cornerRadius: 1)
            .fill(theme.dotActive)
            .frame(width: 2, height: 18)
            .opacity(o)
            .shadow(color: theme.haloPrimary.opacity(0.8), radius: 6)
            .padding(.leading, 2)
    }

    private func syncChars(to newValue: String) {
        let newChars = Array(newValue).map(String.init)
        // The row renders with positional identity (ForEach(chars.indices, id: \.self)),
        // so `chars` has to mirror `text` exactly. The old fast path appended blindly
        // whenever the text grew, which put a mid-string insertion at the END of the
        // row — the character being typed never appeared and the trailing quote just
        // repeated. Keep the smooth append fast-path, rebuild for anything else.
        if newChars.count > chars.count, isPrefix(chars.map(\.ch), of: newChars) {
            for ch in newChars[chars.count...] {
                chars.append(CharCell(id: nextID, ch: ch))
                nextID += 1
            }
        } else if newChars != chars.map(\.ch) {
            chars.removeAll(keepingCapacity: true)
            for ch in newChars {
                chars.append(CharCell(id: nextID, ch: ch))
                nextID += 1
            }
        }
    }

    private func isPrefix(_ existing: [String], of candidate: [String]) -> Bool {
        guard existing.count <= candidate.count else { return false }
        for (a, b) in zip(existing, candidate) where a != b { return false }
        return true
    }
}

// MARK: - Command input caret controller

/// Shared between the key monitor and the command input view so arrow keys
/// move the text caret (left/right) instead of the suggestion highlight.
private final class CommandInputController: ObservableObject {
    @Published var cursorIndex = 0

    @discardableResult
    func moveCaret(_ delta: Int) -> Bool {
        guard let editor = fieldEditor() else { return false }
        let location = max(0, min(editor.string.count, editor.selectedRange.location + delta))
        editor.setSelectedRange(NSRange(location: location, length: 0))
        cursorIndex = location
        return true
    }

    func placeCaretAtEnd() {
        if placeCaretAtEndNow() { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.placeCaretAtEndNow()
        }
    }

    func reset() {
        cursorIndex = 0
    }

    @discardableResult
    private func placeCaretAtEndNow() -> Bool {
        guard let editor = fieldEditor() else { return false }
        let location = editor.string.count
        editor.setSelectedRange(NSRange(location: location, length: 0))
        cursorIndex = location
        return true
    }

    private func fieldEditor() -> NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }
}

#Preview {
    ContentView()
}
