//
//  SongManagerSheet.swift
//  CellaIOS
//
//  The song manager: every song in the library (the Cella Documents folder)
//  plus `.cella` playlists, with tap-to-play, swipe-to-delete, bulk cleanup
//  and import — styled in the Frutiger theme.
//

import SwiftUI
import UniformTypeIdentifiers

struct SongManagerSheet: View {
    let player: IOSPlayerModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var showImporter = false
    /// True when the shared importer is open to pick an `.lrc` instead.
    @State private var pickingLyrics = false
    @State private var pendingDelete: IOSPlayerModel.Track?
    @State private var showDeleteAllConfirm = false

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

    var body: some View {
        VStack(spacing: 10) {
            header
            if !player.playlists.isEmpty {
                playlistBar
            }
            if player.tracks.isEmpty {
                emptyState
            } else {
                songList
            }
            if let notice = player.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .padding(.bottom, 4)
            }
        }
        .padding(.top, 16)
        .background(theme.screenBackground.ignoresSafeArea())
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
        .confirmationDialog(
            "Delete \(pendingDelete.map { "\u{201C}\($0.title)\u{201D}" } ?? "song")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let track = pendingDelete { player.delete(track) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The file and its .lrc lyrics are removed from the Cella folder.")
        }
        .confirmationDialog(
            "Delete all \(player.tracks.count) songs?",
            isPresented: $showDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { player.deleteAllSongs() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every audio file and its .lrc lyrics from the Cella folder. Playlists stay.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Songs")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Text(summaryText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer(minLength: 6)

            Button {
                pickingLyrics = false
                showImporter = true
            } label: {
                headerIcon("plus")
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    pickingLyrics = true
                    showImporter = true
                } label: {
                    Label("Choose .lrc for Current Song…", systemImage: "text.quote")
                }
                .disabled(player.currentTrack == nil)

                Button(role: .destructive) {
                    showDeleteAllConfirm = true
                } label: {
                    Label("Delete All Songs…", systemImage: "trash")
                }
                .disabled(player.tracks.isEmpty)
            } label: {
                headerIcon("ellipsis")
            }

            Button("Done") { dismiss() }
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(headerPill)
        }
        .padding(.horizontal, 22)
    }

    private var summaryText: String {
        let count = player.tracks.count
        guard count > 0 else { return "Nothing here yet" }
        let total = player.tracks.reduce(0) { $0 + $1.duration }
        let playlistNote = player.playlists.isEmpty
            ? ""
            : " · \(player.playlists.count) \(player.playlists.count == 1 ? "playlist" : "playlists")"
        return "\(count) \(count == 1 ? "song" : "songs") · \(Self.format(total)) total\(playlistNote)"
    }

    // MARK: - Playlists

    private var playlistBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                playlistChip(title: "All songs", active: player.activePlaylistID == nil) {
                    player.playAll()
                }
                ForEach(player.playlists) { list in
                    playlistChip(
                        title: list.name,
                        count: list.trackIDs.count,
                        active: player.activePlaylistID == list.id
                    ) {
                        player.play(list)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 3)
        }
    }

    private func playlistChip(
        title: String,
        count: Int? = nil,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if active {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .heavy))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .opacity(0.65)
                }
            }
            .foregroundStyle(active ? theme.dotActive : theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                Capsule()
                    .fill(active ? theme.dotActive.opacity(0.16) : theme.textPrimary.opacity(0.06))
            )
            .overlay(Capsule().stroke(theme.textPrimary.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    private var songList: some View {
        List {
            ForEach(Array(player.tracks.enumerated()), id: \.element.id) { i, track in
                row(i: i, track: track)
                    .listRowInsets(EdgeInsets(top: 3, leading: 22, bottom: 3, trailing: 22))
                    .listRowSeparator(.hidden)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(i == player.index ? theme.dotActive.opacity(0.14) : theme.textPrimary.opacity(0.06))
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = track
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 56)
    }

    private func row(i: Int, track: IOSPlayerModel.Track) -> some View {
        let isCurrent = i == player.index
        return Button {
            if isCurrent {
                player.togglePlay()
            } else {
                player.select(i)
            }
        } label: {
            HStack(spacing: 12) {
                thumb(track)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(isCurrent ? theme.dotActive : theme.textPrimary)
                        .lineLimit(1)
                    Text(track.artist.isEmpty ? "Unknown artist" : track.artist)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if isCurrent {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.dotActive)
                }

                Text(Self.format(track.duration))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func thumb(_ track: IOSPlayerModel.Track) -> some View {
        ZStack {
            if let art = track.artwork {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [theme.dotActive.opacity(0.45), theme.dotInactiveDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.textPrimary.opacity(0.20), lineWidth: 1)
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 26))
                .foregroundStyle(theme.textSecondary)
            Text("No songs yet")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            Text("Tap + to import songs or a .cella playlist,\nor drop a folder into Cella in the Files app.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: - Helpers

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .frame(width: 36, height: 34)
            .background(headerPill)
    }

    private var headerPill: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay(Capsule().fill(theme.appBackground.opacity(0.25)))
            .overlay(Capsule().stroke(theme.textPrimary.opacity(0.18), lineWidth: 1))
    }

    private static func format(_ time: TimeInterval) -> String {
        guard time > 0, time.isFinite else { return "--:--" }
        let total = Int(time.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

#Preview {
    SongManagerSheet(player: IOSPlayerModel())
        .environment(\.theme, .frutiger)
}
