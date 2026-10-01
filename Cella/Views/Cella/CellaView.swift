//
//  CellaView.swift
//  Cella
//
//  Main layout for the Cella tab — emotion screen + player indicator.
//

import SwiftUI

struct CellaView: View {
    var viewModel: PlayerViewModel
    @Environment(\.theme) private var theme
    @AppStorage("displayMode") private var displayMode: String = "matrix"

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            CellaScreenView(
                pattern: viewModel.currentPattern,
                viewModel: viewModel
            )
            .overlay(alignment: .topLeading) {
                DisplayModeSwitch(mode: $displayMode)
                    .padding(.top, 10)
                    .padding(.leading, 12)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 12) {
                    ForEach(0..<5, id: \.self) { _ in
                        Circle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 15, height: 15)
                    }
                }
                .padding(.top, 12)
                .offset(y: -42)
            }
            .overlay {
                ZStack(alignment: .leading) {
                    Color.clear
                    LeftStatusDots(viewModel: viewModel)
                        .padding(.leading, 20)
                }
            }
            .padding(.horizontal, 80)

            HStack(spacing: 14) {
                NowPlayingBar(viewModel: viewModel, selectedTab: .constant(.cella))
                AlbumPill(viewModel: viewModel)
            }

            Spacer()
        }
    }
}

// MARK: - Left Status Dots (top→down: lyric tick, LRC light, +3 spare)

/// Dot 1 flashes once per lyric line. Dot 2 shows LRC status
/// (green = lyric file, yellow = loading, red = none).
/// Dots 3–5 reserved (CMA, quality) — dim for now.
private struct LeftStatusDots: View {
    var viewModel: PlayerViewModel
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lyricFlash = false
    @State private var flashGen = 0

    private var isMixing: Bool { viewModel.playerState == .autoMix }

    private enum LrcState {
        case none, loading, ok, missing
    }

    private var lyricIndex: Int {
        let lyrics = viewModel.currentLyrics
        guard !lyrics.isEmpty else { return -1 }
        for i in stride(from: lyrics.count - 1, through: 0, by: -1) {
            if viewModel.currentTime >= lyrics[i].time - 0.1 { return i }
        }
        return -1
    }

    /// True when the current line is real lyric text (not a "..." gap).
    private var currentLineIsReal: Bool {
        let lyrics = viewModel.currentLyrics
        guard lyricIndex >= 0, lyricIndex < lyrics.count else { return false }
        let t = lyrics[lyricIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(t == "..." || t == "…" || t == ".." || t.isEmpty)
    }

    private static let noLrcRed = Color(red: 1.0, green: 0.36, blue: 0.36)

    /// True when the current track has no lyric file at all
    /// (distinct from an instrumental "..." gap inside an existing file).
    private var trackHasNoLrc: Bool {
        guard let track = viewModel.mixQueue?.currentTrack else { return false }
        return !viewModel.hasLyric(for: track)
    }

    private var lrcState: LrcState {
        guard let track = viewModel.mixQueue?.currentTrack else { return .none }
        if viewModel.isTransitioning { return .loading }
        return viewModel.hasLyric(for: track) ? .ok : .missing
    }

    private var lrcColor: Color {
        switch lrcState {
        case .none: return theme.textSecondary.opacity(0.3)
        case .loading: return Color(red: 0.98, green: 0.80, blue: 0.08)
        case .ok: return Color(red: 0.29, green: 0.85, blue: 0.38)
        case .missing: return Color(red: 1.0, green: 0.36, blue: 0.36)
        }
    }

    private var lrcTip: String {
        switch lrcState {
        case .none: return "LRC: no track"
        case .loading: return "LRC: loading"
        case .ok: return "LRC: lyric file found"
        case .missing: return "LRC: no lyric file"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            // Rows 1–2 merged — lyric tick pill.
            // Mixing: aurora multicolor drift loop until landing (snaps back).
            // Idle: flash on each line, half-glow baseline while real lyric active.
            if isMixing {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let drift = reduceMotion ? 0 : sin(t * 2 * .pi * 0.5)
                    let stops = theme.trailPalette + [theme.trailPalette.first ?? theme.dotActive]
                    Capsule()
                        .fill(.clear)
                        .frame(width: 15, height: 42)
                        .overlay(
                            LinearGradient(colors: stops, startPoint: .top, endPoint: .bottom)
                                .frame(width: 15, height: 84)
                                .offset(y: drift * 21)
                                .mask(Capsule().frame(width: 15, height: 42))
                        )
                        .overlay(
                            Capsule()
                                .stroke(.white.opacity(0.35), lineWidth: 1)
                        )
                        .shadow(color: theme.dotActive.opacity(0.55 + 0.25 * drift), radius: 7)
                        .help("Mixing — aurora until landing")
                }
            } else {
                Capsule()
                    .fill(
                        lyricFlash ? theme.dotActive
                        : currentLineIsReal ? theme.dotActive.opacity(0.5)
                        : trackHasNoLrc ? Self.noLrcRed
                        : theme.textSecondary.opacity(0.3)
                    )
                    .frame(width: 15, height: 42)
                    .shadow(
                        color: lyricFlash ? theme.dotActive.opacity(0.8)
                        : trackHasNoLrc ? Self.noLrcRed.opacity(0.55)
                        : theme.dotActive.opacity(currentLineIsReal ? 0.4 : 0),
                        radius: lyricFlash ? 6 : (trackHasNoLrc ? 5 : 4)
                    )
                    .animation(.lyricsSpring, value: lyricFlash)
                    .animation(.smooth(duration: 0.4), value: currentLineIsReal)
                    .animation(.smooth(duration: 0.3), value: trackHasNoLrc)
                    .help(
                        trackHasNoLrc ? "No lyric file for this track"
                        : "Lyric tick — flashes each line, glows on lyric"
                    )
            }
            // Row 3 — LRC status light (moved down)
            Circle()
                .fill(lrcColor)
                .frame(width: 15, height: 15)
                .shadow(color: lrcColor.opacity(0.6), radius: 5)
                .animation(.smooth(duration: 0.3), value: viewModel.mixQueue?.currentTrack?.url)
                .help(lrcTip)
            // Rows 4–5 — spare (CMA, quality), dim placeholders
            ForEach(0..<2, id: \.self) { _ in
                Circle()
                    .fill(theme.textSecondary.opacity(0.22))
                    .frame(width: 15, height: 15)
            }
        }
        .onChange(of: lyricIndex) { _, new in
            guard new >= 0 else { return }
            flashGen += 1
            let gen = flashGen
            // Hold + release follow the lyric scroll spring settle (~0.7s).
            withAnimation(.lyricsSpring) { lyricFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                if gen == flashGen {
                    withAnimation(.lyricsSpring) { lyricFlash = false }
                }
            }
        }
    }
}

// MARK: - Display Mode Switch (Matrix dots / Line visualizer, Cella capsule)

private struct DisplayModeSwitch: View {
    @Binding var mode: String
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var anim

    private let spring: Animation = .spring(response: 0.3, dampingFraction: 0.8)

    private var modes: [(id: String, icon: String, tip: String)] {
        [
            ("aqua", "drop.fill", "Aqua background"),
            ("line", "waveform.path", "Line visualizer"),
            ("static", "eye.slash", "Screen off"),
        ]
    }

    private var effectiveMode: Binding<String> {
        Binding(
            get: { mode == "matrix" || mode == "liquid" ? "aqua" : mode },
            set: { mode = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(modes, id: \.id) { m in
                let active = effectiveMode.wrappedValue == m.id
                Button {
                    withAnimation(reduceMotion ? .none : spring) { effectiveMode.wrappedValue = m.id }
                } label: {
                    Image(systemName: m.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(active ? theme.tabSelectedText : theme.tabUnselectedText)
                        .frame(width: 30, height: 26)
                        .background(
                            ZStack {
                                if active {
                                    Capsule()
                                        .fill(theme.tabSelectedBackground)
                                        .matchedGeometryEffect(id: "displayMode", in: anim)
                                }
                            }
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(m.tip)
            }
        }
        .padding(3)
        .background(theme.tabBarBackground.opacity(0.85))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(theme.textSecondary.opacity(0.2), lineWidth: 1))
    }
}