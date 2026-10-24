//
//  NowPlayingScreen.swift
//  CellaIOS
//
//  The one now-playing screen: aero backdrop, synced lyrics up top, then the
//  bare transport icons, the progress bar and a flat cover + title row —
//  plus the song manager and song/folder import. Single Frutiger theme.
//

import SwiftUI
import UniformTypeIdentifiers

struct NowPlayingScreen: View {
    let player: IOSPlayerModel
    @Binding var whiteMode: Bool

    @Environment(\.scenePhase) private var scenePhase
    @State private var showImporter = false
    @State private var showSongs = false
    /// True when the shared importer is open to pick an `.lrc` instead.
    @State private var pickingLyrics = false

    /// Frutiger blue glass by default; tapping the playing pill flips the
    /// whole screen to the white day look and back. The theme environment is
    /// injected once by the app, keyed off this binding.
    private var theme: Theme { whiteMode ? .frutigerLight : .frutiger }

    /// Files, folders, .lrc lyrics and .cella playlists are all importable.
    private var importTypes: [UTType] {
        var types: [UTType] = [.audio, .plainText, .folder, .data]
        if let lrc = UTType(filenameExtension: "lrc") { types.append(lrc) }
        if let cella = UTType(filenameExtension: "cella") { types.append(cella) }
        return types
    }

    /// Only `.lrc` (or plain text) is useful for the lyrics picker.
    private var lyricsTypes: [UTType] {
        if let lrc = UTType(filenameExtension: "lrc") { return [lrc, .plainText] }
        return [.plainText, .data]
    }

    private var infoSubtitle: String {
        guard let track = player.currentTrack else {
            return "Import songs or a folder with +"
        }
        return track.artist.isEmpty ? "Unknown artist" : track.artist
    }

    var body: some View {
        ZStack {
            if whiteMode {
                Color.white
                    .ignoresSafeArea()
                    .transition(.opacity)
            } else {
                MetroBackgroundView()
                    .ignoresSafeArea()
                    .transition(.opacity)
                Color.black.opacity(0.20)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            VStack(spacing: 14) {
                topBar
                lyricsBlock
                IOSTransportRow(
                    isPlaying: player.isPlaying,
                    canPlay: player.currentTrack != nil,
                    accent: AnyShapeStyle(theme.textPrimary),
                    onPlayPause: { player.togglePlay() },
                    onPrev: { player.previous() },
                    onNext: { player.next() }
                )
                IOSProgressBar(
                    currentTime: player.currentTime,
                    duration: player.duration,
                    accent: AnyShapeStyle(LinearGradient(
                        colors: [theme.dotActive, theme.dotActive.opacity(0.75)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )),
                    glow: whiteMode
                        ? Color(hex: 0x1D3B54).opacity(0.4)
                        : theme.dotActive
                ) { fraction in
                    player.seek(toFraction: fraction)
                }
                IOSNowPlayingRow(
                    artwork: player.artwork,
                    title: player.currentTrack?.title ?? "Nothing playing",
                    subtitle: infoSubtitle
                )
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.35)) { whiteMode.toggle() }
                }
                if let notice = player.notice {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .background(whiteMode ? Color.white : Color.black)
        .preferredColorScheme(whiteMode ? .light : .dark)
        .task { player.start() }
        .onChange(of: scenePhase) { _, phase in
            // Files dropped in via Finder/Files while we were away show up
            // here; leaving the app saves what to restore next launch.
            if phase == .active {
                player.reloadLibrary()
            } else {
                player.persistState()
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: pickingLyrics ? lyricsTypes : importTypes,
            allowsMultipleSelection: !pickingLyrics
        ) { result in
            guard case .success(let urls) = result else { return }
            if pickingLyrics {
                if let url = urls.first { player.assignLyrics(from: url) }
            } else {
                player.importFiles(urls)
            }
            pickingLyrics = false
        }
        .sheet(isPresented: $showSongs) {
            SongManagerSheet(player: player)
                .environment(\.theme, theme)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.screenBackground)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "water.waves")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.dotActive)
                Text("CELLA")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(pillBackground)

            Spacer(minLength: 0)

            songsButton
            importButton
        }
    }

    private var songsButton: some View {
        Button {
            showSongs = true
        } label: {
            topBarIcon("music.note.list")
        }
        .buttonStyle(.plain)
        .help("Song manager")
    }

    private var importButton: some View {
        Button {
            pickingLyrics = false
            showImporter = true
        } label: {
            topBarIcon("plus")
        }
        .buttonStyle(.plain)
        .help("Import songs, folders, .lrc lyrics or .cella playlists")
    }

    private func topBarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .frame(width: 36, height: 34)
            .background(pillBackground)
    }

    private var pillBackground: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay(Capsule().fill(theme.screenBackground.opacity(0.3)))
            .overlay(Capsule().stroke(theme.textPrimary.opacity(0.18), lineWidth: 1))
    }

    // MARK: - Lyrics

    private var lyricsBlock: some View {
        Group {
            if player.hasLyrics {
                LyricsView(
                    lyrics: player.lyrics,
                    currentTime: player.currentTime,
                    isPlaying: player.isPlaying,
                    textAlignment: .leading,
                    lineHeight: 84,
                    fontSize: 22,
                    visibleLines: 5,
                    maxLines: 2,
                    uniformLineSize: true,
                    textBase: theme.textPrimary,
                    currentLineStyle: whiteMode ? AnyShapeStyle(FrutigerDay.gradient) : nil
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: player.currentTrack == nil ? "waveform" : "text.quote")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.textSecondary)
                    Text(player.currentTrack == nil
                         ? "Import songs or a folder with the + button,\nor drop them into the Cella folder in Files."
                         : "No lyrics for this song yet.\nAdd a matching .lrc file next to it.")
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.textSecondary)
                    if player.currentTrack != nil {
                        Button {
                            pickingLyrics = true
                            showImporter = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "text.quote")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Choose .lrc…")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(pillBackground)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    NowPlayingScreen(player: IOSPlayerModel(), whiteMode: .constant(false))
        .environment(\.theme, .frutiger)
}
