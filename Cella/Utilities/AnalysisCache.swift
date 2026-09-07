//
//  AnalysisCache.swift
//  Cella
//
//  Loads and saves TrackAnalysis to .cellax files in Cache/ subfolder per album.
//  Cache is invalidated when the audio file is newer than the cache.
//

import Foundation

enum AnalysisCache {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Returns the .cellax URL for a given audio file URL.
    /// Cache files live in a `Cache/` subfolder next to the audio file.
    static func cacheURL(for audioURL: URL) -> URL {
        let albumDir = audioURL.deletingLastPathComponent()
        let baseName = audioURL.deletingPathExtension().lastPathComponent
        return albumDir.appendingPathComponent("Cache")
            .appendingPathComponent(baseName)
            .appendingPathExtension("cellax")
    }

    /// Loads cached analysis from disk. Returns nil if cache missing or stale.
    static func load(for audioURL: URL) -> TrackAnalysis? {
        let cacheURL = cacheURL(for: audioURL)
        let fm = FileManager.default

        guard fm.fileExists(atPath: cacheURL.path) else {
            print("[AnalysisCache] MISS \(audioURL.lastPathComponent) — no cache at \(cacheURL.path)")
            return nil
        }

        // Invalidate if audio file is newer than cache
        guard let audioMod = try? fm.attributesOfItem(atPath: audioURL.path)[.modificationDate] as? Date,
              let cacheMod = try? fm.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date,
              audioMod <= cacheMod else {
            print("[AnalysisCache] STALE \(audioURL.lastPathComponent) — audio newer than cache")
            return nil
        }

        guard let data = try? Data(contentsOf: cacheURL) else {
            print("[AnalysisCache] READ_FAIL \(audioURL.lastPathComponent)")
            return nil
        }
        guard let analysis = try? decoder.decode(TrackAnalysis.self, from: data) else {
            print("[AnalysisCache] DECODE_FAIL \(audioURL.lastPathComponent) — old format?")
            return nil
        }

        print("[AnalysisCache] HIT \(audioURL.lastPathComponent)")
        return analysis
    }

    /// Saves analysis to disk as .cellax JSON file in Cache/ subfolder.
    static func save(_ analysis: TrackAnalysis, for audioURL: URL) {
        let cacheURL = cacheURL(for: audioURL)
        let fm = FileManager.default

        // Create Cache/ directory if needed
        let cacheDir = cacheURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: cacheDir.path) {
            try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }

        guard let data = try? encoder.encode(analysis) else {
            print("[AnalysisCache] Failed to encode cache for \(audioURL.lastPathComponent)")
            return
        }

        do {
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            print("[AnalysisCache] Failed to write cache: \(error.localizedDescription)")
        }
    }

    /// Counts how many audio files in a folder have .cellax caches in Cache/ subfolder.
    static func counts(in folderURL: URL) -> (cached: Int, total: Int) {
        let fm = FileManager.default
        let audioExtensions = Set(["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"])

        let contents = (try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil
        )) ?? []

        let audioFiles = contents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        let cached = audioFiles.filter { fm.fileExists(atPath: cacheURL(for: $0).path) }

        return (cached.count, audioFiles.count)
    }

    /// Recursively counts cached/total tracks across all album subfolders in a .cella pack.
    static func countsInPack(_ packURL: URL) -> (cached: Int, total: Int) {
        let fm = FileManager.default
        let audioExtensions = Set(["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"])
        let contents = (try? fm.contentsOfDirectory(
            at: packURL,
            includingPropertiesForKeys: nil
        )) ?? []

        var totalCached = 0
        var totalTracks = 0

        // Root-level audio
        let rootAudio = contents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        totalTracks += rootAudio.count
        totalCached += rootAudio.filter { fm.fileExists(atPath: cacheURL(for: $0).path) }.count

        // Album subfolders
        let subfolders = contents.filter { $0.hasDirectoryPath && $0.pathExtension.lowercased() != "cluster" }
        for subfolder in subfolders {
            let subContents = (try? fm.contentsOfDirectory(
                at: subfolder,
                includingPropertiesForKeys: nil
            )) ?? []
            let subAudio = subContents.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            totalTracks += subAudio.count
            totalCached += subAudio.filter { fm.fileExists(atPath: cacheURL(for: $0).path) }.count
        }

        return (totalCached, totalTracks)
    }
}
