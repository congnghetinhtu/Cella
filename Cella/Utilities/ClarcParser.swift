import Foundation

// MARK: - CLARC Reader
//
// Reader for the CLARC/1 lyric format (spec: clarc/FORMAT.md in the repo
// root). CLARC keeps LRC's `[mm:ss.xx]` timestamps but separates song info
// from lyric events with two required section headers:
//
//     CLARC/1
//
//     [metadata]
//     title: Song title
//     artist.1: Quang Hùng MasterD
//
//     [lyrics]
//     [00:00.00] …
//     [00:19.46] [v1] Khi xưa tan trường
//     [har 01:28.00] (Ah-ah)
//
// Reading is tolerant: unknown metadata keys are preserved, out-of-order
// timestamps are re-sorted, and malformed event lines are skipped. The
// output reuses `LrcLine`, so a CLARC file flows through the existing lyric
// pipeline (scroll engine, placeholders, transitions) untouched.

struct ClarcMetadata {
    var title = ""
    var album = ""
    var writer = ""
    var duration = ""
    /// `artist.N` entries in ascending index order (plain `artist:` acts as 1).
    var artists: [String] = []
    /// Unrecognized `key: value` pairs, preserved per the v1 spec.
    var extras: [String: String] = [:]

    var isEmpty: Bool {
        title.isEmpty && album.isEmpty && writer.isEmpty && duration.isEmpty && artists.isEmpty
    }

    /// Bridge into the legacy LRC tag struct so metadata call sites
    /// (`LrcParser.metadata`) can consume CLARC without branching.
    var toLrcMetadata: LrcMetadata {
        var meta = LrcMetadata()
        meta.title = title
        meta.artist = artists.joined(separator: " & ")
        meta.album = album
        meta.author = writer
        meta.length = duration
        return meta
    }
}

struct ClarcParser {
    /// A file is CLARC only when the first non-empty line is exactly this.
    static let magic = "CLARC/1"

    // MARK: Parsing

    /// Parses CLARC/1 text. Returns nil when the file doesn't carry a
    /// recognized version marker, so callers can fall back to other readers.
    ///
    /// Legacy rescue: an older Cluster edit path once re-emitted a classic
    /// LRC banner (`[ti:…]`,`[ar:…]`) ahead of the magic line, breaking the
    /// first-non-empty check. When every line before a `CLARC/1` line is
    /// blank or a `[word:…]` tag, skip that banner and repair instead of
    /// failing, so existing corrupted files heal on the very next read.
    static func parse(_ content: String) -> (metadata: ClarcMetadata, lines: [LrcLine])? {
        let rows = content.components(separatedBy: "\n")
        var working = content
        if let magicIndex = rows.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == magic }),
           magicIndex > 0,
           rows[..<magicIndex].allSatisfy({ junk in
               let t = junk.trimmingCharacters(in: .whitespaces)
               return t.isEmpty || (t.hasPrefix("[") && t.hasSuffix("]"))
           }) {
            working = rows[magicIndex...].joined(separator: "\n")
        }

        var metadata = ClarcMetadata()
        var artistById: [Int: String] = [:]
        var lines: [LrcLine] = []

        enum Section { case magic, metadata, lyrics }
        var section = Section.magic

        for raw in working.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            switch section {
            case .magic:
                guard trimmed == magic else { return nil }
                section = .metadata   // next recognized section header switches again

            case .metadata:
                if trimmed == "[metadata]" { continue }
                if trimmed == "[lyrics]" { section = .lyrics; continue }
                assignMetadata(trimmed, to: &metadata, artists: &artistById)

            case .lyrics:
                if let line = parseEventLine(trimmed) {
                    lines.append(line)
                }
            }
        }

        metadata.artists = artistById.sorted { $0.key < $1.key }.map(\.value)
        lines.sort { $0.time < $1.time }
        return (metadata, lines)
    }

    static func load(from url: URL) -> (metadata: ClarcMetadata, lines: [LrcLine]) {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let result = parse(content) else {
            return (ClarcMetadata(), [])
        }
        return result
    }

    /// Reads only the `[metadata]` section, stopping at `[lyrics]` — a fast
    /// header-only read for metadata enrichment (mirrors LrcParser).
    static func metadataOnly(from url: URL) -> ClarcMetadata? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var seenMagic = false
        var metadata = ClarcMetadata()
        var artistById: [Int: String] = [:]

        for raw in content.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if !seenMagic {
                guard trimmed == magic else { return nil }
                seenMagic = true
                continue
            }
            if trimmed == "[lyrics]" { break }
            if trimmed == "[metadata]" { continue }
            assignMetadata(trimmed, to: &metadata, artists: &artistById)
        }
        guard seenMagic else { return nil }
        metadata.artists = artistById.sorted { $0.key < $1.key }.map(\.value)
        return metadata
    }

    // MARK: - Internals

    /// `key: value` → recognized fields + indexed artists; unknown keys are
    /// preserved in `extras`. Duplicates are invalid per spec — last wins.
    private static func assignMetadata(
        _ line: String,
        to metadata: inout ClarcMetadata,
        artists: inout [Int: String]
    ) {
        guard let colon = line.firstIndex(of: ":") else { return }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }

        // `artist.N` indexes vocalists; plain `artist` acts as index 1.
        if key == "artist" {
            artists[1] = value
        } else if let dotIndex = key.range(of: "artist.")?.upperBound,
                  let idx = Int(String(key[dotIndex...])), idx > 0 {
            artists[idx] = value
        } else {
            switch key.lowercased() {
            case "title":    metadata.title = value
            case "album":    metadata.album = value
            case "writer":   metadata.writer = value
            case "duration": metadata.duration = value
            default:         metadata.extras[key] = value
            }
        }
    }

    // Compiled once — see LrcParser for why (per-line compilation froze the main thread).
    // Captures: 1 [har ] flag, 2 min, 3 sec, 4 fraction, 5 vocalist marker, 6 text.
    private static let eventRegex = try! NSRegularExpression(
        pattern: #"^\[(har\s+)?(\d+):(\d{1,2})(?:\.(\d{1,3}))?\]\s*(?:\[(v\d+(?:&v\d+)*)\]\s*)?(.*)"#)
    private static let duoMarker = "[DUO]"

    /// One `[lyrics]` row → `LrcLine`. Handles three token forms:
    /// `[mm:ss.xx] text`, harmony `[har mm:ss.xx] text`, and an optional
    /// vocalist marker (`[v1]`, `[v1&v2]`) right after the timestamp.
    /// The `[DUO]` layout marker is display metadata — not lyric text, so
    /// it's carried as the row's left/right split instead of shown; the
    /// vocalist ids ride along as attribution.
    private static func parseEventLine(_ line: String) -> LrcLine? {
        guard let c = captures(eventRegex, in: line), c.count >= 7 else { return nil }
        guard let minutes = Double(c[2]),
              let seconds = Double(c[3]), seconds < 60 else { return nil }

        var fraction: Double = 0
        let frac = c[4]
        if !frac.isEmpty {
            let padded = frac.padding(toLength: 3, withPad: "0", startingAt: 0)
            fraction = (Double(padded) ?? 0) / 1000.0
        }

        var text = c[6]

        var duoLead = ""
        var duoTail = ""
        if let duoRange = text.range(of: duoMarker) {
            // [DUO] is a layout split: before → left part, after → right
            // part of the same display row. The joined form stays in `text`
            // for non-split consumers.
            duoLead = String(text[..<duoRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            duoTail = String(text[duoRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            text = duoLead.isEmpty ? duoTail : (duoTail.isEmpty ? duoLead : duoLead + " " + duoTail)
        }
        text = text.trimmingCharacters(in: .whitespaces)

        let isHarmony = !c[1].isEmpty
        var vocalists: [Int] = []
        if !c[5].isEmpty {
            vocalists = c[5]
                .components(separatedBy: "&")
                .compactMap { Int($0.dropFirst()) }   // "v1" → 1
                .filter { $0 > 0 }
        }

        // Empty lyric is allowed — it occupies a timed gap slot in the scroll.
        return LrcLine(
            time: minutes * 60 + seconds + fraction,
            text: text,
            vocalists: vocalists,
            isHarmony: isHarmony,
            duoLead: duoLead,
            duoTail: duoTail)
    }

    private static func captures(_ regex: NSRegularExpression, in text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            if let r = Range(m.range(at: i), in: text) { return String(text[r]) }
            return ""
        }
    }

    // MARK: - Writing

    /// Composes CLARC/1 text: magic line, `[metadata]` (recognized keys in
    /// spec order, then preserved extras), `[lyrics]` event lines. Timestamps
    /// use `[MM:SS.xx]` hundredths with `] text` separators like the samples.
    static func compose(metadata: ClarcMetadata, lines: [LrcLine]) -> String {
        var out: [String] = [magic, "", "[metadata]"]
        func clean(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        if !metadata.title.isEmpty { out.append("title: \(clean(metadata.title))") }
        for (index, artist) in metadata.artists.enumerated() {
            let name = clean(artist)
            guard !name.isEmpty else { continue }
            out.append("artist.\(index + 1): \(name)")
        }
        if !metadata.writer.isEmpty { out.append("writer: \(clean(metadata.writer))") }
        if !metadata.album.isEmpty { out.append("album: \(clean(metadata.album))") }
        if !metadata.duration.isEmpty { out.append("duration: \(clean(metadata.duration))") }
        for (key, value) in metadata.extras where !key.isEmpty {
            out.append("\(key): \(clean(value))")
        }
        out.append("")
        out.append("[lyrics]")
        for line in lines {
            let t = line.time
            let minutes = Int(t) / 60
            let seconds = Int(t) % 60
            let hundredths = Int(((t - Double(Int(t))) * 100).rounded())
            let stamp = line.isHarmony
                ? String(format: "[har %02d:%02d.%02d]", minutes, seconds, hundredths)
                : String(format: "[%02d:%02d.%02d]", minutes, seconds, hundredths)
            var row = stamp
            // Vocalist attribution: `[v1]` / `[v1&v2]` after the timestamp.
            let ids = line.vocalists.filter { $0 > 0 }
            if !ids.isEmpty {
                row += " [v" + ids.map(String.init).joined(separator: "&v") + "]"
            }
            if line.isDuo {
                // Re-emit the layout marker between the halves; empty halves
                // keep the marker dangling on their side.
                var body = line.duoLead
                if !line.duoTail.isEmpty {
                    body = body.isEmpty ? "[DUO] " + line.duoTail : body + " [DUO] " + line.duoTail
                } else {
                    body = body.isEmpty ? "[DUO]" : body + " [DUO]"
                }
                row += " " + body
            } else if !line.text.isEmpty {
                row += " " + line.text
            }
            out.append(row)
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Maps LRC header tags into CLARC metadata. The combined artist string
    /// splits via ArtistMatcher where possible (falls back to a single entry).
    static func from(lrc: LrcMetadata) -> ClarcMetadata {
        var meta = ClarcMetadata()
        meta.title = lrc.title
        meta.album = lrc.album
        meta.writer = lrc.author
        meta.duration = lrc.length
        let raw = lrc.artist.trimmingCharacters(in: .whitespaces)
        if !raw.isEmpty {
            let split = ArtistMatcher.splitRaw(raw)
            meta.artists = split.isEmpty ? [raw] : split
        }
        return meta
    }

    /// Cluster's edit-song path: swap title / artist / album inside a CLARC
    /// document while every lyric row stays byte-for-byte the same structure
    /// (timestamps, `[har]`, `[vN]` marks). The edited artist string arrives
    /// as the joined display form — it splits back into `artist.N` entries.
    /// An empty field clears it, mirroring the LRC tag surgeon. Returns nil
    /// when the content isn't parseable so callers never blind-write.
    static func updatingMetadata(in content: String, title: String, artist: String, album: String) -> String? {
        guard let doc = parse(content) else { return nil }
        var meta = doc.metadata
        meta.title = title
        if artist.isEmpty {
            meta.artists = []
        } else {
            let split = ArtistMatcher.splitRaw(artist)
            meta.artists = split.isEmpty ? [artist] : split
        }
        meta.album = album
        return compose(metadata: meta, lines: doc.lines)
    }
}
