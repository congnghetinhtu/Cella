//
//  AquaView.swift
//  Cella
//
//  Frutiger Aero water: layered blobs + glossy hero bubbles, theme-colored,
//  energy-reactive. Replaces DotMatrix.
//

import SwiftUI

struct AquaView: View {
    var viewModel: PlayerViewModel?
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Blob: Hashable {
        let anchorX: Double
        let anchorY: Double
        let seedA: Double
        let seedB: Double
        let speed: Double
        let baseR: Double
        let paletteIndex: Double
    }

    /// Frutiger Aero hero bubbles: big, depth-layered, glossy. Few, not many.
    private struct Bubble: Hashable {
        let x0: Double
        let rise: Double
        let size: Double
        let phase: Double
        let wobble: Double
        let depth: Double
    }

    private var bubbles: [Bubble] {
        [
            Bubble(x0: 0.14, rise: 0.026, size: 68, phase: 0.0, wobble: 14, depth: 1.0),
            Bubble(x0: 0.38, rise: 0.040, size: 44, phase: 0.35, wobble: 10, depth: 0.7),
            Bubble(x0: 0.60, rise: 0.022, size: 84, phase: 0.6, wobble: 16, depth: 1.0),
            Bubble(x0: 0.78, rise: 0.036, size: 52, phase: 0.2, wobble: 12, depth: 0.8),
            Bubble(x0: 0.90, rise: 0.024, size: 72, phase: 0.75, wobble: 15, depth: 0.9),
            Bubble(x0: 0.28, rise: 0.033, size: 36, phase: 0.9, wobble: 9, depth: 0.6),
        ]
    }

    private var blobs: [Blob] {
        [
            Blob(anchorX: 0.24, anchorY: 0.34, seedA: 0.0, seedB: 1.7, speed: 0.21, baseR: 0.28, paletteIndex: 0.0),
            Blob(anchorX: 0.76, anchorY: 0.30, seedA: 2.1, seedB: 0.4, speed: 0.16, baseR: 0.24, paletteIndex: 0.35),
            Blob(anchorX: 0.28, anchorY: 0.70, seedA: 4.2, seedB: 3.1, speed: 0.26, baseR: 0.22, paletteIndex: 0.65),
            Blob(anchorX: 0.74, anchorY: 0.68, seedA: 1.2, seedB: 5.0, speed: 0.12, baseR: 0.30, paletteIndex: 0.85),
        ]
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let energy = Double(viewModel?.currentEnergyValue ?? 0.3)
            let playing = viewModel?.playerState.isPlaying ?? false
                || viewModel?.playerState == .autoMix
            let motion: Double = reduceMotion ? 0 : 1
            let amp = 0.32 + energy * 0.18
            ZStack {
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    let unit = min(size.width, size.height)
                    var context = context
                    context.addFilter(.blur(radius: 28))
                    for blob in blobs {
                        let tt = reduceMotion ? 0 : t * blob.speed * motion
                        // Tight orbit around quadrant anchor — blobs never meet.
                        let ox = sin(tt + blob.seedA) * 0.05 + sin(tt * 0.63 + blob.seedB) * 0.025
                        let oy = cos(tt * 0.9 + blob.seedB) * 0.05 + cos(tt * 0.57 + blob.seedA) * 0.025
                        let x = (blob.anchorX + CGFloat(ox) * amp) * size.width
                        let y = (blob.anchorY + CGFloat(oy) * amp) * size.height
                        let pulse = 1 + (playing ? energy * 0.35 * sin(t * 2.2 + blob.seedA) : 0.06 * sin(t * 0.8 + blob.seedA))
                        let r = unit * blob.baseR * pulse
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        // Balanced wash — visible tint, CMA still shows through.
                        let color = theme.trailColorSmooth(at: blob.paletteIndex).opacity(playing ? 0.20 : 0.12)
                        context.fill(Path(ellipseIn: rect), with: .color(color))
                    }
                }
                // Sharp glossy hero bubbles (Frutiger Aero): natural layered drift,
                // depth-scaled size/speed/alpha, full gloss kit per bubble.
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    let tt = reduceMotion ? 0 : t
                    // Far → near so near bubbles overlap correctly.
                    for bubble in bubbles.sorted(by: { $0.depth < $1.depth }) {
                        let rise = bubble.rise * (0.5 + energy * 1.1) * bubble.depth * motion
                        var yFrac = 1.08 - ((tt * rise + bubble.phase).truncatingRemainder(dividingBy: 1.2))
                        if yFrac < -0.06 { yFrac += 1.2 }
                        let edgeFade = min(1.0, max(0.0, min(yFrac / 0.14, (1.14 - yFrac) / 0.14)))
                        // Layered natural drift: slow sway + faster shimmer, eased by depth.
                        let sway = sin(tt * 0.5 + bubble.phase * 6.28) * bubble.wobble
                            + sin(tt * 1.3 + bubble.phase * 12.0) * bubble.wobble * 0.25
                        let x = bubble.x0 * size.width + CGFloat(sway * bubble.depth * motion)
                        let y = yFrac * size.height
                        let r = CGFloat(bubble.size) * (0.55 + 0.45 * bubble.depth) * (0.85 + energy * 0.3)
                        let alpha = (playing ? 0.55 : 0.34) * (0.45 + 0.55 * bubble.depth) * edgeFade
                        guard alpha > 0.01 else { continue }
                        // Soap-film iridescence: hue drifts with time, sweeps across rim.
                        let hueT = (bubble.phase + (reduceMotion ? 0 : t * 0.03)).truncatingRemainder(dividingBy: 1.0)
                        let irid = theme.trailColorSmooth(at: hueT >= 0 ? hueT : hueT + 1)
                        let body = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                        // Aqua glass fill first (depth-tinted)
                        context.fill(
                            body,
                            with: .radialGradient(
                                Gradient(colors: [
                                    irid.opacity(alpha * 0.20),
                                    .white.opacity(alpha * 0.05)
                                ]),
                                center: CGPoint(x: x - r * 0.2, y: y - r * 0.25),
                                startRadius: 0,
                                endRadius: r * 1.1
                            )
                        )
                        // Iridescent rim
                        context.stroke(
                            body,
                            with: .linearGradient(
                                Gradient(colors: [
                                    .white.opacity(alpha),
                                    irid.opacity(alpha * 0.9),
                                    .white.opacity(alpha * 0.7)
                                ]),
                                startPoint: CGPoint(x: x - r, y: y - r),
                                endPoint: CGPoint(x: x + r, y: y + r)
                            ),
                            lineWidth: max(1.5, r * 0.07)
                        )
                        // Big soft specular (top-left gloss)
                        let hr = r * 0.30
                        let hx = x - r * 0.30
                        let hy = y - r * 0.36
                        context.fill(
                            Path(ellipseIn: CGRect(x: hx - hr, y: hy - hr * 0.7, width: hr * 2, height: hr * 1.4)),
                            with: .radialGradient(
                                Gradient(colors: [.white.opacity(alpha * 0.95), .white.opacity(0)]),
                                center: CGPoint(x: hx, y: hy),
                                startRadius: 0,
                                endRadius: hr
                            )
                        )
                        // Bottom bounce light (Frutiger depth cue)
                        var bounce = Path()
                        bounce.addArc(center: CGPoint(x: x, y: y), radius: r * 0.82,
                                      startAngle: .degrees(35), endAngle: .degrees(145), clockwise: false)
                        context.stroke(
                            bounce,
                            with: .color(.white.opacity(alpha * 0.35)),
                            lineWidth: max(1, r * 0.05)
                        )
                    }
                }
            }
        }
    }
}
