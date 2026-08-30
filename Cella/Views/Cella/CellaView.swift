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

            HStack(spacing: 14) {
                NowPlayingBar(viewModel: viewModel, selectedTab: .constant(.cella))
                AlbumPill(viewModel: viewModel)
            }

            Spacer()
        }
    }
}
