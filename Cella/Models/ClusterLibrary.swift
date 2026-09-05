//
//  ClusterLibrary.swift
//  Cella
//
//  A .cluster library — a folder containing multiple .cella playlist packs.
//  Mirrors Apple Photos' library model: the user picks one library once,
//  and it is remembered for subsequent launches.
//

import Foundation

/// Classification of a .cella pack based on presence of a .ca metadata file.
enum CellaPackType {
    /// Has a .ca file — album structure metadata is authoritative.
    case structured
    /// No .ca file — uses .lrc metadata / folder structure heuristics.
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

    var trackCount: Int { tracks.count }
}

/// Scans a .cluster folder for .cella packs and summarizes their contents.
struct ClusterLibrary {
    let url: URL
    let packs: [CellaPack]

    static func scan(_ url: URL) -> ClusterLibrary {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )) ?? []

        let packs = contents
            .filter { $0.hasDirectoryPath && $0.pathExtension.lowercased() == "cella" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { packURL -> CellaPack in
                let hasCa = (try? FileManager.default.contentsOfDirectory(
                    at: packURL, includingPropertiesForKeys: nil
                ))?.contains { $0.pathExtension.lowercased() == "ca" } ?? false

                let type: CellaPackType = hasCa ? .structured : .openCella
                let summary = summarize(packURL)
                let name = packURL.deletingPathExtension().lastPathComponent
                let covers = collectCovers(packURL, structured: hasCa)
                return CellaPack(
                    url: packURL,
                    type: type,
                    name: name,
                    coverURLs: covers,
                    albumCount: summary.albums,
                    trackCount: summary.tracks
                )
            }

        return ClusterLibrary(url: url, packs: packs)
    }

    /// Up to 4 cover image URLs (cover.jpg / folder.jpg / artwork.*) per pack.
    private static func collectCovers(_ packURL: URL, structured: Bool) -> [URL] {
        let fm = FileManager.default
        let coverNames = ["cover", "folder", "artwork", "front", "album"]
        let imageExtensions = Set(["jpg", "jpeg", "png", "heic", "webp"])

        var covers: [URL] = []

        if structured {
            // Individual album covers give the richest collage.
            if let caURL = (try? fm.contentsOfDirectory(
                at: packURL, includingPropertiesForKeys: nil
            ))?.first(where: { $0.pathExtension.lowercased() == "ca" }),
               let playlist = CaParser.load(from: caURL) {
                for album in playlist.albums.prefix(4) {
                    let albumDir = packURL.appendingPathComponent(album.folder)
                    if let cover = findCover(in: albumDir, names: coverNames, exts: imageExtensions) {
                        covers.append(cover)
                    }
                }
            }
        }

        if covers.isEmpty {
            // Root-level cover, or all-covers-from-root top level.
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

    /// Albums + tracks for drill-down inside a pack, without loading audio.
    static func albums(in packURL: URL) -> [CellaAlbum] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: packURL, includingPropertiesForKeys: nil)) ?? []

        // Cella Structured: authoritative list straight from .ca.
        if let caURL = contents.first(where: { $0.pathExtension.lowercased() == "ca" }),
           let playlist = CaParser.load(from: caURL) {
            return playlist.albums.map { album -> CellaAlbum in
                let albumDir = packURL.appendingPathComponent(album.folder)
                let cover = findCover(in: albumDir, names: ["cover", "folder", "artwork", "front", "album"], exts: Set(["jpg", "jpeg", "png", "heic", "webp"]))
                let tracks = (album.tracks ?? []).map {
                    CellaTrack(file: $0.file, title: $0.title, artist: $0.artist)
                }
                return CellaAlbum(
                    name: album.name,
                    folderName: album.folder,
                    artist: album.artist,
                    coverURL: cover,
                    tracks: tracks
                )
            }
        }

        // OpenCella: group root audio as "singles", subfolders as albums.
        let audioExtensions = Set(["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"])
        var albums: [CellaAlbum] = []

        let subfolders = contents
            .filter { $0.hasDirectoryPath && $0.pathExtension.lowercased() != "cluster" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        for subfolder in subfolders {
            let files = ((try? fm.contentsOfDirectory(
                at: subfolder, includingPropertiesForKeys: nil
            )) ?? []).filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            guard !files.isEmpty else { continue }
            let cover = findCover(in: subfolder, names: ["cover", "folder", "artwork", "front", "album"], exts: Set(["jpg", "jpeg", "png", "heic", "webp"]))
            albums.append(CellaAlbum(
                name: subfolder.lastPathComponent.replacingOccurrences(of: ".cella", with: ""),
                folderName: subfolder.lastPathComponent,
                artist: nil,
                coverURL: cover,
                tracks: files.map { CellaTrack(file: $0.lastPathComponent, title: nil, artist: nil) }
            ))
        }

        let rootAudio = contents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        if !rootAudio.isEmpty {
            let cover = findCover(in: packURL, names: ["cover", "folder", "artwork", "front", "album"], exts: Set(["jpg", "jpeg", "png", "heic", "webp"]))
            albums.insert(CellaAlbum(
                name: packURL.deletingPathExtension().lastPathComponent,
                folderName: "",
                artist: nil,
                coverURL: cover,
                tracks: rootAudio.map { CellaTrack(file: $0.lastPathComponent, title: nil, artist: nil) }
            ), at: 0)
        }

        return albums
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

        let caURL = contents.first { $0.pathExtension.lowercased() == "ca" }
        if let caURL, let playlist = CaParser.load(from: caURL) {
            // Cella Structured: authoritative album/track list from .ca
            summary.albums = playlist.albums.count
            summary.tracks = playlist.albums.reduce(0) {
                $0 + ($1.tracks?.count ?? 0)
            }
            return summary
        }

        // OpenCella: scan album subfolders, then root, for audio + .lrc files.
        // Each subfolder with audio counts as one album; a root-level audio file
        // counts as a single-track album.
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