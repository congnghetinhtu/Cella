//
//  TextScroller.swift
//  Cella
//
//  Scrolls text across the 9×5 dot matrix grid.
//  Phase-aware: advances one column per bar boundary.
//

import Foundation

struct TextScroller {
    /// The column data for the full text (each entry = one column of 5 rows).
    let columns: [[Bool]]

    /// Total width of the text in columns.
    var totalWidth: Int { columns.count }

    /// Grid dimensions.
    let gridWidth = 9
    let gridHeight = 5

    // MARK: - Initialization

    /// Creates a scroller for the given text.
    /// Pads with trailing blanks so the text scrolls fully off screen.
    init(text: String) {
        var cols = PixelFont.columns(for: text)
        // Add blank columns so text can scroll off the right edge
        cols.append(contentsOf: [[Bool]](repeating: [Bool](repeating: false, count: 5), count: gridWidth))
        self.columns = cols
    }

    // MARK: - Frame Generation

    /// Returns the 9×5 grid pattern at the given scroll offset.
    /// The text enters from the right and exits to the left.
    func frame(at offset: Int) -> [[Bool]] {
        var grid = [[Bool]](repeating: [Bool](repeating: false, count: gridWidth), count: gridHeight)

        for col in 0..<gridWidth {
            let srcCol = offset + col
            if srcCol >= 0, srcCol < totalWidth {
                let columnData = columns[srcCol]
                for row in 0..<gridHeight {
                    grid[row][col] = columnData[row]
                }
            }
        }

        return grid
    }

    /// Advances the scroll offset by one column.
    /// Returns nil if the text has scrolled completely off screen.
    func advance(_ offset: Int) -> Int? {
        let newOffset = offset + 1
        // Stop when the entire text has scrolled past the left edge
        guard newOffset < totalWidth else { return nil }
        return newOffset
    }
}
