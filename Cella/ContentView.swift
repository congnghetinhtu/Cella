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
    @State private var viewModel = PlayerViewModel()
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("colorSchemeOverride") private var schemeOverride: String = "system"

    private var effectiveColorScheme: ColorScheme {
        switch schemeOverride {
        case "dark": return .dark
        case "light": return .light
        default: return colorScheme
        }
    }

    private var preferredScheme: ColorScheme? {
        switch schemeOverride {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    private var theme: Theme { effectiveColorScheme == .dark ? .dark : .light }

    // MARK: - Body

    var body: some View {
        ZStack {
            theme.appBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top navigation bar
                TopTabBar(selectedTab: $selectedTab)
                    .padding(.top, 20)

                // Active tab content
                Group {
                    switch selectedTab {
                    case .feeds:
                        FeedsView(viewModel: viewModel)
                    case .cella:
                        CellaView(viewModel: viewModel)
                    case .config:
                        ConfigView(viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: effectiveColorScheme)
        .environment(\.theme, theme)
        .preferredColorScheme(preferredScheme)
        // Keyboard handling
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.space) {
            viewModel.togglePlayPause()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            viewModel.skipBackward()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            viewModel.skipForward()
            return .handled
        }
        .onAppear {
            isFocused = true
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .feeds {
                savedVolume = viewModel.currentVolume
                viewModel.setVolume(0.1)
            } else {
                viewModel.setVolume(savedVolume)
            }
            viewModel.setHallReverb(tab == .feeds)
        }
        .onTapGesture {
            // Re-focus when clicking the background so spacebar still works
            isFocused = true
        }
    }
}

#Preview {
    ContentView()
}
