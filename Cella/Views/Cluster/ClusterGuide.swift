//
//  ClusterGuide.swift
//  Cella
//
//  First-visit walkthrough for the Cluster tab. Five paged glass cards:
//  the .cluster library, the two playlist kinds, CueLab, adding songs,
//  and making playlists. Auto-opens once per install (clusterGuideSeen);
//  the toolbar guide button reopens it any time.
//

import SwiftUI

// MARK: - Cross-view signal

extension Notification.Name {
    /// ClusterView posts this to present the guide (object = library display
    /// name). The overlay itself lives at the window root (ContentView), so
    /// the dim covers the tab bar too.
    static let clusterGuideRequest = Notification.Name("clusterGuideRequest")
}

// MARK: - Guide overlay

struct ClusterGuideOverlay: View {
    /// Real library name for the page-1 chain visual (e.g. "musicLiblary"). cluster
    let libraryName: String
    var onClose: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var forward = true

    private let pageCount = 6

    /// Directional page change: new page slides in from the side you move toward.
    private var pageTransition: AnyTransition {
        let distance: CGFloat = 42
        return .asymmetric(
            insertion: .offset(x: forward ? distance : -distance).combined(with: .opacity),
            removal: .offset(x: forward ? -distance : distance).combined(with: .opacity)
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                header
                Divider()
                    .overlay(.white.opacity(0.14))
                    .padding(.horizontal, 22)
                pageBody
                    .padding(.horizontal, 26)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                Spacer(minLength: 0)
                footer
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
            }
            .frame(width: 560, height: 430)
            .aeroCard(radius: CardStyle.radius, wash: 0.08, tint: 0.2)
            .clipShape(RoundedRectangle(cornerRadius: CardStyle.radius))
            .overlay(
                RoundedRectangle(cornerRadius: CardStyle.radius)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30)
            .contentShape(RoundedRectangle(cornerRadius: CardStyle.radius))
        }
        .onExitCommand { close() }
    }

    private func close() {
        withAnimation(.snappy) { onClose() }
    }

    // MARK: - Page definitions

    private struct PageMeta {
        let title: String
        let icon: String
    }

    private var pages: [PageMeta] {
        [
            PageMeta(title: "Cluster is your music library", icon: "books.vertical.fill"),
            PageMeta(title: "Two kinds of playlists", icon: "music.note.list"),
            PageMeta(title: "Meet CueLab", icon: "list.bullet.rectangle.fill"),
            PageMeta(title: "Getting songs in", icon: "tray.and.arrow.down"),
            PageMeta(title: "Making playlists", icon: "folder.badge.plus"),
            PageMeta(title: "The Metro Glass look", icon: "sparkles"),
        ]
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 14) {
            GuideTile(icon: pages[step].icon, size: 46, iconSize: 20)

            Text(pages[step].title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2, reservesSpace: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id("title-\(step)")
                .transition(
                    reduceMotion ? .opacity :
                        .asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                        )
                )

            Text("\(step + 1) of \(pageCount)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textSecondary)
                .fixedSize()

            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.textSecondary.opacity(0.1)))
                    .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Close the guide")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .animation(.snappy, value: step)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                go(-1)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                    Text("Back")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.textSecondary.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(step == 0)
            .opacity(step == 0 ? 0 : 1)
            .accessibilityLabel("Previous page")

            Spacer()

            HStack(spacing: 7) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Button {
                        jump(to: index)
                    } label: {
                        Capsule()
                            .fill(index == step ? theme.dotActive : theme.textSecondary.opacity(0.3))
                            .frame(width: index == step ? 18 : 6, height: 6)
                            .animation(.snappy, value: step)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Page \(index + 1)")
                }
            }

            Spacer()

            Button {
                go(+1)
            } label: {
                HStack(spacing: 5) {
                    Text(step == pageCount - 1 ? "Get Started" : "Next")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.dotActive)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .white.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: theme.dotActive.opacity(0.3), radius: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(step == pageCount - 1 ? "Finish the guide" : "Next page")
        }
        .animation(.snappy, value: step)
    }

    // MARK: - Page content

    @ViewBuilder
    private var pageBody: some View {
        ZStack(alignment: .top) {
            switch step {
            case 0: libraryPage
            case 1: packTypesPage
            case 2: cueLabPage
            case 3: addSongsPage
            case 4: makePlaylistsPage
            default: metroGlassPage
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .id("page-\(step)")
        .transition(reduceMotion ? .opacity : pageTransition)
        .animation(.snappy, value: step)
    }

    /// Page 1 — the .cluster library, with a real-name chain visual.
    private var libraryPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Everything lives inside one “.cluster” library. Choose it once and Cella remembers it on every launch — Apple Photos–style.")
                .font(.system(size: 13.5))
                .foregroundStyle(theme.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                chainCard(icon: "books.vertical.fill", name: libraryName, ext: ".cluster")
                chevron
                chainCard(icon: "music.note.list", name: "Playlist", ext: ".cella")
                chevron
                chainCard(icon: "folder.fill", name: "Album", ext: "")
            }
            .padding(.vertical, 4)

            Text("Change Library (top right) switches or creates one any time — playlists, albums and cached analysis all move with it.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .lineSpacing(3)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(theme.textSecondary.opacity(0.6))
    }

    private func chainCard(icon: String, name: String, ext: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(theme.dotActive)
            Text(name)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: 108)
                .truncationMode(.middle)
            Text(ext.isEmpty ? "folder of songs" : ext)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 136)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.textSecondary.opacity(0.1))
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.16), .white.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
    }

    /// Page 2 — OpenCella vs Cella Structured, with the real folder layout
    /// each kind scans (mirrors ClusterLibrary's discovery rules).
    private var packTypesPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                packTypePanel(
                    type: .openCella,
                    tree: [
                        TreeLine(name: "MyPlaylist.cella", style: .root),
                        TreeLine(name: "├─ 01 Skyline.flac", style: .plain),
                        TreeLine(name: "├─ 02 Drift.flac", style: .plain),
                        TreeLine(name: "├─ cover.jpg", style: .plain),
                        TreeLine(name: "└─ lrc/", style: .plain),
                        TreeLine(name: "   ├─ 01 Skyline.lrc", style: .lyric),
                        TreeLine(name: "   └─ 02 Drift.lrc", style: .lyric),
                    ],
                    caption: "Flat songs — names parsed from .lrc tags and folders, shown as one always-visible list."
                )
                packTypePanel(
                    type: .structured,
                    tree: [
                        TreeLine(name: "MyPlaylist.cella", style: .root),
                        TreeLine(name: "├─ Side A.cue", style: .cue),
                        TreeLine(name: "├─ Side A/", style: .plain),
                        TreeLine(name: "│  ├─ 01 Intro.flac", style: .plain),
                        TreeLine(name: "│  ├─ cover.jpg", style: .plain),
                        TreeLine(name: "│  └─ lrc/", style: .plain),
                        TreeLine(name: "│     └─ 01 Intro.lrc", style: .lyric),
                        TreeLine(name: "└─ Side B.cue", style: .cue),
                    ],
                    caption: "One .cue per album — the sheet owns track order, titles and artists."
                )
            }

            Text("The badge on each playlist card tells you which kind it is.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private struct TreeLine {
        let name: String
        let style: TreeStyle
        enum TreeStyle { case root, cue, lyric, plain }
    }

    private func packTypePanel(type: CellaPackType, tree: [TreeLine], caption: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // The very badge the user knows from playlist cards.
            HStack(spacing: 5) {
                Image(systemName: type.icon)
                    .font(.system(size: 10))
                Text(type.label)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(type == .structured ? theme.dotActive : theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill((type == .structured ? theme.dotActive : theme.textSecondary).opacity(0.14))
            )

            VStack(alignment: .leading, spacing: 1) {
                ForEach(tree.indices, id: \.self) { index in
                    treeLine(tree[index])
                }
            }

            Text(caption)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.textSecondary)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.textSecondary.opacity(0.08))
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.14), .white.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
    }

    private func treeLine(_ line: TreeLine) -> some View {
        Text(line.name)
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(line.style == .cue
                ? theme.dotActive
                : line.style == .lyric
                    ? theme.textSecondary
                    : line.style == .root
                        ? theme.textPrimary
                        : theme.textPrimary.opacity(0.75))
    }

    /// Page 6 — Metro Glass: the design language, shown rather than described.
    private var metroGlassPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cella is drawn in one design language \u{2014} Metro Glass: frosted aero cards, a single accent hue, rounded type, and the living water world floating behind this window.")
                .font(.system(size: 13.5))
                .foregroundStyle(theme.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            metroGlassSpecimen
                .frame(height: 128)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            Text("A specimen: the real window backdrop, with one glass card floating on it. Five accent themes live in Config.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .lineSpacing(3)
        }
    }

    /// A real Metro backdrop (live canvases) with a real aero card on top —
    /// the same two layers every screen of the app is built from.
    private var metroGlassSpecimen: some View {
        ZStack {
            MetroBackgroundView()

            HStack(spacing: 10) {
                GuideTile(icon: "music.note", size: 30, iconSize: 13)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Late Radiance")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                    Text("Glass card over the backdrop")
                        .font(.system(size: 8.5))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.3), .white.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.white.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
        .frame(height: 128)
        .contentShape(Rectangle())
    }

    /// Page 3 — CueLab introduction with a mirror of the real toolbar button.
    private var cueLabPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("CueLab writes .cue sheets — the file that turns a loose folder of songs into a Cella Structured playlist with fixed track order, titles and artists.")
                .font(.system(size: 13.5))
                .foregroundStyle(theme.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                GuideButtonGhost(icon: "list.bullet.rectangle.fill", label: "CueLab")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cluster toolbar")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                    Text("Same place as Playlist and Songs.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)

            Text("Sheets land next to each album's audio; Cella picks them up on the next rescan.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .lineSpacing(3)
        }
    }

    /// Page 4 — the three ways songs reach a playlist.
    private var addSongsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            GuideRow(
                icon: "hand.draw",
                title: "Drag & drop",
                text: "Drop songs or whole album folders straight onto a playlist card."
            )
            GuideRow(
                icon: "square.on.square",
                title: "Drop on empty space",
                text: "Cella asks which playlist gets the songs, then files them in."
            )
            GuideRow(
                icon: "music.note.list",
                title: "Toolbar picker",
                text: "The Songs button picks audio files or folders with the same routing."
            )

            Text("Audio is copied into the pack — .lrc metadata is read or written automatically.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .lineSpacing(3)
                .padding(.top, 2)
        }
    }

    /// Page 5 — creating playlists and what to do from a card.
    private var makePlaylistsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                GuideButtonGhost(icon: "folder.badge.plus", label: "Playlist")
                Text("Names a fresh “.cella” pack inside your library — empty and ready for songs.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            GuideRow(
                icon: "cursorarrow.click",
                title: "Right-click a card",
                text: "Rename, Rescan, Reveal in Finder, or Move to Trash without leaving the tab."
            )
            GuideRow(
                icon: "play.fill",
                title: "Play it",
                text: "Hover a cover and hit the play button — the whole pack loads into Cella."
            )
        }
    }

    // MARK: - Navigation

    private func go(_ direction: Int) {
        let next = step + direction
        guard next >= 0, next < pageCount else {
            // Past the final page: the "Next" button acts as the finish CTA.
            if next >= pageCount { close() }
            return
        }
        forward = direction > 0
        withAnimation(.snappy) { step = next }
    }

    private func jump(to target: Int) {
        guard target != step, target >= 0, target < pageCount else { return }
        forward = target > step
        withAnimation(.snappy) { step = target }
    }
}

// MARK: - Guide building blocks

/// Accent icon tile used across the guide (header page icon).
private struct GuideTile: View {
    let icon: String
    let size: CGFloat
    let iconSize: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.dotActive.opacity(0.16))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.2), .white.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            )
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(theme.dotActive)
            )
    }
}

/// One concept row: icon chip + name + explanation.
private struct GuideRow: View {
    let icon: String
    let title: String
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(theme.dotActive.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.dotActive)
                    .offset(x: icon == "play.fill" ? 1 : 0)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
    }
}

/// Mirror of the discover-bar's CTA buttons, so on-page ghosts look exactly
/// like the real ones the user will click.
private struct GuideButtonGhost: View {
    let icon: String
    let label: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(theme.tabSelectedText)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.tabSelectedBackground)
        )
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.25), .white.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
        .fixedSize()
    }
}
