//
//  StreamAudioEngine.swift
//  Cella
//
//  AVAudioEngine that plays audio received in chunks from OpenMix.
//  Buffers ahead to prevent gaps.
//

import AVFoundation

class StreamAudioEngine {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat

    private var isPlaying = false
    private var scheduledBuffers: [AVAudioPCMBuffer] = []
    private var bufferLock = NSLock()

    private var totalSamplesReceived: Int = 0
    private var samplesPlayed: Int = 0
    private var playStartTime: Date?

    private let minBufferAhead = 3

    var onNeedMoreAudio: (() -> Void)?

    var currentTime: TimeInterval {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard let start = playStartTime, isPlaying else { return 0 }
        let elapsed = -start.timeIntervalSinceNow
        let sampleRate = format.sampleRate
        return Double(samplesPlayed) / sampleRate + elapsed
    }

    // MARK: - Init

    init(sampleRate: Double = 44100, channels: AVAudioChannelCount = 2) {
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!

        setupEngine()
    }

    private func setupEngine() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[StreamAudioEngine] Failed to start: \(error)")
        }
    }

    // MARK: - Chunk Scheduling

    func scheduleChunk(_ data: Data) {
        let ch = Int(format.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(data.count / (4 * ch))) else {
            return
        }

        let sampleCount = data.count / (MemoryLayout<Float>.size * ch)
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            if let channelData = buffer.floatChannelData {
                let frameCount = Int(buffer.frameLength)

                if ch == 2 {
                    let src = baseAddress.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frameCount {
                        channelData[0][frame] = src[frame * 2]
                        channelData[1][frame] = src[frame * 2 + 1]
                    }
                } else {
                    let src = baseAddress.assumingMemoryBound(to: Float.self)
                    channelData[0].update(from: src, count: frameCount)
                }
            }
        }

        bufferLock.lock()
        scheduledBuffers.append(buffer)
        bufferLock.unlock()

        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            guard let self else { return }
            self.bufferLock.lock()
            self.samplesPlayed += sampleCount
            // Prune completed buffer reference to free memory
            if let idx = self.scheduledBuffers.firstIndex(where: { $0 === buffer }) {
                self.scheduledBuffers.remove(at: idx)
            }
            self.bufferLock.unlock()
        }

        bufferLock.lock()
        totalSamplesReceived += sampleCount
        bufferLock.unlock()

        bufferLock.lock()
        let shouldStart = !isPlaying && scheduledBuffers.count >= minBufferAhead
        bufferLock.unlock()
        if shouldStart {
            startPlayback()
        }
    }

    // MARK: - Playback Controls

    func startPlayback() {
        bufferLock.lock()
        guard !isPlaying else { bufferLock.unlock(); return }
        isPlaying = true
        playStartTime = Date()
        bufferLock.unlock()
        playerNode.play()
        print("[StreamAudioEngine] Playback started")
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
    }

    func resume() {
        guard isPlaying else { return }
        playerNode.play()
        playStartTime = Date()
    }

    func stop() {
        playerNode.stop()
        bufferLock.lock()
        isPlaying = false
        scheduledBuffers.removeAll()
        totalSamplesReceived = 0
        samplesPlayed = 0
        playStartTime = nil
        bufferLock.unlock()
    }

    func flush() {
        bufferLock.lock()
        scheduledBuffers.removeAll()
        bufferLock.unlock()
    }
}
