//
//  DotMatrixView.swift
//  Cella
//
//  Renders the 9×5 dot grid for the emotion screen.
//  Supports static display, breathing animation, analyzing pulse, and crossfade blend.
//

import SwiftUI

struct DotMatrixView: View {
    let pattern: [[Bool]]
    @Environment(\.theme) private var theme

    private let dotSize: CGFloat = 36
    private let dotSpacing: CGFloat = 24

    // MARK: - Body

    var body: some View {
        let rows = pattern.count
        let columns = pattern.map { $0.count }.max() ?? 0

        VStack(spacing: dotSpacing) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: dotSpacing) {
                    ForEach(0..<columns, id: \.self) { col in
                        dotView(isActive: col < pattern[row].count ? pattern[row][col] : false, row: row, col: col)
                    }
                }
            }
        }
        .drawingGroup()
    }

    // MARK: - Dot View

    @ViewBuilder
    private func dotView(isActive: Bool, row: Int = 0, col: Int = 0) -> some View {
        Circle()
            .fill(isActive ? theme.trailColorCycle(at: Double(row * 5 + col) / 25.0) : theme.dotInactive)
            .frame(width: dotSize, height: dotSize)
            .opacity(isActive ? 0.9 : 0.6)
            .animation(.snappy, value: isActive)
    }

}
