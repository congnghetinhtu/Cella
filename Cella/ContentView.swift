//
//  ContentView.swift
//  Cella
//
//  Root view — manages tab navigation and keyboard input.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTab: AppTab = .cluster
    @State private var savedVolume: Float = 1.0
    @State private var cellaVolume: Float = 1.0
    @State private var viewModel = PlayerViewModel()
    @State private var detailPack: CellaPack?
    @State private var displayedPack: CellaPack?
    @State private var pendingLRCAudioURL: URL?
    @State private var showCommandPalette = false
    @State private var commandText = ""
    @State private var commandOrigin: CGPoint = .zero
    @State private var mouseMonitor: Any?
    @FocusState private var isFocused: Bool
    @FocusState private var isCommandFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("themeOverride") private var themeOverride: String = "seafoam"

    private var preferredScheme: ColorScheme? {
        .dark
    }

    private var theme: Theme {
        switch themeOverride {
        case "seafoam": return .seafoam
        case "bipolar": return .bipolar
        default: return .dark
        }
    }

    // MARK: - Mouse tracking for command palette

    private func startMouseTracking() {
        stopMouseTracking()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
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

    var body: some View {
        ZStack {
            theme.appBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top: Nav bar
                BottomTabBar(selectedTab: $selectedTab)
                    .padding(.horizontal, 48)
                    .padding(.top, 20)

                // Content
                Group {
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
                    case .motions:
                        CellaMotionsView()
                    case .cella:
                        CellaView(viewModel: viewModel)
                    case .enhancedLRC:
                        EnhancedLRCView(pendingAudioURL: $pendingLRCAudioURL)
                    case .config:
                        ConfigView(viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        showCommandPalette = false
                        commandText = ""
                    }

                CommandPaletteBar(
                    text: $commandText,
                    theme: theme,
                    focus: $isCommandFocused,
                    origin: commandOrigin,
                    onSubmit: {
                        let match = AppTab.allCases.first {
                            $0.rawValue.localizedCaseInsensitiveContains(commandText)
                        }
                        if let match { selectedTab = match }
                        showCommandPalette = false
                        commandText = ""
                        stopMouseTracking()
                    }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.9)),
                    removal: .opacity.combined(with: .scale(scale: 1.06))
                ))
            }
        }
        .animation(.smooth, value: detailPack != nil)
        .animation(.smooth, value: themeOverride)
        .animation(.snappy, value: showCommandPalette)
        .environment(\.theme, theme)
        .preferredColorScheme(preferredScheme)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.space) {
            if showCommandPalette { return .ignored }
            if selectedTab == .enhancedLRC || selectedTab == .cluster {
                return .ignored
            }
            viewModel.togglePlayPause()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            if showCommandPalette { return .ignored }
            if selectedTab == .enhancedLRC || selectedTab == .cluster {
                return .ignored
            }
            viewModel.skipBackward()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if showCommandPalette { return .ignored }
            if selectedTab == .enhancedLRC || selectedTab == .cluster {
                return .ignored
            }
            viewModel.skipForward()
            return .handled
        }
        .onKeyPress(.init("l")) {
            if showCommandPalette { return .ignored }
            if selectedTab == .enhancedLRC || selectedTab == .cluster {
                return .ignored
            }
            withAnimation(.snappy) {
                viewModel.lyricsMode.cycle()
            }
            return .handled
        }
        .onKeyPress(.init("/")) {
            if selectedTab == .enhancedLRC || selectedTab == .cluster {
                return .ignored
            }
            if showCommandPalette {
                withAnimation(.snappy) {
                    showCommandPalette = false
                    commandText = ""
                }
                stopMouseTracking()
                return .handled
            }
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first {
                commandOrigin = CGPoint(x: mouse.x, y: screen.frame.height - mouse.y)
            }
            withAnimation(.snappy) {
                showCommandPalette = true
                commandText = ""
            }
            startMouseTracking()
            DispatchQueue.main.async { isCommandFocused = true }
            return .handled
        }
        .onKeyPress(.escape) {
            if showCommandPalette {
                withAnimation(.snappy) {
                    showCommandPalette = false
                    commandText = ""
                }
                stopMouseTracking()
                return .handled
            }
            return .ignored
        }
        .onAppear {
            isFocused = true
            #if DEBUG
            if let path = ProcessInfo.processInfo.environment["CELLA_TEST_PLAYLIST"] {
                viewModel.importViaOpenMix(url: URL(fileURLWithPath: path))
            }
            #endif
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .motions {
                cellaVolume = viewModel.currentVolume
                viewModel.setVolume(0.1)
            } else {
                viewModel.setVolume(cellaVolume)
            }
            viewModel.setHallReverb(tab == .motions)
            if tab != .cella {
                viewModel.isAnimationPaused = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                viewModel.isAnimationPaused = true
            }
        }
        .onTapGesture {
            isFocused = true
        }
    }
}

// MARK: - Command palette bar

private struct CommandPaletteBar: View {
    @Binding var text: String
    let theme: Theme
    let focus: FocusState<Bool>.Binding
    let origin: CGPoint
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("/")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(theme.dotActive)
            SmoothCommandInput(
                text: $text,
                theme: theme,
                focus: focus,
                onSubmit: onSubmit
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(theme.tabBarBackground.opacity(0.95))
        )
        .overlay { haloBorder(theme: theme) }
        .shadow(
            color: theme.haloPrimary.opacity(0.35 + 0.2 * sin(Date().timeIntervalSinceReferenceDate * 2.0)),
            radius: 12, y: 0
        )
        .position(x: origin.x + 60, y: origin.y)
    }

    private func haloBorder(theme: Theme) -> some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(t * 2.0)
            Capsule()
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            theme.haloPrimary.opacity(0.9),
                            theme.haloSecondary.opacity(0.9),
                            theme.haloAccent.opacity(0.9),
                            theme.haloWarm.opacity(0.9),
                            theme.haloPrimary.opacity(0.9)
                        ],
                        center: .center,
                        startAngle: .degrees(t * 90),
                        endAngle: .degrees(t * 90 + 360)
                    ),
                    lineWidth: 2
                )
                .blur(radius: 1)
                .brightness(0.15 * pulse)
        }
    }
}

// MARK: - Smooth input (Word-like caret, char reveal, gliding)

private struct SmoothCommandInput: View {
    @Binding var text: String
    let theme: Theme
    let focus: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    @State private var chars: [CharCell] = []
    @State private var nextID = 0
    @State private var contentWidth: CGFloat = 0

    struct CharCell: Identifiable, Equatable {
        let id: Int
        var ch: String
    }

    private static let fieldWidth: CGFloat = 140

    private var glideOffset: CGFloat {
        min(0, Self.fieldWidth - contentWidth - 2)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        if chars.isEmpty {
                            Text("tab")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(theme.textSecondary.opacity(0.45))
                        } else {
                            ForEach(chars) { cell in
                                Text(cell.ch)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(theme.textPrimary)
                                    .transition(.opacity)
                            }
                        }
                    }
                    .fixedSize()

                    caret(at: timeline.date.timeIntervalSinceReferenceDate)
                }
                .offset(x: glideOffset)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { contentWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, w in
                                withAnimation(.smooth) { contentWidth = w }
                            }
                    }
                )
            }
            .frame(width: Self.fieldWidth, alignment: .leading)
            .clipped()
            .animation(.smooth, value: chars)
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = true }
        .overlay(alignment: .trailing) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .opacity(0.01)
                .frame(width: 1, height: 1)
                .focused(focus)
                .onSubmit(onSubmit)
        }
        .onChange(of: text) { _, newValue in
            syncChars(to: newValue)
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
        if newChars.count == chars.count {
            for i in newChars.indices where chars[i].ch != newChars[i] {
                chars[i].ch = newChars[i]
            }
        } else if newChars.count > chars.count {
            for i in chars.count..<newChars.count {
                chars.append(CharCell(id: nextID, ch: newChars[i]))
                nextID += 1
            }
        } else {
            chars.removeLast(chars.count - newChars.count)
        }
    }
}

#Preview {
    ContentView()
}
