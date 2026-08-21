//
//  BoomerangMaker.swift
//  Cella
//
//  Instagram boomerang: forward at 1.25x, then backward at 1.25x.
//

import AVFoundation

enum BoomerangMaker {

    private static let timescale: CMTimeScale = 60000

    static func createBoomerang(
        from sourceURL: URL,
        outputURL: URL,
        trimStart: Double = 0,
        trimEnd: Double? = nil,
        loopCount: Int = 3,
        progress: @escaping (Double) -> Void = { _ in },
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let asset = AVURLAsset(url: sourceURL)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_trimmed.mp4")

        Task {
            do {
                let duration = try await asset.load(.duration)
                let sourceDuration = CMTimeGetSeconds(duration)
                let end = trimEnd ?? sourceDuration
                let trimDuration = end - trimStart
                guard trimDuration > 0.1 else { throw BoomerangError.trimTooShort }

                progress(0.05)

                // Step 1: Trim with high-precision timescale
                try await trimAsset(asset, from: trimStart, to: end, output: tmpURL)
                progress(0.3)

                // Step 2: Read frames from actual trimmed file (use real duration)
                let trimmedAsset = AVURLAsset(url: tmpURL)
                let trimmedDuration = try await trimmedAsset.load(.duration)
                let tracks = try await trimmedAsset.loadTracks(withMediaType: .video)
                guard let videoTrack = tracks.first else { throw BoomerangError.noVideoTrack }

                let reader = try AVAssetReader(asset: trimmedAsset)
                reader.timeRange = CMTimeRange(start: .zero, duration: trimmedDuration)
                let outputSettings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
                reader.add(trackOutput)
                reader.startReading()

                var samples: [CMSampleBuffer] = []
                while let s = trackOutput.copyNextSampleBuffer() {
                    samples.append(s)
                }
                guard samples.count >= 2 else { throw BoomerangError.noFrames }

                progress(0.5)

                // Step 3: Write
                let firstBuf = CMSampleBufferGetImageBuffer(samples[0])!
                let pw = CVPixelBufferGetWidth(firstBuf)
                let ph = CVPixelBufferGetHeight(firstBuf)

                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try FileManager.default.removeItem(at: outputURL)
                }

                let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
                let settings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: pw,
                    AVVideoHeightKey: ph
                ]
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ]
                )
                writer.add(input)
                writer.startWriting()

                let sessionStart = CMTime(value: 0, timescale: 30)
                writer.startSession(atSourceTime: sessionStart)

                // 1.0x: use all frames, repeat loopCount times (forward+backward each)
                let fwdFrames = samples
                var allFrames: [CMSampleBuffer] = []
                for _ in 0..<loopCount {
                    allFrames.append(contentsOf: fwdFrames)
                    allFrames.append(contentsOf: fwdFrames.reversed())
                }
                let total = allFrames.count
                var idx = 0

                func waitAndAppend(_ sample: CMSampleBuffer) {
                    while !input.isReadyForMoreMediaData {
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                    guard writer.status == .writing else { return }
                    guard let buf = CMSampleBufferGetImageBuffer(sample) else { return }
                    adaptor.append(buf, withPresentationTime: CMTime(value: Int64(idx), timescale: 30))
                    idx += 1
                }

                // Forward + Backward (looped)
                for sample in allFrames {
                    waitAndAppend(sample)
                    progress(0.5 + Double(idx) / Double(total) * 0.5)
                }

                input.markAsFinished()
                await writer.finishWriting()

                try? FileManager.default.removeItem(at: tmpURL)
                progress(1.0)

                if writer.status == .completed {
                    completion(.success(outputURL))
                } else {
                    completion(.failure(writer.error ?? BoomerangError.exportFailed))
                }
            } catch {
                try? FileManager.default.removeItem(at: tmpURL)
                completion(.failure(error))
            }
        }
    }

    private static func trimAsset(_ asset: AVURLAsset, from start: Double, to end: Double, output: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw BoomerangError.exportFailed
        }
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: timescale),
            duration: CMTime(seconds: end - start, preferredTimescale: timescale)
        )
        session.outputURL = output
        session.outputFileType = .mp4
        await session.export()
        guard session.status == .completed else { throw session.error ?? BoomerangError.exportFailed }
    }
}

enum BoomerangError: LocalizedError {
    case noVideoTrack
    case noFrames
    case trimTooShort
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "No video track found."
        case .noFrames: return "Could not read frames."
        case .trimTooShort: return "Selection too short."
        case .exportFailed: return "Export failed."
        }
    }
}
