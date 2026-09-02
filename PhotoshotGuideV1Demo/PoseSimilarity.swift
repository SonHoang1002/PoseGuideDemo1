import Foundation

/// So khớp pose live/template theo v2: SO SỐ LIÊN TỤC với cùng gốc quy chiếu
/// và cùng đơn vị — không so bucket. Bucket chỉ dùng để chọn chữ trong cue.
nonisolated enum PoseSimilarity {

    /// Score a live camera measurement against the reference template. 0...1, higher = closer match.
    static func score(_ m: Measurement, _ t: Template) -> Double {
        guard m.hasSubject else { return 0 }
        let cfg = GuidanceConfig.default
        var penalty = 0.0

        // Mục 1 — hướng mẫu (độ, gốc = trung điểm hai vai)
        if let yaw = m.bodyYawDeg {
            penalty += weighted(abs(signedAngleDelta(yaw, t.bodyYawDeg)),
                                tolerance: cfg.bodyYaw.accept, weight: 0.30)
        } else {
            penalty += 0.30   // không đo được → phạt trọn weight của mục đó
        }

        // Mục 2 — xa/gần: cùng mốc HeightAnchor mới so được
        if let anchor = m.heightAnchor, let live = m.sizeRatio,
           let tmpl = t.sizeRatioByAnchor[anchor], tmpl > 0 {
            let err = abs(live / tmpl - 1.0) * 100
            penalty += weighted(err, tolerance: cfg.distance.accept * 100, weight: 0.15)
        } else {
            penalty += 0.15
        }

        // Mục 3 — máy cao/thấp: đơn-vị-chiều-cao-mẫu, gốc = đỉnh đầu
        if let rel = m.cameraHeightRel {
            penalty += weighted(abs(rel - t.cameraHeightRel),
                                tolerance: cfg.cameraHeight.accept, weight: 0.10)
        } else {
            penalty += 0.10
        }

        // Mục 4 — ngửa/chúc: độ, gốc = mặt phẳng ngang
        penalty += weighted(abs(m.cameraPitchDeg - t.cameraPitchDeg),
                            tolerance: cfg.cameraPitch.accept, weight: 0.10)

        // Mục 5 — trái/phải: hiệu X tâm thân
        if let cx = m.torsoCenterX {
            penalty += weighted(abs(cx - t.torsoCenterX) * 100,
                                tolerance: cfg.horizontal.accept * 100, weight: 0.10)
        } else {
            penalty += 0.10
        }

        // Mục 6 — dáng tại từng khớp (theo lớp khung hình của template)
        penalty += jointPenalty(m.jointAngles, t.jointAngles,
                                tolerance: cfg.jointAngle.accept, weight: 0.25,
                                framing: t.framing)

        return max(0, 1 - penalty)
    }

    /// Score a still-image analysis (e.g. an extracted video frame, itself run through
    /// TemplateAnalyzer) against the reference template. Same weighting as above.
    static func score(_ frame: Template, against t: Template) -> Double {
        let cfg = GuidanceConfig.default
        var penalty = 0.0

        penalty += weighted(abs(signedAngleDelta(frame.bodyYawDeg, t.bodyYawDeg)),
                            tolerance: cfg.bodyYaw.accept, weight: 0.30)

        // So ở mốc tốt nhất mà CẢ HAI đều có (mốc khác nhau thì không so)
        if let sharedAnchor = HeightAnchor.allCases
            .filter({ frame.sizeRatioByAnchor[$0] != nil && t.sizeRatioByAnchor[$0] != nil })
            .max(),
           let a = frame.sizeRatioByAnchor[sharedAnchor],
           let b = t.sizeRatioByAnchor[sharedAnchor], b > 0 {
            let err = abs(a / b - 1.0) * 100
            penalty += weighted(err, tolerance: cfg.distance.accept * 100, weight: 0.15)
        } else {
            penalty += 0.15
        }

        penalty += weighted(abs(frame.cameraHeightRel - t.cameraHeightRel),
                            tolerance: cfg.cameraHeight.accept, weight: 0.10)
        penalty += weighted(abs(frame.cameraPitchDeg - t.cameraPitchDeg),
                            tolerance: cfg.cameraPitch.accept, weight: 0.10)
        penalty += weighted(abs(frame.torsoCenterX - t.torsoCenterX) * 100,
                            tolerance: cfg.horizontal.accept * 100, weight: 0.10)
        penalty += jointPenalty(frame.jointAngles, t.jointAngles,
                                tolerance: cfg.jointAngle.accept, weight: 0.25,
                                framing: t.framing)

        return max(0, 1 - penalty)
    }

    /// Phạt trung bình sai lệch khớp — CHỈ các khớp thuộc lớp khung hình `framing`.
    private static func jointPenalty(_ current: [JointName: Double], _ target: [JointName: Double],
                                     tolerance: Double, weight: Double,
                                     framing: FramingClass) -> Double {
        let groups = framing.poseGroups
        var deltas: [Double] = []
        for (joint, targetAngle) in target where Self.inGroups(joint, groups) {
            if let cur = current[joint] { deltas.append(abs(cur - targetAngle)) }
        }
        guard !deltas.isEmpty else { return weight }
        let avg = deltas.reduce(0, +) / Double(deltas.count)
        return weighted(avg, tolerance: tolerance, weight: weight)
    }

    /// Một khớp có thuộc nhóm pose được chấm không.
    private static func inGroups(_ j: JointName, _ groups: [PoseGroup]) -> Bool {
        switch j {
        case .leftKnee, .rightKnee: return groups.contains(.legs)
        default:                    return groups.contains(.arms)
        }
    }

    /// 0 at `tolerance`, grows past it; capped so one bad axis doesn't zero out the whole score.
    private static func weighted(_ delta: Double, tolerance: Double, weight: Double) -> Double {
        guard tolerance > 0 else { return 0 }
        let ratio = min(delta / tolerance, 3.0) / 3.0
        return ratio * weight
    }
}
