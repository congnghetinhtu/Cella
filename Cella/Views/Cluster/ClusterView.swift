//
//  ClusterView.swift
//  Cella
//
//  Cluster — manage artist/track clusters and playlists.
//

import SwiftUI

struct ClusterView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 24) {
            Text("Cluster")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)

            Text("Coming soon")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(theme.textSecondary)

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
