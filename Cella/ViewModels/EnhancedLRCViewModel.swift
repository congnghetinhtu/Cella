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

    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var lrcFileURL: URL?
    private var undoStack: [[EditableLrcLine]] = []
    private var undoMetadataStack: [LrcMetadata] = []

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
        autoSave()
    }

    // MARK: - Load

    func loadAudio(from url: URL) async {
        stopPlayback()

        print("[EnhancedLRC] Loading audio from: \(url)")
        print("[EnhancedLRC] Path: \(url.path)")
        print("[EnhancedLRC] Is file: \(url.isFileURL)")

        currentTrackURL = url
        trackName = url.deletingPathExtension().lastPathComponent

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.enableRate = true
            audioPlayer?.rate = playbackSpeed
            audioPlayer?.prepareToPlay()
            print("[EnhancedLRC] Audio loaded successfully, duration: \(audioPlayer?.duration ?? 0)")
        } catch {
            print("[EnhancedLRC] Failed to load audio: \(error)")
        }

        loadLrcIfExists(at: url)
    }

    private func loadLrcIfExists(at audioURL: URL) {
        let folder = audioURL.deletingLastPathComponent()
        let baseName = audioURL.deletingPathExtension().lastPathComponent

        // Try .lrc first, then .elrc
        let possibleExtensions = ["lrc", "elrc"]

        // Search in: album lrc/ subfolder, then root lrc/, then legacy (same dir as audio)
        let searchDirs = [
            folder.appendingPathComponent("lrc"),
            folder.deletingLastPathComponent().appendingPathComponent("lrc"),
            folder
        ]

        for dir in searchDirs {
            for ext in possibleExtensions {
                let lrcName = baseName + "." + ext
                let lrcURL = dir.appendingPathComponent(lrcName)

                guard FileManager.default.fileExists(atPath: lrcURL.path),
                      let content = try? String(contentsOf: lrcURL, encoding: .utf8) else {
                    continue
                }

                print("[EnhancedLRC] Found LRC: \(lrcURL.path)")
                lrcFileURL = lrcURL
                let result = LrcParser.parse(content)
                metadata = result.metadata
                lines = result.lines.map { EditableLrcLine(from: $0) }
                return
            }
        }

        print("[EnhancedLRC] No LRC file found")
        metadata = LrcMetadata()
        lines = []
    }

    // MARK: - Playback

    func togglePlayback() {
        guard let player = audioPlayer else { return }

        if isPlaying {
            player.pause()
            stopTimer()
        } else {
            player.play()
            startTimer()
        }
        isPlaying.toggle()
    }

    func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        currentTime = time
    }

    func setSpeed(_ speed: Float) {
        playbackSpeed = speed
        audioPlayer?.rate = speed
    }

    func stopPlayback() {
        audioPlayer?.stop()
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
        guard let player = audioPlayer, player.isPlaying else {
            if isPlaying {
                isPlaying = false
                stopTimer()
            }
            return
        }
        currentTime = player.currentTime
    }

    // MARK: - Line Operations

    func toggleRecording() {
        isRecording.toggle()
        if isRecording {
            // Start filling from the first untimed line.
            recordingCursorIndex = lines.firstIndex { $0.time <= 0 } ?? 0
        }
    }

    /// While recording, stamp the current live position into the next untimed
    /// lyric line, then advance the cursor so the following M fills the next one.
    func recordLine() {
        guard currentTrackURL != nil, isRecording, !lines.isEmpty else { return }
        pushUndo()
        // Read live time straight from the player — timer may lag behind.
        let liveTime = audioPlayer?.currentTime ?? currentTime
        currentTime = liveTime
        recordLine(in: &lines, at: &recordingCursorIndex, time: liveTime)
        hasUnsavedChanges = true
        autoSave()
    }

    private func recordLine(in lines: inout [EditableLrcLine], at cursor: inout Int, time: TimeInterval) {
        guard cursor >= 0, cursor < lines.count else { return }
        lines[cursor].time = time
        cursor += 1
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
        autoSave()
    }

    func removeLine(at index: Int) {
        guard index >= 0, index < lines.count else { return }
        pushUndo()
        lines.remove(at: index)
        hasUnsavedChanges = true
        autoSave()
    }

    func updateLineText(at index: Int, text: String) {
        guard index >= 0, index < lines.count else { return }
        pushUndo()
        print("[EnhancedLRC] Updating line \(index) from '\(lines[index].text)' to '\(text)'")
        lines[index].text = text
        print("[EnhancedLRC] Line \(index) now: '\(lines[index].text)'")
        hasUnsavedChanges = true
        autoSave()
    }

    func updateLineTime(at index: Int, time: TimeInterval) {
        guard index >= 0, index < lines.count else { return }
        pushUndo()
        lines[index].time = time
        hasUnsavedChanges = true
        autoSave()
    }

    func setTimestampForLine(at index: Int) {
        guard index >= 0, index < lines.count else { return }
        pushUndo()
        lines[index].time = currentTime
        hasUnsavedChanges = true

        lines.sort { $0.time < $1.time }
        autoSave()
    }

    func moveLine(from source: IndexSet, to destination: Int) {
        pushUndo()
        lines.move(fromOffsets: source, toOffset: destination)
        hasUnsavedChanges = true
        autoSave()
    }

    // MARK: - Save

    func saveLrc() {
        guard let audioURL = currentTrackURL else { return }

        let albumDir = audioURL.deletingLastPathComponent()
        let lrcDir = albumDir.appendingPathComponent("lrc")

        // Create album lrc/ folder if needed
        if !FileManager.default.fileExists(atPath: lrcDir.path) {
            try? FileManager.default.createDirectory(at: lrcDir, withIntermediateDirectories: true)
        }

        let lrcName = audioURL.deletingPathExtension().lastPathComponent + ".lrc"
        let saveURL = lrcDir.appendingPathComponent(lrcName)

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

        print("[EnhancedLRC] Saving \(lines.count) lines to \(saveURL.path)")
        if let first = lines.first {
            print("[EnhancedLRC] First line: [\(first.timestampString)] \(first.text)")
        }

        do {
            try content.write(to: saveURL, atomically: true, encoding: .utf8)
            lrcFileURL = saveURL
            hasUnsavedChanges = false
            print("[EnhancedLRC] Save OK")
        } catch {
            print("[EnhancedLRC] Failed to save LRC: \(error)")
        }
    }

    private func autoSave() {
        saveLrc()
    }

    // MARK: - Export

    func exportLrc() -> URL? {
        guard let audioURL = currentTrackURL else { return nil }

        let panel = NSSavePanel()
        if let lrcType = UTType(filenameExtension: "lrc") {
            panel.allowedContentTypes = [lrcType]
        }
        panel.nameFieldStringValue = audioURL.deletingPathExtension().lastPathComponent + ".lrc"
        panel.directoryURL = audioURL.deletingLastPathComponent()

        guard panel.runModal() == .OK, let saveURL = panel.url else { return nil }

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

        do {
            try content.write(to: saveURL, atomically: true, encoding: .utf8)
            return saveURL
        } catch {
            print("[EnhancedLRC] Failed to export LRC: \(error)")
            return nil
        }
    }
}
