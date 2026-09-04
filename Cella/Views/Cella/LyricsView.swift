//
//  LyricsView.swift
//  Cella
//
//  Apple Music-style animated lyrics display.
//  Current line highlighted, smooth scroll, transition fusion.
//

import SwiftUI

struct LyricsView: View {
    let lyrics: [LrcLine]
    let currentTime: TimeInterval
    let isPlaying: Bool
    var nextLyrics: [LrcLine] = []
    var isTransitioning: Bool = false
    var frozenIndex: Int = -1
    var textAlignment: TextAlignment = .center
    @Environment(\.theme) private var theme

    private let lineHeight: CGFloat = 42
    private let visibleLines: CGFloat = 5

    // Non-placeholder lyric lines (skips "..." so instrumental gaps don't
    // become scroll targets / don't delay the next real line).
    private var displayLyrics: [LrcLine] {
        lyrics
    }

    private func isPlaceholder(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == "..." || t == "…" || t == ".." || t.isEmpty
    }

    private var currentIndex: Int {
        let lines = displayLyrics
        guard !lines.isEmpty else { return -1 }
        if isTransitioning && frozenIndex >= 0 { return min(frozenIndex, lines.count - 1) }
        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            if currentTime >= lines[i].time - 0.1 {
                return i
            }
        }
        return 0
    }

    private var nextCurrentIndex: Int {
        guard !nextLyrics.isEmpty else { return 0 }
        for i in stride(from: nextLyrics.count - 1, through: 0, by: -1) {
            if currentTime >= nextLyrics[i].time - 0.1 {
                return i
            }
        }
        return 0
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate

                ZStack {
                    currentLyricsContent(geo: geo, time: t)
                        .offset(x: isTransitioning ? -geo.size.width * 0.6 : 0)
                        .opacity(isTransitioning ? 0.0 : 1.0)
                        .animation(.lyricsSpring, value: isTransitioning)

                    if isTransitioning && !nextLyrics.isEmpty {
                        nextLyricsContent(geo: geo, time: t)
                            .offset(x: isTransitioning ? 0 : geo.size.width * 0.6)
                            .opacity(isTransitioning ? 1.0 : 0.0)
                            .animation(.lyricsSpring, value: isTransitioning)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .clipped()
    }

    // MARK: - Float

    private func floatX(_ index: Int, time: Double) -> CGFloat {
        let s = Double(index) * 1.7 + 0.3
        return CGFloat(sin(time * 0.3 + s) * 1.5 + sin(time * 0.15 + s * 2.1) * 0.8)
    }

    private func floatY(_ index: Int, time: Double) -> CGFloat {
        let s = Double(index) * 2.3 + 1.1
        return CGFloat(cos(time * 0.25 + s) * 1.2 + cos(time * 0.12 + s * 1.9) * 0.6)
    }

    // MARK: - Current Lyrics

    private var alignment: Alignment {
        switch textAlignment {
        case .leading: return .leading
        case .trailing: return .trailing
        default: return .center
        }
    }

    @ViewBuilder
    private func currentLyricsContent(geo: GeometryProxy, time: Double) -> some View {
        let lines = lyrics
        let scrollOffset = -CGFloat(currentIndex) * lineHeight

        ZStack {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                let fixedY = CGFloat(index) * lineHeight
                let distFromCenter = abs(CGFloat(index - currentIndex) * lineHeight)
                let normalizedDist = min(distFromCenter / (lineHeight * 3.0), 1.0)
                let isCurrent = index == currentIndex

                let opacity = isCurrent ? 1.0 : max(0.0, 1.0 - normalizedDist * 1.5)
                let scale: CGFloat = isCurrent ? 1.0 : max(0.85, 1.0 - normalizedDist * 0.15)
                let blur: CGFloat = isCurrent ? 0 : min(3, normalizedDist * 3)

                if abs(CGFloat(index - currentIndex)) < visibleLines {
                    Text(line.text)
                        .font(.system(
                            size: isCurrent ? 28 : 21,
                            weight: .bold,
                            design: .rounded
                        ))
                        .foregroundStyle(
                            isCurrent ? theme.dotActive : theme.textPrimary
                        )
                        .opacity(opacity)
                        .scaleEffect(scale, anchor: .center)
                        .blur(radius: blur)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: geo.size.width * 0.85, alignment: alignment)
                        .multilineTextAlignment(textAlignment)
                        .offset(y: fixedY)
                }
            }
        }
        .offset(y: scrollOffset)
        .animation(.lyricsSpring, value: currentIndex)
    }

    // MARK: - Next Lyrics

    @ViewBuilder
    private func nextLyricsContent(geo: GeometryProxy, time: Double) -> some View {
        ZStack {
            ForEach(Array(nextLyrics.prefix(5).enumerated()), id: \.element.id) { index, line in
                let ni = nextCurrentIndex
                let offset = CGFloat(index - ni - 2) * lineHeight
                let distFromCenter = abs(offset)
                let normalizedDist = min(distFromCenter / (lineHeight * 3.0), 1.0)
                let isCenter = index - ni == 2

                let opacity = isCenter ? 1.0 : max(0.15, 1.0 - normalizedDist * 0.9)
                let scale: CGFloat = isCenter ? 1.0 : max(0.88, 1.0 - normalizedDist * 0.12)
                let yOffset = offset - (isCenter ? lineHeight * 0.12 : 0)
                let blur: CGFloat = isCenter ? 0 : min(2.5, normalizedDist * 2.5)

                let fx = isCenter ? 0 : floatX(index + 100, time: time)
                let fy = isCenter ? 0 : floatY(index + 100, time: time)

                Text(line.text)
                    .font(.system(
                        size: isCenter ? 28 : 21,
                        weight: .bold,
                        design: .rounded
                    ))
                    .foregroundStyle(
                        isCenter ? theme.dotActive : theme.textPrimary
                    )
                    .opacity(opacity)
                    .scaleEffect(scale, anchor: .center)
                    .blur(radius: blur)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: geo.size.width * 0.85, alignment: alignment)
                    .multilineTextAlignment(textAlignment)
                    .offset(x: fx, y: yOffset + fy)
            }
        }
    }
}

#Preview {
    let previewLyrics = [
        LrcLine(time: 0, text: "First line of the song"),
        LrcLine(time: 3.5, text: "Second line comes along"),
        LrcLine(time: 7.0, text: "Third line in the verse"),
        LrcLine(time: 10.5, text: "Fourth line starts to build"),
        LrcLine(time: 14.0, text: "Fifth line, the chorus hits"),
        LrcLine(time: 17.5, text: "Sixth line keeps it going"),
        LrcLine(time: 21.0, text: "Seventh line fades away"),
    ]

    let nextPreview = [
        LrcLine(time: 0, text: "New song begins here"),
        LrcLine(time: 3.0, text: "Second line of new song"),
        LrcLine(time: 6.0, text: "Third line fades in"),
    ]

    ZStack {
        Color.black
        LyricsView(
            lyrics: previewLyrics,
            currentTime: 8.0,
            isPlaying: true,
            nextLyrics: nextPreview,
            isTransitioning: true
        )
    }
}
