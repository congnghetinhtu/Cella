//
//  PlayerIndicatorView.swift
//  Cella
//
//  Shows subtle status text below the emotion screen
//  ("Music Playing" / "Music Paused" / nothing).
//

import SwiftUI

struct PlayerIndicatorView: View {
    let statusText: String?
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            if let text = statusText {
                Text(text)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(theme.textSecondary)
                    .transition(.opacity)
            }
        }
        .frame(height: 20)
        .animation(.snappy, value: statusText)
    }
}
