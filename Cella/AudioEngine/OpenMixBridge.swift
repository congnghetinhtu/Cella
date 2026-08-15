//
//  OpenMixBridge.swift
//  Cella
//
//  Bridges Cella to OpenMix Python subprocess for mix rendering.
//  Communicates via stdin/stdout JSON + named pipe for audio streaming.
//

import Foundation

/// Status update from OpenMix subprocess.
enum OpenMixStatus {
    case ready(sampleRate: Int, channels: Int)
    case analyzingProgress(current: Int, total: Int, file: String)
    case mixingProgress(current: Int, total: Int, file: String)
    case chunkReady(chunkIndex: Int, bytes: Int, progress: Double)
    case analysisDone(tracks: [[String: Any]])
    case done(duration: Double)
    case error(message: String)
    case cancelled
}

/// Manages the OpenMix Python subprocess.
class OpenMixBridge {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var audioPipePath: String?
    private var audioPipeFd: Int32 = -1
    private let readQueue = DispatchQueue(label: "com.cella.openmix.read")
    private let audioReadQueue = DispatchQueue(label: "com.cella.openmix.audio")
    private var launched = false

    var onStatus: ((OpenMixStatus) -> Void)?
    var onChunkReady: ((Data) -> Void)?
    var isRunning: Bool { process?.isRunning == true }

    // MARK: - Lifecycle

    func start() {
        guard !launched else { return }
        launched = true

        let pipeName = "openmix_audio_\(UUID().uuidString)"
        let pipePath = "/tmp/\(pipeName)"
        mkfifo(pipePath, 0o644)
        audioPipePath = pipePath

        guard let openMixURL = findOpenMixScript() else {
            print("[OpenMixBridge] ERROR: openmix cli.py not found")
            DispatchQueue.main.async { [weak self] in
                self?.onStatus?(.error(message: "OpenMix not found. Enable real-time engine in Config."))
            }
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [openMixURL.path, "--stream", "--audio-pipe", pipePath]

        let sin = Pipe()
        let sout = Pipe()
        let serr = Pipe()
        proc.standardInput = sin
        proc.standardOutput = sout
        proc.standardError = serr

        stdinPipe = sin
        stdoutPipe = sout
        process = proc

        // Read Python stderr into Cella log
        let stderrHandle = serr.fileHandleForReading
        readQueue.async {
            while let data = stderrHandle.availableData as Data?, !data.isEmpty {
                let text = String(data: data, encoding: .utf8) ?? ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    print("[OpenMix stderr] \(trimmed)")
                }
            }
        }

        let currentProcess = proc
        proc.terminationHandler = { [weak self] term in
            guard let self else { return }
            // Only clean up if this is still the current process
            // (prevents old process handler from destroying a new process)
            guard self.process === currentProcess else { return }
            print("[OpenMixBridge] Process terminated (status \(term.terminationStatus))")
            self.cleanup()
        }

        do {
            try proc.run()
            print("[OpenMixBridge] Launched (PID \(proc.processIdentifier))")

            startReadingStdout()
            openAudioPipeThenRead()

        } catch {
            print("[OpenMixBridge] Failed to launch: \(error)")
            cleanup()
            DispatchQueue.main.async { [weak self] in
                self?.onStatus?(.error(message: "Failed to launch OpenMix: \(error.localizedDescription)"))
            }
        }
    }

    func stop() {
        launched = false
        if let proc = process, proc.isRunning {
            sendCommand(["cmd": "cancel"])
            proc.terminate()
            // Wait up to 2s for process to actually die
            proc.waitUntilExit()
        }
        cleanup()
    }

    // MARK: - Commands

    func analyze(tracks: [URL]) {
        sendCommand(["cmd": "analyze", "tracks": tracks.map { $0.path }])
    }

    func mix(order: [Int]) {
        sendCommand(["cmd": "mix", "order": order])
    }

    func cancel() {
        sendCommand(["cmd": "cancel"])
    }

    // MARK: - Pipe Management (all off main thread)

    private func openAudioPipeThenRead() {
        audioReadQueue.async { [weak self] in
            guard let self else { return }

            var attempts = 0
            while attempts < 50 {
                guard let path = self.audioPipePath else { return }
                self.audioPipeFd = open(path, O_RDONLY | O_NONBLOCK)
                if self.audioPipeFd >= 0 { break }
                usleep(100_000)
                attempts += 1
            }

            guard self.audioPipeFd >= 0 else {
                print("[OpenMixBridge] Failed to open audio pipe after \(attempts) attempts")
                return
            }

            self.readAudioChunks()
        }
    }

    private func readAudioChunks() {
        let chunkSize = 1_764_000
        var remainder = Data()
        while audioPipeFd >= 0 {
            // Reassemble partial reads into complete chunks
            let remaining = chunkSize - remainder.count
            var buffer = [UInt8](repeating: 0, count: remaining)
            let bytesRead = read(audioPipeFd, &buffer, remaining)

            if bytesRead > 0 {
                remainder.append(Data(bytes: buffer, count: bytesRead))
                // Emit complete chunks, keep any partial tail
                while remainder.count >= chunkSize {
                    let chunk = remainder.prefix(chunkSize)
                    remainder = remainder.dropFirst(chunkSize)
                    onChunkReady?(Data(chunk))
                }
            } else if bytesRead == 0 {
                // Pipe closed — flush remainder
                if remainder.count > 0 {
                    onChunkReady?(remainder)
                    remainder = Data()
                }
                break
            } else {
                usleep(10_000)
            }
        }
    }

    private func startReadingStdout() {
        guard let stdout = stdoutPipe?.fileHandleForReading else { return }

        readQueue.async { [weak self] in
            while let data = stdout.availableData as Data?,
                  !data.isEmpty {
                let text = String(data: data, encoding: .utf8) ?? ""
                for line in text.components(separatedBy: "\n") {
                    guard !line.isEmpty else { continue }
                    self?.handleStatusLine(line)
                }
            }
        }
    }

    // MARK: - Protocol

    private func sendCommand(_ command: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: command),
              let line = (String(data: data, encoding: .utf8)! + "\n").data(using: .utf8) else {
            return
        }
        stdinPipe?.fileHandleForWriting.write(line)
    }

    private func handleStatusLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            switch type {
            case "ready":
                let sr = json["sample_rate"] as? Int ?? 44100
                let ch = json["channels"] as? Int ?? 2
                self?.onStatus?(.ready(sampleRate: sr, channels: ch))

            case "progress":
                let stage = json["stage"] as? String ?? ""
                let current = json["current"] as? Int ?? 0
                let total = json["total"] as? Int ?? 0
                let file = json["file"] as? String ?? ""
                if stage == "analyzing" {
                    self?.onStatus?(.analyzingProgress(current: current, total: total, file: file))
                } else {
                    self?.onStatus?(.mixingProgress(current: current, total: total, file: file))
                }

            case "chunk_ready":
                let idx = json["chunk_index"] as? Int ?? 0
                let bytes = json["bytes"] as? Int ?? 0
                let progress = json["progress"] as? Double ?? 0
                self?.onStatus?(.chunkReady(chunkIndex: idx, bytes: bytes, progress: progress))

            case "analysis_done":
                let tracks = json["tracks"] as? [[String: Any]] ?? []
                self?.onStatus?(.analysisDone(tracks: tracks))

            case "done":
                let duration = json["duration"] as? Double ?? 0
                self?.onStatus?(.done(duration: duration))

            case "mix_started":
                let totalChunks = json["total_chunks"] as? Int ?? 0
                let duration = json["duration"] as? Double ?? 0
                print("[OpenMixBridge] Mix started: \(totalChunks) chunks, \(duration)s")

            case "error":
                let msg = json["message"] as? String ?? "Unknown error"
                self?.onStatus?(.error(message: msg))

            case "cancelled":
                self?.onStatus?(.cancelled)

            default:
                break
            }
        }
    }

    // MARK: - Cleanup

    private func cleanup() {
        if audioPipeFd >= 0 {
            close(audioPipeFd)
            audioPipeFd = -1
        }
        if let path = audioPipePath {
            unlink(path)
            audioPipePath = nil
        }
        process = nil
        launched = false
    }

    private func findOpenMixScript() -> URL? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/Cella/OpenMix/cli.py"),
            URL(fileURLWithPath: "/usr/local/share/openmix/cli.py"),
            URL(fileURLWithPath: "/opt/openmix/cli.py"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
