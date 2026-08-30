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

    /// Metadata from the album's .ca file, when present.
    /// Falls back to filename parsing when nil.
    var title: String?
    var artist: String?
    var albumName: String?

    var fileName: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Artist name from .ca metadata, or parsed from filename (before " - " separator).
    var artistName: String? {
        if let artist = artist, !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return artist
        }
        let name = fileName
        guard let separatorIndex = name.range(of: " - ")?.lowerBound else { return nil }
        let parsed = String(name[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
        return parsed.isEmpty ? nil : parsed
    }

    /// Individual artists split from the combined artist string.
    /// "Như Quỳnh & Mạnh Quỳnh" → ["Như Quỳnh", "Mạnh Quỳnh"].
    var artists: [String] {
        guard let combined = artistName else { return [] }
        return combined.components(separatedBy: " & ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Track title from .ca metadata, or parsed from filename (after " - " separator, or full name).
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
