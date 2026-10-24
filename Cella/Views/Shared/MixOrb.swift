//
//  MixOrb.swift
//  Cella
//
//  Signature Cella mixing orb — hero gloss bubble + two satellite sparks.
//  Replaces system spinners so loading states feel on-brand.
//  Same tempo family as the pill/screen orbs (0.35 / -0.25 rev/s).
//

import SwiftUI

struct MixOrbView: View {
    let theme: Theme
    var diameter: CGFloat = 46
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = reduceMotion ? 0 : sin(t * 2 * .pi * 0.35)
            let heroD: CGFloat = diameter * (1 + pulse * 0.06)
            let a1 = reduceMotion ? 0.8 : (t * 0.35 * 2 * .pi)
            let a2 = reduceMotion ? 2.4 : (-t * 0.25 * 2 * .pi + 2.1)
            let cx: CGFloat = diameter * 1.04
            let cy: CGFloat = diameter * 0.65
            let s1 = CGPoint(x: cx + cos(a1) * diameter * 0.78, y: cy + sin(a1) * diameter * 0.46)
            let s2 = CGPoint(x: cx + cos(a2) * diameter * 0.54, y: cy + sin(a2) * diameter * 0.33)

            ZStack {
                Circle()
                    .fill(theme.dotActive.opacity(0.30))
                    .frame(width: diameter * 1.43, height: diameter * 1.43)
                    .blur(radius: 8)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                .white.opacity(0.95),
                                theme.dotActive.opacity(0.9),
                                theme.haloSecondary.opacity(0.55)
                            ],
                            center: .init(x: 0.35, y: 0.3),
                            startRadius: 0,
                            endRadius: heroD * 0.7
                        )
                    )
                    .frame(width: heroD, height: heroD)
                    .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1.2))
                    .overlay(
                        Ellipse()
                            .fill(.white.opacity(0.9))
                            .frame(width: heroD * 0.34, height: heroD * 0.22)
                            .offset(x: -heroD * 0.12, y: -heroD * 0.22)
                    )
                    .shadow(color: theme.dotActive.opacity(0.6), radius: 10)
                Circle()
                    .fill(.white.opacity(0.95))
                    .frame(width: max(4, diameter * 0.15), height: max(4, diameter * 0.15))
                    .shadow(color: theme.dotActive.opacity(0.8), radius: 4)
                    .position(s1)
                Circle()
                    .fill(theme.haloSecondary.opacity(0.9))
                    .frame(width: max(3, diameter * 0.11), height: max(3, diameter * 0.11))
                    .shadow(color: theme.haloSecondary.opacity(0.7), radius: 3)
                    .position(s2)
            }
            .frame(width: diameter * 2.1, height: diameter * 1.3)
        }
    }
}
