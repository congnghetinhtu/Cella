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

            if let fileMatch = firstMatch(#"FILE\s+"([^"]+)"\s+\w+"#, in: trimmed) {
                currentFile = fileMatch
                continue
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
