//
//  LyricsView.swift
//  Cella
//
//  Apple Music-style animated lyrics display.
//  Current line highlighted, smooth scroll, transition fusion.
//

import SwiftUI

/// Reports the active lyric line's text frame in global coordinates.
/// PreferenceKey is scoped per-file here because `LyricsView` compiles
/// into the iOS target too — plain SwiftUI, shared safely.
struct ActiveLyricFrameKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}

/// Full bounds of the lyric stage (same space as above).
struct LyricStageFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// Hidden measurement pass output: entry index → wrapped content height.
/// Long entries wrap onto a second rendered row; their slots grow so the
/// following line is never squeezed against them.
struct LyricMeasuredHeightsKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, updated in updated })
    }
}

/// Hidden measurement pass output: index → lead-half intrinsic text width
/// (`[DUO]` rows only) — the tail indents to begin just past the lead.
struct LyricDuoLeadWidthsKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, updated in updated })
    }
}

struct LyricsView: View {
    let lyrics: [LrcLine]
    let currentTime: TimeInterval
    let isPlaying: Bool
    var nextLyrics: [LrcLine] = []
    var isTransitioning: Bool = false
    var frozenIndex: Int = -1
    var textAlignment: TextAlignment = .center
    var revealProgress: Double = 0
    var highlightIndex: Int? = nil
    /// Nominal slot pitch, in points — the rhythm of the fade/depth effects,
    /// the preview stack's fallback spacing, and the floor for measured
    /// slots. iOS passes a tighter value so long lines fit a phone screen;
    /// the macOS default is unchanged.
    var lineHeight: CGFloat = 42
    /// Base font size of the current line; other lines render at 0.75×.
    var fontSize: CGFloat = 28
    /// How many lines around the current one are drawn.
    var visibleLines: CGFloat = 5
    /// How many rendered lines each lyric entry may occupy. 1 keeps the
    /// macOS desktop layout; iOS allows 2 so long lines wrap instead of
    /// being truncated.
    var maxLines: Int = 1
    /// When true every lyric line renders at the same font size (and without
    /// the shrink-to-distance effect) — the iOS reading view. macOS keeps its
    /// depth-of-field look.
    var uniformLineSize: Bool = false
    /// Base lyric color — the current line, and the anchor for faded lines.
    /// The iOS white flip passes dark slate; macOS keeps white.
    var textBase: Color = .white
    /// When set, the current line wears this style instead of `textBase` —
    /// the iOS white flip paints it with the theme gradient. Mac and the
    /// blue look keep nil.
    var currentLineStyle: AnyShapeStyle? = nil
    @Environment(\.theme) private var theme

    /// Measured wrapped heights of the current lyrics (index → height).
    /// `[DUO]` rows report their two-line pair, so this drives every slot.
    @State private var measuredHeights: [Int: CGFloat] = [:]
    /// Same for the incoming preview lines.
    @State private var nextMeasuredHeights: [Int: CGFloat] = [:]
    /// Measured lead-half widths of `[DUO]` rows (index → width).
    @State private var duoLeadWidths: [Int: CGFloat] = [:]
    /// Same for the incoming preview lines.
    @State private var nextDuoLeadWidths: [Int: CGFloat] = [:]

    private var displayLyrics: [LrcLine] {
        lyrics
    }

    private var currentIndex: Int {
        let lines = displayLyrics
        guard !lines.isEmpty else { return -1 }
        if let hi = highlightIndex, hi >= 0, hi < lines.count { return hi }
        if isTransitioning && frozenIndex >= 0 && !nextLyrics.isEmpty { return min(frozenIndex, lines.count - 1) }
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

    // MARK: - Slot layout (per-entry natural heights)

    /// Extra air between consecutive entries. Derived from the classic
    /// parameters so every call site keeps its tuned rhythm: base slot
    /// minus one font's height. Wrapped entries then inherit the SAME gap
    /// as short ones instead of colliding with their neighbor.
    private var entryGap: CGFloat { max(10, lineHeight - fontSize) }

    /// Vertical room one entry's slot gets: its measured wrapped height
    /// plus the gap, floored at the legacy pitch. The measurement pass
    /// renders every row exactly as it displays — `[DUO]` rows report
    /// their two-line pair — so one dict drives everyone. Unmeasured
    /// entries fall back to exactly the old fixed slot, so the first
    /// layout frame is identical to the pre-measurement layout.
    private func slotHeight(_ index: Int, measured: [Int: CGFloat]) -> CGFloat {
        let content = measured[index] ?? (lineHeight - entryGap)
        return max(content + entryGap, lineHeight)
    }

    /// Slot centers laid out down from y = 0 (the stage's vertical center,
    /// before scrolling). `scrollOffset` then re-centers the current line.
    private func slotCenters(measured: [Int: CGFloat], count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let heights = (0..<count).map { slotHeight($0, measured: measured) }
        var centers: [CGFloat] = []
        centers.reserveCapacity(count)
        var y: CGFloat = 0
        for h in heights {
            centers.append(y + h / 2)
            y += h
        }
        return centers
    }

    /// Offscreen copies of the lines at the true display font/width, read
    /// through a background GeometryReader. `fixedSize(vertical:)` makes
    /// Text report its fully wrapped height instead of the ambient frame's.
    /// `[DUO]` rows render their two-line pair here exactly as on screen,
    /// and additionally report the lead-half's intrinsic width separately.
    private func measureLayer(_ lines: [LrcLine], width: CGFloat) -> some View {
        ZStack {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                // Primary pass — the row exactly as it displays; its height
                // feeds the slot math (duo rows report their pair).
                lyricRowBody(line, pointSize: fontSize, rowWidth: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width)
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(
                                key: LyricMeasuredHeightsKey.self,
                                value: [index: g.size.height])
                        }
                    )

                if line.isDuo && !line.duoLead.isEmpty {
                    // Lead-half width — feeds the current row's seam indent.
                    Text(line.duoLead)
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                        .fixedSize()
                        .hidden()
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: LyricDuoLeadWidthsKey.self,
                                    value: [index: g.size.width])
                            }
                        )
                }
            }
        }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                currentLyricsContent(geo: geo)
                    .offset(x: isTransitioning ? -geo.size.width * 0.6 : 0)
                    .opacity(isTransitioning ? 0.0 : 1.0)
                    .blur(radius: isTransitioning ? 4 : 0)
                    .animation(.lyricsSpring, value: isTransitioning)

                if isTransitioning && !nextLyrics.isEmpty {
                    // Only the incoming preview needs a live clock (float).
                    TimelineView(.animation) { timeline in
                        nextLyricsContent(
                            geo: geo,
                            time: timeline.date.timeIntervalSinceReferenceDate
                        )
                    }
                    .offset(x: isTransitioning ? 0 : geo.size.width * 0.6)
                    .opacity(isTransitioning ? 1.0 : 0.0)
                    .blur(radius: isTransitioning ? 0 : 4)
                    .animation(.lyricsSpring, value: isTransitioning)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipped()
    }

    // MARK: - Float

    private func floatX(_ index: Int, time: Double) -> CGFloat {
        let s = Double(index) * 1.7 + 0.3
        return CGFloat(sin(time * 0.3 + s) * 2.0 + sin(time * 0.15 + s * 2.1) * 1.0)
    }

    private func floatY(_ index: Int, time: Double) -> CGFloat {
        let s = Double(index) * 2.3 + 1.1
        return CGFloat(cos(time * 0.25 + s) * 1.6 + cos(time * 0.12 + s * 1.9) * 0.8)
    }

    // MARK: - Row body (plain vs [DUO] split)

    /// [DUO] tail right-inset. The centered 85% lyric column ends at 92.5%
    /// of the stage; the right-aligned tail aligns to the song header's text
    /// edge at 89% instead — a 3.5% stage-width inset. Zero when the column
    /// is already docked to 89% (trailing split mode).
    private let duoTailEdgeInset: CGFloat = 0.035

    /// Seam between the lead's end and the tail's start on a [DUO] row —
    /// the tail is indented to begin just past the lead's text instead of
    /// hugging the column's right edge.
    private let duoSeamGap: CGFloat = 12
    /// Inside-a-pair spacing: a small gap between the two stacked lines of
    /// a [DUO] row — roomier than the overlap, still tighter than a
    /// normal row's line pitch.
    private let duoPairSpacing: CGFloat = 8

    /// The row's text body. A `[DUO]` row always breaks into two stacked
    /// single lines: the lead is line 1 left-aligned, the tail is line 2
    /// also left-aligned — except on the **current** row (`duoExpanded`),
    /// where the tail indents to begin just past the lead's end
    /// (`duoSeamGap` after it) and ellipsizes at the column's right
    /// boundary (`tailInset` from the edge). `rowWidth` is the column
    /// width and `duoLeadWidth` the measured lead-text width (0 until
    /// measured). Shared by the on-screen lyrics and the hidden
    /// measurement pass so both size identically.
    @ViewBuilder
    private func lyricRowBody(
        _ line: LrcLine,
        pointSize: CGFloat,
        duoExpanded: Bool = false,
        tailInset: CGFloat = 0,
        rowWidth: CGFloat = 0,
        duoLeadWidth: CGFloat = 0
    ) -> some View {
        if line.isDuo {
            VStack(alignment: .leading, spacing: duoPairSpacing) {
                if !line.duoLead.isEmpty {
                    Text(line.duoLead)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !line.duoTail.isEmpty {
                    // Current line: the tail starts just past the lead's
                    // end. Previous/upcoming lines: stacked plain left.
                    let indent = (duoExpanded && !line.duoLead.isEmpty)
                        ? duoLeadWidth + duoSeamGap
                        : 0
                    let boundary = max(40, rowWidth - tailInset)
                    let available = max(40, boundary - indent)
                    Text(line.duoTail)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: available, alignment: .leading)
                        .padding(.leading, indent)
                }
            }
            .font(.system(size: pointSize, weight: .bold, design: .rounded))
        } else {
            Text(line.text)
                .font(.system(size: pointSize, weight: .bold, design: .rounded))
                .lineLimit(maxLines)
                .truncationMode(.tail)
        }
    }

    // MARK: - Current Lyrics

    private var alignment: Alignment {
        switch textAlignment {
        case .leading: return .leading
        case .trailing: return .trailing
        default: return .center
        }
    }

    /// Split dock (`.trailing`): lyric lines stay right-aligned, pulled out
    /// to 89% of the stage (right margin 11%, just outside the song
    /// header's fixed text edge at 9%). The 0.44 frame also
    /// means the longest line ellipsizes rather than sliding under the
    /// title: a line's left edge can never pass 45%, clear of the header
    /// text (wraps by 51%). Other modes keep the default 85% frame
    /// centred on the stage.
    private func columnLayout(in width: CGFloat)
        -> (frameWidth: CGFloat, shift: CGFloat, frameAlignment: Alignment, textAlignment: TextAlignment) {
        if textAlignment == .trailing {
            return (width * 0.44, width * 0.17, .trailing, .trailing)
        }
        return (width * 0.85, 0, alignment, textAlignment)
    }

    @ViewBuilder
    private func currentLyricsContent(geo: GeometryProxy) -> some View {
        let lines = lyrics
        let column = columnLayout(in: geo.size.width)
        // Tail inset only for the centered column — the docked (trailing)
        // split mode's column already ends at the header's text edge.
        let duoTailInset = textAlignment == .trailing ? 0 : geo.size.width * duoTailEdgeInset
        let centers = slotCenters(measured: measuredHeights, count: lines.count)
        let scrollOffset = currentIndex >= 0 ? -centers[currentIndex] : CGFloat(0)
        let currentY = currentIndex >= 0 ? centers[currentIndex] : CGFloat(0)

        ZStack {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                // Slot positions from real (measured) heights, not a flat
                // pitch × index — wrapped entries spread their slots apart.
                let fixedY = centers.indices.contains(index) ? centers[index] : CGFloat(index) * lineHeight
                let distFromCenter = abs(fixedY - currentY)
                let normalizedDist = min(distFromCenter / (lineHeight * 3.0), 1.0)
                let isCurrent = index == currentIndex
                let isPast = index < currentIndex

                let opacity = isCurrent ? 1.0 : max(0.0, 1.0 - normalizedDist * 1.5)
                let scale: CGFloat = (isCurrent || uniformLineSize) ? 1.0 : max(0.85, 1.0 - normalizedDist * 0.15)
                let blur: CGFloat = isCurrent ? 0 : min(3, normalizedDist * 3)
                let verticalSqueeze: CGFloat = isPast ? 0.97 : 1.0

                let revealClamped = min(max(revealProgress, 0), 1)
                let revealPeak = sin(revealClamped * .pi)
                let revealScale = CGFloat(revealPeak * 0.06)
                let isHighlight = index == highlightIndex
                let highlightColor = theme.haloAccent
                // Plain white text with distance fade — no color, no halo.
                let nearFade = max(0, 1.0 - normalizedDist * 1.4)
                let otherColor = textBase.opacity(0.12 + 0.55 * nearFade)
                let textStyle: AnyShapeStyle = {
                    if isHighlight { return AnyShapeStyle(highlightColor) }
                    if isCurrent, let currentLineStyle { return currentLineStyle }
                    return AnyShapeStyle(isCurrent ? textBase : otherColor)
                }()

                if abs(CGFloat(index - currentIndex)) < visibleLines {
                    lyricRowBody(
                        line,
                        pointSize: (isCurrent || uniformLineSize) ? fontSize : fontSize * 0.75,
                        duoExpanded: isCurrent,
                        tailInset: duoTailInset,
                        rowWidth: column.frameWidth,
                        duoLeadWidth: duoLeadWidths[index] ?? 0)
                        .foregroundStyle(textStyle)
                        .opacity(opacity)
                        .scaleEffect(
                            x: scale + revealScale + (isHighlight ? 0.04 : 0) + (isCurrent ? 0.03 : 0),
                            y: scale * verticalSqueeze + revealScale + (isHighlight ? 0.04 : 0) + (isCurrent ? 0.03 : 0),
                            anchor: .center
                        )
                        // White specular edge only — no halo stack.
                        .shadow(color: isHighlight ? highlightColor.opacity(0.8) : .white.opacity(isCurrent ? 0.38 : 0), radius: isHighlight ? 16 : 1, x: 0, y: isCurrent ? -1 : 0)
                        .blur(radius: blur)
                        // Report the active line's text edge in global space —
                        // the "who's singing" caption in CellaScreenView docks
                        // its right edge to this line's ending edge.
                        .background {
                            if isCurrent {
                                GeometryReader { g in
                                    Color.clear.preference(
                                        key: ActiveLyricFrameKey.self,
                                        value: g.frame(in: .global))
                                }
                            }
                        }
                        .frame(width: column.frameWidth, alignment: column.frameAlignment)
                        .multilineTextAlignment(column.textAlignment)
                        .offset(x: column.shift, y: fixedY)
                }
            }

            // Hidden measurement pass feeding the slot heights above.
            measureLayer(lines, width: column.frameWidth)
                .onPreferenceChange(LyricMeasuredHeightsKey.self) { measuredHeights = $0 }
                .onPreferenceChange(LyricDuoLeadWidthsKey.self) { duoLeadWidths = $0 }
        }
        .offset(y: scrollOffset)
        .animation(.lyricsSpring, value: currentIndex)
        // Slots reflowing as measurements land stays in the lyric-glide
        // family — no pop.
        .animation(.lyricsSpring, value: measuredHeights)
        .animation(.lyricsSpring, value: duoLeadWidths)
    }

    // MARK: - Next Lyrics

    @ViewBuilder
    private func nextLyricsContent(geo: GeometryProxy, time: Double) -> some View {
        let column = columnLayout(in: geo.size.width)
        let previews = Array(nextLyrics.prefix(5))
        let duoTailInset = textAlignment == .trailing ? 0 : geo.size.width * duoTailEdgeInset
        let ni = nextCurrentIndex
        let centers = slotCenters(measured: nextMeasuredHeights, count: previews.count)
        // The virtual "incoming current" anchor sits two slots past the
        // preview head. Beyond the measured range it extrapolates at the
        // nominal pitch so the tail never reads a missing center.
        let anchorIndex = ni + 2
        let anchorY: CGFloat = anchorIndex < centers.count
            ? centers[anchorIndex]
            : (centers.last ?? 0) + CGFloat(anchorIndex - previews.count + 1) * lineHeight

        ZStack {
            ForEach(Array(previews.enumerated()), id: \.element.id) { index, line in
                let offset = centers.indices.contains(index)
                    ? centers[index] - anchorY
                    : CGFloat(index - ni - 2) * lineHeight
                let distFromCenter = abs(offset)
                let normalizedDist = min(distFromCenter / (lineHeight * 3.0), 1.0)
                let isCenter = index - ni == 2

                let opacity = isCenter ? 1.0 : max(0.15, 1.0 - normalizedDist * 0.9)
                let scale: CGFloat = (isCenter || uniformLineSize) ? 1.0 : max(0.88, 1.0 - normalizedDist * 0.12)
                let yOffset = offset - (isCenter ? lineHeight * 0.12 : 0)
                let blur: CGFloat = isCenter ? 0 : min(2.5, normalizedDist * 2.5)

                let fx = isCenter ? 0 : floatX(index + 100, time: time)
                let fy = isCenter ? 0 : floatY(index + 100, time: time)

                let nearFadeNext = max(0, 1.0 - normalizedDist * 1.4)
                let otherNext = textBase.opacity(0.12 + 0.55 * nearFadeNext)

                lyricRowBody(
                    line,
                    pointSize: (isCenter || uniformLineSize) ? fontSize : fontSize * 0.75,
                    duoExpanded: isCenter,
                    tailInset: duoTailInset,
                    rowWidth: column.frameWidth,
                    duoLeadWidth: nextDuoLeadWidths[index] ?? 0)
                    .foregroundStyle(isCenter ? (currentLineStyle ?? AnyShapeStyle(textBase)) : AnyShapeStyle(otherNext))
                    .opacity(opacity)
                    .scaleEffect(scale, anchor: .center)
                    .shadow(color: .white.opacity(isCenter ? 0.38 : 0), radius: 1, x: 0, y: -1)
                    .blur(radius: blur)
                    .frame(width: column.frameWidth, alignment: column.frameAlignment)
                    .multilineTextAlignment(column.textAlignment)
                    .offset(x: fx + column.shift, y: yOffset + fy)
            }

            // Same measured-slot treatment for the incoming preview stack.
            measureLayer(previews, width: column.frameWidth)
                .onPreferenceChange(LyricMeasuredHeightsKey.self) { nextMeasuredHeights = $0 }
                .onPreferenceChange(LyricDuoLeadWidthsKey.self) { nextDuoLeadWidths = $0 }
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
