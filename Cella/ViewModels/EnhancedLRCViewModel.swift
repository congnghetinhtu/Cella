import AVFoundation
import Combine
import AppKit
import SwiftUI

@MainActor
final class EnhancedLRCViewModel: ObservableObject {
    @Published var lines: [EditableLrcLine] = []
    @Published var metadata = LrcMetadata()
    @Published var currentTrackURL: URL?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var hasUnsavedChanges = false
    @Published var trackName: String = ""
    @Published var playbackSpeed: Float = 1.0
    @Published var isRecording = false
    @Published var recordingCursorIndex: Int = 0
    @Published var loadError: String?

    private var audioPlayer: AVPlayer?
    private var timer: Timer?
    private var lrcFileURL: URL?
    private var undoStack: [[EditableLrcLine]] = []
    private var undoMetadataStack: [LrcMetadata] = []
    private var savedLines: [EditableLrcLine] = []
    private var savedMetadata = LrcMetadata()

    var lineCount: Int { lines.count }

    var currentLineIndex: Int {
        guard !lines.isEmpty else { return -1 }
        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            if currentTime >= lines[i].time - 0.1 {
                return i
            }
        }
        return 0
    }

    var canUndo: Bool { !undoStack.isEmpty }

    /// Snapshot last-saved state; clears the undo trail + unsaved flag.
    private func markClean() {
        savedLines = lines
        savedMetadata = metadata
        undoStack = []
        undoMetadataStack = []
        hasUnsavedChanges = false
        vocalistAnchorIndex = nil
    }

    /// Reverts to the last saved state (leave-tab Discard).
    func discardChanges() {
        lines = savedLines
        metadata = savedMetadata
        undoStack = []
        undoMetadataStack = []
        hasUnsavedChanges = false
    }

    private func pushUndo() {
        undoStack.append(lines)
        undoMetadataStack.append(metadata)
        if undoStack.count > 50 {
            undoStack.removeFirst()
            undoMetadataStack.removeFirst()
        }
    }

    func undo() {
        guard let prevLines = undoStack.popLast() else { return }
        lines = prevLines
        if let prevMeta = undoMetadataStack.popLast() {
            metadata = prevMeta
        }
        hasUnsavedChanges = true
    }

    // MARK: - Load

    func loadAudio(from url: URL) async {
        stopPlayback()

        print("[EnhancedLRC] Loading audio from: \(url)")
        print("[EnhancedLRC] Path: \(url.path)")
        print("[EnhancedLRC] Is file: \(url.isFileURL)")

        currentTrackURL = url
        trackName = url.deletingPathExtension().lastPathComponent
        loadError = nil

        // AVPlayer (not AVAudioPlayer): decodes m4a/alac/flac/ogg, keeps rate control.
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        audioPlayer = player
        loadError = nil
        if item.status == .failed, let err = item.error {
            audioPlayer = nil
            loadError = "Can't play this file (\(url.pathExtension.uppercased())): \(err.localizedDescription)"
            print("[EnhancedLRC] Failed to load audio: \(err)")
        } else {
            print("[EnhancedLRC] Audio loaded successfully")
        }

        loadLrcIfExists(at: url)
        markClean()
    }

    private func loadLrcIfExists(at audioURL: URL) {
        let folder = audioURL.deletingLastPathComponent()
        let baseName = audioURL.deletingPathExtension().lastPathComponent

        // CLARC first (the native format now), then .lrc
        let possibleExtensions = ["clarc", "lrc"]

        // Search in: album lrc/ subfolder, then root lrc/, then legacy (same dir as audio)
        let searchDirs = [
            folder.appendingPathComponent("lrc"),
            folder.deletingLastPathComponent().appendingPathComponent("lrc"),
            folder
        ]

        for dir in searchDirs {
            for ext in possibleExtensions {
                let lyrcName = baseName + "." + ext
                let lyrcURL = dir.appendingPathComponent(lyrcName)

                guard FileManager.default.fileExists(atPath: lyrcURL.path),
                      let content = try? String(contentsOf: lyrcURL, encoding: .utf8) else {
                    continue
                }

                print("[Clarc] Found lyric file: \(lyrcURL.path)")
                lrcFileURL = lyrcURL
                if ext == "clarc",
                   let doc = ClarcParser.parse(content) {
                    metadata = doc.metadata.toLrcMetadata
                    lines = doc.lines.map { EditableLrcLine(from: $0) }
                } else {
                    let result = LrcParser.parse(content)
                    metadata = result.metadata
                    lines = result.lines.map { EditableLrcLine(from: $0) }
                }
                return
            }
        }

        print("[Clarc] No lyric file found")
        metadata = LrcMetadata()
        lines = []
    }

    // MARK: - Close

    /// Unloads the current song edit (back to the empty state).
    func closeEditor() {
        stopPlayback()
        audioPlayer = nil
        currentTrackURL = nil
        trackName = ""
        lrcFileURL = nil
        metadata = LrcMetadata()
        lines = []
        loadError = nil
        currentTime = 0
        markClean()
    }

    // MARK: - Playback

    func togglePlayback() {
        guard let player = audioPlayer else { return }

        if isPlaying {
            player.pause()
            stopTimer()
        } else {
            if playbackSpeed == 1.0 {
                player.play()
            } else {
                player.rate = playbackSpeed
            }
            startTimer()
        }
        isPlaying.toggle()
    }

    func seek(to time: TimeInterval) {
        let cm = CMTime(seconds: max(0, time), preferredTimescale: 600)
        audioPlayer?.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }

    func setSpeed(_ speed: Float) {
        playbackSpeed = speed
        if isPlaying {
            audioPlayer?.rate = speed
        }
    }

    func stopPlayback() {
        audioPlayer?.pause()
        audioPlayer?.seek(to: .zero)
        isPlaying = false
        stopTimer()
        currentTime = 0
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateTime()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateTime() {
        guard let player = audioPlayer else {
            if isPlaying {
                isPlaying = false
                stopTimer()
            }
            return
        }
        let t = player.currentTime().seconds
        if t.isFinite { currentTime = t }
        // AVPlayer idles at rate 0 on track end — mirror the old did-finish stop.
        if player.rate == 0, isPlaying {
            isPlaying = false
            stopTimer()
        }
    }

    // MARK: - Line Operations

    func toggleRecording() {
        guard currentTrackURL != nil else { return }
        isRecording.toggle()
        if isRecording {
            // Start filling from the first untimed line.
            recordingCursorIndex = lines.firstIndex { $0.time <= 0 } ?? 0
            // Roll audio so M stamps follow the song.
            if let player = audioPlayer, player.rate == 0, !isPlaying {
                let dur = player.currentItem?.duration.seconds ?? 0
                let pos = player.currentTime().seconds
                if dur > 0, pos.isFinite, pos >= dur - 0.5 {
                    player.seek(to: .zero)
                    currentTime = 0
                }
                if playbackSpeed == 1.0 {
                    player.play()
                } else {
                    player.rate = playbackSpeed
                }
                startTimer()
                isPlaying = true
            }
        }
    }

    /// While recording, stamp the current live position into the next untimed
    /// lyric line, then advance the cursor so the following M fills the next one.
    func recordLine() {
        guard currentTrackURL != nil, isRecording, !lines.isEmpty else { return }
        pushUndo()
        // Read live time straight from the player — timer may lag behind.
        let liveTime = audioPlayer?.currentTime().seconds ?? currentTime
        currentTime = liveTime.isFinite ? liveTime : currentTime
        recordLine(in: &lines, at: &recordingCursorIndex, time: liveTime)
        hasUnsavedChanges = true
    }

    private func recordLine(in lines: inout [EditableLrcLine], at cursor: inout Int, time: TimeInterval) {
        guard cursor >= 0, cursor < lines.count else { return }
        lines[cursor].time = time
        cursor += 1
    }

    /// Evenly spreads untimed ([00:00.00]) lines across the track so a paste
    /// can be preview-played immediately. Timed lines untouched. One undo step.
    func spreadUntimedLines() {
        guard let player = audioPlayer else { return }
        let dur = player.currentItem?.duration.seconds ?? 0
        guard dur.isFinite, dur > 0 else { return }
        let idx = lines.indices.filter { lines[$0].time <= 0 }
        guard !idx.isEmpty else { return }
        pushUndo()
        for (k, i) in idx.enumerated() {
            lines[i].time = dur * Double(k + 1) / Double(idx.count + 1)
        }
        hasUnsavedChanges = true
    }

    /// Preview: spread untimed lines, play from top. Re-stamp with M after.
    func previewFromTop() {
        guard currentTrackURL != nil, !lines.isEmpty else { return }
        spreadUntimedLines()
        seek(to: 0)
        if !isPlaying {
            togglePlayback()
        }
    }

    /// Appends pasted lyric lines. Lines carrying `[mm:ss.xx]` keep their
    /// timestamps; plain lines stamp [00:00.00] for later timing; bare tag
    /// lines (`[ar:…]`) are skipped. One undo step. Time-sorted, ties keep
    /// paste order.
    func appendLines(_ texts: [String]) {
        let fresh = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !fresh.isEmpty else { return }
        var items: [(time: TimeInterval, text: String)] = []
        for raw in fresh {
            let parsed = LrcParser.parse(raw)
            if let first = parsed.lines.first {
                items.append((first.time, first.text))
            } else if parsed.metadata.isEmpty {
                items.append((0, raw))
            }
        }
        guard !items.isEmpty else { return }
        pushUndo()
        lines.append(contentsOf: items.map { EditableLrcLine(time: $0.time, text: $0.text) })
        // Stable time sort: ties keep existing + paste order.
        lines = lines.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map { $0.element }
        hasUnsavedChanges = true
    }

    func addLine(at index: Int? = nil) {
        pushUndo()
        let insertTime: TimeInterval
        if let index = index, index < lines.count {
            insertTime = lines[index].time
        } else {
            insertTime = currentTime
        }

        let newLine = EditableLrcLine(time: insertTime, text: "New line", isEditing: true)

        if let index = index {
            lines.insert(newLine, at: index + 1)
        } else {
            lines.append(newLine)
            lines.sort { $0.time < $1.time }
        }

        hasUnsavedChanges = true
    }

    func removeLine(at index: Int) {
        guard index >= 0, index < lines.count else { return }
        pushUndo()
        lines.remove(at: index)
        hasUnsavedChanges = true
    }

    /// Right-click "Clone Line": duplicate the row right below — same time,
    /// text, singer marks and harmony kind. Handy for alternating repeats
    /// that need the same timestamp on a second vowel/duet part.
    func duplicateLine(at index: Int) {
        guard index >= 0, index < lines.count else { return }
        pushUndo()
        let line = lines[index]
        var copy = EditableLrcLine(time: line.time, text: line.text)
        copy.vocalists = line.vocalists
        copy.isHarmony = line.isHarmony
        copy.duoLead = line.duoLead
        copy.duoTail = line.duoTail
        lines.insert(copy, at: index + 1)
        hasUnsavedChanges = true
    }

    func updateLineText(at index: Int, text: String) {
        guard index >= 0, index < lines.count else { return }
        pushUndo()
        print("[EnhancedLRC] Updating line \(index) from '\(lines[index].text)' to '\(text)'")
        // A literal [DUO] in the edit text sets/clears the CLARC split row.
        lines[index].apply(text: text)
        print("[EnhancedLRC] Line \(index) now: '\(lines[index].text)'")
        hasUnsavedChanges = true
    }

    /// Transfer payload for the bottom-bar `[DUO]` drag handle — dropped
    /// onto a row it routes through `applyDuoMarker(at:)`.
    static let duoDragPayload = "[DUO]"

    /// Drops a dragged `[DUO]` onto a plain lyric line: the words split
    /// about evenly, the first half leading the row and the rest trailing.
    /// Harmony rows, rows already split, and empty text stay as they are.
    /// Undo snapshots the change like every other edit. Double-clicking
    /// the row afterwards opens the raw `lead [DUO] tail` form so the
    /// split point can be nudged by moving the marker (or removed).
    func applyDuoMarker(at index: Int) {
        guard index >= 0, index < lines.count else { return }
        var line = lines[index]
        guard !line.isHarmony, !line.isDuo, !line.text.isEmpty else { return }
        pushUndo()
        let words = line.text
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        let lead: String
        let tail: String
        if words.count <= 1 {
            // A single word can't split — the whole thing leads.
            lead = words.first ?? line.text
            tail = ""
        } else {
            let leadCount = (words.count + 1) / 2
            lead = words[..<leadCount].joined(separator: " ")
            tail = words[leadCount...].joined(separator: " ")
        }
        line.apply(text: lead + " [DUO]" + (tail.isEmpty ? "" : " " + tail))
        lines[index] = line
        hasUnsavedChanges = true
    }

    func updateLineTime(at index: Int, time: TimeInterval) {
        guard index >= 0, index < lines.count else { return }
        pushUndo()
        lines[index].time = time
        hasUnsavedChanges = true
    }

    func setTimestampForLine(at index: Int) {
        guard index >= 0, index < lines.count else { return }
        pushUndo()
        lines[index].time = currentTime
        hasUnsavedChanges = true

        lines.sort { $0.time < $1.time }
    }

    func moveLine(from source: IndexSet, to destination: Int) {
        pushUndo()
        lines.move(fromOffsets: source, toOffset: destination)
        hasUnsavedChanges = true
    }

    // MARK: - Metadata Adjustment

    /// Confirmed edit-panel values replace the header metadata (title /
    /// artists / writer / album / duration). Marks unsaved — writes on the
    /// next Save into the composed .clarc.
    func applyMetadataAdjustment(title: String, artists: [String], writer: String, album: String, duration: String) {
        pushUndo()
        let clean: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
        metadata.title = clean(title)
        metadata.artist = artists
            .map(clean)
            .filter { !$0.isEmpty }
            .joined(separator: " & ")
        metadata.author = clean(writer)
        metadata.album = clean(album)
        metadata.length = clean(duration)
        hasUnsavedChanges = true
    }

    // MARK: - Vocalist Marks (clarc [vN] attribution)

    /// Artist names in v-index order (artist.N). Chips show when 2+.
    var vocalistNames: [String] {
        ArtistMatcher.splitRaw(metadata.artist)
    }

    /// Shift-range anchor: the row of the last chip tap (plain or shift).
    /// Cleared whenever the editor returns to a clean saved state.
    private var vocalistAnchorIndex: Int?

    /// Chip tap on a lyric row:
    /// - plain: set that artist alone; tapped mark removes the artist;
    ///   sets the shift-range anchor on this row
    /// - ⌘: toggle the artist among existing marks → [v1&v2] duets
    ///   (anchor untouched)
    /// - ⇧: paint this artist on every row from the anchor to here, then
    ///   slide the anchor here for the next stretch. Without an anchor it
    ///   marks single.
    func setVocalist(lineIndex: Int, artistNumber: Int, command: Bool, shift: Bool = false) {
        guard lineIndex >= 0, lineIndex < lines.count,
              artistNumber >= 1, artistNumber <= max(vocalistNames.count, 1) else { return }

        if command {
            pushUndo()
            let line = lines[lineIndex]
            if line.vocalists.contains(artistNumber) {
                lines[lineIndex].vocalists = line.vocalists.filter { $0 != artistNumber }
            } else {
                lines[lineIndex].vocalists = (line.vocalists + [artistNumber]).sorted()
            }
            hasUnsavedChanges = true
            return
        }

        if shift, let anchor = vocalistAnchorIndex {
            // Anchor may dangle after deletes/reorder (time-sort on stamp);
            // clamp into range so a stale index paints a sane window.
            let anchor = min(max(anchor, 0), lines.count - 1)
            let start = min(anchor, lineIndex)
            let end = max(anchor, lineIndex)
            pushUndo()
            for i in start...end {
                lines[i].vocalists = [artistNumber]
            }
            vocalistAnchorIndex = lineIndex
            hasUnsavedChanges = true
            return
        }

        pushUndo()
        let line = lines[lineIndex]
        if line.vocalists.contains(artistNumber) {
            lines[lineIndex].vocalists = line.vocalists.filter { $0 != artistNumber }
        } else {
            lines[lineIndex].vocalists = [artistNumber]
        }
        vocalistAnchorIndex = lineIndex
        hasUnsavedChanges = true
    }

    /// Right-click "Convert ↔ Harmony": flips a row between a plain lyric
    /// event and a CLARC harmony event (`[har mm:ss.xx]`). Time, text and
    /// singer marks ride along untouched; Save re-emits the `[har]` prefix.
    func setHarmony(lineIndex: Int, isHarmony: Bool) {
        guard lineIndex >= 0, lineIndex < lines.count else { return }
        pushUndo()
        lines[lineIndex].isHarmony = isHarmony
        hasUnsavedChanges = true
    }

    // MARK: - Save (CLARC)

    /// Saves as CLARC/1 — the editor's single native format. Stale sibling
    /// .lrc/.elrc files in the same folder are retired so the pack keeps
    /// exactly one source of truth.
    func saveLrc() {
        guard let audioURL = currentTrackURL else { return }

        let albumDir = audioURL.deletingLastPathComponent()
        let clarcDir = albumDir.appendingPathComponent("lrc")

        if !FileManager.default.fileExists(atPath: clarcDir.path) {
            try? FileManager.default.createDirectory(at: clarcDir, withIntermediateDirectories: true)
        }

        let base = audioURL.deletingPathExtension().lastPathComponent
        let saveURL = clarcDir.appendingPathComponent(base + ".clarc")
        let content = ClarcParser.compose(
            metadata: ClarcParser.from(lrc: metadata),
            lines: lines.map(\.asLrcLine))

        print("[Clarc] Saving \(lines.count) lines to \(saveURL.path)")
        if let first = lines.first {
            print("[Clarc] First line: [\(first.timestampString)] \(first.text)")
        }

        do {
            try content.write(to: saveURL, atomically: true, encoding: .utf8)
            lrcFileURL = saveURL
            markClean()
            // Retire stale siblings in the save folder.
            for staleExt in ["lrc", "elrc"] {
                let stale = clarcDir.appendingPathComponent(base + "." + staleExt)
                guard FileManager.default.fileExists(atPath: stale.path) else { continue }
                do {
                    try FileManager.default.trashItem(at: stale, resultingItemURL: nil)
                } catch {
                    try? FileManager.default.removeItem(at: stale)
                }
            }
            print("[Clarc] Save OK")
        } catch {
            print("[Clarc] Failed to save: \(error)")
        }
    }


    // MARK: - Export (clarc / lrc, optional break strip)

    /// Single Save panel with a format switch (clarc ↔ lrc) and an option to
    /// strip "..." break lines from the exported copy. The editor file on
    /// disk is untouched — filters apply to the exported output only.
    func exportLyrics() -> URL? {
        guard let audioURL = currentTrackURL else { return nil }

        let panel = NSSavePanel()
        let base = audioURL.deletingPathExtension().lastPathComponent
        panel.directoryURL = audioURL.deletingLastPathComponent()

        var accessory = ClarcExportAccessoryView(base: base)
        accessory.onFormatChange = { [weak panel] isClarc in
            guard let panel else { return }
            panel.allowedContentTypes = [UTType(filenameExtension: isClarc ? "clarc" : "lrc")].compactMap { $0 }
            panel.nameFieldStringValue = base + (isClarc ? ".clarc" : ".lrc")
        }
        accessory.isClarc = true
        panel.accessoryView = accessory
        panel.allowedContentTypes = [UTType(filenameExtension: "clarc")].compactMap { $0 }
        panel.nameFieldStringValue = base + ".clarc"
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }

        // Force the extension to match the picked format.
        let ext = accessory.isClarc ? "clarc" : "lrc"
        let saveURL = chosen.pathExtension.lowercased() == ext
            ? chosen
            : chosen.deletingPathExtension().appendingPathExtension(ext)

        // Strict dot-run filter: "..." / "…" / "...." only. Real text like
        // "(Instrumental)" and untouched addLy stubs never count.
        var lines = lines
        if accessory.removeBreaks {
            lines = lines.filter { line in
                let t = line.text.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { return true }
                return !t.allSatisfy { $0 == "." || $0 == "…" }
            }
        }

        let content = accessory.isClarc
            ? ClarcParser.compose(
                metadata: ClarcParser.from(lrc: metadata),
                lines: lines.map(\.asLrcLine))
            : exportLrcText(metadata: metadata, lines: lines)

        do {
            try content.write(to: saveURL, atomically: true, encoding: .utf8)
            return saveURL
        } catch {
            print("[Clarc] Failed to export: \(error)")
            return nil
        }
    }

    /// Classic LRC writer for the .lrc export branch ([ti:]/[ar:] tags +
    /// `[mm:ss.xx]text` lines).
    private func exportLrcText(metadata: LrcMetadata, lines: [EditableLrcLine]) -> String {
        var content = ""
        if !metadata.isEmpty {
            content = metadata.toLrcString() + "\n"
        }
        content += lines.map { line in
            let minutes = Int(line.time) / 60
            let seconds = Int(line.time) % 60
            let fraction = Int((line.time - Double(Int(line.time))) * 100)
            return String(format: "[%02d:%02d.%02d]%@", minutes, seconds, fraction, line.text)
        }.joined(separator: "\n")
        return content
    }

    // MARK: - LRC → CLARC Conversion (drop flow)

    struct PendingClarcConversion: Identifiable {
        let id = UUID()
        let sourceURL: URL
        var title: String
        var artists: [String]
        var writer: String
        var album: String
        var duration: String
        var lines: [EditableLrcLine]
        /// True when the source LRC carried header tags at all.
        var hadMeta: Bool
    }

    /// Live conversion awaiting user confirmation in the sheet.
    @Published var pendingConversion: PendingClarcConversion?
    /// Additional dropped .lrc files waiting behind the open sheet.
    private var conversionQueue: [URL] = []

    /// Clarc-tab lyric drops: .clarc opens for editing, .lrc enters
    /// the convert flow (confirm sheet → .clarc sibling → original trashed).
    func handleConverterDrop(_ urls: [URL]) {
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            switch url.pathExtension.lowercased() {
            case "clarc":
                adoptClarc(at: url, ifAudioMatches: false)
            case "lrc":
                beginClarcConversion(from: url)
            default:
                break
            }
        }
    }

    /// Entry: parse the source and stage the confirm sheet with the info
    /// extracted from LRC header tags (title / artists / writer / album /
    /// duration). Nothing is written until the user confirms.
    func beginClarcConversion(from url: URL) {
        guard pendingConversion == nil else {
            conversionQueue.append(url)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let result = LrcParser.load(from: url)
        guard !result.metadata.isEmpty || !result.lines.isEmpty else {
            showTransientError("No lyrics inside \(url.lastPathComponent)")
            return
        }

        let rawArtist = result.metadata.artist.trimmingCharacters(in: .whitespaces)
        let split = ArtistMatcher.splitRaw(rawArtist)
        let pending = PendingClarcConversion(
            sourceURL: url,
            title: result.metadata.title,
            artists: split.isEmpty && !rawArtist.isEmpty ? [rawArtist] : split,
            writer: result.metadata.author,
            album: result.metadata.album,
            duration: normalizeDurationTag(result.metadata.length),
            lines: result.lines.map { EditableLrcLine(from: $0) },
            hadMeta: !result.metadata.isEmpty)
        pendingConversion = pending

        // No length tag (or a fake zero) → prefill from sibling audio.
        if pending.duration.isEmpty {
            Task { await self.lookupAudioDuration(for: pending) }
        }
    }

    /// Undoable cancel: dismisses the sheet and abandons the whole batch.
    func cancelClarcConversion() {
        pendingConversion = nil
        conversionQueue.removeAll()
    }

    /// Confirmed: write `<base>.clarc` next to the source, trash the source,
    /// then keep editing in the new .clarc when it belongs to this song.
    func confirmClarcConversion(title: String, artists: [String], writer: String, album: String, duration: String) {
        guard let pending = pendingConversion else { return }
        pendingConversion = nil
        Task {
            await performClarcConversion(
                pending,
                title: title,
                artists: artists.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                writer: writer,
                album: album,
                duration: duration)
            // Next queued file presents after this conversion settles.
            if self.pendingConversion == nil, let next = self.conversionQueue.first {
                self.conversionQueue.removeFirst()
                self.beginClarcConversion(from: next)
            }
        }
    }

    private func performClarcConversion(
        _ pending: PendingClarcConversion,
        title: String,
        artists: [String],
        writer: String,
        album: String,
        duration: String
    ) async {
        var meta = ClarcMetadata()
        meta.title = title.trimmingCharacters(in: .whitespaces)
        meta.artists = artists
        meta.writer = writer.trimmingCharacters(in: .whitespaces)
        meta.album = album.trimmingCharacters(in: .whitespaces)
        meta.duration = duration.trimmingCharacters(in: .whitespaces)

        let content = ClarcParser.compose(
            metadata: meta,
            lines: pending.lines.map(\.asLrcLine))
        let destURL = pending.sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(pending.sourceURL.deletingPathExtension().lastPathComponent + ".clarc")

        do {
            try content.write(to: destURL, atomically: true, encoding: .utf8)
        } catch {
            showTransientError("Couldn't write .clarc: \(error.localizedDescription)")
            return
        }

        // The conversion replaces the original lyric file.
        do {
            try FileManager.default.trashItem(at: pending.sourceURL, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: pending.sourceURL)
        }
        print("[Clarc] Converted \(pending.sourceURL.lastPathComponent) → \(destURL.lastPathComponent)")

        adoptClarc(at: destURL, ifAudioMatches: true)
    }

    /// Loads a .clarc file into the editor (no exchange with audio needed).
    func adoptClarcFile(_ url: URL) {
        adoptClarc(at: url, ifAudioMatches: false)
    }

    private func adoptClarc(at url: URL, ifAudioMatches: Bool) {
        if ifAudioMatches, let audio = currentTrackURL {
            guard audio.deletingPathExtension().lastPathComponent
                == url.deletingPathExtension().lastPathComponent else { return }
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let doc = ClarcParser.parse(content) else {
            showTransientError("Not a valid CLARC file: \(url.lastPathComponent)")
            return
        }
        if currentTrackURL == nil {
            trackName = url.deletingPathExtension().lastPathComponent
        }
        lrcFileURL = url
        metadata = doc.metadata.toLrcMetadata
        lines = doc.lines.map { EditableLrcLine(from: $0) }
        markClean()
    }

    /// Sibling-audio duration lookup: `<lrc dir>` itself, then the parent
    /// (pack layout keeps audio beside the lrc/ folder).
    private func lookupAudioDuration(for pending: PendingClarcConversion) async {
        let base = pending.sourceURL.deletingPathExtension().lastPathComponent
        let lrcDir = pending.sourceURL.deletingLastPathComponent()
        let audioExts = ["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif", "aiff"]
        var audioURL: URL?
        for dir in [lrcDir, lrcDir.deletingLastPathComponent()] {
            guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            if let match = contents.first(where: {
                $0.deletingPathExtension().lastPathComponent == base
                    && audioExts.contains($0.pathExtension.lowercased())
            }) {
                audioURL = match
                break
            }
        }
        guard let audioURL else { return }
        let duration = try? await AVURLAsset(url: audioURL).load(.duration).seconds
        guard var p = pendingConversion, p.id == pending.id,
              let d = duration, d.isFinite, d > 0, p.duration.isEmpty else { return }
        p.duration = String(format: "%02d:%02d", Int(d) / 60, Int(d) % 60)
        pendingConversion = p
    }

    private func normalizeDurationTag(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.allSatisfy({ $0 == "0" || $0 == ":" }) else { return "" }
        return trimmed
    }

    private func showTransientError(_ message: String) {
        loadError = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self?.loadError == message { self?.loadError = nil }
        }
    }
}

// MARK: - Export Accessory (format switch + break strip)

/// Save-panel accessory for Export: CLARC/LRC popup plus a checkbox that
/// strips "..." break lines from the exported copy. Plain AppKit —
/// NSSavePanel wants a real NSView.
final class ClarcExportAccessoryView: NSView {
    var onFormatChange: ((Bool) -> Void)?

    var isClarc: Bool {
        get { formatPopup.indexOfSelectedItem == 0 }
        set { formatPopup.selectItem(at: newValue ? 0 : 1) }
    }
    var removeBreaks: Bool { removeBreaksCheck.state == .on }

    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let removeBreaksCheck = NSButton(title: "Remove \"...\" break lines", target: nil, action: nil)

    init(base: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 78))
        setUp()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 300, height: 78)
    }

    private func setUp() {
        formatPopup.addItems(withTitles: ["CLARC (.clarc)", "LRC (.lrc)"])
        formatPopup.selectItem(at: 0)
        formatPopup.font = NSFont.systemFont(ofSize: 12)
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)

        removeBreaksCheck.setButtonType(.switch)
        removeBreaksCheck.font = NSFont.systemFont(ofSize: 12)
        removeBreaksCheck.state = .off

        let formatLabel = NSTextField(labelWithString: "FORMAT")
        formatLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        formatLabel.textColor = .secondaryLabelColor

        let formatRow = NSStackView(views: [formatLabel, formatPopup])
        formatRow.orientation = .horizontal
        formatRow.spacing = 10

        let column = NSStackView(views: [formatRow, removeBreaksCheck])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8

        addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @objc private func formatChanged() {
        onFormatChange?(isClarc)
    }
}
