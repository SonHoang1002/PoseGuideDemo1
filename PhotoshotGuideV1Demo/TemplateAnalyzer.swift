import Vision
import UIKit
import simd

/// Phân tích ảnh mẫu (chọn từ thư viện hoặc template có sẵn) thành `Template` để
/// GuidanceEngine so sánh với từng frame camera. Chạy 1 lần khi vào màn Camera hoặc
/// khi người dùng đổi ảnh mẫu — không chạy realtime.
///
/// Theo v2 (NGUONG_VA_GOC_QUY_CHIEU.md):
/// - Mục 2 lưu NHIỀU mốc HeightAnchor để live chọn được mốc trùng.
/// - Mục 3 đo theo đơn-vị-chiều-cao-mẫu (gốc = đỉnh đầu), không bucket.
/// - Mục 4/5 là số liên tục: pitchDeg (độ) và torsoCenterX (0...1).
nonisolated enum TemplateAnalyzer {

    /// Ảnh tĩnh không có thông số ống kính thật → giả định vFOV dọc của camera wide
    /// khi cầm dọc. Sai số ở đây chỉ ảnh hưởng mục 3 của template một lượng nhỏ,
    /// nằm trong biên accept = 0.07H. Cần kiểm trên máy thật (mục 6 trong file .md).
    private static let assumedTemplateVFovDeg: Double = 60.0

    /// Giới hạn cạnh dài khi đưa ảnh vào Vision. Toàn bộ phép đo dùng toạ độ
    /// chuẩn hoá 0...1 nên thu nhỏ KHÔNG đổi kết quả — nhưng Vision phát hiện người
    /// ổn định hơn và nhanh hơn hẳn trên ảnh đã thu (ảnh 12MP để nguyên rất hay fail).
    private static let maxAnalysisDimension: CGFloat = 1600

    static func analyze(image: UIImage) -> Template? {
        guard let cgImage = image.cgImage else { return nil }
        let working = downscaled(cgImage: cgImage, maxDimension: maxAnalysisDimension)
        let baseOrientation = cgOrientation(image.imageOrientation)

        // Dãy lượt thử với ngưỡng khớp GIẢM DẦN — chỉ cần 1 lượt thành công.
        // Nguyên nhân "quay đúng ảnh rồi vẫn báo không thấy người": bản cũ đòi
        // đủ 4 khớp thân ≥0.5 (lượt 2 là 0.4). Hông thường xuyên yếu confidence
        // (váy dài, ảnh cắt ngang chân, chụp lại màn hình) → trả nil dù người rõ.
        let passes: [(core: Float, limb: Float)] = [
            (GuidanceConfig.default.minKeypointConfidenceCore,   GuidanceConfig.default.minKeypointConfidenceLimb), // 0.50 / 0.40
            (GuidanceConfig.default.minKeypointConfidenceLimb,   0.30),                                             // 0.40 / 0.30
            (0.30,                                               0.25),
            (0.15,                                               0.12),                                             // chót — gần như luôn thấy được người thật
        ]
        for pass in passes {
            if let t = analyze(cgImage: working, orientation: baseOrientation,
                               coreConf: pass.core, limbConf: pass.limb) {
                return t
            }
        }
        // Lượt cứu nguy cuối: EXIF orientation có thể mất khi ảnh đi qua app khác
        // (Zalo/AirDrop…) khiến Vision nhìn ảnh ngược đầu → thử xoay 180°.
        if let t = analyze(cgImage: working, orientation: flipped180(baseOrientation),
                           coreConf: passes[2].core, limbConf: passes[2].limb) {
            return t
        }
        return nil
    }

    private static func analyze(cgImage: CGImage, orientation: CGImagePropertyOrientation,
                                coreConf: Float, limbConf: Float) -> Template? {
        let cfg = GuidanceConfig.default

        let poseRequest = VNDetectHumanBodyPoseRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage,
                                             orientation: orientation,
                                             options: [:])
        try? handler.perform([poseRequest, faceRequest])
        let face = faceRequest.results?.first

        guard let obs = poseRequest.results?.first,
              let pts = try? obs.recognizedPoints(.all) else { return nil }

        func pt(_ n: VNHumanBodyPoseObservation.JointName, _ minConf: Float) -> SIMD2<Double>? {
            guard let p = pts[n], p.confidence >= minConf else { return nil }
            return SIMD2(Double(p.location.x), 1.0 - Double(p.location.y)) // gốc trên-trái
        }

        // -------- CẦN VAI (mọi lớp đều cần) + tuỳ theo điểm thân thấp hơn --------
        guard let lSh = pt(.leftShoulder, coreConf), let rSh = pt(.rightShoulder, coreConf) else { return nil }

        let neck = (lSh + rSh) / 2
        let nose = pt(.nose, limbConf)
        let lHip = pt(.leftHip, coreConf), rHip = pt(.rightHip, coreConf)
        let hips: SIMD2<Double>? = (lHip != nil && rHip != nil) ? (lHip! + rHip!) / 2 : nil
        let torsoHeight = hips.map { abs(neck.y - $0.y) } ?? 0.0
        let ankleY = [pt(.leftAnkle, limbConf)?.y, pt(.rightAnkle, limbConf)?.y].compactMap { $0 }.max()
        let kneeY  = [pt(.leftKnee, limbConf)?.y,  pt(.rightKnee, limbConf)?.y].compactMap { $0 }.max()

        // ---------- Đỉnh đầu — cùng độ ưu tiên với Measurer ----------
        var headTopY: Double?
        if let f = face {
            headTopY = 1.0 - Double(f.boundingBox.origin.y + f.boundingBox.height)
        } else if torsoHeight > 0.02 {
            headTopY = neck.y - 0.62 * torsoHeight
        } else if let nose = nose {
            headTopY = nose.y - 0.6 * abs(nose.y - neck.y)
        }

        // ---------- LỚP KHUNG HÌNH (V3) suy từ khung chủ thể ----------
        // Bẫy: Vision vẫn trả keypoint NGOÀI khung bằng ngoại suy với confidence thấp;
        // kiểm đồng thời cả confidence lẫn toạ độ y trong 0...1 (đã làm ở `pt`).
        let framing = detectFramingClass(headTopY: headTopY, hips: hips,
                                         ankleY: ankleY, kneeY: kneeY,
                                         shoulderY: max(lSh.y, rSh.y))
        let mode = framing.captureMode
        let scaleAnchor = framing.scaleAnchor

        // ---------- Mục 1: hướng mẫu — theo nguồn của lớp ----------
        var bodyYaw = 0.0
        switch framing.yawSource {
        case .faceYaw:
            // CHEST/HEAD: dùng face yaw (hông khuất, chính xác hơn).
            if let f = face, let yaw = f.yaw?.doubleValue {
                bodyYaw = yaw.degrees
            } else if let nose, hips != nil, torsoHeight >= cfg.bodyYawMinTorsoHeight {
                bodyYaw = nose.x > neck.x ? 1 : -1
            }
        case .shoulderForeshortening:
            if hips != nil, torsoHeight >= cfg.bodyYawMinTorsoHeight {
                let r = abs(lSh.x - rSh.x) / torsoHeight
                let ratio = min(max(r / cfg.defaultRFront, 0), 1)
                if ratio >= cfg.bodyYawFrontalDeadZone {
                    bodyYaw = 0   // chính diện — vùng chết
                } else {
                    let absYaw = acos(ratio).degrees
                    var signedYaw = absYaw
                    if let nose { signedYaw = (nose.x > neck.x) ? absYaw : -absYaw }
                    let seeingFront = (face != nil) || (lSh.x > rSh.x)
                    bodyYaw = seeingFront ? signedYaw
                                          : (signedYaw >= 0 ? 180 - absYaw : -180 + absYaw)
                }
            }
        }

        // ---------- Mục 2: tỉ lệ — DÙNG ĐÚNG MỐC của LỚP (không "lấy mốc tốt nhất") ----------
        var sizeRatioByAnchor: [HeightAnchor: Double] = [:]
        if scaleAnchor == .faceHeight {
            // Chiều cao khung mặt — CHEST/HEAD.
            if let f = face {
                sizeRatioByAnchor[.faceHeight] = Double(f.boundingBox.height)
            } else {
                // Dự phòng: suy từ bề ngang vai (tỉ lệ trung bình mặt/vai).
                sizeRatioByAnchor[.faceHeight] = abs(lSh.x - rSh.x) * 0.55
            }
        } else if let top = headTopY {
            if scaleAnchor == .headToAnkle, let a = ankleY, a > top {
                sizeRatioByAnchor[.headToAnkle] = a - top
            } else if scaleAnchor == .headToKnee, let k = kneeY, k > top {
                sizeRatioByAnchor[.headToKnee] = k - top
            } else if scaleAnchor == .headToHip, let h = hips, h.y > top {
                sizeRatioByAnchor[.headToHip] = h.y - top
            }
        }
        if sizeRatioByAnchor[scaleAnchor] == nil {
            // Không đo được đúng mốc lớp → tạm dùng tỉ lệ đã có rồi ưu tiên retry pass khác.
            if let top = headTopY, let a = ankleY, a > top { sizeRatioByAnchor[.headToAnkle] = a - top }
            if let top = headTopY, let k = kneeY,  k > top { sizeRatioByAnchor[.headToKnee]  = k - top }
            if let top = headTopY, let h = hips,    h.y > top { sizeRatioByAnchor[.headToHip] = h.y - top }
            if hips != nil, torsoHeight >= cfg.bodyYawMinTorsoHeight {
                sizeRatioByAnchor[.shoulderToHip] = torsoHeight
            }
        }

        // Mốc của LỚP là ưu tiên; nếu thiếu thì fallback mốc dài nhất đo được.
        let bestAnchor = (sizeRatioByAnchor[scaleAnchor] != nil)
            ? scaleAnchor
            : (HeightAnchor.allCases.filter { $0 != .faceHeight && sizeRatioByAnchor[$0] != nil }.max() ?? scaleAnchor)
        let bestSpan = sizeRatioByAnchor[bestAnchor] ?? 0.29
        let fullHeightRatio = bestAnchor.isFullHeightScalable ? bestSpan / bestAnchor.factorOfFullHeight : 0

        // ---------- Mục 4: pitch — heuristic phối cảnh chân/thân (ảnh tĩnh) ----------
        // Máy thấp ngửa lên → chân gần máy hơn → chân dài hơn ⇒ ratio lớn ⇒ pitch dương.
        var pitchDeg = 0.0
        if let top = headTopY, let h = hips,
           feet_y(top: top, hips: h, ankleY: ankleY) > h.y, h.y > top {
            let legLen = feet_y(top: top, hips: h, ankleY: ankleY) - h.y
            let torsoLen = h.y - top
            if torsoLen > 0.01 {
                let ratio = legLen / torsoLen
                pitchDeg = min(max((ratio - 1.05) * 40, -25), 25)
            }
        }

        // ---------- Mục 3: cameraHeightRel — đơn vị chiều cao mẫu, gốc = đỉnh đầu ----------
        var cameraHeightRel = 0.0
        if let top = headTopY, fullHeightRatio > 0.02 {
            let k = tan(assumedTemplateVFovDeg.radians / 2)          // = imgH / (2f)
            let elevOffset = atan((0.5 - top) * 2 * k).degrees       // góc tới đỉnh đầu
            let elev = pitchDeg + elevOffset
            cameraHeightRel = -tan(elev.radians) / (2 * k) / fullHeightRatio
            cameraHeightRel = min(max(cameraHeightRel, -2.0), 2.0)   // kẹp biên vô lý
        }
        // CHEST/HEAD (scaleAnchor == .faceHeight) không quy đổi được toàn thân
        // → cameraHeightRel giữ 0, MỤC 3 chỉ so GÓC NHÌN (MỤC 4).

        // ---------- Mục 5: tâm — theo lớp (torso giữa vai/hông, hoặc vai, hoặc mặt) ----------
        let torsoCenterX = centerX(framing: framing, neck: neck, hips: hips, face: face)

        // ---------- Mục 6: dáng — CHỈ các nhóm khớp THUỘC LỚP (RẠCH RÒI) ----------
        let jointAngles = Measurer.jointAngles(pts: pts, minConf: limbConf,
                                               groups: framing.poseGroups,
                                               includeHip: true)
        let spineTilt = (hips.map { atan2(neck.x - $0.x, max(torsoHeight, 1e-6)).degrees }) ?? 0
        let headYaw = face?.yaw?.doubleValue.degrees

        // ---------- Khung mẫu hiển thị trên camera ----------
        // Giữ nguyên hệ Vision (gốc dưới-trái, chuẩn hoá) để ghost view map y hệt
        // SkeletonOverlayView. Ngưỡng lấy bằng mức hiển thị skeleton.
        let ghostJoints = pts.reduce(into: [VNHumanBodyPoseObservation.JointName: CGPoint]()) { dict, entry in
            guard entry.value.confidence >= cfg.minKeypointConfidenceDisplay else { return }
            dict[entry.key] = entry.value.location
        }
        // Tỉ lệ ảnh SAU khi áp EXIF orientation (ảnh xoay 90° thì w/h hoán đổi).
        let rotated = { (o: CGImagePropertyOrientation) in
            switch o { case .left, .right, .leftMirrored, .rightMirrored: return true; default: return false }
        }(orientation)
        let sampleAspectRatio = rotated
            ? Double(cgImage.height) / Double(cgImage.width)
            : Double(cgImage.width) / Double(cgImage.height)

        return Template(
            framing: framing,
            captureMode: mode,
            bodyYawDeg: bodyYaw,
            sizeRatioByAnchor: sizeRatioByAnchor,
            cameraHeightRel: cameraHeightRel,
            cameraPitchDeg: pitchDeg,
            torsoCenterX: torsoCenterX,
            lens: .wide,
            jointAngles: jointAngles,
            spineTiltDeg: spineTilt,
            headYawDeg: headYaw,
            cueForModel: "Bảo mẫu giữ dáng giống ảnh mẫu",
            ghostJoints: ghostJoints,
            sampleAspectRatio: sampleAspectRatio
        )
    }

    /// Tâm chủ thể theo chiều ngang, tuỳ lớp: torso (vai+hông) · vai · mặt.
    private static func centerX(framing: FramingClass,
                                neck: SIMD2<Double>,
                                hips: SIMD2<Double>?,
                                face: VNFaceObservation?) -> Double {
        switch framing {
        case .head:
            if let f = face { return Double(f.boundingBox.midX) }
            return neck.x
        case .chest:
            return neck.x   // giữa hai vai
        case .full, .knee, .half:
            if let h = hips { return (neck.x + h.x) / 2 }
            return neck.x
        }
    }

    /// Quy tắc nhận diện lớp theo tài liệu V3 (y tính từ mép trên, 0...1).
    /// Xác định bằng điểm THẤP NHẤT của cơ thể còn nằm trong khung.
    static func detectFramingClass(headTopY: Double?,
                                   hips: SIMD2<Double>?,
                                   ankleY: Double?,
                                   kneeY: Double?,
                                   shoulderY: Double?) -> FramingClass {
        // Đáy chủ thể = điểm thấp nhất đo được trong khung.
        let bottom = max(
            ankleY ?? -1,
            kneeY ?? -1,
            hips?.y ?? -1,
            shoulderY ?? -1
        )
        let cutAtBottom = bottom > 0.97

        if bottom > 0 {  // có điểm dưới ngực trở xuống ⇒ phân theo độ sâu
            if !cutAtBottom && bottom > 0.80 { return .full }
            if bottom > 0.72 { return .knee }
            if bottom > 0.55 { return .half }
        }
        // Chỉ thấy đầu + vai (hoặc hông chìm ngoài khung).
        if hips != nil { return .chest }
        return .head
    }

    private static func feet_y(top: Double, hips: SIMD2<Double>, ankleY: Double?) -> Double {
        ankleY ?? hips.y + (hips.y - top) * (0.53 / 0.47)   // suy từ nhân trắc nếu mất chân
    }

    /// Thu nhỏ ảnh giữ tỉ lệ để Vision chạy nhanh + phát hiện ổn định hơn.
    private static func downscaled(cgImage: CGImage, maxDimension: CGFloat) -> CGImage {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let longest = max(w, h)
        guard longest > maxDimension else { return cgImage }
        let scale = maxDimension / longest
        let newW = max(1, Int((w * scale).rounded()))
        let newH = max(1, Int((h * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: newW, height: newH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return cgImage
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(newW), height: CGFloat(newH)))
        return ctx.makeImage() ?? cgImage
    }

    private static func flipped180(_ o: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .down
        case .down: return .up
        case .left: return .right
        case .right: return .left
        case .upMirrored: return .downMirrored
        case .downMirrored: return .upMirrored
        case .leftMirrored: return .rightMirrored
        case .rightMirrored: return .leftMirrored
        @unknown default: return o
        }
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
