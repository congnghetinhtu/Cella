//
//  IOSPlayerModel.swift
//  CellaIOS
//
//  Playback core: everything the user imports into the app's Documents
//  folder (which Files/Finder can also drop into), `.cella` playlists,
//  .lrc lookup next to the audio, metadata/artwork extraction, and a
//  display-link clock that drives the shared LyricsView and the progress bar.
//

import AVFoundation
import CryptoKit
import Foundation
import MediaPlayer
import Observation
import UIKit

@MainActor
@Observable
final class IOSPlayerModel {
    struct Track: Identifiable, Equatable {
        let id: String
        let url: URL
        var title: String
        var artist: String
        var duration: TimeInterval = 0
        var artwork: UIImage?

        static func == (a: Track, b: Track) -> Bool { a.id == b.id }
    }

    /// A `.cella` playlist: a named list of songs drawn from the library.
    struct Playlist: Identifiable, Equatable {
        let id: String      // playlist file path
        let url: URL
        var name: String
        /// Library track ids in playlist order; unresolved entries dropped.
        var trackIDs: [String]
        /// Entries that didn't match any song in the library.
        var missing: Int
    }

    /// Extensions the Documents library picks up.
    nonisolated static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "aif", "aiff", "caf", "flac", "alac", "ogg"
    ]

    // MARK: - Observable state

    private(set) var tracks: [Track] = []
    private(set) var playlists: [Playlist] = []
    /// Set while a playlist drives the play queue; nil means the library.
    private(set) var activePlaylistID: String?
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var lyrics: [LrcLine] = []
    private(set) var artwork: UIImage?
    /// Transient import/playback message; auto-clears.
    private(set) var notice: String?

    // MARK: - Engine

    private var player: AVAudioPlayer?
    private var displayLink: CADisplayLink?
    private let finishDelegate = FinishDelegate()
    private let linkProxy = DisplayLinkProxy()
    private var observers: [NSObjectProtocol] = []
    private var wasPlayingBeforeInterruption = false
    private var nowPlayingPulse = 0
    /// Track ids of the active playlist, in order. Empty = whole library.
    private var activeQueueIDs: [String] = []
    /// Guards the async duplicate sweep against overlapping runs.
    private var isCleaningDuplicates = false

    var currentTrack: Track? { tracks.indices.contains(index) ? tracks[index] : nil }
    var activePlaylist: Playlist? { playlists.first { $0.id == activePlaylistID } }
    var progress: Double { duration > 0 ? min(1, max(0, currentTime / duration)) : 0 }
    var totalDuration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }
    var hasLyrics: Bool { !lyrics.isEmpty }

    init() {
        finishDelegate.onFinish = { [weak self] in
            Task { @MainActor in self?.advance(by: 1) }
        }
        linkProxy.onTick = { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: - Lifecycle

    func start() {
        configureSession()
        observeAudioSession()
        configureRemoteCommands()
        restoreSelectedPlaylist()
        reloadLibrary()
        guard !tracks.isEmpty else { return }
        restoreLastTrack()
    }

    /// Brings back the playlist chosen last session; `reloadLibrary()` then
    /// rebuilds its queue from that id.
    private func restoreSelectedPlaylist() {
        if let path = UserDefaults.standard.string(forKey: Keys.activePlaylist) {
            activePlaylistID = path
        }
    }

    /// Re-opens the song and position from last session, paused.
    private func restoreLastTrack() {
        let defaults = UserDefaults.standard
        let savedTrack = defaults.string(forKey: Keys.lastTrack)
        let savedPosition = defaults.double(forKey: Keys.position)
        if let savedTrack, let i = tracks.firstIndex(where: { $0.id == savedTrack }) {
            load(index: i, autoplay: false)
            if savedPosition > 1, duration > 0, savedPosition < duration - 2 {
                seek(toTime: savedPosition)
            }
        } else if player == nil {
            load(index: min(index, tracks.count - 1), autoplay: false)
        }
    }

    // MARK: - Persistence

    private enum Keys {
        static let activePlaylist = "cella.activePlaylistPath"
        static let lastTrack = "cella.lastTrackPath"
        static let position = "cella.lastPosition"
    }

    /// Remembers the playlist, the song on deck and how far into it the user
    /// was, so the next launch opens where they left off.
    func persistState() {
        let defaults = UserDefaults.standard
        defaults.set(activePlaylistID, forKey: Keys.activePlaylist)
        defaults.set(currentTrack?.id, forKey: Keys.lastTrack)
        defaults.set(currentTime, forKey: Keys.position)
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    // MARK: - Library

    nonisolated static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Rebuilds the track list from Documents (alphabetical) and re-resolves
    /// `.cella` playlists. Keeps the current song selected when it still
    /// exists.
    func reloadLibrary() {
        var rebuilt: [Track] = []
        // Documents is scanned recursively, so a whole folder of songs dropped
        // in through Files/Finder (at any depth) is read as-is.
        var found: [URL] = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        if let enumerator = FileManager.default.enumerator(
            at: Self.documentsURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                if (try? url.resourceValues(forKeys: keys))?.isRegularFile == false { continue }
                found.append(url)
            }
        }
        found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        for url in found {
            rebuilt.append(Track(
                id: url.path,
                url: url,
                title: url.deletingPathExtension().lastPathComponent,
                artist: ""
            ))
        }

        let currentID = currentTrack?.id
        tracks = rebuilt
        index = currentID.flatMap { id in rebuilt.firstIndex { $0.id == id } } ?? 0
        rebuildPlaylists()
        loadMetadata()
        refreshLyricsForCurrent()
        cleanDuplicateFiles()
    }

    // MARK: - Playlists (.cella)

    /// Re-reads every `.cella` file in Documents and re-resolves its entries
    /// against the library. The active playlist follows the reload; songs
    /// that disappeared drop out of its queue.
    private func rebuildPlaylists() {
        var files: [URL] = []
        var folders: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: Self.documentsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "cella" {
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isFolder { folders.append(url) } else { files.append(url) }
            }
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        folders.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        playlists = files.compactMap { loadPlaylist(at: $0) }
            + folders.compactMap { loadPlaylistFolder(at: $0) }

        if let activeID = activePlaylistID {
            if let active = playlists.first(where: { $0.id == activeID }), !active.trackIDs.isEmpty {
                activeQueueIDs = active.trackIDs
            } else {
                // The playlist vanished or has no playable songs left.
                activePlaylistID = nil
                activeQueueIDs = []
            }
        }
    }

    /// Reads one `.cella` file. The format is forgiving — JSON
    /// (`{"name": "...", "tracks": ["A.m4a", ...]}`), a bare JSON array, or a
    /// plain text list with one song per line (`#` comments ignored). Entries
    /// may be filenames, paths below Cella, or song titles.
    private func loadPlaylist(at url: URL) -> Playlist? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var name = url.deletingPathExtension().lastPathComponent
        var entries: [String] = []

        if let object = try? JSONSerialization.jsonObject(with: data) {
            if let dict = object as? [String: Any] {
                let jsonName = (dict["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                if !jsonName.isEmpty { name = jsonName }
                entries = (dict["tracks"] as? [String]) ?? (dict["songs"] as? [String]) ?? []
            } else if let list = object as? [String] {
                entries = list
            }
        } else if let text = String(data: data, encoding: .utf8) {
            entries = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }

        var ids: [String] = []
        var missing = 0
        for entry in entries {
            if let track = Self.resolve(entry, in: tracks) {
                if !ids.contains(track.id) { ids.append(track.id) }
            } else if !entry.trimmingCharacters(in: .whitespaces).isEmpty {
                missing += 1
            }
        }
        return Playlist(id: url.path, url: url, name: name, trackIDs: ids, missing: missing)
    }

    /// A folder named `<name>.cella` is a playlist too: every audio file
    /// inside it (at any depth), in alphabetical order. Empty folders are
    /// skipped so leftover duplicates don't show as blank playlists.
    private func loadPlaylistFolder(at url: URL) -> Playlist? {
        var found: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let file as URL in enumerator
            where Self.audioExtensions.contains(file.pathExtension.lowercased()) {
                found.append(file)
            }
        }
        guard !found.isEmpty else { return nil }
        found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let ids = found.compactMap { file in tracks.first { $0.id == file.path }?.id }
        return Playlist(
            id: url.path,
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            trackIDs: ids,
            missing: 0
        )
    }

    /// Matches a playlist entry against the library: full path suffix first,
    /// then filename, then filename without extension, then song title.
    private static func resolve(_ entry: String, in library: [Track]) -> Track? {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let stem = (trimmed as NSString).deletingPathExtension.lowercased()
        if let track = library.first(where: { $0.url.path.lowercased().hasSuffix("/" + lower) }) {
            return track
        }
        if let track = library.first(where: {
            $0.url.deletingPathExtension().lastPathComponent.lowercased() == stem
        }) {
            return track
        }
        return library.first { $0.title.lowercased() == lower }
    }

    /// Copies picked files into Documents so playback never depends on
    /// security-scoped URLs, then refreshes the list.
    ///
    /// Imports merge: a file Cella already holds (same name and byte size) is
    /// skipped instead of copied again, and folders merge into their existing
    /// copy — re-importing can't duplicate a song.
    func importFiles(_ urls: [URL]) {
        let before = tracks.count
        let beforePlaylistIDs = Set(playlists.map(\.id))
        var roots: [URL] = []
        var seen = Self.existingFileKeys()
        var skipped = 0
        var folderCount = 0

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isFolder {
                folderCount += 1
                let root = Self.documentsURL.appendingPathComponent(url.lastPathComponent, isDirectory: true)
                let result = Self.mergeFolder(url, into: root, seen: &seen)
                skipped += result.skipped
                if result.copied > 0 { roots.append(root) }
            } else if let dest = Self.mergeFile(url, into: Self.documentsURL, seen: &seen) {
                roots.append(dest)
            } else {
                skipped += 1
            }
        }

        guard !roots.isEmpty || skipped > 0 else { return }
        reloadLibrary()

        // Select the first newly imported song when nothing is playing.
        if !isPlaying,
           let imported = tracks.first(where: { track in
               roots.contains { track.url.path.hasPrefix($0.path) }
           }),
           let i = tracks.firstIndex(of: imported) {
            load(index: i, autoplay: false)
        }

        let added = max(0, tracks.count - before)
        let newPlaylists = playlists.filter { !beforePlaylistIDs.contains($0.id) }

        // A freshly imported playlist is ready to play: it becomes the queue
        // and starts when nothing else is on. No song is added by it.
        if !isPlaying, let fresh = newPlaylists.first(where: { !$0.trackIDs.isEmpty }) {
            play(fresh)
            return
        }

        let playlistNote = newPlaylists.count == 1
            ? "playlist \(newPlaylists[0].name)"
            : "\(newPlaylists.count) playlists"
        if added == 0, !newPlaylists.isEmpty {
            flashNotice("Imported \(playlistNote)")
        } else if added == 0 {
            flashNotice(skipped > 0
                ? "Already in Cella"
                : (folderCount > 0 ? "No audio found in the folder" : "Nothing new to import"))
        } else if added == 1, skipped == 0, folderCount == 0, roots.count == 1 {
            flashNotice("Imported \(roots[0].lastPathComponent)")
        } else {
            let duplicateNote = skipped > 0 ? " · \(skipped) already in Cella" : ""
            flashNotice("Imported \(added) \(added == 1 ? "song" : "songs")\(duplicateNote)")
        }
    }

    /// Name + byte-size keys for everything already in Documents — the cheap
    /// identity check that keeps re-imports from duplicating songs.
    private static func existingFileKeys() -> Set<String> {
        var keys: Set<String> = []
        guard let enumerator = FileManager.default.enumerator(
            at: documentsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return keys }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            keys.insert("\(url.lastPathComponent.lowercased())|\(size)")
        }
        return keys
    }

    private static func fileKey(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return "\(url.lastPathComponent.lowercased())|\(size)"
    }

    /// Copies a single picked file, skipping it when Cella already holds an
    /// identical one. Returns the new path when it was copied.
    private static func mergeFile(_ url: URL, into folder: URL, seen: inout Set<String>) -> URL? {
        let fm = FileManager.default
        let key = fileKey(url)
        if seen.contains(key) { return nil }
        var target = folder.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: target.path) {
            // Same name, different content — keep both with a numbered suffix.
            target = uniqueDestination(for: url, in: folder)
        }
        do {
            try fm.copyItem(at: url, to: target)
            seen.insert(key)
            return target
        } catch {
            return nil
        }
    }

    /// Merges a picked folder into its Cella counterpart: subfolders are
    /// created as needed and identical files are skipped, so dropping the same
    /// folder twice duplicates nothing.
    private static func mergeFolder(
        _ folder: URL,
        into root: URL,
        seen: inout Set<String>
    ) -> (copied: Int, skipped: Int) {
        let fm = FileManager.default
        var copied = 0
        var skipped = 0
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return (0, 0) }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            let relative = relativePath(of: url, from: folder)
            guard !relative.isEmpty else { continue }
            let target = root.appendingPathComponent(relative)
            if values?.isDirectory == true {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            let key = fileKey(url)
            if seen.contains(key) { skipped += 1; continue }
            var destination = target
            if fm.fileExists(atPath: destination.path) {
                destination = uniqueDestination(for: url, in: target.deletingLastPathComponent())
            }
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: destination)
                seen.insert(key)
                copied += 1
            } catch {
                skipped += 1
            }
        }
        return (copied, skipped)
    }

    private static func relativePath(of url: URL, from root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count > rootComponents.count else { return "" }
        return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func uniqueDestination(for url: URL, in folder: URL) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var dest = folder.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            dest = folder.appendingPathComponent(name)
            n += 1
        }
        return dest
    }

    private func flashNotice(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notice == message { notice = nil }
        }
    }

    // MARK: - Song manager

    /// Deletes one song — audio file plus its matching `.lrc` — and re-homes
    /// playback when it was the song on deck.
    func delete(_ track: Track) {
        let wasCurrent = track.id == currentTrack?.id
        let wasPlaying = isPlaying
        guard Self.removeFiles(for: track) else {
            flashNotice("Couldn't delete \(track.title)")
            return
        }
        if wasCurrent { clearPlayback() }
        reloadLibrary()
        if wasCurrent, !tracks.isEmpty { load(index: index, autoplay: wasPlaying) }
        Self.pruneEmptyFolders()
        flashNotice("Deleted \(track.title)")
    }

    /// Wipes every song in the library.
    func deleteAllSongs() {
        guard !tracks.isEmpty else { return }
        clearPlayback()
        var removed = 0
        for track in tracks where Self.removeFiles(for: track) { removed += 1 }
        reloadLibrary()
        Self.pruneEmptyFolders()
        flashNotice(removed == 1 ? "Deleted 1 song" : "Deleted \(removed) songs")
    }

    /// Removes the audio file first (so a failure keeps the track listed),
    /// then any `.lrc` with the same stem next to it or in an `lrc/` folder.
    nonisolated private static func removeFiles(for track: Track) -> Bool {
        do {
            try FileManager.default.removeItem(at: track.url)
        } catch {
            return false
        }
        removeLyricFiles(for: track)
        return true
    }

    /// Deletes every `.lrc` that pairs with the track — dash/accent variants
    /// included, next to it or in an `lrc/` folder.
    nonisolated private static func removeLyricFiles(for track: Track) {
        let fm = FileManager.default
        let dir = track.url.deletingLastPathComponent()
        let stem = normalizedStem(track.url.deletingPathExtension().lastPathComponent)
        for folder in [dir, dir.appendingPathComponent("lrc", isDirectory: true)] {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension.lowercased() == "lrc"
                && normalizedStem(file.deletingPathExtension().lastPathComponent) == stem {
                try? fm.removeItem(at: file)
            }
        }
    }

    /// Stops and resets the engine — used when the current song is deleted.
    private func clearPlayback() {
        stopTicker()
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        lyrics = []
        artwork = nil
        publishNowPlaying()
    }

    /// Removes folders left empty in Documents after deletions (deepest
    /// first, so nested empty folders go too).
    private static func pruneEmptyFolders() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: documentsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var folders: [URL] = []
        for case let url as URL in enumerator
        where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            folders.append(url)
        }
        for folder in folders.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            if let contents = try? fm.contentsOfDirectory(atPath: folder.path), contents.isEmpty {
                try? fm.removeItem(at: folder)
            }
        }
    }

    // MARK: - Duplicate cleanup

    /// Removes byte-identical copies of the same audio — the numbered files
    /// ("Song 2.m4a", "Song 3.m4a") that earlier imports could leave behind.
    /// Hashes run off the main thread; a found set reloads the library once.
    private func cleanDuplicateFiles() {
        guard !isCleaningDuplicates else { return }
        isCleaningDuplicates = true
        let snapshot = tracks
        let currentID = currentTrack?.id
        Task.detached(priority: .utility) {
            let removed = Self.removeDuplicateFiles(among: snapshot, keeping: currentID)
            let tidy = Self.tidyPlaylistFolders()
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard removed > 0 || tidy.moved > 0 || tidy.removed > 0 else {
                    self.isCleaningDuplicates = false
                    return
                }
                // Flag stays set through the reload so it doesn't re-hash.
                self.reloadLibrary()
                Self.pruneEmptyFolders()
                self.isCleaningDuplicates = false
                if removed > 0 {
                    self.flashNotice("Removed \(removed) duplicate \(removed == 1 ? "file" : "files")")
                }
            }
        }
    }

    /// Deletes extra byte-identical copies, keeping the current song's file
    /// when it is part of the group, otherwise the un-numbered original.
    nonisolated private static func removeDuplicateFiles(
        among tracks: [Track],
        keeping currentID: String?
    ) -> Int {
        // Same-size prefilter keeps hashing cheap for unique files.
        var bySize: [Int: [Track]] = [:]
        for track in tracks {
            guard let size = (try? track.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            bySize[size, default: []].append(track)
        }

        var removed = 0
        for sameSize in bySize.values where sameSize.count > 1 {
            var byHash: [String: [Track]] = [:]
            for track in sameSize {
                guard let hash = contentHash(of: track.url) else { continue }
                byHash[hash, default: []].append(track)
            }
            for copies in byHash.values where copies.count > 1 {
                let keeper = copies.first { $0.id == currentID }
                    ?? copies.min { lhs, rhs in
                        let l = lhs.url.deletingPathExtension().lastPathComponent.lowercased()
                        let r = rhs.url.deletingPathExtension().lastPathComponent.lowercased()
                        return l == r ? lhs.url.path < rhs.url.path : l < r
                    }!
                // A duplicate folder may hold the only copy of the lyrics —
                // carry it over when the keeper has none.
                if lrcURL(for: keeper.url) == nil {
                    for copy in copies where copy.id != keeper.id {
                        guard let lrc = lrcURL(for: copy.url) else { continue }
                        let dest = keeper.url.deletingPathExtension().appendingPathExtension("lrc")
                        if (try? FileManager.default.moveItem(at: lrc, to: dest)) != nil { break }
                    }
                }
                for copy in copies where copy.id != keeper.id {
                    if removeFiles(for: copy) { removed += 1 }
                }
            }
        }
        return removed
    }

    nonisolated private static func contentHash(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Tidies playlist folders left behind by duplicate imports: lyrics in an
    /// emptied `<name>.cella` folder are adopted by the surviving copy, then
    /// the emptied duplicate folder is removed.
    nonisolated private static func tidyPlaylistFolders() -> (moved: Int, removed: Int) {
        let fm = FileManager.default
        var folders: [URL] = []
        if let enumerator = fm.enumerator(
            at: documentsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "cella" {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    folders.append(url)
                }
            }
        }

        func audioFiles(in folder: URL) -> [URL] {
            var found: [URL] = []
            if let enumerator = fm.enumerator(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let url as URL in enumerator
                where audioExtensions.contains(url.pathExtension.lowercased()) {
                    found.append(url)
                }
            }
            return found
        }

        var playableByBase: [String: [URL]] = [:]
        for folder in folders where !audioFiles(in: folder).isEmpty {
            playableByBase[playlistBaseName(folder), default: []].append(folder)
        }

        var moved = 0
        var removed = 0
        for folder in folders where audioFiles(in: folder).isEmpty {
            let siblings = playableByBase[playlistBaseName(folder)] ?? []
            guard siblings.count == 1, let target = siblings.first else { continue }

            // Carry the lyrics over, keeping them in an `lrc/` subfolder if
            // that is where they lived.
            var lyrics: [URL] = []
            if let enumerator = fm.enumerator(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in enumerator
                where url.pathExtension.lowercased() == "lrc" {
                    lyrics.append(url)
                }
            }
            for lyric in lyrics {
                let inLrcFolder = lyric.deletingLastPathComponent().lastPathComponent.lowercased() == "lrc"
                let dir = inLrcFolder
                    ? target.appendingPathComponent("lrc", isDirectory: true)
                    : target
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(lyric.lastPathComponent)
                if (try? fm.moveItem(at: lyric, to: dest)) != nil { moved += 1 }
            }

            if isEmptyTree(folder), (try? fm.removeItem(at: folder)) != nil {
                removed += 1
            }
        }
        return (moved, removed)
    }

    /// "Music 2.cella" → "music", so duplicate-import copies group together.
    nonisolated private static func playlistBaseName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: #"\s+([2-9]|[1-9]\d)$"#, with: "", options: .regularExpression)
        return normalizedStem(name)
    }

    nonisolated private static func isEmptyTree(_ url: URL) -> Bool {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for item in contents {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if !isEmptyTree(item) { return false }
            } else {
                return false
            }
        }
        return true
    }

    // MARK: - Transport

    func select(_ i: Int) {
        // Picking a song outside the active playlist leaves playlist mode;
        // picking one inside keeps the queue intact.
        if activePlaylistID != nil, tracks.indices.contains(i),
           !activeQueueIDs.contains(tracks[i].id) {
            activePlaylistID = nil
            activeQueueIDs = []
        }
        load(index: i, autoplay: true)
    }

    /// Starts a playlist from its first song and makes it the play queue.
    func play(_ playlist: Playlist) {
        let ids = playlist.trackIDs.filter { id in tracks.contains { $0.id == id } }
        guard !ids.isEmpty else {
            flashNotice(playlist.missing > 0
                ? "\(playlist.name): no matching songs found"
                : "\(playlist.name) is empty")
            return
        }
        activePlaylistID = playlist.id
        activeQueueIDs = ids
        if let first = ids.first, let i = tracks.firstIndex(where: { $0.id == first }) {
            load(index: i, autoplay: true)
        }
        persistState()
        flashNotice("Playing \(playlist.name)")
    }

    /// Leaves playlist mode. Keeps the current song going when something is
    /// already loaded; otherwise starts the library from the top.
    func playAll() {
        activePlaylistID = nil
        activeQueueIDs = []
        if player == nil, !tracks.isEmpty {
            load(index: 0, autoplay: true)
        }
        persistState()
    }

    func togglePlay() {
        if let p = player {
            if p.isPlaying {
                p.pause()
                isPlaying = false
                stopTicker()
            } else {
                try? AVAudioSession.sharedInstance().setActive(true)
                p.play()
                isPlaying = true
                startTicker()
            }
        } else if !tracks.isEmpty {
            load(index: index, autoplay: true)
        }
        publishNowPlaying()
        persistState()
    }

    func next() { advance(by: 1) }

    func previous() {
        guard !tracks.isEmpty else { return }
        // Restart the current song first (classic player behavior).
        if currentTime > 3, let p = player {
            p.currentTime = 0
            currentTime = 0
            persistState()
            return
        }
        advance(by: -1)
    }

    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        seek(toTime: min(max(0, fraction), 1) * duration)
    }

    func seek(toTime time: TimeInterval) {
        guard let p = player, duration > 0 else { return }
        let t = min(max(0, time), duration)
        p.currentTime = t
        currentTime = t
        publishNowPlaying()
        persistState()
    }

    /// Moves through the active playlist when one is chosen, otherwise
    /// through the whole library.
    private func advance(by step: Int) {
        guard !tracks.isEmpty else { return }
        let ids = activeQueueIDs.isEmpty ? tracks.map(\.id) : activeQueueIDs
        guard !ids.isEmpty else { return }
        let pos = currentTrack.flatMap { track in ids.firstIndex(of: track.id) }
            ?? (step > 0 ? -1 : 0)
        let nextID = ids[(pos + step + ids.count) % ids.count]
        guard let i = tracks.firstIndex(where: { $0.id == nextID }) else { return }
        load(index: i, autoplay: true)
    }

    // MARK: - Loading

    private func load(index i: Int, autoplay: Bool) {
        guard tracks.indices.contains(i) else { return }
        index = i
        let track = tracks[i]

        stopTicker()
        player?.stop()
        player = nil
        duration = track.duration
        currentTime = 0
        artwork = track.artwork ?? Self.fallbackArtwork()
        // One parse per load gives the lyric lines and the [ti:]/[ar:] tags.
        let lrc = Self.lrcURL(for: track.url).map { LrcParser.load(from: $0) }
        lyrics = lrc?.lines ?? []
        if let tags = lrc?.metadata { Self.applyDisplayTags(tags, to: &tracks[i]) }
        isPlaying = false
        notice = nil
        nowPlayingPulse = 0

        do {
            let p = try AVAudioPlayer(contentsOf: track.url)
            p.delegate = finishDelegate
            p.prepareToPlay()
            player = p
            if duration <= 0 { duration = p.duration }
            if autoplay {
                p.play()
                isPlaying = true
                startTicker()
            }
        } catch {
            notice = "Can't play \(track.title)"
        }
        publishNowPlaying()
        persistState()
    }

    /// Re-reads the current song's `.lrc` after files change on disk (the
    /// cleanup can move lyrics into place while a song is loaded).
    private func refreshLyricsForCurrent() {
        guard let track = currentTrack,
              let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let lrc = Self.lrcURL(for: track.url).map { LrcParser.load(from: $0) }
        lyrics = lrc?.lines ?? []
        if let tags = lrc?.metadata { Self.applyDisplayTags(tags, to: &tracks[i]) }
    }

    /// Attaches a picked `.lrc` to a song: replaces existing lyric variants
    /// and stores it next to the audio as `<song>.lrc`.
    func assignLyrics(from source: URL, to track: Track? = nil) {
        guard let target = track ?? currentTrack else { return }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            flashNotice("Couldn't read that .lrc file")
            return
        }
        Self.removeLyricFiles(for: target)
        let dest = target.url.deletingPathExtension().appendingPathExtension("lrc")
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            flashNotice("Couldn't attach the lyrics file")
            return
        }
        if let i = tracks.firstIndex(where: { $0.id == target.id }) {
            let tags = LrcParser.load(from: dest).metadata
            Self.applyDisplayTags(tags, to: &tracks[i])
        }
        refreshLyricsForCurrent()
        flashNotice("Lyrics attached to \(target.title)")
    }

    /// Finds the matching `<song>.lrc` next to the audio (also in an `lrc/`
    /// subfolder) — used for both the lyric lines and the header tags. Names
    /// are compared dash- and accent-insensitively (`–` vs `-`).
    nonisolated private static func lrcURL(for audioURL: URL) -> URL? {
        let stem = normalizedStem(audioURL.deletingPathExtension().lastPathComponent)
        let dir = audioURL.deletingLastPathComponent()
        var searchDirs = [dir]
        let lrcDir = dir.appendingPathComponent("lrc", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: lrcDir.path, isDirectory: &isDir), isDir.boolValue {
            searchDirs.append(lrcDir)
        }
        for d in searchDirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
            if let match = files.first(where: {
                $0.pathExtension.lowercased() == "lrc"
                    && normalizedStem($0.deletingPathExtension().lastPathComponent) == stem
            }) {
                return match
            }
        }
        return nil
    }

    /// File names often differ only in dash style or accents; compare stems
    /// on a folded form so the lyric still pairs up.
    nonisolated private static func normalizedStem(_ stem: String) -> String {
        let dashes: Set<Unicode.Scalar> = ["-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}", "_"]
        let folded = stem.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        let spaced = folded.unicodeScalars.map { dashes.contains($0) ? " " : String($0) }.joined()
        return spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// LRC `[ti:]` / `[ar:]` are the display name when present — they win
    /// over embedded metadata and the filename.
    private static func applyDisplayTags(_ tags: LrcMetadata, to track: inout Track) {
        let title = tags.title.trimmingCharacters(in: .whitespaces)
        let artist = tags.artist.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { track.title = title }
        if !artist.isEmpty { track.artist = artist }
    }

    // MARK: - Metadata

    /// Title/artist/duration/artwork loads off the main thread; each track is
    /// patched in as it resolves.
    private func loadMetadata() {
        let snapshot = tracks
        Task {
            for (i, track) in snapshot.enumerated() {
                var updated = track
                let asset = AVURLAsset(url: track.url)
                if let loaded = try? await asset.load(.duration) {
                    updated.duration = loaded.seconds
                }
                let common = (try? await asset.load(.commonMetadata)) ?? []
                if let item = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierTitle).first,
                   let title = try? await item.load(.stringValue), !title.isEmpty {
                    updated.title = title
                }
                if let item = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierArtist).first,
                   let artist = try? await item.load(.stringValue), !artist.isEmpty {
                    updated.artist = artist
                }
                if let item = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierArtwork).first,
                   let data = try? await item.load(.dataValue), let image = UIImage(data: data) {
                    updated.artwork = image
                }
                if let tags = Self.lrcURL(for: track.url).map { LrcParser.load(from: $0).metadata } {
                    Self.applyDisplayTags(tags, to: &updated)
                }
                guard tracks.indices.contains(i), tracks[i].id == updated.id else { continue }
                tracks[i] = updated
                if i == index {
                    duration = updated.duration
                    if let art = updated.artwork { artwork = art }
                    publishNowPlaying()
                }
            }
        }
    }

    // MARK: - System now playing (Lock Screen · Dynamic Island · Control Center)

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resumeFromRemote() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pauseFromRemote() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = position.positionTime
            Task { @MainActor in self?.seek(toTime: time) }
            return .success
        }
    }

    private func resumeFromRemote() {
        guard let p = player else {
            togglePlay()
            return
        }
        guard !p.isPlaying else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        p.play()
        isPlaying = true
        startTicker()
        publishNowPlaying()
    }

    private func pauseFromRemote() {
        guard let p = player, p.isPlaying else { return }
        p.pause()
        isPlaying = false
        stopTicker()
        publishNowPlaying()
        persistState()
    }

    /// Publishes the system now-playing entry: title, artist, artwork,
    /// duration, position and rate. This is what makes the Dynamic Island,
    /// Lock Screen player and Control Center show the song.
    private func publishNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist.isEmpty ? "Cella" : track.artist,
            MPMediaItemPropertyAlbumTitle: "Cella",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let art = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            pauseFromRemote()
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            if wasPlayingBeforeInterruption, options.contains(.shouldResume) {
                resumeFromRemote()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable {
            pauseFromRemote() // headphones unplugged
        } else if isPlaying {
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    // MARK: - Artwork fallback

    /// Aero cover used when a track has no embedded artwork.
    static func fallbackArtwork() -> UIImage { cachedFallbackArtwork }

    private static let cachedFallbackArtwork: UIImage = {
        let size = CGSize(width: 600, height: 600)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let colors = [
                UIColor(red: 0.055, green: 0.37, blue: 0.68, alpha: 1).cgColor,
                UIColor(red: 0.18, green: 0.64, blue: 0.91, alpha: 1).cgColor,
                UIColor(red: 0.88, green: 0.96, blue: 1.0, alpha: 1).cgColor,
            ]
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0, 0.62, 1]
            ) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            cg.setFillColor(UIColor.white.withAlphaComponent(0.38).cgColor)
            cg.fillEllipse(in: CGRect(
                x: size.width * 0.40,
                y: size.height * 0.08,
                width: size.width * 0.52,
                height: size.height * 0.52
            ))
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.22).cgColor)
            cg.setLineWidth(7)
            for i in 0..<3 {
                let base = size.height * (0.60 + CGFloat(i) * 0.11)
                cg.move(to: CGPoint(x: -10, y: base))
                cg.addCurve(
                    to: CGPoint(x: size.width + 10, y: base),
                    control1: CGPoint(x: size.width * 0.30, y: base - 34),
                    control2: CGPoint(x: size.width * 0.70, y: base + 34)
                )
                cg.strokePath()
            }
        }
    }()

    // MARK: - Clock

    /// Display-link clock. A plain 30 Hz timer only wakes the UI 30 times a
    /// second, and with the Metro canvas gone the white theme has nothing
    /// else requesting frames — the panel settles onto that 30 Hz cadence and
    /// everything reads as choppy. A display link updates every frame, so the
    /// white theme scrolls as smoothly as the animated blue one.
    private func startTicker() {
        stopTicker()
        let link = CADisplayLink(
            target: linkProxy,
            selector: #selector(DisplayLinkProxy.handleTick)
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopTicker() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func tick() {
        guard let p = player else { return }
        let t = p.currentTime
        // Epsilon guard: only publish real movement (well under one frame).
        if abs(t - currentTime) > 0.008 { currentTime = t }
        if p.duration > 0, abs(p.duration - duration) > 0.05 { duration = p.duration }
        // Refresh the system now-playing clock every ~10 s so the Lock Screen
        // and Dynamic Island stay in sync without churning every frame.
        nowPlayingPulse += 1
        if isPlaying, nowPlayingPulse % 600 == 0 { publishNowPlaying() }
    }
}

/// AVAudioPlayer delegate proxy — `@Observable` classes can't implement
/// NSObject protocols directly.
private final class FinishDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (@Sendable () -> Void)?

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard flag else { return }
        onFinish?()
    }
}

/// CADisplayLink target proxy — the observable model isn't an NSObject.
private final class DisplayLinkProxy: NSObject {
    var onTick: (() -> Void)?

    @objc func handleTick() { onTick?() }
}
