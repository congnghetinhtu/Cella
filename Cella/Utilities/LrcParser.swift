import Foundation

struct LrcLine: Identifiable {
    let id = UUID()
    let time: TimeInterval
    let text: String
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
    static func parse(_ content: String) -> (metadata: LrcMetadata, lines: [LrcLine]) {
        var metadata = LrcMetadata()
        var lines: [LrcLine] = []

        for raw in content.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Try metadata: [key:value]
            if let metaMatch = firstMatch(
                #"\[([a-zA-Z]+):(.*)\]"#,
                in: trimmed
            ), metaMatch.count >= 3 {
                let key = metaMatch[1]
                let value = metaMatch[2]
                // Only treat as metadata if key is NOT a number (timestamp)
                if Int(key) == nil {
                    metadata.set(key: key, value: value)
                    continue
                }
            }

            // Try timestamp: [MM:SS.xx]
            let matches = matchesForPattern(
                #"\[(\d{2}):(\d{2})\.?(\d{0,3})\](.*)"#,
                in: trimmed
            )
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

    /// Looks up the .lrc file matching `audioURL` inside `playlistFolder` and
    /// returns its metadata tags (title, artist, album, etc.).
    /// Search order mirrors `loadLyrics`: album/lrc/ → root/lrc/ → root/.
    static func metadata(for audioURL: URL, in playlistFolder: URL) -> LrcMetadata {
        let lrcName = audioURL.deletingPathExtension().lastPathComponent + ".lrc"
        let albumDir = audioURL.deletingLastPathComponent()
        let candidates = [
            albumDir.appendingPathComponent("lrc").appendingPathComponent(lrcName),
            playlistFolder.appendingPathComponent("lrc").appendingPathComponent(lrcName),
            playlistFolder.appendingPathComponent(lrcName)
        ]
        for lrcURL in candidates where FileManager.default.fileExists(atPath: lrcURL.path) {
            let meta = loadMetadataOnly(from: lrcURL)
            if !meta.isEmpty { return meta }
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
            if let metaMatch = firstMatch(
                #"\[([a-zA-Z]+):(.*)\]"#,
                in: trimmed
            ), metaMatch.count >= 3 {
                metadata.set(key: metaMatch[1], value: metaMatch[2])
            }
        }
        return metadata
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            if let r = Range(m.range(at: i), in: text) {
                return String(text[r])
            }
            return ""
        }
    }

    private static func matchesForPattern(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
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
