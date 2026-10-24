//
//  MetroBackground.swift
//  Cella
//
//  Frutiger-Aero window backdrop: deep blue water world with a focused sun
//  glow, glass orbs, luminous grass, lily pads, drift leaves and bubbles.
//  Fixed palette (ignores theme); a fresh random composition per launch.
//
//  Alive but calm: the sun breathes, lily pads bob and slowly turn, drift
//  leaves cross the water, grass sways, glass orbs float and bubbles rise
//  with a lazy wobble. Motion renders at 30fps and freezes for Reduce
//  Motion or while the app is in the background.
//
//  Layered for cost: the full-screen gradients (water field + washes) and
//  the vignette live on static canvases — repainted only on layout change —
//  while the per-frame timeline canvas draws just the moving elements.
//  The vignette canvas sits above the motion layer so the original stacking
//  order is preserved. Lives at the window root behind everything — edges
//  stay dark so the UI keeps contrast.
//

import SwiftUI

struct MetroBackgroundView: View {
    /// Fresh composition per launch; stable for the whole session.
    @State private var seed: Int = Int.random(in: 0..<1_000_000_000)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var motionPaused: Bool {
        reduceMotion || scenePhase != .active
    }

    var body: some View {
        ZStack {
            MetroBaseCanvas(seed: seed)
            MetroMotionCanvas(seed: seed, paused: motionPaused)
            MetroVignetteCanvas()
        }
        .ignoresSafeArea()
    }
}

// MARK: - Static field (full-screen gradients, painted once per layout)

private struct MetroBaseCanvas: View {
    let seed: Int

    var body: some View {
        Canvas { context, size in
            MetroArt.paintBase(&context, size: size, seed: seed)
        }
    }
}

// MARK: - Calm motion (per-frame, capped at 30fps)

private struct MetroMotionCanvas: View {
    let seed: Int
    let paused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { timeline in
            Canvas { context, size in
                MetroArt.paintMotion(
                    &context,
                    size: size,
                    seed: seed,
                    time: timeline.date.timeIntervalSinceReferenceDate
                )
            }
        }
    }
}

// MARK: - Vignette (static overlay, keeps original z-order above motion)

private struct MetroVignetteCanvas: View {
    var body: some View {
        Canvas { context, size in
            MetroArt.paintVignette(&context, size: size)
        }
        .allowsHitTesting(false)
    }
}

private enum MetroArt {
    /// Deterministic pseudo-random in [0, 1) from seed + index.
    static func hash(_ seed: Int, _ i: Int) -> Double {
        var x = UInt64(bitPattern: Int64(seed &* 31 &+ i &* 2654435761 &+ 97))
        x ^= x >> 15
        x &*= 0x2C1B3C6D
        x ^= x >> 12
        return Double(x % 10000) / 10000.0
    }

    // MARK: - Time

    /// Seed-decorrelated animation clock (seconds). A per-launch offset
    /// makes every session's phases different even with the same seed.
    static func clock(_ time: TimeInterval, seed: Int) -> Double {
        time + Double(seed % 4096) * 0.37
    }

    /// Slow sine in [-1, 1] at `period` seconds with a phase offset.
    static func wave(_ t: Double, period: Double, phase: Double) -> Double {
        sin(t * 2 * .pi / period + phase)
    }

    // Palette: bright Windows-7 water blue + eco greens + aqua light.
    static let deepTop = Color(hex: 0x0E5FAE)
    static let deepBottom = Color(hex: 0x0E4E8E)
    static let waterMid = Color(hex: 0x2EA3E8)
    static let sunCore = Color(hex: 0xF2FBFF)
    static let aquaGlow = Color(hex: 0x6FD2F2)
    static let bladeBase = Color(hex: 0x15803D)
    static let bladeTip = Color(hex: 0xBBF7D0)

    // MARK: - Static base (water field + washes)

    static func paintBase(_ ctx: inout GraphicsContext, size: CGSize, seed: Int) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        let rect = CGRect(origin: .zero, size: size)

        // Deep ocean field — dark everywhere except the mid band.
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [
                .init(color: deepTop, location: 0.0),
                .init(color: waterMid, location: 0.48),
                .init(color: deepBottom, location: 1.0)
            ]),
            startPoint: CGPoint(x: w * 0.5, y: 0),
            endPoint: CGPoint(x: w * 0.5, y: h)
        ))

        // Green-teal wash low in the water for the eco feel.
        ctx.fill(Path(rect), with: .radialGradient(
            Gradient(colors: [Color(hex: 0x2FA36B).opacity(0.45), .clear]),
            center: CGPoint(x: w * (0.25 + hash(seed, 7) * 0.5), y: h * 0.88),
            startRadius: 0,
            endRadius: max(w, h) * 0.50
        ))
        // Faint secondary bloom elsewhere for balance.
        ctx.fill(Path(rect), with: .radialGradient(
            Gradient(colors: [aquaGlow.opacity(0.22), .clear]),
            center: CGPoint(x: w * hash(seed, 5), y: h * (0.55 + hash(seed, 6) * 0.3)),
            startRadius: 0,
            endRadius: max(w, h) * 0.22
        ))
    }

    // MARK: - Motion (one calm frame at a time)

    static func paintMotion(_ ctx: inout GraphicsContext, size: CGSize, seed: Int,
                            time: TimeInterval) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        let t = clock(time, seed: seed)
        let wD = Double(w)
        let hD = Double(h)

        // Sun — a slow breath with a whisper of drift. Filling only the
        // glow's own circle keeps the full-window gradient off the hot path.
        let glowX = wD * (0.35 + hash(seed, 1) * 0.40)
        let glowY = hD * (0.02 + hash(seed, 2) * 0.10)
        let glowBase = max(wD, hD) * (0.13 + hash(seed, 3) * 0.06)
        let breathe = 0.5 + 0.5 * wave(t, period: 16, phase: 0)
        let gx = glowX + wave(t, period: 31, phase: 1.3) * wD * 0.004
        let gy = glowY + wave(t, period: 37, phase: 2.1) * hD * 0.004
        let glowR = glowBase * (1 + 0.05 * breathe)
        let coreAlpha = 0.85 + 0.10 * breathe
        let glowCircle = Path(ellipseIn: CGRect(
            x: gx - glowR, y: gy - glowR, width: glowR * 2, height: glowR * 2
        ))
        ctx.fill(glowCircle, with: .radialGradient(
            Gradient(stops: [
                .init(color: sunCore.opacity(coreAlpha), location: 0.0),
                .init(color: sunCore.opacity(0.5), location: 0.10),
                .init(color: aquaGlow.opacity(0.30), location: 0.45),
                .init(color: .clear, location: 1.0)
            ]),
            center: CGPoint(x: gx, y: gy),
            startRadius: 0,
            endRadius: glowR
        ))

        // Lily pads — placed once from the seed (never overlapping), then
        // each pad bobs on the water and turns its notch on its own phase.
        let padCount = 2 + Int(hash(seed, 65) * 2)
        var placed: [(CGPoint, CGFloat)] = []
        var attempt = 0
        while placed.count < padCount && attempt < 16 {
            let cx = w * (0.10 + hash(seed, 4000 + attempt * 7) * 0.80)
            let cy = h * (0.72 + hash(seed, 4010 + attempt * 7) * 0.22)
            let r = min(w, h) * (0.045 + hash(seed, 4020 + attempt * 7) * 0.035)
            if placed.allSatisfy({ hypot($0.0.x - cx, $0.0.y - cy) > ($0.1 + r) * 1.3 }) {
                placed.append((CGPoint(x: cx, y: cy), r))
            }
            attempt += 1
        }
        for (idx, spot) in placed.enumerated() {
            let phase = hash(seed, 4040 + idx) * 2 * .pi
            let bobX = CGFloat(wave(t, period: 11, phase: phase)) * spot.1 * 0.05
            let bobY = CGFloat(wave(t, period: 9, phase: phase)) * spot.1 * 0.10
            let turn = wave(t, period: 13, phase: phase * 1.7) * 0.06
            paintLilyPad(
                &ctx,
                center: CGPoint(x: spot.0.x + bobX, y: spot.0.y + bobY),
                r: spot.1,
                seed: seed,
                index: idx,
                turn: turn
            )
        }

        // Drift leaves — a lazy crossing of the water with a gentle spin.
        for i in 0..<5 {
            let speed = 4 + hash(seed, 5040 + i) * 7          // pt/s
            let rightward = hash(seed, 5050 + i) < 0.5
            let margin = wD * 0.10
            let travel = wD + margin * 2
            let phase = hash(seed, 5060 + i) * travel
            let travelled = (t * speed + phase).truncatingRemainder(dividingBy: travel)
            let px = rightward ? -margin + travelled : wD + margin - travelled
            let phaseY = hash(seed, 5070 + i) * 2 * .pi
            let py = hD * (0.25 + hash(seed, 5010 + i) * 0.55)
                + wave(t, period: 8, phase: phaseY) * hD * 0.008
            let angle = (rightward ? 0.0 : Double.pi)
                + wave(t, period: 15, phase: phaseY * 1.9) * 0.20
            let leafLen = min(wD, hD) * (0.03 + hash(seed, 5020 + i) * 0.035)
            paintDriftLeaf(
                &ctx,
                center: CGPoint(x: px, y: py),
                angle: angle,
                leafLen: leafLen,
                index: i
            )
        }

        // Luminous grass — anchored at the bottom, tips swaying in the water.
        let grassCount = 12 + Int(hash(seed, 70) * 8)
        for i in 0..<grassCount {
            let phase = hash(seed, 3400 + i) * 2 * .pi
            let period = 5 + hash(seed, 3450 + i) * 4
            let amp = w * (0.003 + hash(seed, 3460 + i) * 0.005)
            let sway = CGFloat(wave(t, period: period, phase: phase)) * amp
            paintBlade(&ctx, w: w, h: h, seed: seed, index: i, swayX: sway)
        }

        // A few crisp glass orbs — drifting on tiny, almost weightless orbits.
        let orbCount = 4 + Int(hash(seed, 90) * 3)
        for i in 0..<orbCount {
            let cx = hash(seed, 100 + i) * wD
            let cy = hD * (0.15 + hash(seed, 200 + i) * 0.60)
            let r = 6 + hash(seed, 300 + i) * 20
            let phase = hash(seed, 520 + i) * 2 * .pi
            let amp = r * 0.30
            let dx = wave(t, period: 12 + hash(seed, 530 + i) * 6, phase: phase) * amp
            let dy = wave(t, period: 13 + hash(seed, 540 + i) * 6, phase: phase * 1.6) * amp
            glassOrb(
                &ctx,
                center: CGPoint(x: cx + dx, y: cy + dy),
                r: r,
                alpha: 0.55 + hash(seed, 500 + i) * 0.45
            )
        }

        // Bubble rings clustered near the light, sparse elsewhere — rising
        // slowly with a lazy side-wobble, fading in at the bottom and out
        // at the top so the wrap never pops.
        let bubbleCount = 18 + Int(hash(seed, 600) * 14)
        let margin = hD * 0.06
        for i in 0..<bubbleCount {
            let nearGlow = hash(seed, 605 + i) < 0.7
            let x: Double
            if nearGlow {
                let gxr = (hash(seed, 610 + i) + hash(seed, 615 + i)) / 2
                x = glowX + (gxr - 0.5) * wD * 0.7
            } else {
                x = hash(seed, 610 + i) * wD
            }
            let r = 1.5 + hash(seed, 810 + i) * 5
            var alpha = 0.14 + hash(seed, 910 + i) * 0.30
            let period = 60 + hash(seed, 920 + i) * 80           // seconds per rise
            let phase = hash(seed, 930 + i)
            let p = ((t / period) + phase).truncatingRemainder(dividingBy: 1)
            let y = (hD + margin) - p * (hD + margin * 2)
            let wobble = wave(t, period: 9, phase: hash(seed, 940 + i) * 2 * .pi) * 4
            let fadeIn = min(1.0, p / 0.08)
            let fadeOut = min(1.0, (1 - p) / 0.08)
            alpha *= max(0, min(fadeIn, fadeOut))

            let tinted = hash(seed, 915 + i)
            let ringColor: Color
            if tinted < 0.35 {
                ringColor = Color(hex: 0xB6F09C)
            } else if tinted < 0.55 {
                ringColor = Color(hex: 0x9BE8F5)
            } else {
                ringColor = .white
            }
            let ring = Path(ellipseIn: CGRect(
                x: x + wobble - r, y: y - r, width: r * 2, height: r * 2
            ))
            ctx.stroke(ring, with: .color(ringColor.opacity(alpha)), lineWidth: 1.2)
        }
    }

    // MARK: - Vignette

    /// Gentle vignette in deep blue (not black) so the scene stays bright
    /// while edges still anchor text. Drawn above the motion layer.
    static func paintVignette(_ ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
            Gradient(colors: [.clear, Color(hex: 0x02122E).opacity(0.28)]),
            center: CGPoint(x: w * 0.5, y: h * 0.45),
            startRadius: min(w, h) * 0.35,
            endRadius: max(w, h) * 0.75
        ))
    }

    // MARK: - Grass blade

    /// Tapered luminous blade rising from the bottom edge. `swayX` bends the
    /// tip (and half as much the control point) for the water current.
    static func paintBlade(_ ctx: inout GraphicsContext, w: CGFloat, h: CGFloat,
                           seed: Int, index i: Int, swayX: CGFloat = 0) {
        let bx = hash(seed, 3000 + i) * w
        let height = h * (0.10 + hash(seed, 3100 + i) * 0.24)
        let lean = (hash(seed, 3200 + i) - 0.5) * w * 0.10
        let baseW = 6 + hash(seed, 3300 + i) * 11
        let base = CGPoint(x: bx, y: h + 4)
        let tip = CGPoint(x: bx + lean + swayX, y: h - height)
        let ctrl = CGPoint(x: bx + lean * 0.2 + swayX * 0.5, y: h - height * 0.55)
        let steps = 12
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for s in 0...steps {
            let f = Double(s) / Double(steps)
            let mt = 1 - f
            let x = mt * mt * base.x + 2 * mt * f * ctrl.x + f * f * tip.x
            let y = mt * mt * base.y + 2 * mt * f * ctrl.y + f * f * tip.y
            let dx = 2 * mt * (ctrl.x - base.x) + 2 * f * (tip.x - ctrl.x)
            let dy = 2 * mt * (ctrl.y - base.y) + 2 * f * (tip.y - ctrl.y)
            let len = max(1, sqrt(dx * dx + dy * dy))
            let half = baseW * 0.5 * pow(1 - f, 0.7)
            left.append(CGPoint(x: x - dy / len * half, y: y + dx / len * half))
            right.append(CGPoint(x: x + dy / len * half, y: y - dx / len * half))
        }
        var path = Path()
        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        for p in right.reversed() { path.addLine(to: p) }
        path.closeSubpath()
        ctx.fill(path, with: .linearGradient(
            Gradient(colors: [bladeBase.opacity(0.9), bladeTip.opacity(0.75)]),
            startPoint: CGPoint(x: bx, y: h),
            endPoint: CGPoint(x: tip.x, y: tip.y)
        ))
    }

    // MARK: - Lily pad

    /// Small glossy eco pad with a notch, highlight streak and rim light.
    /// `turn` rotates the notch/gloss (radians) — the pad reads as turning
    /// on the water without the cost of a transform layer per frame.
    static func paintLilyPad(_ ctx: inout GraphicsContext, center: CGPoint, r: CGFloat,
                             seed: Int, index i: Int, turn: Double = 0) {
        let cx = center.x, cy = center.y
        let notch = hash(seed, 4030 + i) * 6.28 + turn
        let notchHalf = 0.11
        var pad = Path()
        pad.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                   startAngle: Angle(radians: notch + notchHalf),
                   endAngle: Angle(radians: notch - notchHalf + 6.28), clockwise: false)
        pad.addLine(to: CGPoint(x: cx, y: cy))
        pad.closeSubpath()
        ctx.fill(pad, with: .radialGradient(
            Gradient(colors: [
                Color(hex: 0x86EFAC).opacity(0.95),
                Color(hex: 0x22C55E).opacity(0.9),
                Color(hex: 0x15803D).opacity(0.92)
            ]),
            center: CGPoint(x: cx - r * 0.25, y: cy - r * 0.3),
            startRadius: 0,
            endRadius: r * 1.25
        ))
        ctx.stroke(pad, with: .color(.white.opacity(0.5)), lineWidth: 1.5)
        // Gloss streak hugging the pad's upper curve, clear of the notch.
        let glossAngle = notch + 0.9
        var gloss = Path()
        gloss.move(to: CGPoint(
            x: cx + cos(glossAngle - 0.45) * r * 0.62,
            y: cy + sin(glossAngle - 0.45) * r * 0.62
        ))
        gloss.addQuadCurve(
            to: CGPoint(
                x: cx + cos(glossAngle + 0.45) * r * 0.62,
                y: cy + sin(glossAngle + 0.45) * r * 0.62
            ),
            control: CGPoint(
                x: cx + cos(glossAngle) * r * 0.78,
                y: cy + sin(glossAngle) * r * 0.78
            )
        )
        ctx.stroke(gloss, with: .color(.white.opacity(0.45)),
                   style: StrokeStyle(lineWidth: r * 0.09, lineCap: .round))
        // Center bud.
        let br = r * 0.10
        let bud = Path(ellipseIn: CGRect(x: cx - br, y: cy - br, width: br * 2, height: br * 2))
        ctx.fill(bud, with: .color(Color(hex: 0xF0FDF4).opacity(0.95)))
    }

    // MARK: - Drift leaf

    /// Single pointed-oval leaf floating mid-water, drawn from `center`
    /// along `angle`.
    static func paintDriftLeaf(_ ctx: inout GraphicsContext, center: CGPoint,
                               angle: Double, leafLen: Double, index i: Int) {
        let px = center.x, py = center.y
        let tip = CGPoint(
            x: px + CGFloat(cos(angle) * leafLen),
            y: py + CGFloat(sin(angle) * leafLen)
        )
        let leafW = CGFloat(leafLen * 0.40)
        let mx = (px + tip.x) / 2, my = (py + tip.y) / 2
        let nx = -(tip.y - py), ny = tip.x - px
        let nl = max(1, sqrt(nx * nx + ny * ny))
        var leaf = Path()
        leaf.move(to: CGPoint(x: px, y: py))
        leaf.addQuadCurve(
            to: tip,
            control: CGPoint(x: mx + nx / nl * leafW, y: my + ny / nl * leafW)
        )
        leaf.addQuadCurve(
            to: CGPoint(x: px, y: py),
            control: CGPoint(x: mx - nx / nl * leafW, y: my - ny / nl * leafW)
        )
        leaf.closeSubpath()
        let green = i % 2 == 0 ? Color(hex: 0x86EFAC) : Color(hex: 0x4ADE80)
        ctx.fill(leaf, with: .color(green.opacity(0.85)))
        ctx.stroke(leaf, with: .color(.white.opacity(0.3)), lineWidth: 1)
    }

    // MARK: - Glass orb

    /// Small crisp droplet: bright offset core fading fast to aqua, hard rim.
    static func glassOrb(_ ctx: inout GraphicsContext, center: CGPoint, r: CGFloat, alpha: Double) {
        let ball = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                          width: r * 2, height: r * 2))
        ctx.fill(ball, with: .radialGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.75 * alpha), location: 0.0),
                .init(color: aquaGlow.opacity(0.30 * alpha), location: 0.35),
                .init(color: aquaGlow.opacity(0.05 * alpha), location: 1.0)
            ]),
            center: CGPoint(x: center.x - r * 0.25, y: center.y - r * 0.3),
            startRadius: 0,
            endRadius: r
        ))
        ctx.stroke(ball, with: .color(.white.opacity(0.55 * alpha)), lineWidth: max(1, r * 0.05))
        let hr = r * 0.20
        let spec = Path(ellipseIn: CGRect(
            x: center.x - r * 0.40 - hr, y: center.y - r * 0.46 - hr,
            width: hr * 2, height: hr * 2
        ))
        ctx.fill(spec, with: .color(.white.opacity(0.9 * alpha)))
    }
}
