//
//  CellaView.swift
//  Cella
//
//  Main layout for the Cella tab — emotion screen + player indicator.
//

import SwiftUI

struct CellaView: View {
    var viewModel: PlayerViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            EmotionScreenView(
                pattern: viewModel.currentPattern,
                viewModel: viewModel
            )
            .padding(.horizontal, 80)

            HStack(spacing: 16) {
                PlayerIndicatorView(statusText: viewModel.statusText)

                Button {
                    withAnimation(.snappy) {
                        viewModel.lyricsMode.cycle()
                    }
                } label: {
                    Image(systemName: viewModel.lyricsMode.iconName)
                        .font(.system(size: 14))
                        .foregroundStyle(
                            viewModel.lyricsMode != .off
                                ? theme.dotActive
                                : viewModel.currentTrackHasLrc
                                    ? theme.textPrimary
                                    : theme.textSecondary
                        )
                }
                .buttonStyle(.plain)
                .help(viewModel.currentTrackHasLrc
                    ? viewModel.lyricsMode.label
                    : "No lyrics for this track")
                .keyboardShortcut("l", modifiers: [])
            }

            Spacer()
        }
    }
}
