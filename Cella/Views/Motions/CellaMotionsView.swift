//
//  CellaMotionsView.swift
//  Cella
//
//  Cella Motions — currently blank.
//

import SwiftUI

struct CellaMotionsView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack {
            Spacer()
            Text("Cella Motions")
                .font(.largeTitle)
                .foregroundStyle(theme.textPrimary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
