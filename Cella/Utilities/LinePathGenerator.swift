import SwiftUI

struct SeededRandomGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: Int) {
        self.state = UInt64(bitPattern: Int64(seed))
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

enum LinePathGenerator {
    /// Returns the control points for a smooth path constrained to rect.
    /// Deterministic given the same rect and seed.
    static func pathPoints(in rect: CGRect, seed: Int) -> [CGPoint] {
        var rng = SeededRandomGenerator(seed: seed)
        let count = Int.random(in: 6...12, using: &rng)
        var points: [CGPoint] = []
        for _ in 0..<count {
            points.append(CGPoint(
                x: rect.minX + CGFloat.random(in: 0...rect.width, using: &rng),
                y: rect.minY + CGFloat.random(in: 0...rect.height, using: &rng)
            ))
        }
        return points
    }

    /// Builds a Catmull-Rom path from control points.
    static func catmullRomPath(_ points: [CGPoint]) -> Path {
        guard points.count >= 2 else { return Path() }
        return Path { path in
            for i in 0..<(points.count - 1) {
                let p0 = i > 0 ? points[i - 1] : points[i]
                let p1 = points[i]
                let p2 = points[i + 1]
                let p3 = i + 2 < points.count ? points[i + 2] : points[i + 1]

                let cp1 = CGPoint(
                    x: p1.x + (p2.x - p0.x) / 6,
                    y: p1.y + (p2.y - p0.y) / 6
                )
                let cp2 = CGPoint(
                    x: p2.x - (p3.x - p1.x) / 6,
                    y: p2.y - (p3.y - p1.y) / 6
                )

                if i == 0 {
                    path.move(to: p1)
                }
                path.addCurve(to: p2, control1: cp1, control2: cp2)
            }
        }
    }

    /// Convenience: generate points and build path in one call.
    static func smoothPath(in rect: CGRect, seed: Int) -> Path {
        catmullRomPath(pathPoints(in: rect, seed: seed))
    }
}
