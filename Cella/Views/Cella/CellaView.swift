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

                if !viewModel.currentLyrics.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            viewModel.lyricsMode.cycle()
                        }
                    } label: {
                        Image(systemName: viewModel.lyricsMode.iconName)
                            .font(.system(size: 14))
                            .foregroundStyle(
                                viewModel.lyricsMode != .off
                                    ? theme.dotActive
                                    : theme.textSecondary
                            )
                    }
                    .buttonStyle(.plain)
                    .help(viewModel.lyricsMode.label)
                }
            }

            Spacer()
        }
    }
}
