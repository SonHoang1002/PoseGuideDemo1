import SwiftUI
import Vision

struct SkeletonOverlayView: View {
    /// Vision-native points (origin bottom-left, normalized 0-1) — the same dictionary
    /// Measurer already builds for the guidance pipeline, reused here for drawing.
    let jointPoints: [VNHumanBodyPoseObservation.JointName: JointPoint]?

    // Full skeleton: torso/limbs + face so every detected point has at least one line to it.
    private let connections: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
        (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip), (.leftHip, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        (.neck, .nose), (.nose, .leftEye), (.nose, .rightEye),
        (.leftEye, .leftEar), (.rightEye, .rightEar),
        (.neck, .root)
    ]

    var body: some View {
        GeometryReader { geo in
            if let jointPoints, !jointPoints.isEmpty {
                ZStack {
                    ForEach(0..<connections.count, id: \.self) { i in
                        let (a, b) = connections[i]
                        if let pa = jointPoints[a], let pb = jointPoints[b] {
                            Path { path in
                                path.move(to: convert(pa.location, geo.size))
                                path.addLine(to: convert(pb.location, geo.size))
                            }
                            .stroke(Color.green.opacity(lineOpacity(pa, pb)), lineWidth: 3)
                        }
                    }
                    ForEach(Array(jointPoints.keys), id: \.self) { key in
                        if let joint = jointPoints[key] {
                            Circle()
                                .fill(Color.yellow.opacity(dotOpacity(joint)))
                                .frame(width: 9, height: 9)
                                .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 0.5))
                                .position(convert(joint.location, geo.size))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func convert(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
    }

    // Fade points/lines toward the low-confidence end instead of hard-cutting them, so
    // "showing all points" doesn't mean flickering ghost dots when Vision is unsure.
    private func dotOpacity(_ j: JointPoint) -> Double {
        max(0.35, min(1.0, Double(j.confidence)))
    }
    private func lineOpacity(_ a: JointPoint, _ b: JointPoint) -> Double {
        min(dotOpacity(a), dotOpacity(b))
    }
}
