import Vision
import UIKit

struct BodyPose: Equatable {
    var points: [VNHumanBodyPoseObservation.JointName: CGPoint] // normalized 0-1, origin bottom-left
}

enum PoseAnalyzer {

    /// Detect pose from a live camera frame.
    static func detectPose(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> BodyPose? {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        try? handler.perform([request])
        return extractPose(from: request.results?.first)
    }

    /// Detect pose from a static reference image (called once when entering the camera screen).
    static func detectPose(image: UIImage) -> BodyPose? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNDetectHumanBodyPoseRequest()
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try? handler.perform([request])
        return extractPose(from: request.results?.first)
    }

    private static func extractPose(from observation: VNHumanBodyPoseObservation?) -> BodyPose? {
        guard let observation, let recognized = try? observation.recognizedPoints(.all) else { return nil }
        var points: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
        for (name, point) in recognized where point.confidence > 0.3 {
            points[name] = point.location
        }
        return points.isEmpty ? nil : BodyPose(points: points)
    }
}

private extension CGImagePropertyOrientation {
    init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
