//
//  CellaView.swift
//  Cella
//
//  Main layout for the Cella tab — emotion screen + player indicator.
//

import SwiftUI
import UniformTypeIdentifiers

struct CellaView: View {
    var viewModel: PlayerViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            screenStage

            HStack(spacing: 14) {
                NowPlayingBar(viewModel: viewModel, selectedTab: .constant(.cella))
                AlbumPill(viewModel: viewModel)
            }

            Spacer()
        }
        .onDrop(of: [.fileURL], isTargeted: .constant(false)) { providers in
            // Lyric files route to the same handler the app-wide drop zone
            // uses — this deeper target must not swallow them (returning
            // true consumes the drop).
            let group = DispatchGroup()
            var lrcs: [URL] = []
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    defer { group.leave() }
                    guard let url = url as? URL else { return }
                    if PlayerViewModel.droppedLrcExtensions.contains(url.pathExtension.lowercased()) {
                        lrcs.append(url)
                    }
                }
            }
            group.notify(queue: .main) {
                if !lrcs.isEmpty {
                    viewModel.handleDroppedLrcs(lrcs)
                }
            }
            return true
        }
    }

    // MARK: - Screen stage

    private var screenStage: some View {
        GeometryReader { geo in
            // Center the screen vertically — GeometryReader pins content
            // top-leading, which left a dead gap above the pills.
            screenPage
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 80)
    }

    private var screenPage: some View {
        CellaScreenView(
            viewModel: viewModel
        )
        .overlay {
            ZStack(alignment: .trailing) {
                Color.clear
                    .allowsHitTesting(false)
                RightVolumeRail(viewModel: viewModel)
                    .padding(.trailing, 20)
            }
        }
    }

}

// MARK: - Right Volume Rail (mirrors the left status dots)

// Thin full-height level bar mirroring the left dots column (lyric pill 42
// + 3×15 dots + 3×12 gaps = 123pt). Aero glass, visible only while volume
// is being adjusted — fades out after. Wide invisible hit area for grabs.
private let statusRailHeight: CGFloat = 123

private struct RightVolumeRail: View {
    var viewModel: PlayerViewModel
    @Environment(\.theme) private var theme
    @State private var adjusting = false
    @State private var hideTask: Task<Void, Never>?

    private var volume: Float { viewModel.currentVolume }

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule()
                .fill(theme.screenBackground.opacity(0.45))
                .frame(width: 5, height: statusRailHeight)
            Capsule()
                .fill(.ultraThinMaterial)
                .frame(width: 5, height: statusRailHeight)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.28), .white.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .frame(width: 5, height: statusRailHeight)
                .allowsHitTesting(false)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [theme.haloPrimary, theme.dotActive],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 5, height: max(5, statusRailHeight * CGFloat(volume)))
                .shadow(color: theme.dotActive.opacity(0.7), radius: 8)
            Capsule()
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                .frame(width: 5, height: statusRailHeight)
        }
        .opacity(adjusting ? 1 : 0)
        .animation(.smooth(duration: 0.3), value: adjusting)
        .animation(.smooth(duration: 0.15), value: volume)
        .frame(width: 24)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    viewModel.setVolume(Float(max(0, min(1, 1 - Double(value.location.y / statusRailHeight)))))
                }
        )
        .onChange(of: volume) {
            adjusting = true
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { adjusting = false }
            }
        }
        .help("Volume \(Int(volume * 100))% — drag to adjust, or scroll on the screen")
    }
}

// MARK: - Left Status Dots (top→down: lyric tick, LRC light, +3 spare)

/// Dot 1 flashes once per lyric line. Dot 2 shows LRC status
/// (green = lyric file, yellow = loading, red = none).
/// Dots 3–5 reserved (quality) — dim for now.
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
        // Pin to -1 unless the loaded lyrics belong to the current track.
        // During autoMix the queue already points at the incoming song while
        // currentLyrics still holds the outgoing lines — indexing those
        // against the new clock flashes (and sticks) the tick on landing.
        guard let trackURL = viewModel.mixQueue?.currentTrack?.url,
              viewModel.currentLyricsTrackURL == trackURL else { return -1 }
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
        return !lyrics[lyricIndex].text.isLyricPlaceholder
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
            // Rows 4–5 — spare (quality), dim placeholders
            ForEach(0..<2, id: \.self) { _ in
                Circle()
                    .fill(theme.textSecondary.opacity(0.22))
                    .frame(width: 15, height: 15)
            }
        }
        .onChange(of: lyricIndex) { _, new in
            // Never flash mid-mix (the aurora owns the pill), and never
            // leave a stale flash behind when the index parks at -1 on a
            // track hop — otherwise the tick sticks fully lit on the next song.
            guard !isMixing else {
                flashGen += 1
                if lyricFlash {
                    withAnimation(.lyricsSpring) { lyricFlash = false }
                }
                return
            }
            guard new >= 0 else {
                flashGen += 1
                if lyricFlash {
                    withAnimation(.lyricsSpring) { lyricFlash = false }
                }
                return
            }
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
        .onChange(of: viewModel.mixQueue?.currentTrack?.url) { _, _ in
            // Track hop: drop any in-flight flash so the next song starts clean.
            flashGen += 1
            if lyricFlash {
                withAnimation(.lyricsSpring) { lyricFlash = false }
            }
        }
        .onChange(of: isMixing) { _, mixing in
            // Mix start: the aurora replaces the pill — clear the tick so it
            // can't carry a stale flash into the landing.
            if mixing {
                flashGen += 1
                if lyricFlash {
                    withAnimation(.lyricsSpring) { lyricFlash = false }
                }
            }
        }
    }
}
