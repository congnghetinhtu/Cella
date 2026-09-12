import SwiftUI
import AppKit

struct ConfigView: View {
    var viewModel: PlayerViewModel
    @Environment(\.theme) private var theme
    @AppStorage("themeOverride") private var themeOverride: String = "seafoam"

    private let cardRadius: CGFloat = 18
    private let cardPadding: CGFloat = 28
    private let gridSpacing: CGFloat = 16

    private var cardBorder: some ShapeStyle {
        theme.textSecondary.opacity(0.10)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: gridSpacing) {
                importBar

                orquestaCard

                appInfoCard

                if let error = viewModel.importError {
                    errorCard(error)
                        .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.97)))
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
            .animation(.smooth, value: viewModel.hasTracks)
            .animation(.smooth, value: viewModel.importError)
        }
    }

    // MARK: - Import Bar (compact top row)

    private var importBar: some View {
        HStack(spacing: 12) {
            // Status dot — only visible when player is active
            if viewModel.playerState != .idle {
                Circle()
                    .fill(viewModel.playerState.isPlaying ? Color.green : theme.textSecondary)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .fill(Color.green.opacity(0.4))
                            .frame(width: 8, height: 8)
                            .scaleEffect(viewModel.playerState.isPlaying ? 1.8 : 1.0)
                            .opacity(viewModel.playerState.isPlaying ? 0 : 1)
                            .animation(
                                .easeOut(duration: 1.2).repeatForever(autoreverses: false),
                                value: viewModel.playerState.isPlaying
                            )
                    )
            }

            if viewModel.playlistCount > 0 {
                Text("\(viewModel.playlistCount) tracks")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer()

            Button(action: selectFolder) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                    Text(viewModel.playlistCount > 0 ? "Import" : "Import Playlist")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(theme.dotActive)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.playerState.isTransitioning)
        }
        .padding(.horizontal, cardPadding)
        .padding(.vertical, 12)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Orquesta (full width hero)

    private var orquestaCard: some View {
        OrquestaView(viewModel: viewModel)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - App Info Card

    private var appInfoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.dotActive)
                Text("About")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }

            Divider().background(cardBorder)

            HStack(alignment: .top, spacing: 32) {
                appInfoColumn(
                    title: "Cella",
                    lines: [
                        "macOS music player",
                        "Swift / SwiftUI frontend",
                        "OpenMix analysis engine",
                        "Beat-aligned crossfades"
                    ]
                )

                appInfoColumn(
                    title: "OpenMix",
                    lines: [
                        "Python audio analysis",
                        "BPM, key, energy, vocals",
                        "Equal-power crossfade",
                        "Vocal-aware ducking"
                    ]
                )

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Text("Developer")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSecondary.opacity(0.6))
                    Text("Thanh Solar NEXT")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Owner")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)

                    Spacer().frame(height: 6)

                    Text("Publisher")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSecondary.opacity(0.6))
                    Text("Tic")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                }
            }
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    private func appInfoColumn(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    // MARK: - Error Card

    private func errorCard(_ error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.red)
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .lineLimit(3)
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose .cella Playlist"
        panel.message = "Select a .cella playlist folder"

        let result = panel.runModal()
        print("[ConfigView] Panel result: \(result.rawValue), url: \(panel.url?.path ?? "nil")")

        if result == .OK, let url = panel.url {
            guard url.pathExtension.lowercased() == "cella" else {
                viewModel.importError = "Not a .cella playlist. Rename folder with .cella extension."
                print("[ConfigView] ERROR: Selected folder is not .cella: \(url.lastPathComponent)")
                return
            }
            viewModel.importViaOpenMix(url: url)
        }
    }
}
