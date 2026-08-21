import Vision
import UIKit
import simd

/// Phân tích ảnh mẫu (chọn từ thư viện hoặc template có sẵn) thành `Template` để
/// GuidanceEngine so sánh với từng frame camera. Chạy 1 lần khi vào màn Camera hoặc
/// khi người dùng đổi ảnh mẫu — không chạy realtime.
enum TemplateAnalyzer {

    static func analyze(image: UIImage) -> Template? {
        guard let cgImage = image.cgImage else { return nil }

        let poseRequest = VNDetectHumanBodyPoseRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage,
                                             orientation: cgOrientation(image.imageOrientation),
                                             options: [:])
        try? handler.perform([poseRequest, faceRequest])

        guard let obs = poseRequest.results?.first,
              let pts = try? obs.recognizedPoints(.all) else { return nil }

        func pt(_ n: VNHumanBodyPoseObservation.JointName) -> SIMD2<Double>? {
            guard let p = pts[n], p.confidence >= Tolerance.minKeypointConf else { return nil }
            return SIMD2(Double(p.location.x), 1.0 - Double(p.location.y)) // gốc trên-trái
        }

        guard let lSh = pt(.leftShoulder), let rSh = pt(.rightShoulder),
              let lHip = pt(.leftHip), let rHip = pt(.rightHip) else { return nil }

        let neck = (lSh + rSh) / 2
        let hips = (lHip + rHip) / 2
        let nose = pt(.nose)

        // ---------- Mục 1: hướng mẫu (cùng công thức foreshortening với Measurer) ----------
        var bodyYaw = 0.0
        let W = abs(lSh.x - rSh.x), H = abs(neck.y - hips.y)
        if H > 0.02 {
            let r = W / H
            let absYaw = acos(min(max(r / 0.62, 0), 1)).degrees
            let seeingFront = lSh.x > rSh.x
            var signedYaw = absYaw
            if let nose { signedYaw = (nose.x > neck.x) ? absYaw : -absYaw }
            bodyYaw = seeingFront ? signedYaw : (signedYaw >= 0 ? 180 - absYaw : -180 + absYaw)
        }

        // ---------- Mục 2: chiều cao mẫu trong khung ----------
        let headTopY = nose.map { $0.y - 0.6 * abs($0.y - neck.y) }
        let feetY = [pt(.leftAnkle)?.y, pt(.rightAnkle)?.y].compactMap { $0 }.max()
        let heightRatio: Double = {
            guard let top = headTopY, let feet = feetY, feet > top else { return 0.55 }
            return feet - top
        }()

        // ---------- Mục 3+4: máy cao/thấp & ngửa/chúc ----------
        // Ảnh mẫu tĩnh không có CoreMotion/optics thật, nên ước lượng thô qua tỉ lệ
        // chân/thân: máy thấp (chụp hất lên) làm chân trông dài hơn thân so với chuẩn ~1.05.
        var heightBucket = 2, pitchBucket = 2, pitchDeg = 0.0
        if let top = headTopY, let feet = feetY, feet > hips.y, hips.y > top {
            let legLen = feet - hips.y, torsoLen = hips.y - top
            if torsoLen > 0.01 {
                let ratio = legLen / torsoLen
                let devDeg = (ratio - 1.05) * 40   // quy đổi thô lệch tỉ lệ -> độ
                pitchDeg = -devDeg
                pitchBucket = Measurer.pitchBucket(pitchDeg)
                heightBucket = Measurer.heightBucket(devDeg / 100)
            }
        }

        // ---------- Mục 5: lệch trái/phải ----------
        let hipCenterX = hips.x

        // ---------- Mục 6: dáng ----------
        let spineTilt = atan2(neck.x - hips.x, abs(neck.y - hips.y)).degrees
        let jointAngles = Measurer.jointAngles(pts: pts)
        let headYaw = faceRequest.results?.first?.yaw?.doubleValue.degrees

        return Template(
            bodyYawDeg: bodyYaw,
            subjectHeightRatio: heightRatio,
            cameraHeightBucket: heightBucket,
            pitchDeg: pitchDeg,
            pitchBucket: pitchBucket,
            hipCenterX: hipCenterX,
            lens: .wide,
            jointAngles: jointAngles,
            spineTiltDeg: spineTilt,
            headYawDeg: headYaw,
            cueForModel: "Bảo mẫu giữ dáng giống ảnh mẫu"
        )
    }

    private static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
