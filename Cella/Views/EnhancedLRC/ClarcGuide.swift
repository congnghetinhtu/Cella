//
//  ClarcGuide.swift
//  Cella
//
//  Format tutorial for the Clarc tab (lyric editor). Five paged glass
//  cards covering the CLARC/1 lyric format — spec: clarc/FORMAT.md in the
//  repo root: the magic line and file layout, the [metadata] section, the
//  timed [lyrics] section, vocalist/harmony/DUO attribution, and the
//  LRC → CLARC conversion flow. Auto-opens once per install
//  (clarcGuideSeen); the header "?" button reopens it any time.
//
//  Presentation mirrors ClusterGuide: the editor posts .clarcGuideRequest
//  (object = true/false) and the overlay lives at the window root
//  (ContentView), so the dim covers the Metro tab bar too.
//
//  Sample rows are the real "Trễ Giờ Cơm" lines from clarc/FORMAT.md.
//

import SwiftUI

// MARK: - Cross-view signal

extension Notification.Name {
    /// The Clarc editor posts this to present (object = true) or retire
    /// (object = false) the format guide. The overlay itself lives at the
    /// window root, so the dim covers the tab bar as well.
    static let clarcGuideRequest = Notification.Name("clarcGuideRequest")
}

// MARK: - Guide overlay

struct ClarcGuideOverlay: View {
    var onClose: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var forward = true

    private let pageCount = 5

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
        .onAppear {
            // Reopening after a tap-out restarts the tour at page 1.
            forward = true
            step = 0
        }
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
            PageMeta(title: "CLARC is a lyric file", icon: "doc.text"),
            PageMeta(title: "Song info: [metadata]", icon: "info.circle.fill"),
            PageMeta(title: "Timing: [lyrics]", icon: "timer"),
            PageMeta(title: "Voices, harmony, DUO", icon: "person.2.fill"),
            PageMeta(title: "LRC → CLARC, in this tab", icon: "arrow.triangle.2.circlepath"),
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
                .id("clarc-guide-title-\(step)")
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
            case 0: magicPage
            case 1: metadataPage
            case 2: lyricTimingPage
            case 3: attributionPage
            default: conversionPage
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .id("clarc-guide-page-\(step)")
        .transition(reduceMotion ? .opacity : pageTransition)
        .animation(.snappy, value: step)
    }

    // MARK: Page 1 — the magic line and the file skeleton

    private var magicPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lyrics live in one plain UTF-8 text file you could edit in any text editor. CLARC/1 is Cella's home format — LRC's familiar timestamps kept, song info separated, and each singer attributable.")
                .font(.system(size: 13.5))
                .foregroundStyle(theme.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            specimen([
                SpecLine(text: "CLARC/1", style: .magic),
                SpecLine(text: " "),
                SpecLine(text: "[metadata]", style: .header),
                SpecLine(text: "title: Song title", lead: "title"),
                SpecLine(text: "artist.1: Main singer", lead: "artist.1"),
                SpecLine(text: " "),
                SpecLine(text: "[lyrics]", style: .header),
                SpecLine(text: "[00:00.00] First lyric line", lead: "[00:00.00]"),
                SpecLine(text: "[00:19.46] Second lyric line", lead: "[00:19.46]"),
            ])

            Text("Always in this order: the CLARC/1 magic line, [metadata] for the song info, [lyrics] for the timed rows. The magic line is the entry card — a reader that doesn't match it exactly knows to step aside.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Page 2 — the [metadata] section

    private var metadataPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Song info lives in key: value rows inside [metadata]. Values are literal text — quotes, punctuation and Unicode stay exactly as written.")
                .font(.system(size: 13.5))
                .foregroundStyle(theme.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            specimen([
                SpecLine(text: "[metadata]", style: .header),
                SpecLine(text: "title: Trễ Giờ Cơm", lead: "title"),
                SpecLine(text: "artist.1: Quang Hùng MasterD", lead: "artist.1"),
                SpecLine(text: "artist.2: Xuân Định K.Y", lead: "artist.2"),
                SpecLine(text: "writer: Trịnh Thăng Bình", lead: "writer"),
                SpecLine(text: "album: TINH HÀ \"SAY HI\", TẬP 13", lead: "album"),
                SpecLine(text: "duration: 05:08", lead: "duration"),
            ])

            VStack(alignment: .leading, spacing: 6) {
                bullet("artist.N numbers the vocalists — v1, v2, v3… A plain artist: still counts as artist.1.")
                bullet("duration uses mm:ss. Unknown keys ride along untouched; duplicate keys are invalid.")
            }
        }
    }

    // MARK: Page 3 — the [lyrics] section and timing

    private var lyricTimingPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Each lyric row carries its beat: [mm:ss.xx] with hundredths of a second, then the text. Lists go in non-decreasing order — the scroll engine rides the stamps line by line.")
                .font(.system(size: 13.5))
                .foregroundStyle(theme.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            specimen([
                SpecLine(text: "[lyrics]", style: .header),
                SpecLine(text: "[00:00.00] …", lead: "[00:00.00]"),
                SpecLine(text: "[00:19.46] Khi xưa tan trường", lead: "[00:19.46]"),
                SpecLine(text: "[00:23.21] Cùng mấy đứa bạn thân", lead: "[00:23.21]"),
                SpecLine(text: "[00:27.71] Ngồi quán net đến hai giờ trưa", lead: "[00:27.71]"),
                SpecLine(text: "[01:27.29] Là có mẹ, có cha, có chúng ta", lead: "[01:27.29]"),
            ])

            VStack(alignment: .leading, spacing: 6) {
                bullet("Equal stamps are allowed — simultaneous rows land together; explicitly backward rows read invalid.")
                bullet("Blank lines are ignored. An empty row still occupies its timed gap in the scroll.")
            }
        }
    }

    // MARK: Page 4 — vocalists, harmony, DUO

    private var attributionPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attribution is metadata, not lyric text: [vN] names the singer, [har …] times a backing-vocal part, and [DUO] splits one row into left and right halves.")
                .font(.system(size: 13.5))
                .foregroundStyle(theme.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            specimen([
                SpecLine(text: "[00:19.46] [v1] Khi xưa tan trường", lead: "[v1]"),
                SpecLine(text: "[00:23.21] [v2] Cùng mấy đứa bạn thân", lead: "[v2]"),
                SpecLine(text: "[01:27.29] [v1&v2] Là có mẹ, có cha", lead: "[v1&v2]"),
                SpecLine(text: "[har 01:28.00] (Ah-ah)", lead: "[har 01:28.00]"),
                SpecLine(text: "[01:13.27] Bàn chân cứ bước đi đất trời [DUO] Vượt qua trùng khơi", lead: "[DUO]"),
            ])

            VStack(alignment: .leading, spacing: 6) {
                bullet("[v1] alone, [v1&v2] together — each ID is the matching artist.N in [metadata].")
                bullet("[har mm:ss.xx] orders like any lyric row; [DUO] never shows on screen — it is layout.")
            }
        }
    }

    // MARK: Page 5 — LRC conversion and tab actions

    private var conversionPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            GuideRow(
                icon: "square.and.arrow.down.on.square",
                title: "Drop a .lrc",
                text: "Confirm the convert sheet — a .clarc sibling is written beside the audio and the old .lrc moves to Trash."
            )
            GuideRow(
                icon: "record.circle",
                title: "Record, then Save",
                text: "R arms tap-timing and M taps each row as the song plays; Save writes Song.clarc into the playlist's lrc folder. Export flips to classic .lrc any time."
            )

            Text("LRC tags land in [metadata] like this:")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .padding(.top, 2)

            specimen([
                SpecLine(text: "[ti: …] → title: …", lead: "[ti:]"),
                SpecLine(text: "[ar: A & B] → artist.1: …, artist.2: …", lead: "[ar:]"),
                SpecLine(text: "[al: …] → album: …", lead: "[al:]"),
                SpecLine(text: "[length:5:08] → duration: 05:08", lead: "[length:]"),
            ])

            Text("Apply an old [offset:] into the stamps first — CLARC has no offset key. Timestamps and text copy over unchanged.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .lineSpacing(3)
        }
    }

    // MARK: - Specimen (monospaced file content)

    private struct SpecLine {
        var text: String
        /// Substring to accent (a metadata key, a stamp, an attributor).
        var lead: String? = nil
        var style: SpecStyle = .plain
        enum SpecStyle { case magic, header, plain }
    }

    private func specimen(_ rows: [SpecLine]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(rows.indices, id: \.self) { index in
                specRow(rows[index])
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

    @ViewBuilder
    private func specRow(_ line: SpecLine) -> some View {
        Group {
            switch line.style {
            case .magic:
                Text(line.text)
                    .foregroundStyle(theme.dotActive)
                    .bold()
            case .header:
                Text(line.text)
                    .foregroundStyle(theme.textPrimary)
                    .bold()
            case .plain:
                if let lead = line.lead, let range = line.text.range(of: lead) {
                    Text(line.text[..<range.upperBound])
                        .foregroundStyle(theme.dotActive)
                        .bold() +
                    Text(line.text[range.upperBound...])
                        .foregroundStyle(theme.textPrimary.opacity(0.85))
                } else {
                    Text(line.text)
                        .foregroundStyle(theme.textPrimary.opacity(0.85))
                }
            }
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(theme.dotActive.opacity(0.6))
                .frame(width: 4.5, height: 4.5)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Navigation

    private func go(_ direction: Int) {
        let next = step + direction
        guard next >= 0, next < pageCount else {
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
// File-local twins of ClusterGuide's private blocks (both files compile the
// private top-level names independently).

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
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textSecondary)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Floating launch pill (docked at the editor's bottom-right)

/// A floating glass pill that opens the format walkthrough card, which
/// presents full-screen at the window root. Stateless by design — the
/// pill only posted the request; the modal owns its own presentation.
struct ClarcGuidePill: View {
    var onTap: () -> Void
    @Environment(\.theme) private var theme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "questionmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.dotActive)
            Text("Guide")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(theme.dotActive.opacity(0.14))
        )
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
        )
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        .scaleEffect(isHovering ? 1.06 : 1.0)
        .animation(.snappy, value: isHovering)
        .contentShape(Capsule())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onTap)
        .help("How CLARC works — open the format guide")
    }
}
