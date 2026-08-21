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
                TopTabBar(selectedTab: $selectedTab)
                    .padding(.top, 20)

                Group {
                    switch selectedTab {
                    case .motions:
                        CellaMotionsView()
                    case .cella:
                        CellaView(viewModel: viewModel)
                    case .config:
                        ConfigView(viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Engine indicator — top-right
            if viewModel.playerState.isPlaying || viewModel.playerState == .autoMix {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(viewModel.activeEngine)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(viewModel.activeEngine == "OpenMix" ? .green : .orange)

                    if !viewModel.engineLog.isEmpty {
                        VStack(alignment: .trailing, spacing: 1) {
                            ForEach(Array(viewModel.engineLog.suffix(8).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 8, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.trailing, 16)
                .padding(.top, 50)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.4), value: viewModel.activeEngine)
                .animation(.easeInOut(duration: 0.3), value: viewModel.playerState.isPlaying)
                .animation(.easeInOut(duration: 0.25), value: viewModel.engineLog.count)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: effectiveColorScheme)
        .environment(\.theme, theme)
        .preferredColorScheme(preferredScheme)
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
            if tab == .motions {
                savedVolume = viewModel.currentVolume
                viewModel.setVolume(0.1)
            } else {
                viewModel.setVolume(savedVolume)
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
