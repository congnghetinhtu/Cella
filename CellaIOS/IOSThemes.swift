//
//  IOSThemes.swift
//  CellaIOS
//
//  The white flip of the Frutiger look: tapping the playing pill fades the
//  backdrop to plain white, where text turns slate blue and icons/accents
//  wear the Frutiger blue→aqua gradient. Blue glass stays the default.
//

import SwiftUI

extension Theme {
    /// Frutiger by day — white background, slate text, aqua-blue accents.
    static let frutigerLight = Theme(
        dotInactive: Color(hex: 0xB9D6E8),
        dotActive: Color(hex: 0x1FA97C),
        dotInactiveDeep: Color(hex: 0x9CC4DD),
        appBackground: Color(hex: 0xF4F9FD),
        screenBackground: Color(hex: 0xFFFFFF),
        tabBarBackground: Color(hex: 0xFFFFFF),
        tabSelectedBackground: Color(hex: 0x1FA97C, opacity: 0.15),
        tabSelectedText: Color(hex: 0x1FA97C),
        tabUnselectedText: Color(hex: 0x8296A6),
        textPrimary: Color(hex: 0x1D3B54),
        textSecondary: Color(hex: 0x5F7A8F)
    )
}

/// The Frutiger vista gradient — sky blue into aqua green, worn by the
/// current lyric line in white mode.
enum FrutigerDay {
    static let gradient = LinearGradient(
        colors: [Color(hex: 0x3E9BD6), Color(hex: 0x3ED598)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
