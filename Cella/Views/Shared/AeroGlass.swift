//
//  AeroGlass.swift
//  Cella
//
//  Frutiger Aero glass kit: frosted capsules/cards with aqua wash,
//  top gloss streak, and hairline highlight. Theme-aware.
//

import SwiftUI

/// Aqua anchor palette (classic Vista water-glass).
enum AeroAqua {
    static let washTop = Color(hex: 0x9BE8F5)
    static let washMid = Color(hex: 0x4FB9D9)
    static let washDeep = Color(hex: 0x1E6E8C)
    static let sparkle = Color.white
}

/// Glass button style: frosted capsule, gloss streak, hairline border.
/// Tints with the theme accent when prominent.
struct AeroButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false
    @State private var isHovering = false

    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? .white : theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(prominent ? theme.dotActive.opacity(0.85) : theme.textSecondary.opacity(0.14))
            )
            .background(
                Capsule().fill(.ultraThinMaterial.opacity(prominent ? 0.35 : 0.0))
            )
            .overlay(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(prominent ? 0.28 : 0.12), .white.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                Capsule()
                    .stroke(.white.opacity(prominent ? 0.35 : 0.14), lineWidth: 1)
            )
            .shadow(color: prominent ? theme.dotActive.opacity(0.3) : .clear, radius: 6)
            .scaleEffect(configuration.isPressed ? 0.95 : (isHovering ? 1.03 : 1.0))
            .animation(reduceMotion ? .none : .snappy, value: configuration.isPressed)
            .animation(reduceMotion ? .none : .snappy, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// Glass button style in recording red: frosted capsule, gloss streak,
/// hairline border. Idle shows theme text, recording fills red.
struct AeroRecordButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var recording: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(recording || configuration.isPressed ? .white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color.red.opacity(recording ? 0.85 : (configuration.isPressed ? 0.5 : 0.14)))
            )
            .overlay(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(recording ? 0.28 : 0.12), .white.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                Capsule()
                    .stroke(.white.opacity(recording ? 0.35 : 0.14), lineWidth: 1)
            )
            .shadow(color: recording ? Color.red.opacity(0.4) : .clear, radius: 6)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(reduceMotion ? .none : .snappy, value: configuration.isPressed)
            .animation(reduceMotion ? .none : .snappy, value: recording)
    }
}

extension View {
    /// Frosted glass card: blur material + aqua wash + gloss streak + border.
    func aeroCard(radius: CGFloat = CardStyle.radius, wash: Double = 0.10) -> some View {
        modifier(AeroCardModifier(radius: radius, wash: wash))
    }

    /// Top gloss streak (Frutiger shine): white gradient fading by 45% height.
    /// Never intercepts taps — decorative only.
    func aeroGloss(radius: CGFloat = CardStyle.radius, opacity: Double = 0.16) -> some View {
        overlay(
            GeometryReader { geo in
                LinearGradient(
                    colors: [.white.opacity(opacity), .white.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .center
                )
                .frame(height: geo.size.height * 0.48)
                .clipShape(RoundedRectangle(cornerRadius: radius))
            }
            .allowsHitTesting(false)
        )
    }
}

private struct AeroCardModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let radius: CGFloat
    let wash: Double

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // Frosted base
                    RoundedRectangle(cornerRadius: radius)
                        .fill(.ultraThinMaterial)
                    // Aqua wash (top-lit water tint)
                    RoundedRectangle(cornerRadius: radius)
                        .fill(
                            LinearGradient(
                                colors: [
                                    AeroAqua.washTop.opacity(wash),
                                    theme.dotActive.opacity(wash * 0.7),
                                    AeroAqua.washDeep.opacity(wash * 1.2)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    // Screen tint underneath for depth
                    RoundedRectangle(cornerRadius: radius)
                        .fill(theme.screenBackground.opacity(0.55))
                        .allowsHitTesting(false)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.35), .white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .aeroGloss(radius: radius)
    }
}
