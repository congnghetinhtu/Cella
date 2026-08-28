//
//  ContentView.swift
//  Cella
//
//  Root view — manages tab navigation and keyboard input.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTab: AppTab = .cella
    @State private var savedVolume: Float = 1.0
    @State private var cellaVolume: Float = 1.0
    @State private var viewModel = PlayerViewModel()
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @AppStorage("themeOverride") private var themeOverride: String = "default"

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
        let isDark = effectiveColorScheme == .dark
        switch themeOverride {
        case "seafoam": return isDark ? .seafoam : .lightSeafoam
        default: return isDark ? .dark : .light
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
                        ClusterView()
                    case .motions:
                        CellaMotionsView()
                    case .cella:
                        CellaView(viewModel: viewModel)
                    case .enhancedLRC:
                        EnhancedLRCView()
                    case .config:
                        ConfigView(viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
