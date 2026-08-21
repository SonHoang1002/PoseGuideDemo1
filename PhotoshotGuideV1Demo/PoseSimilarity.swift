import Foundation

enum PoseSimilarity {

    /// Score a live camera measurement against the reference template. 0...1, higher = closer match.
    static func score(_ m: Measurement, _ t: Template) -> Double {
        guard m.hasSubject else { return 0 }
        var penalty = 0.0

        if let yaw = m.bodyYawDeg {
            penalty += weighted(abs(signedAngleDelta(yaw, t.bodyYawDeg)), tolerance: Tolerance.bodyYawDeg, weight: 0.30)
        } else {
            penalty += 0.30
        }

        if let ratio = m.subjectHeightRatio, t.subjectHeightRatio > 0 {
            let err = abs(ratio / t.subjectHeightRatio - 1.0) * 100
            penalty += weighted(err, tolerance: Tolerance.subjectSizeRatio * 100, weight: 0.15)
        }

        if let bucket = m.cameraHeightBucket {
            penalty += weighted(Double(abs(bucket - t.cameraHeightBucket)), tolerance: 1, weight: 0.15)
        }

        penalty += weighted(Double(abs(m.pitchBucket - t.pitchBucket)), tolerance: 1, weight: 0.15)

        if let cx = m.hipCenterX {
            penalty += weighted(abs(cx - t.hipCenterX) * 100, tolerance: Tolerance.horizontalOffset * 100, weight: 0.10)
        }

        penalty += jointPenalty(m.jointAngles, t.jointAngles, weight: 0.15)

        return max(0, 1 - penalty)
    }

    /// Score a still-image analysis (e.g. an extracted video frame, itself run through
    /// TemplateAnalyzer) against the reference template. Same weighting as above.
    static func score(_ frame: Template, against t: Template) -> Double {
        var penalty = 0.0
        penalty += weighted(abs(signedAngleDelta(frame.bodyYawDeg, t.bodyYawDeg)), tolerance: Tolerance.bodyYawDeg, weight: 0.30)
        if t.subjectHeightRatio > 0 {
            let err = abs(frame.subjectHeightRatio / t.subjectHeightRatio - 1.0) * 100
            penalty += weighted(err, tolerance: Tolerance.subjectSizeRatio * 100, weight: 0.15)
        }
        penalty += weighted(Double(abs(frame.cameraHeightBucket - t.cameraHeightBucket)), tolerance: 1, weight: 0.15)
        penalty += weighted(Double(abs(frame.pitchBucket - t.pitchBucket)), tolerance: 1, weight: 0.15)
        penalty += weighted(abs(frame.hipCenterX - t.hipCenterX) * 100, tolerance: Tolerance.horizontalOffset * 100, weight: 0.10)
        penalty += jointPenalty(frame.jointAngles, t.jointAngles, weight: 0.15)
        return max(0, 1 - penalty)
    }

    private static func jointPenalty(_ current: [JointName: Double], _ target: [JointName: Double], weight: Double) -> Double {
        var deltas: [Double] = []
        for (joint, targetAngle) in target {
            if let cur = current[joint] { deltas.append(abs(cur - targetAngle)) }
        }
        guard !deltas.isEmpty else { return 0 }
        let avg = deltas.reduce(0, +) / Double(deltas.count)
        return weighted(avg, tolerance: Tolerance.jointAngleDeg, weight: weight)
    }

    /// 0 at `tolerance`, grows past it; capped so one bad axis doesn't zero out the whole score.
    private static func weighted(_ delta: Double, tolerance: Double, weight: Double) -> Double {
        guard tolerance > 0 else { return 0 }
        let ratio = min(delta / tolerance, 3.0) / 3.0
        return ratio * weight
    }
}
