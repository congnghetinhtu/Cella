//
//  LrcParser.swift
//  Cella
//
//  Parses standard LRC format lyrics files.
//  Format: [MM:SS.xx] Lyrics line text
//

import Foundation

struct LrcLine: Identifiable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}

struct LrcParser {
    static func parse(_ content: String) -> [LrcLine] {
        var lines: [LrcLine] = []

        for raw in content.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

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

        return lines.sorted { $0.time < $1.time }
    }

    static func load(from url: URL) -> [LrcLine] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return parse(content)
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
