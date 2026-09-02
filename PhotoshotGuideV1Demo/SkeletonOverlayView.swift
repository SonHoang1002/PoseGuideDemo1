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

/// Khung mẫu (ghost) vẽ từ điểm khớp đã phân tích của ảnh mẫu, để người chụp ướm
/// người thật vào đúng tư thế/vị trí. Khung được letterbox GIỮ NGUYÊN tỉ lệ ảnh mẫu
/// trong khung preview nên dáng không bị méo, bất kể ảnh mẫu chụp ở tỉ lệ nào.
struct TemplateGhostOverlayView: View {
    /// Điểm khớp ảnh mẫu — hệ Vision gốc dưới-trái, chuẩn hoá 0...1.
    let joints: [VNHumanBodyPoseObservation.JointName: CGPoint]
    /// Tỉ lệ w/h của ảnh mẫu.
    let sampleAspect: Double

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
            let rect = fittedRect(in: geo.size)
            ZStack {
                // Nền mờ định vùng "ướm người vào đây"
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.white.opacity(0.35),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                Path { path in
                    for (a, b) in connections {
                        if let pa = joints[a], let pb = joints[b] {
                            path.move(to: convert(pa, rect))
                            path.addLine(to: convert(pb, rect))
                        }
                    }
                }
                .stroke(Color.cyan.opacity(0.85),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                ForEach(Array(joints.keys), id: \.self) { key in
                    if let pt = joints[key] {
                        Circle()
                            .fill(Color.cyan.opacity(0.30))
                            .overlay(Circle().stroke(Color.cyan.opacity(0.9), lineWidth: 1.5))
                            .frame(width: 10, height: 10)
                            .position(convert(pt, rect))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Chữ nhật hiển thị khung mẫu: lấp đầy preview theo chiều lớn nhất nhưng
    /// vẫn giữ đúng tỉ lệ ảnh mẫu (aspect-fit).
    private func fittedRect(in size: CGSize) -> CGRect {
        guard sampleAspect > 0 else { return CGRect(origin: .zero, size: size) }
        let viewAspect = Double(size.width / size.height)
        var w = Double(size.width), h = Double(size.height)
        if sampleAspect < viewAspect {
            w = h * sampleAspect          // mẫu "đứng" hơn màn hình → thu hẹp ngang
        } else {
            h = w / sampleAspect          // mẫu "ngang" hơn màn hình → hạ cao độ
        }
        return CGRect(x: (Double(size.width) - w) / 2,
                      y: (Double(size.height) - h) / 2,
                      width: w, height: h)
    }

    /// Vision gốc dưới-trái → toạ độ screen trong chữ nhật khung mẫu.
    private func convert(_ point: CGPoint, _ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + Double(point.x) * rect.width,
                y: rect.maxY - Double(point.y) * rect.height)
    }
}
