import Vision
import CoreGraphics

struct PoseSuggestion: Identifiable {
    let id = UUID()
    let text: String
    let priority: Int // lower = shown first
}

enum PoseComparator {

    struct Metrics {
        var shoulderTilt: CGFloat = 0   // deg; + = left shoulder higher than right
        var bodyLean: CGFloat = 0       // deg from vertical; + = torso leaning left
        var headTilt: CGFloat = 0       // deg; + = head tilted left
        var leftArmAngle: CGFloat?      // shoulder-elbow-wrist angle
        var rightArmAngle: CGFloat?
    }

    static func metrics(from pose: BodyPose) -> Metrics? {
        guard let lS = pose.points[.leftShoulder], let rS = pose.points[.rightShoulder] else { return nil }

        var m = Metrics()
        m.shoulderTilt = angle(rS, lS)

        if let lH = pose.points[.leftHip], let rH = pose.points[.rightHip] {
            let shoulderMid = midpoint(lS, rS)
            let hipMid = midpoint(lH, rH)
            m.bodyLean = angle(hipMid, shoulderMid) - 90
        }
        if let neck = pose.points[.neck], let nose = pose.points[.nose] {
            m.headTilt = angle(neck, nose) - 90
        }
        if let e = pose.points[.leftElbow], let w = pose.points[.leftWrist] {
            m.leftArmAngle = jointAngle(lS, e, w)
        }
        if let e = pose.points[.rightElbow], let w = pose.points[.rightWrist] {
            m.rightArmAngle = jointAngle(rS, e, w)
        }
        return m
    }

    /// Compares live pose metrics against the reference and returns ordered suggestions.
    static func suggestions(reference: Metrics, live: Metrics, angleThreshold: CGFloat = 8, armThreshold: CGFloat = 15) -> [PoseSuggestion] {
        var results: [PoseSuggestion] = []

        let shoulderDiff = live.shoulderTilt - reference.shoulderTilt
        if abs(shoulderDiff) > angleThreshold {
            results.append(.init(text: shoulderDiff > 0 ? "Hạ vai trái xuống" : "Nâng vai trái lên", priority: 2))
        }

        let leanDiff = live.bodyLean - reference.bodyLean
        if abs(leanDiff) > angleThreshold {
            results.append(.init(text: leanDiff > 0 ? "Nghiêng người sang phải" : "Nghiêng người sang trái", priority: 1))
        }

        let headDiff = live.headTilt - reference.headTilt
        if abs(headDiff) > angleThreshold {
            results.append(.init(text: headDiff > 0 ? "Nghiêng đầu sang phải" : "Nghiêng đầu sang trái", priority: 3))
        }

        if let refArm = reference.rightArmAngle, let liveArm = live.rightArmAngle, abs(liveArm - refArm) > armThreshold {
            results.append(.init(text: liveArm > refArm ? "Duỗi thẳng tay phải hơn" : "Thu tay phải lại gần hơn", priority: 4))
        }
        if let refArm = reference.leftArmAngle, let liveArm = live.leftArmAngle, abs(liveArm - refArm) > armThreshold {
            results.append(.init(text: liveArm > refArm ? "Duỗi thẳng tay trái hơn" : "Thu tay trái lại gần hơn", priority: 4))
        }

        return results.sorted { $0.priority < $1.priority }
    }

    // MARK: - Geometry helpers

    private static func angle(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        atan2(b.y - a.y, b.x - a.x) * 180 / .pi
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private static func jointAngle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let v1 = CGPoint(x: a.x - b.x, y: a.y - b.y)
        let v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
        let mag1 = hypot(v1.x, v1.y), mag2 = hypot(v2.x, v2.y)
        guard mag1 > 0, mag2 > 0 else { return 0 }
        let cosA = max(-1, min(1, (v1.x * v2.x + v1.y * v2.y) / (mag1 * mag2)))
        return acos(cosA) * 180 / .pi
    }
}
