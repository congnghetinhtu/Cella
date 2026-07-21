//
//  EpubParser.swift
//  Cella
//
//  Extract text from epub files via EPUBKit.
//

import Foundation
import EPUBKit

enum EpubParser {

    private static let wordsPerPage = 25

    struct ParsedBook {
        let title: String
        let author: String
        let pages: [String]
        let pageNumbers: [Int]
        let coverURL: URL?
    }

    static func parse(url: URL) -> ParsedBook? {
        guard let document = EPUBDocument(url: url) else { return nil }

        let title = document.title ?? url.deletingPathExtension().lastPathComponent
        let author = document.author ?? ""
        let coverURL = document.cover

        var fullText = ""

        for (_, spineItem) in document.spine.items.enumerated() {
            guard let manifestItem = document.manifest.items[spineItem.idref] else { continue }
            let fileURL = document.contentDirectory.appendingPathComponent(manifestItem.path)
            guard let html = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            fullText += stripHTML(html) + " "
        }

        let words = fullText.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }

        var pages: [String] = []
        var pageNumbers: [Int] = []
        var pageNum = 1

        var i = 0
        while i < words.count {
            let end = min(i + wordsPerPage, words.count)
            let chunk = words[i..<end].joined(separator: " ")
            pages.append(chunk)
            pageNumbers.append(pageNum)

            if end >= words.count { break }
            i = end
            pageNum += 1
        }

        return ParsedBook(title: title, author: author, pages: pages, pageNumbers: pageNumbers, coverURL: coverURL)
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html
        let patterns = [
            "<script[^>]*>[\\s\\S]*?</script>",
            "<style[^>]*>[\\s\\S]*?</style>",
            "<[^>]+>"
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }
        let entities: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&nbsp;": " ",
            "&#x27;": "'", "&#x2F;": "/", "&hellip;": "...",
            "&mdash;": "—", "&ndash;": "–"
        ]
        for (entity, char) in entities {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        text = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
