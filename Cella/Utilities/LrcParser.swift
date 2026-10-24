import Foundation

struct LrcLine: Identifiable {
    let id = UUID()
    let time: TimeInterval
    let text: String
    /// CLARC vocalist attribution — artist.N indexes (1, 2, …). Displayed
    /// lyric text never contains the [vN] marker.
    var vocalists: [Int] = []
    /// CLARC harmony row ([har mm:ss.xx]) — a timed backing-vocal part.
    var isHarmony: Bool = false
    /// CLARC `[DUO]` layout split: the row's displayed halves on one row —
    /// `duoLead` hugs the left edge, `duoTail` hugs the right. Both are
    /// display text (the marker itself is stripped). `text` keeps the joined
    /// reading form for non-split consumers (slim captions, "..." checks).
    var duoLead: String = ""
    var duoTail: String = ""
    /// True only when the row carried a `[DUO]` marker with text on a side.
    var isDuo: Bool { !(duoLead.isEmpty && duoTail.isEmpty) }
}

struct LrcMetadata {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var author: String = ""
    var length: String = ""
    var by: String = ""
    var offset: String = ""
    var editor: String = ""
    var version: String = ""

    var isEmpty: Bool {
        title.isEmpty && artist.isEmpty && album.isEmpty && author.isEmpty &&
        length.isEmpty && by.isEmpty && offset.isEmpty && editor.isEmpty && version.isEmpty
    }

    mutating func set(key: String, value: String) {
        switch key.lowercased() {
        case "ti": title = value
        case "ar": artist = value
        case "al": album = value
        case "au": author = value
        case "length": length = value
        case "by": by = value
        case "offset": offset = value
        case "re": editor = value
        case "ve": version = value
        default: break
        }
    }

    func toLrcString() -> String {
        var lines: [String] = []
        if !title.isEmpty   { lines.append("[ti:\(title)]") }
        if !artist.isEmpty { lines.append("[ar:\(artist)]") }
        if !album.isEmpty  { lines.append("[al:\(album)]") }
        if !author.isEmpty { lines.append("[au:\(author)]") }
        if !length.isEmpty { lines.append("[length:\(length)]") }
        if !by.isEmpty     { lines.append("[by:\(by)]") }
        if !offset.isEmpty { lines.append("[offset:\(offset)]") }
        if !editor.isEmpty { lines.append("[re:\(editor)]") }
        if !version.isEmpty { lines.append("[ve:\(version)]") }
        return lines.joined(separator: "\n")
    }
}

struct LrcParser {
    /// Rewrites only the leading `[ti:]` / `[ar:]` / `[al:]` header tags and leaves
    /// every lyric line byte-identical, so timestamps are never reformatted.
    /// An empty value drops the tag.
    static func updatingMetadata(in content: String, title: String, artist: String, album: String) -> String {
        // Split/join on "\n" only: `components(separatedBy: .newlines)` also splits
        // on a bare "\r", injecting blank lines into CRLF lyric files on every save.
        let cr = content.contains("\r\n") ? "\r" : ""
        let lines = content.components(separatedBy: "\n")

        func clean(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "]", with: ")")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }
        let newTitle = clean(title)
        let newArtist = clean(artist)
        let newAlbum = clean(album)

        var out: [String] = []
        var inHeader = true
        var keptHeader: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if inHeader, isTimestampTag(trimmed) { inHeader = false; out.append(line); continue }
            if !inHeader { out.append(line); continue }
            // Still in the header: drop old ti/ar/al, keep every other tag in place.
            if let key = headerKey(trimmed) {
                switch key {
                case "ti", "ar", "al": continue // re-emitted below in canonical order
                default: keptHeader.append(line)
                }
                continue
            }
            keptHeader.append(line)
        }

        // Canonical order, then the untouched tags ([by:], [offset:], …).
        var header: [String] = []
        if !newTitle.isEmpty { header.append("[ti:\(newTitle)]\(cr)") }
        if !newArtist.isEmpty { header.append("[ar:\(newArtist)]\(cr)") }
        if !newAlbum.isEmpty { header.append("[al:\(newAlbum)]\(cr)") }
        header += keptHeader

        return (header + out).joined(separator: "\n")
    }

    /// `[key:value]` → lowercased non-numeric key, else nil.
    private static func headerKey(_ line: String) -> String? {
        guard line.hasPrefix("["), line.hasSuffix("]"),
              let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[line.index(line.startIndex, offsetBy: 1)..<colon])
        guard !key.isEmpty, Int(key) == nil else { return nil }
        return key.lowercased()
    }

    // Compiled once — these used to recompile per line, per track, which
    // froze the main thread when opening big structured packs.
    private static let metaTagRegex = try! NSRegularExpression(pattern: #"\[([a-zA-Z]+):(.*)\]"#)
    private static let timestampRegex = try! NSRegularExpression(pattern: #"\[(\d{2}):(\d{2})\.?(\d{0,3})\](.*)"#)

    private static func isTimestampTag(_ line: String) -> Bool {
        guard line.hasPrefix("["), line.hasSuffix("]"),
              let colon = line.firstIndex(of: ":") else { return false }
        return Int(line[line.index(line.startIndex, offsetBy: 1)..<colon]) != nil
    }

    static func parse(_ content: String) -> (metadata: LrcMetadata, lines: [LrcLine]) {
        var metadata = LrcMetadata()
        var lines: [LrcLine] = []

        for raw in content.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Try metadata: [key:value]
            if let metaMatch = firstMatch(metaTagRegex, in: trimmed),
               metaMatch.count >= 3 {
                let key = metaMatch[1]
                let value = metaMatch[2]
                // Only treat as metadata if key is NOT a number (timestamp)
                if Int(key) == nil {
                    metadata.set(key: key, value: value)
                    continue
                }
            }

            // Try timestamp: [MM:SS.xx]
            let matches = matchesForPattern(timestampRegex, in: trimmed)
            for match in matches {
                guard match.count >= 5 else { continue }
                let minStr = match[1]
                let secStr = match[2]
                let fracStr = match[3]
                let text = match[4].trimmingCharacters(in: .whitespaces)

                guard let minutes = Double(minStr),
                      let seconds = Double(secStr) else { continue }

                var fraction: Double = 0
                if !fracStr.isEmpty {
                    let padded = fracStr.padding(toLength: 3, withPad: "0", startingAt: 0)
                    fraction = Double(padded) ?? 0
                    fraction /= 1000.0
                }

                let time = minutes * 60.0 + seconds + fraction
                if !text.isEmpty {
                    lines.append(LrcLine(time: time, text: text))
                }
            }
        }

        return (metadata, lines.sorted { $0.time < $1.time })
    }

    static func load(from url: URL) -> (metadata: LrcMetadata, lines: [LrcLine]) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return (LrcMetadata(), [])
        }
        return parse(content)
    }

    /// Looks up the lyric file matching `audioURL` inside `playlistFolder`
    /// and returns its metadata tags (title, artist, album, etc.).
    /// Search order mirrors `loadLyrics`: album/lrc/ → root/lrc/ → root/.
    /// On macOS, a sibling .clarc wins within each directory (CLARC/1
    /// carries richer tags — indexed artists, writer, duration).
    static func metadata(for audioURL: URL, in playlistFolder: URL) -> LrcMetadata {
        let lrcBase = audioURL.deletingPathExtension().lastPathComponent
        let albumDir = audioURL.deletingLastPathComponent()
        let dirs = [
            albumDir.appendingPathComponent("lrc"),
            playlistFolder.appendingPathComponent("lrc"),
            playlistFolder
        ]
        for dir in dirs {
            #if os(macOS)
            let clarcURL = dir.appendingPathComponent(lrcBase + ".clarc")
            if FileManager.default.fileExists(atPath: clarcURL.path),
               let clarcMeta = ClarcParser.metadataOnly(from: clarcURL),
               !clarcMeta.isEmpty {
                return clarcMeta.toLrcMetadata
            }
            #endif
            let lrcURL = dir.appendingPathComponent(lrcBase + ".lrc")
            if FileManager.default.fileExists(atPath: lrcURL.path) {
                let meta = loadMetadataOnly(from: lrcURL)
                if !meta.isEmpty { return meta }
            }
        }
        return LrcMetadata()
    }

    /// Reads only the header tags from an .lrc file, stopping at the first
    /// timestamp line. Much faster than parsing the full file.
    private static func loadMetadataOnly(from url: URL) -> LrcMetadata {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return LrcMetadata()
        }
        var metadata = LrcMetadata()
        for raw in content.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // First timestamp = end of header
            if trimmed.hasPrefix("[") {
                if let firstChar = trimmed.dropFirst().first, firstChar.isNumber { break }
            }
            if let metaMatch = firstMatch(metaTagRegex, in: trimmed),
               metaMatch.count >= 3 {
                metadata.set(key: metaMatch[1], value: metaMatch[2])
            }
        }
        return metadata
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            if let r = Range(m.range(at: i), in: text) {
                return String(text[r])
            }
            return ""
        }
    }

    private static func matchesForPattern(_ regex: NSRegularExpression, in text: String) -> [[String]] {
        let range = NSRange(text.startIndex..., in: text)
        let nsMatches = regex.matches(in: text, range: range)

        return nsMatches.map { m in
            (0..<m.numberOfRanges).map { i in
                if let r = Range(m.range(at: i), in: text) {
                    return String(text[r])
                }
                return ""
            }
        }
    }
}

// MARK: - Placeholder Identity

extension String {
    /// Gap/instrumental marker identity — all of these count as "...":
    /// blank, dot runs ("...", "…"), and "instrumental" in any wrapper
    /// ("(Instrumental)", "[Instrumental]", "Instrumental", …).
    /// Real lyrics ("...yeah", "Instrumental dreams") never match.
    var isLyricPlaceholder: Bool {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.allSatisfy({ $0 == "." || $0 == "…" }) { return true }
        var s = t.lowercased()
        let wrappers = [
            ("(", ")"), ("[", "]"), ("{", "}"),
            ("\"", "\""), ("“", "”"), ("‘", "’"), ("（", "）"),
        ]
        for (open, close) in wrappers
        where s.hasPrefix(open) && s.hasSuffix(close)
            && s.count >= open.count + close.count {
            s = String(s.dropFirst(open.count).dropLast(close.count))
            break
        }
        let inner = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.isEmpty { return true }
        if inner.allSatisfy({ $0 == "." || $0 == "…" }) { return true }
        let core = inner
            .trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return core == "instrumental"
    }
}
