//
//  BookAsset.swift
//  Cella
//
//  Epub book metadata with reading progress.
//

import Foundation

struct BookAsset: Identifiable, Codable, Hashable {
    let id: UUID
    let fileName: String
    var title: String
    var author: String
    var totalSentences: Int
    var lastSentenceIndex: Int
    var coverFileName: String?
    let dateAdded: Date

    var progress: Double {
        guard totalSentences > 0 else { return 0 }
        return Double(lastSentenceIndex) / Double(totalSentences)
    }

    var progressPercent: Int {
        Int(progress * 100)
    }

    var hasCover: Bool {
        coverFileName != nil
    }

    init(
        id: UUID = UUID(),
        fileName: String,
        title: String = "",
        author: String = "",
        totalSentences: Int = 0,
        lastSentenceIndex: Int = 0,
        coverFileName: String? = nil,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.title = title.isEmpty ? fileName.replacingOccurrences(of: ".epub", with: "") : title
        self.author = author
        self.totalSentences = totalSentences
        self.lastSentenceIndex = lastSentenceIndex
        self.coverFileName = coverFileName
        self.dateAdded = dateAdded
    }
}
