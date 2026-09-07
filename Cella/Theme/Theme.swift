import SwiftUI

struct Theme {
    let dotInactive: Color
    let dotActive: Color
    let dotInactiveDeep: Color
    let appBackground: Color
    let screenBackground: Color
    let tabBarBackground: Color
    let tabSelectedBackground: Color
    let tabSelectedText: Color
    let tabUnselectedText: Color
    let textPrimary: Color
    let textSecondary: Color

    var isColorful: Bool { dotActive == Color(hex: 0xFF5C8A) }

    /// Halo / glow colors — adapt to theme
    var haloPrimary: Color { isColorful ? Color(hex: 0xFF7EB3) : Color(hex: 0x4ADE80) }    // pink vs green
    var haloSecondary: Color { isColorful ? Color(hex: 0x8B7EFA) : Color(hex: 0x6EE7B7) }  // lavender vs mint
    var haloAccent: Color { isColorful ? Color(hex: 0x56CCF2) : Color(hex: 0xFACC15) }     // sky blue vs yellow
    var haloWarm: Color { isColorful ? Color(hex: 0xFF9A5C) : Color(hex: 0xFB923C) }       // tangerine vs orange

    /// Trail / star color palette per theme
    var trailPalette: [Color] {
        switch dotActive {
        case Color(hex: 0xFF8038): // dark — warm fire
            return [Color(hex: 0xFF8038), Color(hex: 0xFFAA33), Color(hex: 0xFF5533), Color(hex: 0xFFCC44), Color(hex: 0xFF6622)]
        case Color(hex: 0x93E9BE): // seafoam — ocean
            return [Color(hex: 0x93E9BE), Color(hex: 0x5EEAD4), Color(hex: 0x67E8F9), Color(hex: 0x4ADE80), Color(hex: 0x2DD4BF)]
        case Color(hex: 0xFF5C8A): // bipolar — pastel rainbow
            return [Color(hex: 0xFF7EB3), Color(hex: 0xFF9A5C), Color(hex: 0x8B7EFA), Color(hex: 0x56CCF2), Color(hex: 0x6FCF97)]
        default:
            return [dotActive]
        }
    }

    /// Smoothly interpolated trail color at position 0–1 across the palette.
    func trailColorSmooth(at t: Double) -> Color {
        let palette = trailPalette
        guard palette.count > 1 else { return palette.first ?? dotActive }
        let scaled = t * Double(palette.count - 1)
        let idx = Int(scaled)
        let frac = scaled - Double(idx)
        guard idx < palette.count - 1 else { return palette.last! }
        return palette[idx].mix(with: palette[idx + 1], by: frac)
    }

    /// Returns a cycling accent color from the palette at position 0–1.
    func trailColorCycle(at t: Double) -> Color {
        let palette = trailPalette
        let idx = Int(t * Double(palette.count)) % palette.count
        return palette[idx]
    }

    /// Multi-color per tab — each tab gets a distinct color (Colorful theme only).
    var tabColors: [Color] { isColorful ? trailPalette : [tabSelectedText] }

    func tabColor(for index: Int) -> Color {
        let colors = tabColors
        return colors[index % colors.count]
    }

    /// Lyric line color — shifts through palette per line index (Colorful theme only).
    func lyricColor(for lineIndex: Int) -> Color {
        guard isColorful else { return dotActive }
        return trailColorCycle(at: Double(lineIndex % trailPalette.count) / Double(trailPalette.count))
    }

    static let dark = Theme(
        dotInactive: Color(hex: 0x3E2D24),
        dotActive: Color(hex: 0xFF8038),
        dotInactiveDeep: Color(hex: 0x231A16),
        appBackground: Color(hex: 0x0D0D0D),
        screenBackground: Color(hex: 0x231A16),
        tabBarBackground: Color(hex: 0x231A16),
        tabSelectedBackground: Color(hex: 0xFF8038, opacity: 0.2),
        tabSelectedText: Color(hex: 0xFF8038),
        tabUnselectedText: Color(hex: 0x6B4F3A),
        textPrimary: Color(hex: 0xD9D9D9),
        textSecondary: Color(hex: 0x666666)
    )

    static let seafoam = Theme(
        dotInactive: Color(hex: 0x2D3A33),
        dotActive: Color(hex: 0x93E9BE),
        dotInactiveDeep: Color(hex: 0x1A2420),
        appBackground: Color(hex: 0x0D1210),
        screenBackground: Color(hex: 0x1A2420),
        tabBarBackground: Color(hex: 0x1A2420),
        tabSelectedBackground: Color(hex: 0x93E9BE, opacity: 0.2),
        tabSelectedText: Color(hex: 0x93E9BE),
        tabUnselectedText: Color(hex: 0x5A7A6A),
        textPrimary: Color(hex: 0xD9E8E0),
        textSecondary: Color(hex: 0x668878)
    )

    static let bipolar = Theme(
        dotInactive: Color(hex: 0x1E1830),
        dotActive: Color(hex: 0xFF5C8A),
        dotInactiveDeep: Color(hex: 0x0E0B1A),
        appBackground: Color(hex: 0x080612),
        screenBackground: Color(hex: 0x14102A),
        tabBarBackground: Color(hex: 0x14102A),
        tabSelectedBackground: Color(hex: 0xFF5C8A, opacity: 0.2),
        tabSelectedText: Color(hex: 0xFF5C8A),
        tabUnselectedText: Color(hex: 0x6A5B88),
        textPrimary: Color(hex: 0xFFF0F5),
        textSecondary: Color(hex: 0x998AAA)
    )
}

struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.dark
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Unified Animation Curves

extension Animation {
    /// Fast UI interactions (button taps, tab switches, hovers)
    static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.8)

    /// Content transitions (theme changes, image crossfades, blur)
    static let smooth = Animation.spring(response: 0.35, dampingFraction: 0.85)

    /// Lyrics line transitions (scroll, fade, depth-of-field)
    static let lyricsSpring = Animation.interpolatingSpring(stiffness: 60, damping: 18)
}
