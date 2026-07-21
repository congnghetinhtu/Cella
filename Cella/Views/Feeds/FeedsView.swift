//
//  FeedsView.swift
//  Cella
//
//  Bento grid layout: epub library, mini reader, music indicator, water reminder.
//

import SwiftUI

struct FeedsView: View {
    var viewModel: PlayerViewModel
    @State private var feedsVM = FeedsViewModel()
    @Environment(\.theme) private var theme

    private let gridSpacing: CGFloat = 16
    private let rightColumnWidth: CGFloat = 300

    var body: some View {
        ScrollView {
            VStack(spacing: gridSpacing) {
                EpubDropZone(feedsVM: feedsVM)

                HStack(alignment: .top, spacing: gridSpacing) {
                    MiniReaderView(feedsVM: feedsVM)

                    VStack(spacing: gridSpacing) {
                        MusicIndicatorView(viewModel: viewModel)
                        WaterReminderView(feedsVM: feedsVM)
                    }
                    .frame(width: rightColumnWidth)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
    }
}
