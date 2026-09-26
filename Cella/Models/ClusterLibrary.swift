//
//  ClusterLibrary.swift
//  Cella
//
//  A .cluster library — a folder containing multiple .cella playlist packs.
//  Mirrors Apple Photos' library model: the user picks one library once,
//  and it is remembered for subsequent launches.
//

import Foundation

/// Classification of a .cella pack based on per-album .cue files.
enum CellaPackType {
    /// Has per-album .cue files — cue metadata is authoritative.
    case structured
    /// No .cue file — uses .lrc metadata / folder structure heuristics.
    case openCella

    var label: String {
        switch self {
        case .structured: return "Cella Structured"
        case .openCella: return "OpenCella"
        }
    }

    var icon: String {
        switch self {
        case .structured: return "square.stack.3d.up.fill"
        case .openCella: return "music.note.list"
        }
    }
}

/// A single .cella pack discovered inside a .cluster library.
struct CellaPack: Identifiable {
    let id = UUID()
    let url: URL
    let type: CellaPackType
    let name: String
    var coverURLs: [URL]
    let albumCount: Int
    let trackCount: Int
    var cachedTrackCount: Int
}

/// A single track inside a Cella album.
struct CellaTrack: Identifiable {
    let id = UUID()
    let file: String
    let title: String?
    let artist: String?
}

/// An album inside a .cella pack — the drill-down unit of the Cluster library.
struct CellaAlbum: Identifiable {
    let id = UUID()
    let name: String
    let folderName: String
    let artist: String?
    let coverURL: URL?
    let tracks: [CellaTrack]
    let cachedTrackCount: Int

    var trackCount: Int { tracks.count }
}

/// Legacy aliases — use unified `Artist`. Kept for incremental migration.
typealias LibraryArtist = Artist
typealias PackArtist = Artist

/// Scans a .cluster folder for .cella packs and summarizes their contents.
struct ClusterLibrary {
    let url: URL
    var packs: [CellaPack]

    /// Re-scans .cellax cache counts for all packs.
    mutating func refreshCacheCounts() {
        for i in packs.indices {
            packs[i].cachedTrackCount = AnalysisCache.countsInPack(packs[i].url).cached
        }
    }

    static func scan(_ url: URL) -> ClusterLibrary {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )) ?? []

        let packs = contents
            .filter { $0.hasDirectoryPath && $0.pathExtension.lowercased() == "cella" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { packURL -> CellaPack in
                let hasCue = hasPerAlbumCue(in: packURL)
                let type: CellaPackType = hasCue ? .structured : .openCella
                let summary = summarize(packURL)
                let cacheCounts = AnalysisCache.countsInPack(packURL)
                let name = packURL.deletingPathExtension().lastPathComponent
                let covers = collectCovers(packURL)
                return CellaPack(
                    url: packURL,
                    type: type,
                    name: name,
                    coverURLs: covers,
                    albumCount: summary.albums,
                    trackCount: summary.tracks,
                    cachedTrackCount: cacheCounts.cached
                )
            }

        return ClusterLibrary(url: url, packs: packs)
    }

    /// Heuristic: pack is considered structured if any album subfolder or root contains a .cue file.
    private static func hasPerAlbumCue(in packURL: URL) -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: packURL, includingPropertiesForKeys: nil) else { return false }
        if contents.contains(where: { $0.pathExtension.lowercased() == "cue" }) { return true }
        for sub in contents where sub.hasDirectoryPath && sub.pathExtension.lowercased() != "cluster" {
            guard let subContents = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) else { continue }
            if subContents.contains(where: { $0.pathExtension.lowercased() == "cue" }) { return true }
        }
        return false
    }

    /// Up to 4 cover image URLs (cover.jpg / folder.jpg / artwork.*) per pack.
    private static func collectCovers(_ packURL: URL) -> [URL] {
        let fm = FileManager.default
        let coverNames = ["cover", "folder", "artwork", "front", "album"]
        let imageExtensions = Set(["jpg", "jpeg", "png", "heic", "webp"])

        var covers: [URL] = []

        // Try root-level cover first
        if let rootCover = findCover(in: packURL, names: coverNames, exts: imageExtensions) {
            covers.append(rootCover)
        }
        let subfolders = ((try? fm.contentsOfDirectory(
            at: packURL, includingPropertiesForKeys: nil
        )) ?? []).filter { $0.hasDirectoryPath && $0.pathExtension.lowercased() != "cluster" }
        for folder in subfolders where covers.count < 4 {
            if let cover = findCover(in: folder, names: coverNames, exts: imageExtensions) {
                covers.append(cover)
            }
        }

        return Array(covers.prefix(4))
    }

    private static func findCover(in dir: URL, names: [String], exts: Set<String>) -> URL? {
        guard dir.hasDirectoryPath else { return nil }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        return contents.first { url in
            guard exts.contains(url.pathExtension.lowercased()) else { return false }
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            return names.contains(base)
        }
    }

    /// Counts audio files in a folder that have .cellax cache files in Cache/ subfolder.
    private static func countCachedTracks(in dir: URL, audioExtensions: Set<String>) -> Int {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let audioFiles = contents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        return audioFiles.filter { fm.fileExists(atPath: AnalysisCache.cacheURL(for: $0).path) }.count
    }

    /// Albums + tracks for drill-down inside a pack, without loading audio.
    /// Each album subfolder that contains a .cue uses the cue as authoritative
    /// source for track order / title / artist. Otherwise audio files are scanned directly.
    static func albums(in packURL: URL) -> [CellaAlbum] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: packURL, includingPropertiesForKeys: nil)) ?? []
        let audioExtensions = Set(["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"])
        let coverNames = ["cover", "folder", "artwork", "front", "album"]
        let imageExts = Set(["jpg", "jpeg", "png", "heic", "webp"])

        var albums: [CellaAlbum] = []

        let subfolders = contents
            .filter { $0.hasDirectoryPath && $0.pathExtension.lowercased() != "cluster" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        for subfolder in subfolders {
            let subContents = (try? fm.contentsOfDirectory(at: subfolder, includingPropertiesForKeys: nil)) ?? []
            let audioFiles = subContents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            guard !audioFiles.isEmpty else { continue }

            // Check for per-album cue
            if let cueURL = subContents.first(where: { $0.pathExtension.lowercased() == "cue" }),
               let sheet = CueParser.load(from: cueURL) {
                let cover = findCover(in: subfolder, names: coverNames, exts: imageExts)
                let cached = countCachedTracks(in: subfolder, audioExtensions: audioExtensions)
                // Build ordered tracks from cue, include unmatched files at end
                let orderedFiles = sheet.trackOrder(for: audioFiles)
                let cueMap = Dictionary(uniqueKeysWithValues: sheet.tracks.map { ($0.fileName.lowercased(), $0) })
                let tracks: [CellaTrack] = orderedFiles.map { url in
                    let name = url.lastPathComponent
                    if let c = cueMap[name.lowercased()] {
                        let t = c.title.isEmpty ? nil : c.title
                        let a = c.performer.isEmpty ? nil : c.performer
                        if t != nil || a != nil {
                            return CellaTrack(file: name, title: t, artist: a)
                        }
                    }
                    // Cue miss → LRC fallback (cue → lrc → filename)
                    let meta = LrcParser.metadata(for: url, in: packURL)
                    return CellaTrack(
                        file: name,
                        title: meta.title.isEmpty ? nil : meta.title,
                        artist: meta.artist.isEmpty ? nil : meta.artist
                    )
                }
                let albumName = sheet.title.isEmpty ? subfolder.lastPathComponent : sheet.title
                let albumArtist = sheet.performer.isEmpty ? nil : sheet.performer
                albums.append(CellaAlbum(
                    name: albumName,
                    folderName: subfolder.lastPathComponent,
                    artist: albumArtist,
                    coverURL: cover,
                    tracks: tracks,
                    cachedTrackCount: cached
                ))
                continue
            }

            // No cue: scan directly + LRC fallback for OpenCella (e.g. [ar: Phuong My Chi & DTAP])
            let files = audioFiles.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            let cover = findCover(in: subfolder, names: coverNames, exts: imageExts)
            let cached = countCachedTracks(in: subfolder, audioExtensions: audioExtensions)
            albums.append(CellaAlbum(
                name: subfolder.lastPathComponent,
                folderName: subfolder.lastPathComponent,
                artist: nil,
                coverURL: cover,
                tracks: files.map { url in
                    let meta = LrcParser.metadata(for: url, in: packURL)
                    return CellaTrack(
                        file: url.lastPathComponent,
                        title: meta.title.isEmpty ? nil : meta.title,
                        artist: meta.artist.isEmpty ? nil : meta.artist
                    )
                },
                cachedTrackCount: cached
            ))
        }

        // Root-level cue (if exists) orders root audio; otherwise alphabetical
        let rootAudioAll = contents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        var rootAudio = rootAudioAll.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        var rootCueSheet: CueSheet?
        if let rootCueURL = contents.first(where: { $0.pathExtension.lowercased() == "cue" }),
           let sheet = CueParser.load(from: rootCueURL) {
            rootCueSheet = sheet
            rootAudio = sheet.trackOrder(for: rootAudioAll)
        }
        if !rootAudio.isEmpty {
            let cover = findCover(in: packURL, names: coverNames, exts: imageExts)
            let cached = countCachedTracks(in: packURL, audioExtensions: audioExtensions)
            let tracks: [CellaTrack]
            if let sheet = rootCueSheet {
                let cueMap = Dictionary(uniqueKeysWithValues: sheet.tracks.map { ($0.fileName.lowercased(), $0) })
                tracks = rootAudio.map { url in
                    let name = url.lastPathComponent
                    if let c = cueMap[name.lowercased()] {
                        let t = c.title.isEmpty ? nil : c.title
                        let a = c.performer.isEmpty ? nil : c.performer
                        if t != nil || a != nil {
                            return CellaTrack(file: name, title: t, artist: a)
                        }
                    }
                    let meta = LrcParser.metadata(for: url, in: packURL)
                    return CellaTrack(
                        file: name,
                        title: meta.title.isEmpty ? nil : meta.title,
                        artist: meta.artist.isEmpty ? nil : meta.artist
                    )
                }
            } else {
                // OpenCella flat: read artist/title from lrc ([ar: Phuong My Chi & DTAP] supported)
                tracks = rootAudio.map { url in
                    let meta = LrcParser.metadata(for: url, in: packURL)
                    return CellaTrack(
                        file: url.lastPathComponent,
                        title: meta.title.isEmpty ? nil : meta.title,
                        artist: meta.artist.isEmpty ? nil : meta.artist
                    )
                }
            }
            albums.insert(CellaAlbum(
                name: packURL.deletingPathExtension().lastPathComponent,
                folderName: "",
                artist: rootCueSheet?.performer.isEmpty == false ? rootCueSheet?.performer : nil,
                coverURL: cover,
                tracks: tracks,
                cachedTrackCount: cached
            ), at: 0)
        }

        return albums
    }

    /// Smart artist aggregation per pack: cue PERFORMER → split collabs → filename fallback.
    /// Delegates to ArtistMatcher (single source). Sorted by trackCount desc.
    static func artists(in packURL: URL) -> [Artist] {
        let albums = albums(in: packURL)
        var counts: [String: (display: String, tracks: Int, albums: Set<String>, files: [String], urls: [URL], cover: URL?)] = [:]
        for album in albums {
            let albumDir: URL = album.folderName.isEmpty ? packURL : packURL.appendingPathComponent(album.folderName)
            let contents = (try? FileManager.default.contentsOfDirectory(at: albumDir, includingPropertiesForKeys: nil)) ?? []
            let urlByName = Dictionary(uniqueKeysWithValues: contents.map { ($0.lastPathComponent.lowercased(), $0) })
            for track in album.tracks {
                let names = ArtistMatcher.splitNames(trackArtist: track.artist, file: track.file)
                let effective = names.isEmpty ? ["Unknown"] : names
                for name in effective {
                    let key = ArtistMatcher.normKey(name)
                    guard !key.isEmpty else { continue }
                    var entry = counts[key] ?? (display: name, tracks: 0, albums: Set<String>(), files: [], urls: [], cover: nil)
                    entry.tracks += 1
                    entry.albums.insert(album.folderName.isEmpty ? album.name : album.folderName)
                    entry.files.append(track.file)
                    if let u = urlByName[track.file.lowercased()] { entry.urls.append(u) }
                    if entry.cover == nil { entry.cover = album.coverURL }
                    if entry.display.count < name.count { entry.display = name }
                    counts[key] = entry
                }
            }
        }
        return counts.map { key, v in
            Artist(name: v.display, key: key, trackCount: v.tracks, packCount: 1, albumCount: v.albums.count, trackURLs: v.urls, files: v.files, videoURL: nil, coverURL: v.cover)
        }.sorted { $0.trackCount > $1.trackCount }
    }

    /// Normalized key — delegates to ArtistMatcher.
    static func normKey(_ s: String) -> String { ArtistMatcher.normKey(s) }

    /// Library-wide artists: merges per-pack artists across all .cella packs.
    /// Delegates matching to ArtistMatcher. VideoURL = first cma video for snapshot.
    static func libraryArtists(in libraryURL: URL) -> [Artist] {
        let packs = scan(libraryURL).packs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var counts: [String: (display: String, urls: [URL], packs: Set<String>, video: URL?)] = [:]
        for pack in packs {
            let albums = albums(in: pack.url)
            for album in albums {
                let albumDir: URL = album.folderName.isEmpty ? pack.url : pack.url.appendingPathComponent(album.folderName)
                let contents = (try? FileManager.default.contentsOfDirectory(at: albumDir, includingPropertiesForKeys: nil)) ?? []
                let urlByName = Dictionary(uniqueKeysWithValues: contents.map { ($0.lastPathComponent.lowercased(), $0) })
                for track in album.tracks {
                    guard let fileURL = urlByName[track.file.lowercased()] else { continue }
                    let names = ArtistMatcher.splitNames(trackArtist: track.artist, file: track.file)
                    let effective = names.isEmpty ? ["Unknown"] : names
                    for name in effective {
                        let key = ArtistMatcher.normKey(name)
                        guard !key.isEmpty else { continue }
                        var entry = counts[key] ?? (display: name, urls: [], packs: Set<String>(), video: nil)
                        entry.urls.append(fileURL)
                        entry.packs.insert(pack.name)
                        if entry.display.count < name.count { entry.display = name }
                        counts[key] = entry
                    }
                }
            }
        }
        var out: [Artist] = []
        for (key, v) in counts {
            let video = findArtistVideo(in: libraryURL, artistName: v.display)
            out.append(Artist(name: v.display, key: key, trackCount: v.urls.count, packCount: v.packs.count, albumCount: 0, trackURLs: v.urls, files: v.urls.map { $0.lastPathComponent }, videoURL: video, coverURL: nil))
        }
        return out.sorted { $0.trackCount > $1.trackCount }
    }

    /// First cma video matching artist across packs. Mirrors PlayerViewModel CMA matching:
    /// NFD normalize, title-case, hyphen/underscore variants, flat-file fallback.
    static func findArtistVideo(in libraryURL: URL, artistName: String) -> URL? {
        let fm = FileManager.default
        let packs = (try? fm.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: nil))?.filter { $0.hasDirectoryPath && $0.pathExtension.lowercased() == "cella" } ?? []
        let videoExts = Set(["mp4", "mov", "cma"])
        let lowered = artistName.lowercased()
        let nfd = lowered.precomposedStringWithCanonicalMapping.decomposedStringWithCanonicalMapping
        let titleCase = nfd.split(separator: " ").map(\.capitalized).joined(separator: " ")
        for pack in packs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let cmaDir = pack.appendingPathComponent("cma")
            guard fm.fileExists(atPath: cmaDir.path) else { continue }
            let candidates = [
                cmaDir.appendingPathComponent(nfd),
                cmaDir.appendingPathComponent(titleCase),
                cmaDir.appendingPathComponent(nfd.replacingOccurrences(of: " ", with: "-")),
                cmaDir.appendingPathComponent(nfd.replacingOccurrences(of: " ", with: "_")),
                cmaDir.appendingPathComponent(lowered),
                cmaDir.appendingPathComponent(artistName),
            ]
            for dir in candidates where fm.fileExists(atPath: dir.path) {
                let sub = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                let vids = sub.filter { videoExts.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                if let first = vids.first { return first }
            }
            // Flat fallback: cma/<Artist Name>.mp4 style
            let flat = (try? fm.contentsOfDirectory(at: cmaDir, includingPropertiesForKeys: nil)) ?? []
            for f in flat where videoExts.contains(f.pathExtension.lowercased()) {
                let base = f.deletingPathExtension().lastPathComponent.lowercased()
                    .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
                if base == lowered || base == nfd { return f }
            }
        }
        return nil
    }

    /// Split delegates to ArtistMatcher (single source).
    static func splitArtistNames(trackArtist: String?, file: String) -> [String] {
        ArtistMatcher.splitNames(trackArtist: trackArtist, file: file)
    }

    private static func isTrackNumberPrefix(_ s: String) -> Bool {
        ArtistMatcher.isTrackNumberPrefix(s)
    }

    private struct Summary {
        var albums: Int = 0
        var tracks: Int = 0
    }

    /// Counts albums/tracks inside a .cella pack without loading audio.
    private static func summarize(_ packURL: URL) -> Summary {
        var summary = Summary()
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: packURL, includingPropertiesForKeys: nil)) ?? []

        // Cue-aware but same counting as open: scan subfolders + root for audio.
        // Each subfolder with audio counts as one album; root audio as one album.
        let audioExtensions = Set(["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"])
        let subfolders = contents.filter { $0.hasDirectoryPath && $0.pathExtension.lowercased() != "cluster" }
        let rootAudio = contents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        summary.tracks += rootAudio.count
        if !rootAudio.isEmpty { summary.albums += 1 }

        for subfolder in subfolders {
            let subContents = (try? fm.contentsOfDirectory(
                at: subfolder, includingPropertiesForKeys: nil
            )) ?? []
            let isAlbum = subContents.contains { audioExtensions.contains($0.pathExtension.lowercased()) }
            if isAlbum {
                summary.albums += 1
                summary.tracks += subContents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }.count
            }
        }
        return summary
    }
}