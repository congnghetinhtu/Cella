import SwiftUI
import Combine
import CoreGraphics

struct LineAnimationView: View {
    let viewModel: PlayerViewModel
    @Environment(\.theme) private var theme

    @State private var path: Path = Path()
    @State private var headPosition: Double = 0
    @State private var lastUpdate: CFTimeInterval = 0
    @State private var previousSeed: Int = 0
    @State private var viewSize: CGSize = .zero
    @State private var tick: UInt = 0
    @State private var stars: [Star] = []
    @State private var starStartTime: Date = Date()
    private let segmentCount = 8
    private let starCount = 4
    private let displayLink = DisplayLink.shared

    private struct Star {
        let normX: Double
        let normY: Double
        let angle: Double
        let driftSpeed: Double
        let size: CGFloat
        let phase: Double
        let twinkleSpeed: Double
    }

    private var trackSeed: Int {
        viewModel.mixQueue?.currentTrack?.url.absoluteString.hash ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if viewModel.playerState.isPlaying || viewModel.playerState == .autoMix {
                    trailCanvas
                } else {
                    idleTrailView
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .onAppear {
                viewSize = geo.size
                regeneratePath()
                regenerateStars(seed: trackSeed)
                lastUpdate = CACurrentMediaTime()
                previousSeed = trackSeed
            }
            .onChange(of: trackSeed) { _, newSeed in
                guard newSeed != previousSeed else { return }
                previousSeed = newSeed
                regeneratePath()
                regenerateStars(seed: trackSeed)
                headPosition = 0
            }
            .onChange(of: geo.size) { _, newSize in
                viewSize = newSize
                regeneratePath()
                regenerateStars(seed: trackSeed)
            }
            .onChange(of: viewModel.isAnimationPaused) { _, paused in
                if paused {
                    displayLink.stop()
                } else {
                    displayLink.start()
                }
            }
        }
        .onReceive(displayLink.framePublisher) { now in
            guard viewModel.playerState.isPlaying || viewModel.playerState == .autoMix,
                  !viewModel.isAnimationPaused else {
                lastUpdate = now
                return
            }
            let dt = min(now - lastUpdate, 0.12)
            lastUpdate = now
            let energy = Double(viewModel.currentEnergyValue)
            let speed = 0.1 + energy * 0.4
            headPosition += dt * speed
            if headPosition >= 1.0 {
                headPosition = 0
                regeneratePath()
            }
            tick &+= 1
        }
        .onAppear {
            if !(viewModel.isAnimationPaused) {
                displayLink.start()
            }
        }
        .onDisappear { displayLink.stop() }
    }

    // MARK: - Trail Views

    private var trailCanvas: some View {
        let _ = tick
        let energy = Double(viewModel.currentEnergyValue)
        let trailLen = 0.15 + energy * 0.15
        let activeColor = theme.dotActive
        return Canvas { context, size in
            drawStars(context: context, size: size)
            for i in 0..<segmentCount {
                let t = Double(i) / Double(segmentCount)
                let nextT = Double(i + 1) / Double(segmentCount)
                let segFrom = headPosition - trailLen + t * trailLen
                let segTo = headPosition - trailLen + nextT * trailLen
                let fade = 1.0 - pow(t, 1.5)
                let opacity = 0.85 * fade
                let lineWidth: CGFloat = i == segmentCount - 1 ? 4 : 2.5
                let normFrom = positiveMod(segFrom)
                let normTo = positiveMod(segTo)
                if normFrom < normTo {
                    let trimmed = path.trimmedPath(from: normFrom, to: normTo)
                    context.stroke(trimmed, with: .color(activeColor.opacity(opacity)), lineWidth: lineWidth)
                } else if normFrom > normTo {
                    let tail = path.trimmedPath(from: normFrom, to: 1.0)
                    context.stroke(tail, with: .color(activeColor.opacity(opacity)), lineWidth: lineWidth)
                    let head = path.trimmedPath(from: 0, to: normTo)
                    context.stroke(head, with: .color(activeColor.opacity(opacity * 0.7)), lineWidth: lineWidth)
                }
            }
        }
    }

    private var idleTrailView: some View {
        ZStack {
            path
                .trimmedPath(from: 0, to: 1)
                .stroke(theme.dotInactive, lineWidth: 1.5)
                .opacity(0.3)
            TimelineView(.animation) { _ in
                Canvas { context, size in
                    drawStars(context: context, size: size)
                }
            }
        }
    }

    // MARK: - Helpers

    private func positiveMod(_ value: Double) -> Double {
        let m = value.truncatingRemainder(dividingBy: 1.0)
        return m >= 0 ? m : m + 1
    }

    private func regeneratePath() {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        path = LinePathGenerator.smoothPath(
            in: CGRect(origin: .zero, size: viewSize),
            seed: Int(Date().timeIntervalSince1970 * 1000)
        )
    }

    // MARK: - Stars

    private func regenerateStars(seed: Int) {
        var rng = SeededRandomGenerator(seed: seed + 999)
        stars = (0..<starCount).map { _ in
            Star(
                normX: Double.random(in: 0.15...0.85, using: &rng),
                normY: Double.random(in: 0.15...0.85, using: &rng),
                angle: Double.random(in: 0..<(.pi * 2), using: &rng),
                driftSpeed: Double.random(in: 4...12, using: &rng),
                size: CGFloat.random(in: 4...10, using: &rng),
                phase: Double.random(in: 0..<(.pi * 2), using: &rng),
                twinkleSpeed: Double.random(in: 0.4...1.2, using: &rng)
            )
        }
        starStartTime = Date()
    }

    private func drawStars(context: GraphicsContext, size: CGSize) {
        let elapsed = -starStartTime.timeIntervalSinceNow
        let w = size.width, h = size.height
        for star in stars {
            let dx = cos(star.angle) * star.driftSpeed * elapsed
            let dy = sin(star.angle) * star.driftSpeed * elapsed
            let rawX = star.normX * w + dx
            let rawY = star.normY * h + dy
            let posX = Self.positiveMod(rawX, max: w)
            let posY = Self.positiveMod(rawY, max: h)
            let edgeDist = min(posX, w - posX, posY, h - posY)
            let edgeFade = min(1.0, max(0.0, edgeDist / 60))
            let raw = sin(elapsed * star.twinkleSpeed * .pi * 2 + star.phase)
            let t = raw * 0.5 + 0.5
            let soft = t * t * (3 - 2 * t)
            let twinkle = 0.3 + 0.7 * soft
            let finalOpacity = twinkle * edgeFade
            let sp = Self.starPath(at: CGPoint(x: posX, y: posY), size: star.size)
            context.fill(sp, with: .color(theme.dotActive.opacity(finalOpacity)))
            // rounded stroke softens corners
            context.stroke(sp, with: .color(theme.dotActive.opacity(finalOpacity)),
                          style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    private static func starPath(at point: CGPoint, size: CGFloat) -> Path {
        let s = size
        // 4-point star outline matching the SVG path (scaled to size)
        let pts: [(CGFloat, CGFloat)] = [
            (0, -s),              // top
            (0.17 * s, -0.32 * s), // inner right-up
            (s, 0),               // right
            (0.17 * s, 0.32 * s),  // inner right-down
            (0, s),               // bottom
            (-0.17 * s, 0.32 * s), // inner left-down
            (-s, 0),              // left
            (-0.17 * s, -0.32 * s),// inner left-up
        ]
        var p = Path()
        p.move(to: CGPoint(x: point.x + pts[0].0, y: point.y + pts[0].1))
        for i in 1..<pts.count {
            p.addLine(to: CGPoint(x: point.x + pts[i].0, y: point.y + pts[i].1))
        }
        p.closeSubpath()
        return p
    }

    private static func positiveMod(_ value: Double, max: Double) -> Double {
        let m = value.truncatingRemainder(dividingBy: max)
        return m >= 0 ? m : m + max
    }
}
