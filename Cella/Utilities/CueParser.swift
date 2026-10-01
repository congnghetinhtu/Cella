import Foundation

struct CueTrack {
    let number: Int
    let title: String
    let performer: String
    let fileName: String
    let index01: String
}

struct CueSheet {
    let title: String
    let performer: String
    let tracks: [CueTrack]

    var trackCount: Int { tracks.count }

    func trackOrder(for audioFiles: [URL]) -> [URL] {
        guard !tracks.isEmpty else { return audioFiles }

        var matched: [URL] = []
        var unmatched = audioFiles

        for cueTrack in tracks {
            if let idx = unmatched.firstIndex(where: {
                $0.lastPathComponent.lowercased() == cueTrack.fileName.lowercased()
            }) {
                matched.append(unmatched.remove(at: idx))
            }
        }

        matched.append(contentsOf: unmatched)
        return matched
    }
}

struct CueParser {
    static func parse(_ content: String) -> CueSheet {
        var title = ""
        var performer = ""
        var tracks: [CueTrack] = []

        var currentTrack: (number: Int, title: String, performer: String, fileName: String, index01: String)?
        var currentFile = ""

        for raw in content.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Tolerates malformed lines CueLab once wrote:
            //   FILE "07 - Mua Xuan Cua Me".wav WAVE  (stray extension after quote)
            //   FILE "10 - ...Cam On" WAVE  (missing extension → assume .wav)
            if trimmed.hasPrefix("FILE") {
                let name = fileNameFromLine(trimmed)
                if !name.isEmpty {
                    currentFile = name
                    continue
                }
            }

            if let trackMatch = firstMatch(#"TRACK\s+(\d+)\s+\w+"#, in: trimmed) {
                if let t = currentTrack {
                    tracks.append(CueTrack(
                        number: t.number,
                        title: t.title,
                        performer: t.performer,
                        fileName: t.fileName,
                        index01: t.index01
                    ))
                }
                currentTrack = (number: Int(trackMatch) ?? 0, title: "", performer: "", fileName: currentFile, index01: "")
                continue
            }

            if trimmed.hasPrefix("TITLE") {
                let value = extractQuoted(trimmed)
                if currentTrack != nil {
                    currentTrack!.title = value
                } else {
                    title = value
                }
                continue
            }

            if trimmed.hasPrefix("PERFORMER") {
                let value = extractQuoted(trimmed)
                if currentTrack != nil {
                    currentTrack!.performer = value
                } else {
                    performer = value
                }
                continue
            }

            if trimmed.contains("INDEX") {
                if let idxMatch = firstMatch(#"INDEX\s+\d+\s+(\d+:\d+:\d+)"#, in: trimmed) {
                    currentTrack?.index01 = idxMatch
                }
            }
        }

        if let t = currentTrack {
            tracks.append(CueTrack(
                number: t.number,
                title: t.title,
                performer: t.performer,
                fileName: t.fileName,
                index01: t.index01
            ))
        }

        return CueSheet(title: title, performer: performer, tracks: tracks)
    }

    static func load(from url: URL) -> CueSheet? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let sheet = parse(content)
        return sheet.trackCount > 0 ? sheet : nil
    }

    /// Rewrites album-level TITLE/PERFORMER, leaving TRACK blocks and every other
    /// line (REM DATE, CATALOG, tolerated malformed FILE lines) byte-identical.
    /// An empty value drops the line, so the scanner falls back to the folder name.
    static func updatingMetadata(in content: String, title: String, performer: String) -> String {
        // Split/join on "\n" only: `components(separatedBy: .newlines)` also splits
        // on a bare "\r", which injects blank lines into CRLF cue files on every save.
        let cr = content.contains("\r\n") ? "\r" : ""
        let lines = content.components(separatedBy: "\n")
        var insideTrack = false
        var wroteTitle = false
        var wrotePerformer = false
        var out: [String] = []
        out.reserveCapacity(lines.count + 2)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("TRACK") { insideTrack = true }

            if !insideTrack, trimmed.hasPrefix("TITLE") {
                if wroteTitle { continue }
                wroteTitle = true
                let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { out.append("TITLE \"\(sanitize(value))\"\(cr)") }
                continue
            }
            if !insideTrack, trimmed.hasPrefix("PERFORMER") {
                if wrotePerformer { continue }
                wrotePerformer = true
                let value = performer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { out.append("PERFORMER \"\(sanitize(value))\"\(cr)") }
                continue
            }
            out.append(line)
        }

        var prefix: [String] = []
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty, !wroteTitle { prefix.append("TITLE \"\(sanitize(cleanTitle))\"\(cr)") }
        let cleanPerformer = performer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanPerformer.isEmpty, !wrotePerformer { prefix.append("PERFORMER \"\(sanitize(cleanPerformer))\"\(cr)") }

        return (prefix + out).joined(separator: "\n")
    }

    /// CUE has no escape for quotes inside a quoted value, so flatten them.
    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Rewrites one track (the segment whose FILE matches `fileName`): TITLE,
    /// PERFORMER, and optionally the FILE name when the audio file is renamed.
    /// Every other segment is copied byte-identical.
    ///
    /// Segments start at a FILE line, because a real cue puts FILE *before* its
    /// TRACK. Keying off TRACK instead would hand each track the previous
    /// track's filename.
    static func updatingTrack(
        in content: String,
        fileName: String,
        newFileName: String?,
        title: String,
        performer: String
    ) -> String {
        // Split/join on "\n" only: `components(separatedBy: .newlines)` also splits
        // on a bare "\r", which injects blank lines into CRLF cue files on every save.
        let cr = content.contains("\r\n") ? "\r" : ""
        let lines = content.components(separatedBy: "\n")

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPerformer = performer.trimmingCharacters(in: .whitespacesAndNewlines)

        func trimmed(_ line: String) -> String {
            line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func isCueLine(_ line: String, _ prefix: String) -> Bool {
            trimmed(line).hasPrefix(prefix)
        }

        // Album header: everything before the first FILE (or TRACK, when the cue
        // has no FILE lines at all).
        let firstFile = lines.firstIndex { isCueLine($0, "FILE") }
        let firstTrack = lines.firstIndex { isCueLine($0, "TRACK") }
        let splitAt: Int
        if let firstFile {
            splitAt = firstFile
        } else if let firstTrack {
            splitAt = firstTrack
        } else {
            return content
        }
        let head = Array(lines[..<splitAt])
        let rest = Array(lines[splitAt...])

        var out = head

        if firstFile != nil {
            // FILE-led segments.
            var starts: [Int] = []
            for (index, line) in rest.enumerated() where isCueLine(line, "FILE") {
                starts.append(index)
            }
            starts.append(rest.endIndex)
            for seg in 0..<(starts.count - 1) {
                let segment = Array(rest[starts[seg]..<starts[seg + 1]])
                let segmentFile = fileNameFromLine(segment[0].trimmingCharacters(in: .whitespaces))
                guard segmentFile.caseInsensitiveCompare(fileName) == .orderedSame else {
                    out += segment
                    continue
                }
                out.append("FILE \"\(sanitize(newFileName ?? segmentFile))\" WAVE")
                out += rewrittenSegmentBody(segment.dropFirst(), title: cleanTitle, performer: cleanPerformer, cr: cr)
            }
            return out.joined(separator: "\n")
        }

        // No FILE lines: TRACK-led segments.
        var starts: [Int] = []
        for (index, line) in rest.enumerated() where isCueLine(line, "TRACK") {
            starts.append(index)
        }
        guard starts.count > 1 else { return content }
        starts.append(rest.endIndex)
        for seg in 0..<(starts.count - 1) {
            let segment = Array(rest[starts[seg]..<starts[seg + 1]])
            out.append(segment[0])
            out += rewrittenSegmentBody(segment.dropFirst(), title: cleanTitle, performer: cleanPerformer, cr: cr)
        }
        return out.joined(separator: "\n")
    }

    /// Replaces the first TITLE/PERFORMER after a TRACK line with the new values,
    /// dropping them when empty. Anything else (INDEX, REM, …) is untouched.
    private static func rewrittenSegmentBody(_ body: ArraySlice<String>, title: String, performer: String, cr: String) -> [String] {
        var kept: [String] = []
        var sawTrack = false
        var wroteTitle = false
        var wrotePerformer = false
        for line in body {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("TRACK") { sawTrack = true }
            if sawTrack, trimmed.hasPrefix("TITLE"), !wroteTitle {
                wroteTitle = true
                if !title.isEmpty { kept.append("    TITLE \"\(sanitize(title))\"\(cr)") }
                continue
            }
            if sawTrack, trimmed.hasPrefix("PERFORMER"), !wrotePerformer {
                wrotePerformer = true
                if !performer.isEmpty { kept.append("    PERFORMER \"\(sanitize(performer))\"\(cr)") }
                continue
            }
            kept.append(line)
        }
        if sawTrack {
            if !title.isEmpty, !wroteTitle { kept.insert("    TITLE \"\(sanitize(title))\"\(cr)", at: 0) }
            if !performer.isEmpty, !wrotePerformer {
                kept.insert("    PERFORMER \"\(sanitize(performer))\"\(cr)", at: title.isEmpty ? 0 : 1)
            }
        }
        return kept
    }

    /// Extracts the FILE name, tolerating a stray extension after the closing
    /// quote (`"07 - Foo".wav`) and a missing extension (`"10 - Foo"` → `10 - Foo.wav`).
    private static func fileNameFromLine(_ line: String) -> String {
        guard let open = line.range(of: "\"")?.upperBound,
              let close = line[open...].range(of: "\"")?.lowerBound else { return "" }
        var name = String(line[open..<close])
        let tail = String(line[close...]).trimmingCharacters(in: .whitespaces)
        // Tail like `.wav WAVE` — reattach the extension to the quoted stem.
        if tail.hasPrefix("."),
           let space = tail.range(of: " ")?.lowerBound {
            let ext = String(tail[tail.startIndex..<space])
            if !name.lowercased().hasSuffix(ext.lowercased()) { name += ext }
        }
        // Cue FILEs always carry an extension; assume .wav when absent.
        if (name as NSString).pathExtension.isEmpty { name += ".wav" }
        return name
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func extractQuoted(_ line: String) -> String {
        guard let start = line.range(of: "\"")?.upperBound,
              let end = line[start...].range(of: "\"")?.lowerBound else {
            return line.replacingOccurrences(of: "TITLE", with: "")
                .replacingOccurrences(of: "PERFORMER", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        return String(line[start..<end])
    }
}
