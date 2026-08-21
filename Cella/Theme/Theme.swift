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

    static let light = Theme(
        dotInactive: Color(hex: 0xD4C5B8),
        dotActive: Color(hex: 0xFF8038),
        dotInactiveDeep: Color(hex: 0xF0EAE4),
        appBackground: Color(hex: 0xFFFFFF),
        screenBackground: Color(hex: 0xF5F0EB),
        tabBarBackground: Color(hex: 0xF5F0EB),
        tabSelectedBackground: Color(hex: 0xFF8038, opacity: 0.15),
        tabSelectedText: Color(hex: 0xFF8038),
        tabUnselectedText: Color(hex: 0x8B7355),
        textPrimary: Color(hex: 0x2D1F17),
        textSecondary: Color(hex: 0x7A6B5D)
    )

    static let lightSeafoam = Theme(
        dotInactive: Color(hex: 0xC5D8CE),
        dotActive: Color(hex: 0x1A8A52),
        dotInactiveDeep: Color(hex: 0xE4EDE8),
        appBackground: Color(hex: 0xFFFFFF),
        screenBackground: Color(hex: 0xECF5F0),
        tabBarBackground: Color(hex: 0xECF5F0),
        tabSelectedBackground: Color(hex: 0x1A8A52, opacity: 0.15),
        tabSelectedText: Color(hex: 0x1A8A52),
        tabUnselectedText: Color(hex: 0x5A7A6A),
        textPrimary: Color(hex: 0x1A2E24),
        textSecondary: Color(hex: 0x5A7A6A)
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
