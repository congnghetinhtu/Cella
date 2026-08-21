import SwiftUI
import AppKit

struct ConfigView: View {
    var viewModel: PlayerViewModel
    @Environment(\.theme) private var theme
    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @AppStorage("themeOverride") private var themeOverride: String = "default"

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
                        VStack(spacing: gridSpacing) {
                            statusCard
                            appearanceCard
                        }
                        .frame(maxHeight: .infinity)

                        queueCard
                            .frame(width: 300)
                            .frame(maxHeight: .infinity)
                            .clipped()
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

    // MARK: - Queue Card

    private var queueCard: some View {
        QueueView(viewModel: viewModel)
            .background(theme.screenBackground)
            .clipShape(RoundedRectangle(cornerRadius: cardRadius))
            .clipped()
            .overlay(
                RoundedRectangle(cornerRadius: cardRadius)
                    .stroke(cardBorder, lineWidth: 1)
            )
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            Spacer(minLength: 0)
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

    @AppStorage("displayMode") private var displayMode: String = "matrix"


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

            Picker("Display", selection: $displayMode) {
                Text("Matrix").tag("matrix")
                Text("Line").tag("line")
                Text("Static").tag("static")
            }
            .pickerStyle(.segmented)
            .labelsHidden()



            Divider().background(cardBorder)

            HStack(spacing: 8) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.dotActive)
                Text("Appearance")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textPrimary)
            }

            Picker("Appearance", selection: $appearanceMode) {
                Text("System").tag("system")
                Text("Dark").tag("dark")
                Text("Light").tag("light")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                ForEach([("default", "Default"), ("seafoam", "Seafoam")], id: \.0) { id, label in
                    let isSelected = themeOverride == id
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            themeOverride = id
                        }
                    } label: {
                        Text(label)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .white : theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(isSelected ? theme.dotActive : theme.dotInactive.opacity(0.25))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
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
                    Button {
                        viewModel.applyAudioProfile(profile)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: profile.iconName)
                                .font(.system(size: 16))
                                .foregroundStyle(isSelected ? .white : theme.textSecondary)
                            Text(profile.displayName)
                                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? .white : theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 6)
                        .background(isSelected ? theme.dotActive : theme.dotInactive.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                .stroke(cardBorder, lineWidth: 1)
        )
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
