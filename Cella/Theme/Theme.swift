import SwiftUI

struct Theme {
    let dotInactive: Color
    let dotActive: Color
    let dotActiveGlow: Color
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
        dotActiveGlow: Color(hex: 0xFF5500),
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

    static let light = Theme(
        dotInactive: Color(hex: 0xD4C5B8),
        dotActive: Color(hex: 0xFF8038),
        dotActiveGlow: Color(hex: 0xFF5500),
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
