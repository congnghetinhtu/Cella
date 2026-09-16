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

            CellaScreenView(
                pattern: viewModel.currentPattern,
                viewModel: viewModel
            )
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 12) {
                    ForEach(0..<5, id: \.self) { _ in
                        Circle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 15, height: 15)
                    }
                }
                .padding(.top, 12)
                .offset(y: -42)
            }
            .overlay {
                ZStack(alignment: .leading) {
                    Color.clear
                    VStack(spacing: 12) {
                        ForEach(0..<5, id: \.self) { _ in
                            Circle()
                                .fill(Color.white.opacity(0.9))
                                .frame(width: 15, height: 15)
                        }
                    }
                    .padding(.leading, 20)
                }
            }
            .padding(.horizontal, 80)

            HStack(spacing: 14) {
                NowPlayingBar(viewModel: viewModel, selectedTab: .constant(.cella))
                AlbumPill(viewModel: viewModel)
            }

            Spacer()
        }
    }
}