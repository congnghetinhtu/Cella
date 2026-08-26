import Foundation

struct CaAlbum: Codable {
    let name: String
    let folder: String
    let artist: String?
    let year: String?
    let genre: String?
    let artwork: String?
    let tracks: [CaTrack]?
}

struct CaTrack: Codable {
    let file: String
    let title: String?
    let artist: String?
    let duration: String?
}

struct CaPlaylist: Codable {
    let name: String?
    let artist: String?
    let albums: [CaAlbum]
}

struct CaParser {
    static func parse(_ content: String) -> CaPlaylist? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CaPlaylist.self, from: data)
    }

    static func load(from url: URL) -> CaPlaylist? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(content)
    }

    static func audioFiles(from playlist: CaPlaylist, in cellaFolder: URL) -> [URL] {
        var files: [URL] = []

        for album in playlist.albums {
            let albumDir = cellaFolder.appendingPathComponent(album.folder)
            guard FileManager.default.fileExists(atPath: albumDir.path) else { continue }

            let audioExtensions = Set(["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"])
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: albumDir, includingPropertiesForKeys: nil
            )) ?? []

            let audioFiles = contents.filter {
                audioExtensions.contains($0.pathExtension.lowercased())
            }

            if let tracks = album.tracks {
                let ordered = tracks.compactMap { track -> URL? in
                    let url = albumDir.appendingPathComponent(track.file)
                    return FileManager.default.fileExists(atPath: url.path) ? url : nil
                }
                let unmatched = audioFiles.filter { url in
                    !ordered.contains { $0.path == url.path }
                }
                files.append(contentsOf: ordered)
                files.append(contentsOf: unmatched)
            } else {
                files.append(contentsOf: audioFiles)
            }
        }

        return files
    }

    static func lrcFolder(for audioURL: URL, in cellaFolder: URL) -> URL? {
        let albumName = audioURL.deletingLastPathComponent().lastPathComponent
        let albumDir = cellaFolder.appendingPathComponent(albumName)
        let lrcDir = albumDir.appendingPathComponent("lrc")
        return FileManager.default.fileExists(atPath: lrcDir.path) ? lrcDir : nil
    }

    static func albumInfo(for audioURL: URL, playlist: CaPlaylist) -> CaAlbum? {
        let albumFolder = audioURL.deletingLastPathComponent().lastPathComponent
        return playlist.albums.first { $0.folder == albumFolder }
    }
}
