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

    var fileName: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Artist name parsed from filename (before " - " separator), if present.
    var artistName: String? {
        let name = fileName
        guard let separatorIndex = name.range(of: " - ")?.lowerBound else { return nil }
        let artist = String(name[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
        return artist.isEmpty ? nil : artist
    }

    /// Track title parsed from filename (after " - " separator, or full name).
    var trackTitle: String {
        let name = fileName
        guard let separatorIndex = name.range(of: " - ")?.upperBound else {
            return name.trimmingCharacters(in: .whitespaces)
        }
        return String(name[separatorIndex...]).trimmingCharacters(in: .whitespaces)
    }
}
