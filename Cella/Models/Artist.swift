import Foundation

/// Unified artist model — replaces PackArtist/LibraryArtist duplication.
/// Single source for name normalization, splitting, video lookup.
struct Artist: Identifiable {
    let id = UUID()
    let name: String
    let key: String
    let trackCount: Int
    let packCount: Int
    let albumCount: Int
    /// Full file URLs (library scope). Empty for legacy pack-only entries.
    let trackURLs: [URL]
    /// Filenames only (pack scope compat). Derived from trackURLs when empty.
    let files: [String]
    let videoURL: URL?
    let coverURL: URL?

    var effectiveFiles: [String] {
        if !files.isEmpty { return files }
        return trackURLs.map { $0.lastPathComponent }
    }
}

/// Centralized artist matching: normalization, splitting, track-number guard.
/// Previously duplicated in ClusterLibrary, TrackAsset, PlayerViewModel.
enum ArtistMatcher {
    static func normKey(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func splitNames(trackArtist: String?, file: String) -> [String] {
        if let raw = trackArtist?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let parts = splitRaw(raw)
            if !parts.isEmpty { return parts }
        }
        let base = (file as NSString).deletingPathExtension
        if let range = base.range(of: " - ") {
            let left = String(base[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if isTrackNumberPrefix(left) { return [] }
            let parts = splitRaw(left)
            if !parts.isEmpty { return parts }
        }
        return []
    }

    static func splitRaw(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: "&,/\u{FF0C}")
        return raw.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    static func isTrackNumberPrefix(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        let digits = t.filter { $0.isNumber }
        if digits.count >= 1 && Double(t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces)) != nil {
            return true
        }
        let lower = t.lowercased()
        if lower.hasPrefix("track") || lower.hasPrefix("cd") || lower.hasPrefix("disc") { return true }
        let allowed = CharacterSet(charactersIn: "0123456789._- ")
        if t.unicodeScalars.allSatisfy({ allowed.contains($0) }) && !digits.isEmpty { return true }
        return false
    }

    /// True if track matches artist filter (split collabs, diacritic-insensitive).
    static func matches(trackArtist: String?, file: String, needleKey: String, displayArtist: String? = nil, rawArtist: String? = nil) -> Bool {
        let names = splitNames(trackArtist: trackArtist, file: file)
        if names.map({ normKey($0) }).contains(needleKey) { return true }
        if let d = displayArtist, normKey(d).contains(needleKey) { return true }
        if let r = rawArtist, normKey(r).contains(needleKey) { return true }
        return false
    }
}
