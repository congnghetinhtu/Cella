//
//  BookStorage.swift
//  Cella
//
//  File management for ~/Library/Application Support/CellaBooks/
//

import Foundation

enum BookStorage {
    private static let libraryDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("CellaBooks", isDirectory: true)
    }()

    private static let libraryJSON = libraryDir.appendingPathComponent("library.json")

    static func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
    }

    static func copyToLibrary(from sourceURL: URL) throws -> URL {
        ensureDirectoryExists()
        let dest = libraryDir.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        return dest
    }

    static func bookURL(for fileName: String) -> URL {
        libraryDir.appendingPathComponent(fileName)
    }

    static func loadLibrary() -> [BookAsset] {
        guard FileManager.default.fileExists(atPath: libraryJSON.path),
              let data = try? Data(contentsOf: libraryJSON),
              let books = try? JSONDecoder().decode([BookAsset].self, from: data) else {
            return []
        }
        return books
    }

    static func saveLibrary(_ books: [BookAsset]) {
        ensureDirectoryExists()
        guard let data = try? JSONEncoder().encode(books) else {
            print("[BookStorage] Failed to encode library")
            return
        }
        do {
            try data.write(to: libraryJSON, options: .atomic)
        } catch {
            print("[BookStorage] Failed to save library: \(error)")
        }
    }
}
