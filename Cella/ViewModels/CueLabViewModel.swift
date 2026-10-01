import Foundation
import SwiftUI
import Combine

/// CueLab: build ExactAudioCopy-style per-album .cue sheets.
/// Flow: source files → target pack/album → single format → editable TITLE/PERFORMER →
/// bulk rename (bolero "NN - Title" detect) → move → write .cue → lrc/cma folders if missing.
@MainActor
final class CueLabViewModel: ObservableObject {
    enum Format: String, CaseIterable, Identifiable {
        case wav, flac, m4a, mp3
        var id: String { rawValue }
        var label: String { rawValue.uppercased() }
        /// Cue FILE type keyword (Cella parser accepts any word; EAC uses WAVE/MP3/AIFF).
        var fileType: String {
            switch self {
            case .wav: return "WAVE"
            case .mp3: return "MP3"
            case .flac: return "FLAC"
            case .m4a: return "M4A"
            }
        }
    }

    struct DraftTrack: Identifiable {
        let id = UUID()
        var sourceURL: URL
        var fileName: String
        var title: String
        var performer: String
        /// Suggested rename (bolero detect), nil when name already fits.
        var suggestedName: String?
        var extMismatch: Bool = false
    }

    // MARK: - Source

    @Published var sourceURLs: [URL] = []
    @Published var coverURL: URL?
    @Published var format: Format = .wav

    // MARK: - Target

    @Published var targetPackURL: URL?
    @Published var targetAlbumName: String = ""
    @Published var useExistingAlbum: Bool = true
    @Published var albumTitle: String = ""
    @Published var year: String = String(Calendar.current.component(.year, from: Date()))

    // MARK: - Tracks

    @Published var tracks: [DraftTrack] = []

    // MARK: - Options

    /// Create lrc folder only when the album lacks it (no cma).
    @Published var ensureLrc = true

    @Published var error: String?
    @Published var didExportURL: URL?

    var audioExtensions: Set<String> { ["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"] }
    var imageExtensions: Set<String> { ["jpg", "jpeg", "png", "heic", "webp"] }

    // MARK: - Source intake

    func addSources(_ urls: [URL]) {
        loadedCueFileNames = []
        let fm = FileManager.default
        var collected: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                collected.append(contentsOf: contents.filter { audioExtensions.contains($0.pathExtension.lowercased()) })
                // Auto-pick first cover-ish image as cover when none set
                if coverURL == nil {
                    let coverNames = ["cover", "folder", "front", "artwork", "album"]
                    let images = contents.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
                    if let named = images.first(where: { coverNames.contains($0.deletingPathExtension().lastPathComponent.lowercased()) }) {
                        coverURL = named
                    } else if let first = images.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
                        coverURL = first
                    }
                }
            } else if audioExtensions.contains(url.pathExtension.lowercased()) {
                collected.append(url)
            } else if imageExtensions.contains(url.pathExtension.lowercased()) {
                if coverURL == nil { coverURL = url }
            }
        }
        let existing = Set(sourceURLs.map { $0.path })
        for u in collected.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !existing.contains(u.path) {
            sourceURLs.append(u)
        }
        rebuildTracks()
    }

    func setCover(_ url: URL?) {
        coverURL = url
    }

    func removeSource(at offsets: IndexSet) {
        loadedCueFileNames = []
        sourceURLs.remove(atOffsets: offsets)
        rebuildTracks()
    }

    /// Cue FILE names in loaded-cue order (re-edit only). Powers "rename files to cue names".
    @Published var loadedCueFileNames: [String] = []

    func clear() {
        sourceURLs = []
        coverURL = nil
        tracks = []
        loadedCueFileNames = []
        error = nil
        didExportURL = nil
    }

    // MARK: - Re-edit existing album

    /// Loads an existing pack/album back into the draft: cue TITLE/PERFORMER/FILE order,
    /// plus any audio files missing from the cue appended at the end. Detects format,
    /// year (REM DATE), album title, and cover image. Overwrites nothing until export.
    func loadAlbum(packURL: URL, albumName: String) throws {
        let fm = FileManager.default
        let albumDir = packURL.appendingPathComponent(albumName)
        guard fm.fileExists(atPath: albumDir.path) else {
            throw NSError(domain: "CueLab", code: 10, userInfo: [NSLocalizedDescriptionKey: "Album folder not found."])
        }
        let contents = (try? fm.contentsOfDirectory(at: albumDir, includingPropertiesForKeys: nil)) ?? []
        let audioFiles = contents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        guard !audioFiles.isEmpty else {
            throw NSError(domain: "CueLab", code: 11, userInfo: [NSLocalizedDescriptionKey: "No audio files in that album."])
        }

        // Find cue: prefer "<AlbumTitle>.cue" match, else first .cue
        let cueFiles = contents.filter { $0.pathExtension.lowercased() == "cue" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        var sheet: CueSheet?
        var sheetURL: URL?
        if let exact = cueFiles.first(where: { $0.deletingPathExtension().lastPathComponent == albumName }) {
            sheetURL = exact
        } else {
            sheetURL = cueFiles.first
        }
        if let url = sheetURL {
            sheet = CueParser.load(from: url)
        }

        // Year from REM DATE
        var detectedYear = ""
        if let url = sheetURL,
           let raw = try? String(contentsOf: url, encoding: .utf8),
           let regex = try? NSRegularExpression(pattern: #"REM\s+DATE\s+(\d{4})"#),
           let m = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           let r = Range(m.range(at: 1), in: raw) {
            detectedYear = String(raw[r])
        }

        // Order: cue order first, unmatched audio appended
        var ordered: [URL] = []
        var cueByFile: [String: CueTrack] = [:]
        if let sheet {
            cueByFile = Dictionary(sheet.tracks.map { ($0.fileName.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
            let byName = Dictionary(audioFiles.map { ($0.lastPathComponent.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
            for cueTrack in sheet.tracks {
                if let u = byName[cueTrack.fileName.lowercased()] { ordered.append(u) }
            }
            let inCue = Set(ordered.map { $0.path })
            ordered.append(contentsOf: audioFiles.filter { !inCue.contains($0.path) })
        } else {
            ordered = audioFiles
        }

        // Format = most common extension
        let extCounts = Dictionary(grouping: ordered, by: { $0.pathExtension.lowercased() })
            .mapValues { $0.count }
        if let top = extCounts.max(by: { $0.value < $1.value })?.key,
           let f = Format(rawValue: top) {
            format = f
        }

        targetPackURL = packURL
        targetAlbumName = albumName
        albumTitle = (sheet?.title.isEmpty == false) ? (sheet?.title ?? albumName) : albumName
        if !detectedYear.isEmpty { year = detectedYear }
        loadedCueFileNames = sheet?.tracks.map { $0.fileName } ?? []
        sourceURLs = ordered
        coverURL = findCover(in: albumDir)

        tracks = ordered.enumerated().map { idx, url in
            let key = url.lastPathComponent.lowercased()
            let title = cueByFile[key]?.title ?? prefillTitle(for: url)
            let performer = cueByFile[key]?.performer ?? ""
            var draft = DraftTrack(
                sourceURL: url,
                fileName: url.lastPathComponent,
                title: title,
                performer: performer,
                extMismatch: url.pathExtension.lowercased() != format.rawValue
            )
            draft.suggestedName = suggestedBoleroName(for: url, index: idx, title: title)
            return draft
        }
        error = nil
        didExportURL = nil
    }

    private func prefillTitle(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        if let r = base.range(of: " - ") {
            return String(base[r.upperBound...]).replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        }
        if base.range(of: #"^(?i)track[\s_\-]*0*\d+$"#, options: .regularExpression) != nil { return "" }
        return base.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }

    private func findCover(in albumDir: URL) -> URL? {
        let names = ["cover", "folder", "front", "artwork", "album"]
        let exts = imageExtensions
        let contents = (try? FileManager.default.contentsOfDirectory(at: albumDir, includingPropertiesForKeys: nil)) ?? []
        for n in names {
            for e in exts {
                if let hit = contents.first(where: {
                    $0.deletingPathExtension().lastPathComponent.lowercased() == n && $0.pathExtension.lowercased() == e
                }) { return hit }
            }
        }
        return contents.filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    // MARK: - Track rebuild (cue → filename prefill, bolero rename detect)

    func rebuildTracks() {
        let sorted = sourceURLs.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        tracks = sorted.enumerated().map { idx, url in
            let base = url.deletingPathExtension().lastPathComponent
            // Prefill title: strip leading "NN - " or "Track_NN" noise
            var title = base
            if let r = base.range(of: " - ") {
                let left = String(base[..<r.lowerBound])
                if !ArtistMatcher.isTrackNumberPrefix(left) {
                    title = String(base[r.upperBound...])
                } else {
                    title = String(base[r.upperBound...])
                }
            } else if let m = base.range(of: #"^(?i)track[\s_\-]*0*(\d+)$"#, options: .regularExpression) {
                _ = m
                title = ""
            }
            title = title.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
            let extMismatch = url.pathExtension.lowercased() != format.rawValue
            var draft = DraftTrack(sourceURL: url, fileName: url.lastPathComponent, title: title, performer: "", extMismatch: extMismatch)
            draft.suggestedName = suggestedBoleroName(for: url, index: idx, title: title)
            return draft
        }
        if albumTitle.isEmpty, let first = tracks.first {
            albumTitle = first.title
        }
    }

    /// Bolero detect: "Track_01.wav" / "Track 1" / "01" → "01 - <Title>.<format>"
    /// NN comes from the filename's own digits when present (Track_01 → 01),
    /// else falls back to list position. Title ascii-folded like bolero
    /// filenames ("Tình Yêu Vỗ Cánh" → "Tinh Yeu Vo Canh").
    func suggestedBoleroName(for url: URL, index: Int, title: String) -> String? {
        let base = url.deletingPathExtension().lastPathComponent
        let generic = base.range(of: #"^(?i)track[\s_\-]*0*\d+$"#, options: .regularExpression) != nil
            || base.range(of: #"^0*\d+$"#, options: .regularExpression) != nil
        guard generic else { return nil }
        let nn = numberFromGeneric(base) ?? String(format: "%02d", index + 1)
        let ascii = title.folding(options: .diacriticInsensitive, locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var clean = ascii
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "*", with: "")
        clean = clean.split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        let candidate = "\(nn) - \(clean).\(format.rawValue)"
        return candidate == url.lastPathComponent ? nil : candidate
    }

    /// Digits embedded in generic names ("Track_01" → "01", "3" → "03").
    func numberFromGeneric(_ base: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)"#) else { return nil }
        let range = NSRange(base.startIndex..., in: base)
        guard let m = regex.matches(in: base, range: range).last,
              let r = Range(m.range(at: 1), in: base) else { return nil }
        let digits = String(base[r])
        if digits.count >= 2 { return digits }
        return String(format: "%02d", Int(digits) ?? 0)
    }

    /// Called as the user types TITLE so the rename preview follows live.
    func updateTitle(id: DraftTrack.ID, title: String) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].title = title
        tracks[i].suggestedName = suggestedBoleroName(for: tracks[i].sourceURL, index: i, title: title)
        if albumTitle.isEmpty { albumTitle = title }
    }

    func updatePerformer(id: DraftTrack.ID, performer: String) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].performer = performer
    }

    func updateFileName(id: DraftTrack.ID, fileName: String) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].fileName = fileName
        tracks[i].extMismatch = URL(fileURLWithPath: fileName).pathExtension.lowercased() != format.rawValue
    }

    /// Bulk rename applies to disk immediately (same folder rename), not just the draft —
    /// so the user sees renamed files right away. Export then moves them into the album.
    func applySuggestedRenames() {
        let fm = FileManager.default
        var failures: [String] = []
        for i in tracks.indices {
            guard let s = tracks[i].suggestedName, s != tracks[i].fileName else { continue }
            let dest = tracks[i].sourceURL.deletingLastPathComponent().appendingPathComponent(s)
            do {
                if fm.fileExists(atPath: dest.path) {
                    failures.append("\(s) exists")
                    continue
                }
                try fm.moveItem(at: tracks[i].sourceURL, to: dest)
                tracks[i].sourceURL = dest
                tracks[i].fileName = s
                tracks[i].suggestedName = nil
                tracks[i].extMismatch = dest.pathExtension.lowercased() != format.rawValue
            } catch {
                failures.append("\(tracks[i].sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // Rebuild source list from current track URLs (renamed on disk)
        sourceURLs = tracks.map { $0.sourceURL }
        if failures.isEmpty {
            error = nil
        } else {
            error = "Rename issues: " + failures.joined(separator: "; ")
        }
    }

    /// Rename files on disk to match loaded cue FILE names, paired by position
    /// (cue track order ↔ current track order). Re-edit only.
    var cueRenameSuggestions: [(from: String, to: String)] {
        guard !loadedCueFileNames.isEmpty else { return [] }
        return tracks.enumerated().compactMap { idx, t in
            guard idx < loadedCueFileNames.count else { return nil }
            let want = loadedCueFileNames[idx]
            guard want.lowercased() != t.sourceURL.lastPathComponent.lowercased(),
                  want.lowercased() != t.fileName.lowercased() else { return nil }
            return (t.sourceURL.lastPathComponent, want)
        }
    }

    func applyCueFileNames() {
        let fm = FileManager.default
        var failures: [String] = []
        for item in cueRenameSuggestions {
            guard let i = tracks.firstIndex(where: { $0.sourceURL.lastPathComponent == item.from }) else { continue }
            let dest = tracks[i].sourceURL.deletingLastPathComponent().appendingPathComponent(item.to)
            do {
                if fm.fileExists(atPath: dest.path) {
                    failures.append("\(item.to) exists")
                    continue
                }
                try fm.moveItem(at: tracks[i].sourceURL, to: dest)
                tracks[i].sourceURL = dest
                tracks[i].fileName = item.to
                tracks[i].suggestedName = nil
                tracks[i].extMismatch = dest.pathExtension.lowercased() != format.rawValue
            } catch {
                failures.append("\(item.from): \(error.localizedDescription)")
            }
        }
        sourceURLs = tracks.map { $0.sourceURL }
        error = failures.isEmpty ? nil : "Rename issues: " + failures.joined(separator: "; ")
    }

    var renameSuggestions: [(from: String, to: String)] {
        tracks.compactMap { t in
            guard let s = t.suggestedName, s != t.fileName else { return nil }
            return (t.sourceURL.lastPathComponent, s)
        }
    }

    // MARK: - Validation

    var validationError: String? {
        if tracks.isEmpty { return "Add source audio files first." }
        if targetPackURL == nil { return "Choose a playlist (pack)." }
        if targetAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Choose or name an album." }
        if albumTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Album TITLE is required." }
        if tracks.contains(where: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Every track needs a TITLE."
        }
        let names = tracks.map { $0.fileName.lowercased() }
        if Set(names).count != names.count { return "Duplicate FILE names — adjust titles or renames." }
        return nil
    }

    // MARK: - Export

    /// Moves (not copies) sources + cover into pack/album, applies renames, writes .cue,
    /// creates lrc folder only when missing (no cma). Returns cue URL.
    @discardableResult
    func export() throws -> URL {
        if let err = validationError { throw NSError(domain: "CueLab", code: 1, userInfo: [NSLocalizedDescriptionKey: err]) }
        let fm = FileManager.default
        guard let packURL = targetPackURL else { throw NSError(domain: "CueLab", code: 2, userInfo: [NSLocalizedDescriptionKey: "No playlist chosen."]) }
        let albumFolder = targetAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumDir = packURL.appendingPathComponent(albumFolder)
        try fm.createDirectory(at: albumDir, withIntermediateDirectories: true)

        // Move + rename audio into album dir
        var finalNames: [String] = []
        for track in tracks {
            let dest = albumDir.appendingPathComponent(track.fileName)
            if track.sourceURL.path != dest.path {
                if fm.fileExists(atPath: dest.path) {
                    throw NSError(domain: "CueLab", code: 3, userInfo: [NSLocalizedDescriptionKey: "Target exists: \(track.fileName). Adjust rename."])
                }
                try fm.moveItem(at: track.sourceURL, to: dest)
            }
            finalNames.append(track.fileName)
        }

        // Move cover image (if any) into album dir
        if let cover = coverURL {
            let dest = albumDir.appendingPathComponent(cover.lastPathComponent)
            if cover.path != dest.path {
                if fm.fileExists(atPath: dest.path) {
                    throw NSError(domain: "CueLab", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cover exists: \(cover.lastPathComponent). Remove it first."])
                }
                try fm.moveItem(at: cover, to: dest)
            }
            coverURL = dest
        }

        // lrc folder only when missing (no cma per user)
        if ensureLrc {
            let lrc = albumDir.appendingPathComponent("lrc")
            if !fm.fileExists(atPath: lrc.path) { try fm.createDirectory(at: lrc, withIntermediateDirectories: true) }
        }

        // Write cue
        let cueTitle = albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cueURL = albumDir.appendingPathComponent("\(cueTitle).cue")
        let content = renderCue(date: year, albumTitle: cueTitle)
        try content.write(to: cueURL, atomically: true, encoding: .utf8)

        // Refresh local state to moved files
        sourceURLs = tracks.map { albumDir.appendingPathComponent($0.fileName) }
        didExportURL = cueURL
        return cueURL
    }

    func renderCue(date: String, albumTitle: String) -> String {
        var lines: [String] = []
        let yyyy = date.trimmingCharacters(in: .whitespacesAndNewlines)
        if !yyyy.isEmpty { lines.append("REM DATE \(yyyy)") }
        lines.append("REM COMMENT \"By CueLab, Cella 2026\"")
        lines.append("TITLE \"\(escape(albumTitle))\"")
        for (idx, track) in tracks.enumerated() {
            lines.append("FILE \"\(track.fileName)\" \(format.fileType)")
            lines.append("  TRACK \(String(format: "%02d", idx + 1)) AUDIO")
            lines.append("    TITLE \"\(escape(track.title))\"")
            let perf = track.performer.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("    PERFORMER \"\(escape(perf.isEmpty ? "Unknown" : perf))\"")
            lines.append("    INDEX 01 00:00:00")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "'")
    }
}
