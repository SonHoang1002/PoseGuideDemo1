//
//  VideoFrameExtractor.swift
//  PhotoshotGuideV1Demo
//

import AVFoundation
import UIKit

nonisolated struct RawVideoFrame {
    let image: UIImage
    let time: Double
}

nonisolated enum VideoFrameExtractor {

    /// Trích xuất các khung hình cách đều nhau `interval` giây, kèm timestamp gốc trong video.
    static func extractFrames(url: URL,
                              interval: Double,
                              maxDimension: CGFloat = 1280,
                              progress: (@Sendable (Double) -> Void)? = nil) async -> [RawVideoFrame] {
        let step = min(max(interval, 0.05), 3.0)
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return [] }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: min(step / 3.0, 0.15), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var times: [NSValue] = []
        var t = 0.0
        while t < seconds {
            times.append(NSValue(time: CMTime(seconds: t, preferredTimescale: 600)))
            t += step
        }
        guard !times.isEmpty else { return [] }

        let total = times.count
        return await withCheckedContinuation { continuation in
            var frames: [RawVideoFrame] = []
            var completed = 0
            generator.generateCGImagesAsynchronously(forTimes: times) { requested, cgImage, actualTime, _, _ in
                if let cgImage {
                    let scaled = Self.downscale(cgImage, maxDimension: maxDimension)
                    let image = UIImage(cgImage: scaled ?? cgImage)
                    let time = actualTime.isValid ? CMTimeGetSeconds(actualTime)
                                                  : CMTimeGetSeconds(requested)
                    frames.append(RawVideoFrame(image: image, time: time))
                }
                completed += 1
                if let progress {
                    let frac = Double(completed) / Double(total)
                    progress(frac)
                }
                if completed == total {
                    continuation.resume(returning: frames)
                }
            }
        }
    }

    private static func downscale(_ cgImage: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let scale = min(1, maxDimension / max(w, h))
        guard scale < 1 else { return nil }
        let nw = max(4, Int(w * scale)), nh = max(4, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8,
                                  bytesPerRow: nw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }
}
