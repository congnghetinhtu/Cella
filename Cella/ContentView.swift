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
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @AppStorage("themeOverride") private var themeOverride: String = "seafoam"

    private var effectiveColorScheme: ColorScheme {
        switch appearanceMode {
        case "dark": return .dark
        case "light": return .light
        default: return colorScheme
        }
    }

    private var preferredScheme: ColorScheme? {
        switch appearanceMode {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    private var theme: Theme {
        switch themeOverride {
        case "seafoam": return .seafoam
        default: return .dark
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
                pack: displayedPack ?? CellaPack(url: URL(fileURLWithPath: ""), type: .openCella, name: "", coverURLs: [], albumCount: 0, trackCount: 0),
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
        }
        .animation(.smooth, value: detailPack != nil)
        .animation(.smooth, value: effectiveColorScheme)
        .animation(.smooth, value: themeOverride)
        .environment(\.theme, theme)
        .preferredColorScheme(preferredScheme)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.space) {
            if selectedTab == .enhancedLRC || selectedTab == .cluster {
                return .ignored
            }
            viewModel.togglePlayPause()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            if selectedTab == .enhancedLRC || selectedTab == .cluster {
                return .ignored
            }
            viewModel.skipBackward()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if selectedTab == .enhancedLRC || selectedTab == .cluster {
                return .ignored
            }
            viewModel.skipForward()
            return .handled
        }
        .onKeyPress(.init("l")) {
            if selectedTab == .enhancedLRC || selectedTab == .cluster {
                return .ignored
            }
            withAnimation(.snappy) {
                viewModel.lyricsMode.cycle()
            }
            return .handled
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

#Preview {
    ContentView()
}
