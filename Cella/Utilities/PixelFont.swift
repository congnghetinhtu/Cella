//
//  PixelFont.swift
//  Cella
//
//  3×5 bitmap pixel font for the 9×5 dot matrix display.
//  Each character is 3 columns wide, 5 rows tall.
//  Bit pattern: bit 2 = col 0, bit 1 = col 1, bit 0 = col 2.
//

import Foundation

enum PixelFont {
    /// Width of each character in columns.
    static let charWidth = 3

    /// Height of each character in rows (must match MatrixPatterns.rows).
    static let charHeight = 5

    /// Column spacing between characters.
    static let spacing = 1

    /// Returns the 5-row bitmap for a character, or nil if unsupported.
    static func glyph(for character: Character) -> [[Bool]]? {
        let upper = Character(character.uppercased())
        guard let bitmap = glyphs[upper] else { return nil }
        var result = [[Bool]]()
        for row in bitmap {
            var rowBools = [Bool]()
            for col in 0..<3 {
                rowBools.append((row >> (2 - col)) & 1 == 1)
            }
            result.append(rowBools)
        }
        return result
    }

    /// Converts a string to a flat column array (one Bool per row per column).
    /// Each character is 3 columns + 1 spacing column.
    static func columns(for text: String) -> [[Bool]] {
        var result = [[Bool]]()
        let chars = Array(text.uppercased())

        for (index, char) in chars.enumerated() {
            if let glyph = glyph(for: char) {
                // Transpose: glyph[row][col] → result[col][row]
                for col in 0..<charWidth {
                    var column = [Bool](repeating: false, count: charHeight)
                    for row in 0..<charHeight {
                        column[row] = glyph[row][col]
                    }
                    result.append(column)
                }
            }

            // Add spacing column between characters (not after last)
            if index < chars.count - 1 {
                result.append([Bool](repeating: false, count: charHeight))
            }
        }

        return result
    }

    // MARK: - Glyph Definitions

    /// Each entry: 5 rows, each row is a 3-bit pattern (bit 2=left, bit 1=center, bit 0=right).
    private static let glyphs: [Character: [UInt8]] = [
        "A": [0b010, 0b101, 0b111, 0b101, 0b101],
        "B": [0b110, 0b101, 0b110, 0b101, 0b110],
        "C": [0b011, 0b100, 0b100, 0b100, 0b011],
        "D": [0b110, 0b101, 0b101, 0b101, 0b110],
        "E": [0b111, 0b100, 0b110, 0b100, 0b111],
        "F": [0b111, 0b100, 0b110, 0b100, 0b100],
        "G": [0b011, 0b100, 0b101, 0b101, 0b011],
        "H": [0b101, 0b101, 0b111, 0b101, 0b101],
        "I": [0b111, 0b010, 0b010, 0b010, 0b111],
        "J": [0b001, 0b001, 0b001, 0b101, 0b010],
        "K": [0b101, 0b101, 0b110, 0b101, 0b101],
        "L": [0b100, 0b100, 0b100, 0b100, 0b111],
        "M": [0b101, 0b111, 0b111, 0b101, 0b101],
        "N": [0b101, 0b111, 0b111, 0b111, 0b101],
        "O": [0b010, 0b101, 0b101, 0b101, 0b010],
        "P": [0b110, 0b101, 0b110, 0b100, 0b100],
        "Q": [0b010, 0b101, 0b101, 0b110, 0b011],
        "R": [0b110, 0b101, 0b110, 0b101, 0b101],
        "S": [0b011, 0b100, 0b010, 0b001, 0b110],
        "T": [0b111, 0b010, 0b010, 0b010, 0b010],
        "U": [0b101, 0b101, 0b101, 0b101, 0b010],
        "V": [0b101, 0b101, 0b101, 0b010, 0b010],
        "W": [0b101, 0b101, 0b111, 0b111, 0b101],
        "X": [0b101, 0b101, 0b010, 0b101, 0b101],
        "Y": [0b101, 0b101, 0b010, 0b010, 0b010],
        "Z": [0b111, 0b001, 0b010, 0b100, 0b111],
        "0": [0b111, 0b101, 0b101, 0b101, 0b111],
        "1": [0b010, 0b110, 0b010, 0b010, 0b111],
        "2": [0b111, 0b001, 0b111, 0b100, 0b111],
        "3": [0b111, 0b001, 0b111, 0b001, 0b111],
        "4": [0b101, 0b101, 0b111, 0b001, 0b001],
        "5": [0b111, 0b100, 0b111, 0b001, 0b111],
        "6": [0b111, 0b100, 0b111, 0b101, 0b111],
        "7": [0b111, 0b001, 0b010, 0b010, 0b010],
        "8": [0b111, 0b101, 0b111, 0b101, 0b111],
        "9": [0b111, 0b101, 0b111, 0b001, 0b111],
        " ": [0b000, 0b000, 0b000, 0b000, 0b000],
        "-": [0b000, 0b000, 0b111, 0b000, 0b000],
        ".": [0b000, 0b000, 0b000, 0b000, 0b010],
        "'": [0b010, 0b010, 0b000, 0b000, 0b000],
        "!": [0b010, 0b010, 0b010, 0b000, 0b010],
        "&": [0b010, 0b101, 0b010, 0b101, 0b011],
        "#": [0b101, 0b111, 0b101, 0b111, 0b101],
    ]
}
