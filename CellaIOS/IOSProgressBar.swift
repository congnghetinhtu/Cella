//
//  IOSProgressBar.swift
//  CellaIOS
//
//  Seek bar in the Cella language: capsule track, glowing accent fill,
//  knurled knob while dragging, time labels on both ends. Drag anywhere on
//  the bar to scrub; release seeks. The fill takes any shape style, so the
//  white flip can wear the Frutiger-blue gradient.
//

import SwiftUI

struct IOSProgressBar: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    var accent: AnyShapeStyle
    var glow: Color
    var onSeek: (Double) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragFraction: Double?
    @State private var dragging = false

    private var enabled: Bool { duration > 0 }
    private var progress: Double { duration > 0 ? min(1, max(0, currentTime / duration)) : 0 }
    private var shown: Double { dragFraction ?? progress }

    private var elapsed: TimeInterval {
        if let dragFraction { return dragFraction * duration }
        return currentTime
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = max(1, geo.size.width)
                let knobD: CGFloat = dragging ? 16 : 11
                let barH: CGFloat = dragging ? 7 : 5
                let fillW = max(barH, CGFloat(shown) * w)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.textPrimary.opacity(0.16))
                        .frame(height: barH)
                    Capsule()
                        .fill(accent)
                        .frame(width: fillW, height: barH)
                        .shadow(color: glow.opacity(0.6), radius: dragging ? 9 : 5)
                    Circle()
                        .fill(.white)
                        .frame(width: knobD, height: knobD)
                        .overlay(Circle().stroke(theme.textPrimary.opacity(0.18), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .offset(x: fillW - knobD)
                        .opacity(shown > 0.001 || dragging ? 1 : 0)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard enabled else { return }
                            dragging = true
                            dragFraction = min(1, max(0, value.location.x / w))
                        }
                        .onEnded { value in
                            guard enabled else { return }
                            let fraction = min(1, max(0, value.location.x / w))
                            dragging = false
                            dragFraction = nil
                            onSeek(fraction)
                        }
                )
                .animation(reduceMotion ? .none : .snappy, value: dragging)
            }
            .frame(height: 26)

            HStack {
                Text(Self.timeString(elapsed))
                Spacer()
                Text("-" + Self.timeString(max(0, duration - elapsed)))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(theme.textPrimary.opacity(0.75))
        }
        .opacity(enabled ? 1 : 0.55)
        .sensoryFeedback(.selection, trigger: dragging)
    }

    static func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
