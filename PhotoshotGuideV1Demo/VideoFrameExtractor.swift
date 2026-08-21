import AVFoundation
import UIKit

enum VideoFrameExtractor {

    /// Extracts frames from a recorded clip at a fixed interval for post-hoc pose matching.
    static func extractFrames(url: URL, interval: Double = 0.5) async -> [UIImage] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return [] }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var times: [NSValue] = []
        var t = 0.0
        while t < seconds {
            times.append(NSValue(time: CMTime(seconds: t, preferredTimescale: 600)))
            t += interval
        }
        guard !times.isEmpty else { return [] }

        return await withCheckedContinuation { continuation in
            var images: [UIImage] = []
            var remaining = times.count
            generator.generateCGImagesAsynchronously(forTimes: times) { _, cgImage, _, _, _ in
                if let cgImage { images.append(UIImage(cgImage: cgImage)) }
                remaining -= 1
                if remaining == 0 { continuation.resume(returning: images) }
            }
        }
    }
}
