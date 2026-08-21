import SwiftUI
import AppKit

struct ConfigView: View {
    var viewModel: PlayerViewModel
    @Environment(\.theme) private var theme
    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @AppStorage("themeOverride") private var themeOverride: String = "default"
    @AppStorage("displayMode") private var displayMode: String = "matrix"

    private let cardRadius: CGFloat = 18
    private let cardPadding: CGFloat = 28
    private let gridSpacing: CGFloat = 16

    private var cardBorder: some ShapeStyle {
        theme.textSecondary.opacity(0.10)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: gridSpacing) {
                libraryCard

                if viewModel.hasTracks {
                    HStack(alignment: .top, spacing: gridSpacing) {
                        statusCard

                        appearanceCard
                    }

                    audioCard
                } else {
                    HStack(alignment: .top, spacing: gridSpacing) {
                        statusCard
                        appearanceCard
                    }

                    audioCard
                }

                if let error = viewModel.importError {
                    errorCard(error)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Library Card (hero, full width)

    private var libraryCard: some View {
        VStack(spacing: 20) {
            Button(action: selectFolder) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 16, weight: .medium))
                    Text("Import Playlist")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(theme.dotActive)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.playerState.isTransitioning)

            if viewModel.playlistCount > 0 {
                Divider().background(cardBorder)

                HStack(spacing: 20) {
                    statPill(
                        icon: "music.note",
                        value: "\(viewModel.playlistCount)",
                        label: "tracks"
                    )

                    Spacer()
                }
            } else {
                Text("Import a folder to get started")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary.opacity(0.6))
            }
        }
        .padding(.vertical, cardPadding + 6)
        .padding(.horizontal, cardPadding + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.playerState.isPlaying ? Color.green : theme.textSecondary)
                    .frame(width: 8, height: 8)
                Text(stateLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }

            if let status = viewModel.statusText {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No track loaded")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary.opacity(0.6))
            }

            if viewModel.hasTracks {
                Divider()
                    .background(cardBorder)
                    .padding(.vertical, 10)

                QueueView(viewModel: viewModel)
                    .frame(maxHeight: 260)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Appearance Card

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.dotActive)
                Text("Display")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }

            HStack(spacing: 6) {
                ForEach([("matrix", "Matrix"), ("line", "Line"), ("static", "Static")], id: \.0) { id, label in
                    let isSelected = displayMode == id
                    Button {
                        withAnimation(.snappy) {
                            displayMode = id
                        }
                    } label: {
                        Text(label)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .white : theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? theme.dotActive : theme.dotInactive.opacity(0.25))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().background(cardBorder)

            HStack(spacing: 8) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.dotActive)
                Text("Appearance")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textPrimary)
            }

            HStack(spacing: 6) {
                ForEach([("system", "System"), ("dark", "Dark"), ("light", "Light")], id: \.0) { id, label in
                    let isSelected = appearanceMode == id
                    Button {
                        withAnimation(.smooth) {
                            appearanceMode = id
                        }
                    } label: {
                        Text(label)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .white : theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? theme.dotActive : theme.dotInactive.opacity(0.25))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 6) {
                ForEach([("default", "Default"), ("seafoam", "Seafoam")], id: \.0) { id, label in
                    let isSelected = themeOverride == id
                    Button {
                        withAnimation(.smooth) {
                            themeOverride = id
                        }
                    } label: {
                        Text(label)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .white : theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? theme.dotActive : theme.dotInactive.opacity(0.25))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Audio Profile Card

    private var audioCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.dotActive)
                Text("Audio Profile")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(viewModel.currentAudioProfile.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.dotActive)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(AudioProfile.allCases, id: \.self) { profile in
                    let isSelected = profile == viewModel.currentAudioProfile
                    let isSpecial = profile.isSpecial && isSelected
                    Button {
                        withAnimation(.snappy) {
                            viewModel.applyAudioProfile(profile)
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: profile.iconName)
                                .font(.system(size: 16))
                                .foregroundStyle(isSpecial ? .white : isSelected ? .white : theme.textSecondary)
                                .shadow(color: isSpecial ? theme.dotActive.opacity(0.8) : .clear, radius: 8)
                            Text(profile.displayName)
                                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSpecial ? .white : isSelected ? .white : theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 6)
                        .background(
                            Group {
                                if isSpecial {
                                    LinearGradient(
                                        colors: [theme.dotActive, theme.dotActive.opacity(0.6), theme.dotActive],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                } else {
                                    theme.dotActive
                                }
                            }
                            .opacity(isSpecial || isSelected ? 1 : 0.25)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isSpecial || isSelected ? Color.clear : theme.dotInactive)
                                .opacity(isSpecial || isSelected ? 0 : 0.25)
                        )
                        .shadow(color: isSpecial ? theme.dotActive.opacity(0.4) : .clear, radius: 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(isAirPodsMaxSelected ? Color(theme.dotActive).opacity(0.3) : Color(theme.textSecondary).opacity(0.10), lineWidth: 1)
        )
    }

    private var isAirPodsMaxSelected: Bool {
        viewModel.currentAudioProfile == .airpodsMax
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
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func statPill(icon: String, value: String, label: String, accent: Color? = nil) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(accent ?? theme.textSecondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent ?? theme.textPrimary)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private var stateLabel: String {
        switch viewModel.playerState {
        case .idle: return "Idle"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .analyzing: return "Analyzing"
        case .loading: return "Loading"
        case .autoMix: return "AutoMix"
        }
    }

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
