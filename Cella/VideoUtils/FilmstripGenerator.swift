import AVFoundation
import AppKit

enum FilmstripGenerator {

    static func generateThumbnails(
        from url: URL,
        count: Int = 20,
        height: CGFloat = 60
    ) async -> [NSImage] {
        let asset = AVURLAsset(url: url)

        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            return []
        }

        let duration = try? await asset.load(.duration)
        guard let duration = duration else { return [] }
        let totalSeconds = CMTimeGetSeconds(duration)
        guard totalSeconds > 0 else { return [] }

        let width = height * (videoTrack.naturalSize.width / videoTrack.naturalSize.height)

        guard let reader = try? AVAssetReader(asset: asset) else { return [] }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferHeightKey as String: Int(height),
            kCVPixelBufferWidthKey as String: Int(width)
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        reader.add(trackOutput)
        reader.startReading()

        var images: [NSImage] = []
        let frameInterval = totalSeconds / Double(count)
        var nextTime: Double = 0
        var frameIndex = 0

        while reader.status == .reading {
            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else { continue }

            let currentTime = CMTimeGetSeconds(CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer))

            if currentTime >= nextTime && frameIndex < count {
                if let image = sampleBufferToNSImage(sampleBuffer) {
                    images.append(image)
                }
                frameIndex += 1
                nextTime = Double(frameIndex) * frameInterval
            }

            CMSampleBufferInvalidate(sampleBuffer)
        }

        // Pad with last frame if we didn't get enough
        while images.count < count, let last = images.last {
            images.append(last)
        }

        return Array(images.prefix(count))
    }

    private static func sampleBufferToNSImage(_ sampleBuffer: CMSampleBuffer) -> NSImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

        guard let cgImage = context.createCGImage(ciImage, from: rect) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: rect.width, height: rect.height))
    }
}
