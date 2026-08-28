import AVFoundation
import AppKit

enum FilmstripGenerator {

    /// Generate thumbnails by seeking directly to target timestamps.
    /// Uses AVAssetImageGenerator (random access) — far faster than sequential
    /// full-video decode. Only decodes the frames we actually show.
    static func generateThumbnails(
        from url: URL,
        count: Int = 20,
        height: CGFloat = 60,
        start: Double = 0,
        end: Double? = nil
    ) async -> [NSImage] {
        let asset = AVURLAsset(url: url)

        let duration = try? await asset.load(.duration)
        guard let duration = duration else { return [] }
        let totalSeconds = CMTimeGetSeconds(duration)
        guard totalSeconds > 0 else { return [] }

        let windowStart = max(0, start)
        let windowEnd = min(totalSeconds, end ?? totalSeconds)
        let windowDuration = max(0.05, windowEnd - windowStart)

        // Compute target times evenly across the window
        var times: [CMTime] = []
        times.reserveCapacity(count)
        for i in 0..<count {
            let t = windowStart + Double(i) * (windowDuration / Double(count))
            times.append(CMTime(seconds: t, preferredTimescale: 60000))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(
            width: height * 16 / 9 * UIScale,
            height: height * UIScale
        )

        return await withCheckedContinuation { continuation in
            var images: [NSImage?] = Array(repeating: nil, count: times.count)
            var pending = times.count
            let lock = NSLock()

            for (idx, time) in times.enumerated() {
                generator.generateCGImageAsynchronously(for: time) { cgImage, _, _ in
                    var result: NSImage? = nil
                    if let cgImage = cgImage {
                        result = NSImage(
                            cgImage: cgImage,
                            size: CGSize(width: cgImage.width, height: cgImage.height)
                        )
                    }
                    lock.lock()
                    images[idx] = result
                    pending -= 1
                    lock.unlock()
                    if pending == 0 {
                        let flat = images.compactMap { $0 }
                        continuation.resume(returning: flat)
                    }
                }
            }
        }
    }

    /// Retina-aware scale factor.
    private static var UIScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2.0
    }
}
