//
//  BestShotSelector.swift
//  Chọn 5 ảnh tốt nhất từ video (hoặc chuỗi ảnh) theo một ảnh mẫu.
//
//  Đầu vào : URL video đã quay + ảnh mẫu (CGImage) — toàn thân HOẶC chân dung
//  Đầu ra  : 5 ảnh xếp hạng, đã cắt về bố cục mẫu
//
//  Nguyên tắc chấm điểm (PO chốt, Documents/PoseCoach_Phan_Lop_Khung_Hinh.docx §7):
//      Khớp hình học với mẫu (góc chụp, vị trí, tỉ lệ) ...... 0.55
//      Chất lượng ảnh ....................................... 0.35
//      Dáng của mẫu ......................................... 0.10   ← để cuối, user tự do
//  → Khớp mọi thứ trừ dáng = 0.90. Khớp cả dáng = 1.00.
//
//  Nguồn: Documents/BestShotSelector.swift (đúng nguyên bản, chỉ khác 3 điểm):
//   1. Dùng FramingClass.swift dùng chung với GuidanceEngine.swift, thay vì tự
//      định nghĩa lại enum riêng — tránh 2 nơi định nghĩa "lớp khung hình" lệch
//      nhau theo thời gian.
//   2. Bổ sung 3/4 tiêu chí tài liệu đề xuất thêm mà bản gốc chưa có: lọc frame
//      lúc máy đang di chuyển (angularSpeedLog), tay che mặt (handNearFace),
//      khoá đúng 1 chủ thể khi nhiều người trong khung (subject lock).
//      Tiêu chí còn lại — "không cắt vào khớp" — bản gốc đã có (`badCropJoint`).
//   3. Đổi tên `analyzeTemplate`/`measure` nội bộ dùng `FramingClass.detect`
//      thay vì hàm `detectFramingClass` riêng.
//
//  Toàn bộ chạy on-device. Không server, không train model.
//

import SwiftUI
import Vision
import AVFoundation
import CoreImage
import Accelerate
import simd

// =====================================================================
// MARK: - 1. HỒ SƠ TEMPLATE
// =====================================================================

struct TemplateProfile: Codable {
    var framing: FramingClass

    // Hình học — đơn vị chuẩn hóa 0...1 theo khung, góc theo độ
    var scaleValue: Double          // giá trị của framing.scaleAnchor
    var centerX: Double             // 0 = mép trái, 1 = mép phải
    var centerY: Double             // 0 = mép trên, 1 = mép dưới
    var bodyYawDeg: Double          // 0 = mẫu nhìn thẳng máy, ±180 = quay lưng
    var faceYawDeg: Double?
    var elevationDeg: Double        // góc nhìn từ máy tới elevationAnchor. Âm = nhìn xuống
    var cameraPitchDeg: Double      // góc trục ống kính so mặt phẳng ngang. Âm = chúc xuống

    // Dáng
    var jointAngles: [String: Double]
    var spineTiltDeg: Double
    var headPitchDeg: Double?
    /// Cổ tay nằm trong khung mặt ở ẢNH MẪU (vd. mẫu đang vuốt tóc) — nếu true,
    /// live có tay che mặt sẽ KHÔNG bị trừ điểm dáng vì đó đúng là chủ ý của mẫu.
    var handNearFace: Bool = false

    // Tỉ lệ khung ảnh mẫu (để cắt đúng)
    var aspectRatio: Double
}

// =====================================================================
// MARK: - 2. THAM SỐ CHẠY  (mọi con số nằm ở đây, sửa 1 chỗ)
// =====================================================================

struct SelectionConfig {
    /// Khoảng cách giữa hai frame lấy ra. 0.1s = 10fps, 0.2s = 5fps.
    var extractInterval: Double = 0.15

    /// Kích thước cạnh dài khi phân tích (giảm để nhanh; cắt ảnh vẫn dùng frame gốc).
    var analysisMaxDimension: CGFloat = 640

    /// Số ảnh trả về.
    var outputCount: Int = 5

    /// Số frame lọt qua vòng lọc thô để vào vòng chấm kỹ.
    var shortlistCount: Int = 36

    /// Hai ảnh xuất ra phải cách nhau tối thiểu ngần này (giây) — chống 5 ảnh giống hệt.
    var minTimeGapSeconds: Double = 0.9

    /// Hoặc phải khác dáng đủ nhiều (0...1, càng cao càng khắt khe).
    var minPoseDistance: Double = 0.12

    // --- Trọng số 3 nhóm (tổng = 1.0) ---
    var weightGeometry: Double = 0.55
    var weightQuality:  Double = 0.35
    var weightPose:     Double = 0.10

    // --- Ngưỡng "sai bao nhiêu thì điểm về 0" của từng đại lượng hình học ---
    var toleranceScale: Double        = 0.30
    var toleranceCenter: Double       = 0.22
    var toleranceBodyYawDeg: Double   = 55
    var toleranceFaceYawDeg: Double   = 45
    var toleranceElevationDeg: Double = 22
    var tolerancePitchDeg: Double     = 18
    var toleranceJointDeg: Double     = 55
    var toleranceSpineDeg: Double     = 28

    // --- Lọc thô: dưới ngưỡng này thì loại thẳng ---
    var minSharpness: Double = 0.10
    var minKeypointConfidence: Float = 0.35
    var maxClippedHighlightRatio: Double = 0.22

    /// Loại frame chụp lúc máy đang di chuyển (đề xuất bổ sung #2 tài liệu).
    /// Chỉ áp dụng khi `selectBestShots` được truyền `angularSpeedLog`.
    var maxAngularSpeedDegPerSec: Double = 15

    /// Cắt về bố cục mẫu sau khi chọn.
    var autoCropToTemplate: Bool = true
    /// Không cắt quá mức này (giữ độ phân giải — iPhone 11 quay 1080p).
    var maxCropRatio: Double = 0.14

    static let `default` = SelectionConfig()
}

// =====================================================================
// MARK: - 3. ĐO ĐẠC MỘT FRAME
// =====================================================================

struct FrameMeasurement {
    var time: Double
    var hasSubject = false

    // Hình học
    var scaleValue: Double?
    var centerX: Double?
    var centerY: Double?
    var bodyYawDeg: Double?
    var faceYawDeg: Double?
    var elevationDeg: Double?
    var cameraPitchDeg: Double?

    // Dáng
    var jointAngles: [String: Double] = [:]
    var spineTiltDeg: Double?
    var headPitchDeg: Double?
    var handNearFace: Bool = false

    // Chất lượng
    var sharpness: Double = 0
    var motionBlur: Double = 0
    var clippedHighlights: Double = 0
    var underExposed: Double = 0
    var faceCaptureQuality: Double?
    var eyesOpen: Double?
    var badCropJoint = false

    /// Tốc độ góc của máy tại thời điểm frame (độ/giây) — nil nếu không có log.
    var angularSpeedDegPerSec: Double?

    var subjectBox: CGRect = .zero
}

// =====================================================================
// MARK: - 4. BỘ ĐO  (Vision)
// =====================================================================

final class FrameMeasurer {

    private let cfg: SelectionConfig
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Khoá 1 chủ thể trong suốt phiên (đề xuất bổ sung #4 tài liệu). Nhiều
    /// người trong khung: frame đầu chọn người có khung bao lớn nhất, các frame
    /// sau bám theo bằng vị trí gần nhất — không khoá thì thuật toán nhảy giữa
    /// hai người và điểm số vô nghĩa.
    private var lockedCenter: SIMD2<Double>?

    init(config: SelectionConfig) { self.cfg = config }

    func resetLock() { lockedCenter = nil }

    /// Phân tích ảnh mẫu → TemplateProfile.
    func analyzeTemplate(_ image: CGImage, cameraPitchHint: Double? = nil) -> TemplateProfile? {
        resetLock()
        guard let m = measureRaw(image, time: 0, framing: nil) else { return nil }
        let framing = FramingClass.detect(subjectBox: m.subjectBox)
        // Đo lại theo đúng lớp vừa xác định
        guard let mm = measureRaw(image, time: 0, framing: framing) else { return nil }

        return TemplateProfile(
            framing: framing,
            scaleValue: mm.scaleValue ?? 0.8,
            centerX: mm.centerX ?? 0.5,
            centerY: mm.centerY ?? 0.5,
            bodyYawDeg: mm.bodyYawDeg ?? 0,
            faceYawDeg: mm.faceYawDeg,
            elevationDeg: mm.elevationDeg ?? 0,
            cameraPitchDeg: cameraPitchHint ?? Self.inferPitchFromImage(mm),
            jointAngles: mm.jointAngles,
            spineTiltDeg: mm.spineTiltDeg ?? 0,
            headPitchDeg: mm.headPitchDeg,
            handNearFace: mm.handNearFace,
            aspectRatio: Double(image.width) / Double(image.height)
        )
    }

    /// Đo một frame của video theo lớp khung hình đã biết từ template.
    func measure(_ image: CGImage, time: Double, framing: FramingClass) -> FrameMeasurement? {
        guard var m = measureRaw(image, time: time, framing: framing) else { return nil }
        measureQuality(image, into: &m)
        return m
    }

    // ---------------------------------------------------------------
    // Đo hình học + dáng
    // ---------------------------------------------------------------
    private func measureRaw(_ image: CGImage, time: Double, framing: FramingClass?) -> FrameMeasurement? {
        var m = FrameMeasurement(time: time)

        let poseReq = VNDetectHumanBodyPoseRequest()
        let faceReq = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try? handler.perform([poseReq, faceReq])

        guard let observations = poseReq.results, !observations.isEmpty else { return nil }
        guard let obs = pickSubject(from: observations) else { return nil }
        guard let pts = try? obs.recognizedPoints(.all) else { return nil }

        func p(_ n: VNHumanBodyPoseObservation.JointName, minConf: Float? = nil) -> SIMD2<Double>? {
            guard let q = pts[n], q.confidence >= (minConf ?? cfg.minKeypointConfidence) else { return nil }
            return SIMD2(Double(q.location.x), 1.0 - Double(q.location.y))
        }

        let lSh = p(.leftShoulder), rSh = p(.rightShoulder)
        let lHip = p(.leftHip), rHip = p(.rightHip)
        guard let ls = lSh, let rs = rSh else { return nil }
        m.hasSubject = true

        let neck = (ls + rs) / 2
        let hips: SIMD2<Double>? = (lHip != nil && rHip != nil) ? (lHip! + rHip!) / 2 : nil
        let nose = p(.nose)
        let lAnk = p(.leftAnkle), rAnk = p(.rightAnkle)
        let lKnee = p(.leftKnee), rKnee = p(.rightKnee)
        let lWrist = p(.leftWrist), rWrist = p(.rightWrist)

        // --- Khuôn mặt ---
        let face = faceReq.results?.first(where: { faceBox in
            // Ghép mặt với đúng người đã khoá (lấy mặt gần cổ nhất).
            let c = SIMD2(Double(faceBox.boundingBox.midX), 1.0 - Double(faceBox.boundingBox.midY))
            return length(c - neck) < 0.25
        }) ?? faceReq.results?.first

        if let f = face {
            m.faceYawDeg = f.yaw?.doubleValue.deg
            m.headPitchDeg = f.pitch?.doubleValue.deg
            m.eyesOpen = Self.eyeOpenness(f)
        }

        // --- Đỉnh đầu: ưu tiên khung mặt, sau đó suy từ nhân trắc ---
        var headTopY: Double?
        if let f = face {
            headTopY = 1.0 - Double(f.boundingBox.maxY)
        } else if let nose = nose, let hips = hips {
            headTopY = nose.y - 0.62 * abs(neck.y - hips.y) * 0.42
        } else if let nose = nose {
            headTopY = nose.y - 0.10
        }

        // --- Tay che mặt (đề xuất bổ sung #3 tài liệu) ---
        if let f = face {
            let faceBox = f.boundingBox.insetBy(dx: -f.boundingBox.width * 0.15,
                                                dy: -f.boundingBox.height * 0.15)
            func wristInFace(_ w: SIMD2<Double>?) -> Bool {
                guard let w = w else { return false }
                let pt = CGPoint(x: w.x, y: 1.0 - w.y)   // về lại gốc dưới-trái của boundingBox
                return faceBox.contains(pt)
            }
            m.handNearFace = wristInFace(lWrist) || wristInFace(rWrist)
        }

        // --- Tâm chủ thể (mục 5) ---
        let cls = framing ?? .full
        switch cls.centerAnchor {
        case .torsoCenter:
            if let hips = hips { let c = (neck + hips) / 2; m.centerX = c.x; m.centerY = c.y }
            else { m.centerX = neck.x; m.centerY = neck.y }
        case .shoulderCenter:
            m.centerX = neck.x; m.centerY = neck.y
        case .faceCenter:
            if let f = face {
                m.centerX = Double(f.boundingBox.midX)
                m.centerY = 1.0 - Double(f.boundingBox.midY)
            } else { m.centerX = neck.x; m.centerY = neck.y }
        }

        // Cập nhật mốc khoá chủ thể cho frame kế tiếp.
        if let cx = m.centerX, let cy = m.centerY { lockedCenter = SIMD2(cx, cy) }

        // --- Tỉ lệ chủ thể (mục 2) — DÙNG ĐÚNG MỐC CỦA TEMPLATE ---
        switch cls.scaleAnchor {
        case .headToAnkle:
            if let top = headTopY, let a = [lAnk?.y, rAnk?.y].compactMap({ $0 }).max(), a > top {
                m.scaleValue = a - top
            }
        case .headToKnee:
            if let top = headTopY, let k = [lKnee?.y, rKnee?.y].compactMap({ $0 }).max(), k > top {
                m.scaleValue = k - top
            }
        case .headToHip:
            if let top = headTopY, let h = hips?.y, h > top { m.scaleValue = h - top }
        case .faceHeight:
            if let f = face { m.scaleValue = Double(f.boundingBox.height) }
            else { m.scaleValue = abs(ls.x - rs.x) * 0.55 }
        }

        // --- Hướng mẫu (mục 1) ---
        switch cls.yawSource {
        case .shoulderForeshortening:
            if let hips = hips {
                let W = abs(ls.x - rs.x), H = abs(neck.y - hips.y)
                if H > 0.02 {
                    let r = W / H
                    let rFront = 0.62
                    let ratio = min(max(r / rFront, 0), 1)
                    var absYaw = ratio >= 0.93 ? 0 : acos(ratio).deg
                    if let nose = nose, nose.x < neck.x { absYaw = -absYaw }
                    let seeingFront = ls.x > rs.x
                    m.bodyYawDeg = seeingFront ? absYaw
                        : (absYaw >= 0 ? 180 - abs(absYaw) : -180 + abs(absYaw))
                }
            }
        case .faceYaw:
            m.bodyYawDeg = m.faceYawDeg
        }

        // --- Góc nhìn tới điểm mốc (mục 3) ---
        var anchorY: Double?
        switch cls.elevationAnchor {
        case .midHip:   anchorY = hips?.y
        case .midTorso: anchorY = hips.map { (neck.y + $0.y) / 2 } ?? neck.y
        case .eyeLine:  anchorY = face.map { 1.0 - Double($0.boundingBox.midY) - 0.02 } ?? nose?.y
        }
        if let ay = anchorY { m.elevationDeg = (0.5 - ay) * 62.0 }   // 62° = vFOV tham chiếu

        // --- Dáng ---
        if let hips = hips { m.spineTiltDeg = atan2(neck.x - hips.x, abs(neck.y - hips.y)).deg }
        m.jointAngles = Self.jointAngles(pts: pts, minConf: cfg.minKeypointConfidence)

        // --- Khung chủ thể + kiểm cắt vào khớp ---
        let xs = [ls.x, rs.x, hips?.x, lAnk?.x, rAnk?.x].compactMap { $0 }
        let ys = [headTopY, ls.y, rs.y, hips?.y, lAnk?.y, rAnk?.y].compactMap { $0 }
        if let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() {
            m.subjectBox = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
        m.badCropJoint = Self.cutsAtJoint(pts: pts, framing: cls)

        return m
    }

    /// Chọn observation đúng chủ thể đã khoá: gần vị trí lần trước nhất; chưa
    /// có khoá thì chọn khung bao LỚN NHẤT (giả định người gần máy nhất/chính).
    private func pickSubject(from observations: [VNHumanBodyPoseObservation]) -> VNHumanBodyPoseObservation? {
        guard observations.count > 1 else { return observations.first }

        func center(_ obs: VNHumanBodyPoseObservation) -> SIMD2<Double>? {
            guard let pts = try? obs.recognizedPoints([.leftShoulder, .rightShoulder]),
                  let l = pts[.leftShoulder], let r = pts[.rightShoulder],
                  l.confidence >= cfg.minKeypointConfidence, r.confidence >= cfg.minKeypointConfidence
            else { return nil }
            return SIMD2((Double(l.location.x) + Double(r.location.x)) / 2,
                         1.0 - (Double(l.location.y) + Double(r.location.y)) / 2)
        }

        if let locked = lockedCenter {
            return observations.min { a, b in
                let da = center(a).map { length($0 - locked) } ?? .greatestFiniteMagnitude
                let db = center(b).map { length($0 - locked) } ?? .greatestFiniteMagnitude
                return da < db
            }
        }

        func boxArea(_ obs: VNHumanBodyPoseObservation) -> Double {
            guard let pts = try? obs.recognizedPoints(.all) else { return 0 }
            let xs = pts.values.filter { $0.confidence >= cfg.minKeypointConfidence }.map { Double($0.location.x) }
            let ys = pts.values.filter { $0.confidence >= cfg.minKeypointConfidence }.map { Double($0.location.y) }
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return 0 }
            return (x1 - x0) * (y1 - y0)
        }
        return observations.max { boxArea($0) < boxArea($1) }
    }

    // ---------------------------------------------------------------
    // Đo chất lượng ảnh
    // ---------------------------------------------------------------
    private func measureQuality(_ image: CGImage, into m: inout FrameMeasurement) {
        guard let gray = Self.grayscaleBuffer(image) else { return }
        defer { gray.data?.deallocate() }

        let box = m.subjectBox.insetBy(dx: -m.subjectBox.width * 0.1, dy: -m.subjectBox.height * 0.1)
        let roi = Self.clampROI(box, width: gray.width, height: gray.height)

        let (varLap, gx, gy) = Self.laplacianAndGradients(gray, roi: roi)
        m.sharpness = min(1.0, varLap / 900.0)

        let total = gx + gy
        m.motionBlur = total > 0 ? min(1.0, abs(gx - gy) / total) : 0

        let (clip, dark) = Self.exposureStats(gray, roi: roi)
        m.clippedHighlights = clip
        m.underExposed = dark

        let q = VNDetectFaceCaptureQualityRequest()
        try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([q])
        if let f = q.results?.first, let s = f.faceCaptureQuality {
            m.faceCaptureQuality = Double(s)
        }
    }

    // ---------------------------------------------------------------
    // Tiện ích tĩnh
    // ---------------------------------------------------------------

    static func inferPitchFromImage(_ m: FrameMeasurement) -> Double {
        guard let elev = m.elevationDeg else { return 0 }
        return elev
    }

    static func eyeOpenness(_ f: VNFaceObservation) -> Double? {
        guard let lm = f.landmarks,
              let le = lm.leftEye?.normalizedPoints,
              let re = lm.rightEye?.normalizedPoints,
              le.count > 3, re.count > 3 else { return nil }
        func ear(_ pts: [CGPoint]) -> Double {
            let xs = pts.map { $0.x }, ys = pts.map { $0.y }
            let w = (xs.max()! - xs.min()!), h = (ys.max()! - ys.min()!)
            return w > 0 ? Double(h / w) : 0
        }
        let v = (ear(le) + ear(re)) / 2
        return min(1.0, max(0, (v - 0.12) / 0.20))
    }

    static func cutsAtJoint(pts: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
                            framing: FramingClass) -> Bool {
        let risky: [VNHumanBodyPoseObservation.JointName] = [
            .leftAnkle, .rightAnkle, .leftKnee, .rightKnee, .leftWrist, .rightWrist
        ]
        for j in risky {
            guard let q = pts[j], q.confidence >= 0.3 else { continue }
            let y = 1.0 - Double(q.location.y)
            if y > 0.93 && y < 1.02 { return true }
        }
        return false
    }

    static func jointAngles(pts: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
                            minConf: Float) -> [String: Double] {
        func p(_ n: VNHumanBodyPoseObservation.JointName) -> SIMD2<Double>? {
            guard let q = pts[n], q.confidence >= minConf else { return nil }
            return SIMD2(Double(q.location.x), 1.0 - Double(q.location.y))
        }
        func ang(_ a: SIMD2<Double>?, _ v: SIMD2<Double>?, _ b: SIMD2<Double>?) -> Double? {
            guard let a = a, let v = v, let b = b else { return nil }
            let u = a - v, w = b - v
            let d = length(u) * length(w)
            guard d > 1e-6 else { return nil }
            return acos(min(max(dot(u, w) / d, -1), 1)).deg
        }
        var out: [String: Double] = [:]
        out["leftElbow"]     = ang(p(.leftShoulder), p(.leftElbow), p(.leftWrist))
        out["rightElbow"]    = ang(p(.rightShoulder), p(.rightElbow), p(.rightWrist))
        out["leftShoulder"]  = ang(p(.leftElbow), p(.leftShoulder), p(.leftHip))
        out["rightShoulder"] = ang(p(.rightElbow), p(.rightShoulder), p(.rightHip))
        out["leftKnee"]      = ang(p(.leftHip), p(.leftKnee), p(.leftAnkle))
        out["rightKnee"]     = ang(p(.rightHip), p(.rightKnee), p(.rightAnkle))
        return out.compactMapValues { $0 }
    }

    // --- vImage helpers ---
    struct GrayBuffer { var data: UnsafeMutableRawPointer?; var width: Int; var height: Int; var rowBytes: Int }

    static func grayscaleBuffer(_ image: CGImage) -> GrayBuffer? {
        let w = image.width, h = image.height
        let rowBytes = w
        guard let data = malloc(rowBytes * h) else { return nil }
        guard let cs = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(data: data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: rowBytes, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            free(data); return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return GrayBuffer(data: data, width: w, height: h, rowBytes: rowBytes)
    }

    static func clampROI(_ box: CGRect, width: Int, height: Int) -> (Int, Int, Int, Int) {
        let x0 = max(0, Int(box.minX * CGFloat(width)))
        let y0 = max(0, Int(box.minY * CGFloat(height)))
        let x1 = min(width  - 1, Int(box.maxX * CGFloat(width)))
        let y1 = min(height - 1, Int(box.maxY * CGFloat(height)))
        if x1 <= x0 + 4 || y1 <= y0 + 4 { return (0, 0, width - 1, height - 1) }
        return (x0, y0, x1, y1)
    }

    static func laplacianAndGradients(_ g: GrayBuffer, roi: (Int, Int, Int, Int)) -> (Double, Double, Double) {
        guard let base = g.data?.assumingMemoryBound(to: UInt8.self) else { return (0, 0, 0) }
        let (x0, y0, x1, y1) = roi
        var sum = 0.0, sumSq = 0.0, n = 0.0
        var gx = 0.0, gy = 0.0
        for y in stride(from: y0 + 1, to: y1, by: 2) {
            for x in stride(from: x0 + 1, to: x1, by: 2) {
                let i = y * g.rowBytes + x
                let c = Double(base[i])
                let l = Double(base[i - 1]), r = Double(base[i + 1])
                let u = Double(base[i - g.rowBytes]), d = Double(base[i + g.rowBytes])
                let lap = l + r + u + d - 4 * c
                sum += lap; sumSq += lap * lap; n += 1
                gx += abs(r - l); gy += abs(d - u)
            }
        }
        guard n > 1 else { return (0, 0, 0) }
        let mean = sum / n
        return (sumSq / n - mean * mean, gx, gy)
    }

    static func exposureStats(_ g: GrayBuffer, roi: (Int, Int, Int, Int)) -> (Double, Double) {
        guard let base = g.data?.assumingMemoryBound(to: UInt8.self) else { return (0, 0) }
        let (x0, y0, x1, y1) = roi
        var clipped = 0.0, dark = 0.0, n = 0.0
        for y in stride(from: y0, through: y1, by: 2) {
            for x in stride(from: x0, through: x1, by: 2) {
                let v = base[y * g.rowBytes + x]
                if v >= 250 { clipped += 1 }
                if v <= 12 { dark += 1 }
                n += 1
            }
        }
        guard n > 0 else { return (0, 0) }
        return (clipped / n, dark / n)
    }
}

// =====================================================================
// MARK: - 5. CHẤM ĐIỂM
// =====================================================================

struct FrameScore {
    var total: Double = 0
    var geometry: Double = 0
    var quality: Double = 0
    var pose: Double = 0
    var breakdown: [String: Double] = [:]
    var rejected: String?
}

final class FrameScorer {

    private let cfg: SelectionConfig
    init(config: SelectionConfig) { self.cfg = config }

    private func sim(_ delta: Double, _ tolerance: Double) -> Double {
        guard tolerance > 0 else { return 1 }
        return max(0, 1 - abs(delta) / tolerance)
    }

    private func geometryWeights(_ f: FramingClass) -> [String: Double] {
        switch f {
        case .full, .knee:
            return ["yaw": 0.26, "elevation": 0.24, "pitch": 0.20, "scale": 0.16, "center": 0.14]
        case .half:
            return ["yaw": 0.24, "elevation": 0.22, "pitch": 0.20, "scale": 0.19, "center": 0.15]
        case .chest, .head:
            return ["yaw": 0.22, "elevation": 0.20, "pitch": 0.16, "scale": 0.24, "center": 0.18]
        }
    }

    func score(_ m: FrameMeasurement, _ t: TemplateProfile) -> FrameScore {
        var s = FrameScore()

        // --- Loại thẳng ---
        if !m.hasSubject { s.rejected = "không thấy người"; return s }
        if m.sharpness < cfg.minSharpness { s.rejected = "quá mờ"; return s }
        if m.clippedHighlights > cfg.maxClippedHighlightRatio { s.rejected = "cháy sáng"; return s }
        if let e = m.eyesOpen, e < 0.20 { s.rejected = "nhắm mắt"; return s }
        if let speed = m.angularSpeedDegPerSec, speed > cfg.maxAngularSpeedDegPerSec {
            s.rejected = "máy đang di chuyển"; return s
        }

        // --- 1. Hình học (0.55) ---
        let gw = geometryWeights(t.framing)
        var g = 0.0, gTotalWeight = 0.0

        if let v = m.bodyYawDeg {
            let tol = t.framing.yawSource == .faceYaw ? cfg.toleranceFaceYawDeg : cfg.toleranceBodyYawDeg
            let x = sim(signedDelta(v, t.bodyYawDeg), tol)
            g += gw["yaw"]! * x; gTotalWeight += gw["yaw"]!
            s.breakdown["yaw"] = x
        }
        if let v = m.elevationDeg {
            let x = sim(v - t.elevationDeg, cfg.toleranceElevationDeg)
            g += gw["elevation"]! * x; gTotalWeight += gw["elevation"]!
            s.breakdown["elevation"] = x
        }
        if let v = m.cameraPitchDeg {
            let x = sim(v - t.cameraPitchDeg, cfg.tolerancePitchDeg)
            g += gw["pitch"]! * x; gTotalWeight += gw["pitch"]!
            s.breakdown["pitch"] = x
        }
        if let v = m.scaleValue, t.scaleValue > 0 {
            let x = sim(v / t.scaleValue - 1.0, cfg.toleranceScale)
            g += gw["scale"]! * x; gTotalWeight += gw["scale"]!
            s.breakdown["scale"] = x
        }
        if let v = m.centerX {
            let x = sim(v - t.centerX, cfg.toleranceCenter)
            g += gw["center"]! * x; gTotalWeight += gw["center"]!
            s.breakdown["center"] = x
        }
        s.geometry = gTotalWeight > 0 ? g / gTotalWeight : 0

        // --- 2. Chất lượng (0.35) ---
        var q = 0.0, qw = 0.0
        q += 0.34 * m.sharpness;                 qw += 0.34
        q += 0.22 * (1 - m.motionBlur);          qw += 0.22
        q += 0.16 * (1 - min(1, m.clippedHighlights / cfg.maxClippedHighlightRatio)); qw += 0.16
        q += 0.08 * (1 - min(1, m.underExposed / 0.30)); qw += 0.08
        if let fq = m.faceCaptureQuality { q += 0.14 * fq; qw += 0.14 }
        if let eo = m.eyesOpen           { q += 0.06 * eo; qw += 0.06 }
        s.quality = qw > 0 ? q / qw : 0
        if m.badCropJoint { s.quality *= 0.80 }

        // --- 3. Dáng (0.10) — để cuối, user tự do tạo dáng ---
        var pTotal = 0.0, pCount = 0.0
        for group in t.framing.poseGroups {
            switch group {
            case .spine:
                if let v = m.spineTiltDeg {
                    pTotal += sim(v - t.spineTiltDeg, cfg.toleranceSpineDeg); pCount += 1
                }
            case .head:
                if let v = m.headPitchDeg, let tv = t.headPitchDeg {
                    pTotal += sim(v - tv, cfg.toleranceJointDeg); pCount += 1
                }
            case .arms:
                for k in ["leftElbow", "rightElbow", "leftShoulder", "rightShoulder"] {
                    if let v = m.jointAngles[k], let tv = t.jointAngles[k] {
                        pTotal += sim(v - tv, cfg.toleranceJointDeg); pCount += 1
                    }
                }
            case .legs:
                for k in ["leftKnee", "rightKnee"] {
                    if let v = m.jointAngles[k], let tv = t.jointAngles[k] {
                        pTotal += sim(v - tv, cfg.toleranceJointDeg); pCount += 1
                    }
                }
            }
        }
        s.pose = pCount > 0 ? pTotal / pCount : 0.5
        // Tay che mặt mà mẫu KHÔNG che (đề xuất bổ sung #3 tài liệu) — trừ điểm dáng.
        if m.handNearFace && !t.handNearFace { s.pose *= 0.7 }

        s.total = cfg.weightGeometry * s.geometry
                + cfg.weightQuality  * s.quality
                + cfg.weightPose     * s.pose
        return s
    }
}

// =====================================================================
// MARK: - 6. TRÍCH FRAME TỪ VIDEO
// =====================================================================

final class VideoFrameExtractor {

    private let cfg: SelectionConfig
    init(config: SelectionConfig) { self.cfg = config }

    struct ExtractedFrame { let time: Double; let image: CGImage }

    func extract(from url: URL) async throws -> [ExtractedFrame] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { return [] }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: cfg.analysisMaxDimension, height: cfg.analysisMaxDimension)

        var times: [CMTime] = []
        var t = 0.0
        while t < duration {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += cfg.extractInterval
        }

        var out: [ExtractedFrame] = []
        for await result in gen.images(for: times) {
            if case .success(let img, let requested, _) = result {
                out.append(ExtractedFrame(time: requested.seconds, image: img))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    func fullResolutionFrame(from url: URL, at time: Double) async throws -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        return try await gen.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }
}

// =====================================================================
// MARK: - 7. BỘ CHỌN — ghép tất cả
// =====================================================================

struct SelectedShot: Identifiable {
    let id = UUID()
    let time: Double
    let score: FrameScore
    let image: CGImage
}

/// Một mẫu tốc độ góc tại 1 thời điểm — đề xuất bổ sung #2 tài liệu ("Loại
/// frame chụp trong lúc máy đang di chuyển"). Nơi gọi (CameraManager) ghi log
/// này song song lúc quay, đồng bộ theo `CACurrentMediaTime()`.
struct AngularSpeedSample { let time: Double; let degPerSec: Double }

final class BestShotSelector {

    private let cfg: SelectionConfig
    private let measurer: FrameMeasurer
    private let scorer: FrameScorer
    private let extractor: VideoFrameExtractor

    init(config: SelectionConfig = .default) {
        self.cfg = config
        self.measurer = FrameMeasurer(config: config)
        self.scorer = FrameScorer(config: config)
        self.extractor = VideoFrameExtractor(config: config)
    }

    /// Toàn bộ quy trình.
    /// - Parameter angularSpeedLog: mẫu tốc độ góc ghi song song lúc quay (tuỳ
    ///   chọn). Nếu có, frame nào rơi vào lúc máy rung > `maxAngularSpeedDegPerSec`
    ///   bị loại thẳng thay vì đoán nhoè từ ảnh — chính xác hơn nhiều.
    func selectBestShots(videoURL: URL,
                         templateImage: CGImage,
                         angularSpeedLog: [AngularSpeedSample] = [],
                         progress: ((Double, String) -> Void)? = nil) async throws -> [SelectedShot] {

        // B1. Phân tích ảnh mẫu → biết LỚP KHUNG HÌNH và mọi mốc đo
        progress?(0.05, "Đang phân tích ảnh mẫu")
        guard let template = measurer.analyzeTemplate(templateImage) else { return [] }

        // B2. Trích frame theo interval
        progress?(0.15, "Đang tách frame")
        let frames = try await extractor.extract(from: videoURL)
        guard !frames.isEmpty else { return [] }

        // B3. Vòng lọc thô — loại frame hỏng, giữ shortlist
        progress?(0.35, "Loại ảnh mờ, nhắm mắt, rung máy")
        measurer.resetLock()
        var measured: [(FrameMeasurement, FrameScore)] = []
        for f in frames {
            guard var m = measurer.measure(f.image, time: f.time, framing: template.framing) else { continue }
            m.angularSpeedDegPerSec = Self.nearestAngularSpeed(at: f.time, in: angularSpeedLog)
            let s = scorer.score(m, template)
            if s.rejected == nil { measured.append((m, s)) }
        }
        guard !measured.isEmpty else { return [] }

        let shortlist = measured
            .sorted { $0.1.total > $1.1.total }
            .prefix(cfg.shortlistCount)

        // B4. Chọn theo điểm + ràng buộc đa dạng
        progress?(0.70, "Chọn ảnh khớp mẫu nhất")
        var picked: [(FrameMeasurement, FrameScore)] = []
        for cand in shortlist {
            if picked.count >= cfg.outputCount { break }
            let tooClose = picked.contains { p in
                abs(p.0.time - cand.0.time) < cfg.minTimeGapSeconds
                && poseDistance(p.0, cand.0) < cfg.minPoseDistance
            }
            if !tooClose { picked.append(cand) }
        }
        if picked.count < cfg.outputCount {
            for cand in shortlist where picked.count < cfg.outputCount {
                if !picked.contains(where: { $0.0.time == cand.0.time }) { picked.append(cand) }
            }
        }

        // B5. Lấy ảnh gốc + cắt về bố cục mẫu
        progress?(0.85, "Cắt về bố cục mẫu")
        var out: [SelectedShot] = []
        for (m, s) in picked {
            guard var img = try await extractor.fullResolutionFrame(from: videoURL, at: m.time) else { continue }
            if cfg.autoCropToTemplate, let cropped = cropToTemplate(img, m: m, t: template) {
                img = cropped
            }
            out.append(SelectedShot(time: m.time, score: s, image: img))
        }
        progress?(1.0, "Xong")
        return out.sorted { $0.score.total > $1.score.total }
    }

    private func poseDistance(_ a: FrameMeasurement, _ b: FrameMeasurement) -> Double {
        var sum = 0.0, n = 0.0
        for (k, v) in a.jointAngles {
            if let w = b.jointAngles[k] { sum += abs(v - w) / 180.0; n += 1 }
        }
        if let x = a.centerX, let y = b.centerX { sum += abs(x - y) * 2; n += 1 }
        return n > 0 ? sum / n : 1
    }

    private func cropToTemplate(_ image: CGImage, m: FrameMeasurement, t: TemplateProfile) -> CGImage? {
        guard let scale = m.scaleValue, scale > 0, let cx = m.centerX, let cy = m.centerY else { return nil }
        let zoom = scale / t.scaleValue
        guard zoom > 1.0 else { return nil }
        let cropRatio = min(1 - 1 / zoom, cfg.maxCropRatio)
        let w = Double(image.width)  * (1 - cropRatio)
        let h = Double(image.height) * (1 - cropRatio)
        var x = cx * Double(image.width)  - t.centerX * w
        var y = cy * Double(image.height) - t.centerY * h
        x = min(max(0, x), Double(image.width) - w)
        y = min(max(0, y), Double(image.height) - h)
        return image.cropping(to: CGRect(x: x, y: y, width: w, height: h))
    }

    /// Mẫu tốc độ góc gần thời điểm `time` nhất trong log — log ghi liên tục
    /// khi quay nên tra tuyến tính là đủ nhanh cho một clip vài chục giây.
    private static func nearestAngularSpeed(at time: Double, in log: [AngularSpeedSample]) -> Double? {
        guard !log.isEmpty else { return nil }
        return log.min(by: { abs($0.time - time) < abs($1.time - time) })?.degPerSec
    }
}

// =====================================================================
// MARK: - 8. GIAO DIỆN SwiftUI (tuỳ chọn — dùng để debug/thử độc lập)
// =====================================================================

@MainActor
final class BestShotViewModel: ObservableObject {
    @Published var config = SelectionConfig.default
    @Published var shots: [SelectedShot] = []
    @Published var isWorking = false
    @Published var progress: Double = 0
    @Published var stage = ""

    func run(videoURL: URL, templateImage: CGImage) async {
        isWorking = true; shots = []; progress = 0
        let selector = BestShotSelector(config: config)
        do {
            let result = try await selector.selectBestShots(
                videoURL: videoURL, templateImage: templateImage
            ) { [weak self] p, s in
                Task { @MainActor in self?.progress = p; self?.stage = s }
            }
            shots = result
        } catch {
            stage = "Lỗi: \(error.localizedDescription)"
        }
        isWorking = false
    }
}

struct BestShotView: View {
    @StateObject private var vm = BestShotViewModel()
    let videoURL: URL
    let templateImage: CGImage

    private let intervals: [Double] = [0.10, 0.15, 0.20, 0.30, 0.50]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Tách frame mỗi")
                Picker("", selection: $vm.config.extractInterval) {
                    ForEach(intervals, id: \.self) { Text(String(format: "%.2fs", $0)).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            HStack {
                Text("Số ảnh")
                Stepper("\(vm.config.outputCount)", value: $vm.config.outputCount, in: 1...10)
            }
            if vm.isWorking {
                ProgressView(value: vm.progress) { Text(vm.stage) }
            } else {
                Button("Chọn ảnh đẹp nhất") {
                    Task { await vm.run(videoURL: videoURL, templateImage: templateImage) }
                }
                .buttonStyle(.borderedProminent)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(vm.shots) { shot in
                        VStack(alignment: .leading, spacing: 4) {
                            Image(decorative: shot.image, scale: 1)
                                .resizable().scaledToFit().frame(height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            Text(String(format: "Khớp %.0f%%", shot.score.total * 100))
                                .font(.caption)
                            Text(String(format: "hình học %.0f · nét %.0f · dáng %.0f",
                                        shot.score.geometry * 100,
                                        shot.score.quality * 100,
                                        shot.score.pose * 100))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
    }
}

// =====================================================================
// MARK: - Tiện ích
// =====================================================================

extension Double {
    var rad: Double { self * .pi / 180 }
    var deg: Double { self * 180 / .pi }
}

func signedDelta(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}
