//
//  TrackAsset.swift
//  Cella
//
//  Represents a single audio track with its analysis metadata.
//

import Foundation

struct TrackAsset: Identifiable {
    let id = UUID()
    let url: URL
    var analysis: TrackAnalysis?

    /// Metadata from per-album .cue sheet, when present.
    /// Falls back to .lrc metadata then filename parsing.
    var title: String?
    var artist: String?
    var albumName: String?

    var fileName: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Artist name from .cue metadata, or parsed from filename. Delegates number-guard to ArtistMatcher.
    var artistName: String? {
        if let artist = artist, !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return artist
        }
        let name = fileName
        guard let separatorIndex = name.range(of: " - ")?.lowerBound else { return nil }
        let parsed = String(name[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
        guard !parsed.isEmpty else { return nil }
        if ArtistMatcher.isTrackNumberPrefix(parsed) { return nil }
        return parsed
    }

    /// Individual artists via unified ArtistMatcher.
    var artists: [String] {
        guard let combined = artistName else { return [] }
        return ArtistMatcher.splitRaw(combined)
    }

    /// Clean artist display: the split artists joined with " & ".
    var displayArtist: String {
        let names = artists
        if names.isEmpty { return artistName ?? "" }
        return names.joined(separator: " & ")
    }

    /// Track title from .cue metadata, or parsed from filename (after " - " separator, or full name).
    var trackTitle: String {
        if let title = title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        let name = fileName
        guard let separatorIndex = name.range(of: " - ")?.upperBound else {
            return name.trimmingCharacters(in: .whitespaces)
        }
        return String(name[separatorIndex...]).trimmingCharacters(in: .whitespaces)
    }
}

/// A group of tracks sharing the same album folder.
struct AlbumGroup: Identifiable {
    let id = UUID()
    let name: String
    let dir: String
    let songs: [TrackAsset]
}
