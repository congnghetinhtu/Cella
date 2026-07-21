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
    var analysisStatus: AnalysisStatus = .pending

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

    /// Display text for the matrix scroller: "ARTIST - TITLE" or just "TITLE".
    var displayText: String {
        if let artist = artistName {
            return "\(artist) - \(trackTitle)"
        }
        return trackTitle
    }
}

enum AnalysisStatus: Equatable {
    case pending
    case analyzing(progress: Double)
    case complete
    case failed(String)

    static func == (lhs: AnalysisStatus, rhs: AnalysisStatus) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending),
             (.complete, .complete):
            return true
        case (.analyzing(let a), .analyzing(let b)):
            return a == b
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}
