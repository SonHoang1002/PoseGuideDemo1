//
//  PoseSimilarity.swift
//  Chấm điểm 0...1 độ khớp giữa MỘT phép đo (frame live hoặc frame video) với
//  ảnh mẫu — dùng để xếp hạng và lấy "N ảnh khớp nhất" (CameraManager.topMatches).
//
//  Cố ý đơn giản hơn Documents/BestShotSelector.swift (chưa chấm chất lượng
//  ảnh nét/rung/phơi sáng, chưa có ràng buộc đa dạng) — việc đó thuộc phạm vi
//  tích hợp BestShotSelector.swift (bước kế tiếp), không phải phạm vi sửa lỗi
//  hướng dẫn realtime ở đây. Chỉ có 1 overload: (Measurement, Template) — CỐ
//  Ý bỏ overload Template-vs-Template kiểu cũ, vì đó chính là hiện thân của
//  "nguyên nhân 8": phân tích lại mỗi frame như một ảnh mẫu độc lập khiến nó
//  tự chọn mốc riêng thay vì dùng đúng mốc của template gốc.
//

import Foundation

enum PoseSimilarity {

    private static let cfg = GuidanceConfig.default

    /// Score một phép đo (đã đo ĐÚNG theo `t.framing`) so với mẫu. 0...1, cao hơn = khớp hơn.
    static func score(_ m: Measurement, _ t: Template) -> Double {
        guard m.hasSubject else { return 0 }
        let bands = cfg.thresholds(for: t.framing)
        var penalty = 0.0

        if let yaw = m.bodyYawDeg {
            penalty += weighted(abs(signedAngleDelta(yaw, t.bodyYawDeg)), tolerance: bands.bodyYaw.accept, weight: 0.30)
        } else {
            penalty += 0.30
        }

        if let scale = m.scaleValue, t.scaleValue > 0 {
            let err = abs(scale / t.scaleValue - 1.0) * 100
            penalty += weighted(err, tolerance: bands.distance.accept * 100, weight: 0.15)
        }

        if let elev = m.elevationDeg {
            penalty += weighted(abs(elev - t.elevationDeg), tolerance: bands.elevation.accept, weight: 0.15)
        }

        penalty += weighted(abs(m.cameraPitchDeg - t.cameraPitchDeg), tolerance: bands.pitch.accept, weight: 0.15)

        if let cx = m.centerX {
            penalty += weighted(abs(cx - t.centerX) * 100, tolerance: bands.horizontal.accept * 100, weight: 0.10)
        }

        penalty += jointPenalty(m.jointAngles, t.jointAngles, tolerance: bands.jointAngle.accept, weight: 0.15)

        return max(0, 1 - penalty)
    }

    private static func jointPenalty(_ current: [JointName: Double], _ target: [JointName: Double],
                                     tolerance: Double, weight: Double) -> Double {
        var deltas: [Double] = []
        for (joint, targetAngle) in target {
            if let cur = current[joint] { deltas.append(abs(cur - targetAngle)) }
        }
        guard !deltas.isEmpty else { return 0 }
        let avg = deltas.reduce(0, +) / Double(deltas.count)
        return weighted(avg, tolerance: tolerance, weight: weight)
    }

    /// 0 tại `tolerance`, tăng dần sau đó; giới hạn để 1 trục lệch không xoá sạch điểm.
    private static func weighted(_ delta: Double, tolerance: Double, weight: Double) -> Double {
        guard tolerance > 0 else { return 0 }
        let ratio = min(delta / tolerance, 3.0) / 3.0
        return ratio * weight
    }
}
