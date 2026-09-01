//
//  GuidanceEngine.swift  — v3 (phân lớp khung hình)
//  Thuật toán kiểm 6 tiêu chí và sinh cue hướng dẫn realtime.
//
//  Nguồn thiết kế:
//    - GuidanceEngineV2.txt / NGUONG_VA_GOC_QUY_CHIEU.md — 7 nguyên nhân cue rung
//      (bucket, attitude.pitch, giả định chiều cao, acos gần chính diện, thiếu
//      debounce, không làm tròn số, không có sàn hành động) + cảnh báo
//      visionOrientation. TẤT CẢ giữ nguyên ở bản này.
//    - PoseCoach_Phan_Lop_Khung_Hinh_V3.docx ("verify tài liệu v2") — phát hiện
//      NGUYÊN NHÂN THỨ 8, nguyên nhân duy nhất khiến cue KHÔNG BAO GIỜ tắt được:
//      các bản trước tự chọn "mốc tốt nhất còn đo được" trên frame live, trong
//      khi ảnh mẫu lại dùng mốc khác. Sửa bằng FramingClass.swift — mốc đo suy
//      MỘT LẦN từ ảnh mẫu, áp nguyên xi cho mọi frame sau. Đồng thời: mục 3 đổi
//      từ "đơn vị chiều cao mẫu" sang GÓC NHÌN (độ) — universal mọi lớp, không
//      cần biết chiều cao thật; mục 1 dùng face yaw khi hông khuất (chân dung);
//      ngưỡng & sàn hành động tách riêng theo từng lớp.
//
//  ⚠️ CHƯA ĐO TRÊN MÁY THẬT (xem mục 9 tài liệu verify-v3). Các con số actionFloor
//  không được tài liệu cho trực tiếp (mục 1,3,4,5,6) được suy từ đúng tỉ lệ
//  accept:actionFloor mà v2 đã dùng — coi là giá trị khởi điểm, PHẢI đo lại độ
//  lệch chuẩn thật cho cả 5 lớp trước khi chốt số (accept ≥ 3× độ lệch chuẩn).
//  Chiều dấu của cue mục 3 (nâng/hạ) được suy từ hình học, cũng CẦN kiểm trên
//  máy thật — nếu cue chỉ sai chiều, xem ghi chú tại `CueFactory.cameraElevation`.
//

import Vision
import CoreMotion
import AVFoundation
import QuartzCore
import ImageIO
import simd

// =====================================================================
// MARK: - 0. NGƯỠNG THEO TỪNG LỚP  ***SỬA MỌI THỨ Ở ĐÂY***
// =====================================================================

/// Một dải ngưỡng cho 1 tiêu chí. |err| <= accept → ĐẠT (im lặng).
/// accept < |err| <= accept×enterFactor → vùng xám (giữ nguyên trạng thái).
/// |err| > accept×enterFactor → VI PHẠM. |err| > accept×unlockFactor → mở khoá
/// mục đã đạt. action < actionFloor → im lặng dù |err| vượt ngưỡng (lượng phải
/// sửa quá nhỏ, người thật không làm nổi).
struct ThresholdBand {
    var accept: Double
    var enterFactor: Double = 1.5
    var unlockFactor: Double = 3.0
    var actionFloor: Double = 0

    var enter: Double { accept * enterFactor }
    var unlock: Double { accept * unlockFactor }
}

/// Ngưỡng cho cả 6 tiêu chí, riêng cho MỘT lớp khung hình.
struct ClassThresholds {
    var bodyYaw: ThresholdBand
    var distance: ThresholdBand      // accept = tỉ lệ (vd 0.10 = 10%); actionFloor = MÉT
    var elevation: ThresholdBand     // độ — góc nhìn máy tới mốc của lớp (mục 3)
    var pitch: ThresholdBand         // độ — góc trục ống kính (mục 4)
    var horizontal: ThresholdBand    // phần bề ngang khung
    var spineTilt: ThresholdBand
    var jointAngle: ThresholdBand
    var headYaw: ThresholdBand
}

struct GuidanceConfig {

    /// Vùng chết chính diện: r/rFront >= số này thì coi bodyYaw = 0. acos gần 0°
    /// có đạo hàm → vô cực, nhiễu 2% ở r biến thành 12° ở yaw.
    var bodyYawFrontalDeadZone: Double = 0.93
    /// Chiều cao thân tối thiểu (phần khung) mới tin công thức vai/thân.
    var bodyYawMinTorsoHeight: Double = 0.08
    /// Hiệu chuẩn mặc định khi mẫu chính diện (median thật cần đo với ≥5 người,
    /// gồm người mặc áo rộng — xem mục 9 tài liệu verify-v3).
    var rFrontDefault: Double = 0.62

    /// FOV dọc tham chiếu dùng để ước lượng elevationDeg của ẢNH MẪU tĩnh —
    /// không có IMU tại thời điểm chụp mẫu nên không biết FOV thật của máy đã
    /// chụp ảnh đó. Live dùng CameraOptics.vFovDeg đo thật, chính xác hơn.
    var referenceVFOVDegrees: Double = 62.0

    // -----------------------------------------------------------------
    // CHẤT LƯỢNG SỐ ĐO — dưới ngưỡng này thì KHÔNG ĐO ĐƯỢC (loại mục ra),
    // KHÔNG phải "sai".
    // -----------------------------------------------------------------
    var minKeypointConfidenceCore: Float = 0.50   // vai, hông
    var minKeypointConfidenceLimb: Float = 0.40   // khuỷu, cổ tay, gối, cổ chân
    var minValidFramesBeforeUse: Int = 3
    var faceCacheSeconds: Double = 0.6

    // -----------------------------------------------------------------
    // THỜI GIAN — chống nháy cue (dùng chung cho mọi lớp, v2 không nói cần
    // tách theo lớp cho phần này)
    // -----------------------------------------------------------------
    var cueEnterHoldSeconds: Double = 0.45
    var cueExitHoldSeconds: Double = 0.20
    var cueMinDisplaySeconds: Double = 1.20
    var cueNumberRefreshSeconds: Double = 1.00

    var quantizeDegrees: Double = 5
    var quantizeCentimeters: Double = 5

    // -----------------------------------------------------------------
    // CỔNG CHỤP
    // -----------------------------------------------------------------
    var dwellSeconds: Double = 0.80
    var countdownSeconds: Double = 3.00
    var countdownGraceSeconds: Double = 1.00
    var maxAngularSpeedDegPerSec: Double = 15
    var freezeCueAngularSpeedDegPerSec: Double = 45
    var stallTimeoutSeconds: Double = 2.50

    // -----------------------------------------------------------------
    // NHỊP XỬ LÝ (mốc iPhone 11)
    // -----------------------------------------------------------------
    var poseEveryNFrames: Int = 2
    var faceEveryNFrames: Int = 8
    /// CHỈ để đổi % → "bước" trong câu chữ mục 2. Không dùng để so ngưỡng.
    var assumedBodyHeightMeters: Double = 1.70

    /// ***PHẢI KIỂM TRÊN MÁY THẬT.*** Buffer AVCapture là LANDSCAPE theo cảm
    /// biến; cầm dọc + camera sau ⇒ `.right`. Đây chỉ là giá trị THAM KHẢO cho
    /// test — nơi gọi (CameraManager) vẫn tự tính theo camera trước/sau vì
    /// hướng cầm máy đổi liên tục, không cố định như tài liệu gốc giả định.
    var visionOrientation: CGImagePropertyOrientation = .right

    // -----------------------------------------------------------------
    // NGƯỠNG THEO LỚP — bảng lõi từ PoseCoach_Phan_Lop_Khung_Hinh_V3.docx §5.
    // actionFloor không được tài liệu cho trực tiếp (trừ mục 2) được suy từ
    // đúng tỉ lệ accept:actionFloor mà v2 đã dùng cho lớp toàn thân.
    // -----------------------------------------------------------------
    var perClass: [FramingClass: ClassThresholds] = GuidanceConfig.defaultClassThresholds()

    func thresholds(for cls: FramingClass) -> ClassThresholds {
        perClass[cls] ?? GuidanceConfig.defaultClassThresholds()[.full]!
    }

    static let `default` = GuidanceConfig()

    static func defaultClassThresholds() -> [FramingClass: ClassThresholds] {
        let fullKnee = ClassThresholds(
            bodyYaw:    ThresholdBand(accept: 30, enterFactor: 1.4, unlockFactor: 2.5, actionFloor: 15),
            distance:   ThresholdBand(accept: 0.10, actionFloor: 0.35),
            elevation:  ThresholdBand(accept: 6, actionFloor: 4),
            pitch:      ThresholdBand(accept: 5, actionFloor: 4),
            horizontal: ThresholdBand(accept: 0.05, actionFloor: 0.02),
            spineTilt:  ThresholdBand(accept: 10, actionFloor: 8),
            jointAngle: ThresholdBand(accept: 15, actionFloor: 12),
            headYaw:    ThresholdBand(accept: 25, enterFactor: 1.4, actionFloor: 15)
        )
        let half = ClassThresholds(
            bodyYaw:    ThresholdBand(accept: 30, enterFactor: 1.4, unlockFactor: 2.5, actionFloor: 15),
            distance:   ThresholdBand(accept: 0.10, actionFloor: 0.30),
            elevation:  ThresholdBand(accept: 6, actionFloor: 4),
            pitch:      ThresholdBand(accept: 5, actionFloor: 4),
            horizontal: ThresholdBand(accept: 0.05, actionFloor: 0.02),
            spineTilt:  ThresholdBand(accept: 10, actionFloor: 8),
            jointAngle: ThresholdBand(accept: 15, actionFloor: 12),
            headYaw:    ThresholdBand(accept: 25, enterFactor: 1.4, actionFloor: 15)
        )
        let chest = ClassThresholds(
            bodyYaw:    ThresholdBand(accept: 20, enterFactor: 1.4, unlockFactor: 2.5, actionFloor: 10),
            distance:   ThresholdBand(accept: 0.08, actionFloor: 0.12),
            elevation:  ThresholdBand(accept: 4, actionFloor: 2.7),
            pitch:      ThresholdBand(accept: 4, actionFloor: 3.2),
            horizontal: ThresholdBand(accept: 0.04, actionFloor: 0.016),
            spineTilt:  ThresholdBand(accept: 12, actionFloor: 9.6),
            jointAngle: ThresholdBand(accept: 18, actionFloor: 14.4),
            headYaw:    ThresholdBand(accept: 15, enterFactor: 1.4, actionFloor: 9)
        )
        let head = ClassThresholds(
            bodyYaw:    ThresholdBand(accept: 15, enterFactor: 1.4, unlockFactor: 2.5, actionFloor: 7.5),
            distance:   ThresholdBand(accept: 0.06, actionFloor: 0.08),
            elevation:  ThresholdBand(accept: 3, actionFloor: 2.0),
            pitch:      ThresholdBand(accept: 3, actionFloor: 2.4),
            horizontal: ThresholdBand(accept: 0.03, actionFloor: 0.012),
            spineTilt:  ThresholdBand(accept: 12, actionFloor: 9.6),   // không dùng (head không có nhóm spine)
            jointAngle: ThresholdBand(accept: 18, actionFloor: 14.4),  // không dùng (head không có nhóm arms/legs)
            headYaw:    ThresholdBand(accept: 10, enterFactor: 1.4, actionFloor: 6)
        )
        return [.full: fullKnee, .knee: fullKnee, .half: half, .chest: chest, .head: head]
    }
}

// =====================================================================
// MARK: - 1. KIỂU DỮ LIỆU
// =====================================================================

enum LensKind { case ultraWide, wide }

enum Criterion: Int, CaseIterable {
    case bodyYaw      = 1
    case distance     = 2
    case elevation    = 3
    case pitch        = 4
    case horizontal   = 5
    case pose         = 6

    var title: String {
        switch self {
        case .bodyYaw:    return "Hướng mẫu"
        case .distance:   return "Xa/gần"
        case .elevation:  return "Máy cao/thấp"
        case .pitch:      return "Ngửa/chúc"
        case .horizontal: return "Trái/phải"
        case .pose:       return "Dáng"
        }
    }
    var actor: Violation.Actor {
        switch self {
        case .bodyYaw, .pose: return .model
        default:              return .shooter
        }
    }
}

enum JointName: String, CaseIterable {
    case leftElbow, rightElbow, leftShoulder, rightShoulder, leftKnee, rightKnee
}

/// Template đã phân tích sẵn từ ảnh mẫu (xem TemplateAnalyzer.swift). `framing`
/// quyết định mốc đo — mọi frame live/video sau đó PHẢI dùng đúng mốc này.
struct Template {
    let framing: FramingClass

    let bodyYawDeg: Double            // 0 = mẫu quay thẳng mặt vào máy, ±180 = quay lưng
    let scaleValue: Double            // giá trị theo framing.scaleAnchor (0...1 phần khung)
    let centerX: Double               // 0 = mép trái, 1 = mép phải (theo framing.centerAnchor)
    let centerY: Double
    let elevationDeg: Double          // góc nhìn máy tới framing.elevationAnchor (độ)
    let cameraPitchDeg: Double        // ước lượng — ảnh mẫu tĩnh không có IMU, coi ~0

    let jointAngles: [JointName: Double]
    let spineTiltDeg: Double
    let headYawDeg: Double?           // nil nếu không thấy mặt

    let lens: LensKind
    /// Câu nhắc dáng soạn sẵn (giọng tự nhiên).
    let cueForModel: String
}

/// Thông số quang học camera đang dùng.
struct CameraOptics {
    let hFovDeg: Double
    let vFovDeg: Double
    let focalPixels: Double
    let imageWidthPixels: Double
    let imageHeightPixels: Double

    init(hFovDeg: Double, vFovDeg: Double, focalPixels: Double,
         imageWidthPixels: Double, imageHeightPixels: Double) {
        self.hFovDeg = hFovDeg
        self.vFovDeg = vFovDeg
        self.focalPixels = focalPixels
        self.imageWidthPixels = imageWidthPixels
        self.imageHeightPixels = imageHeightPixels
    }

    /// Chính xác nhất: từ intrinsicMatrix của sample buffer (cần bật
    /// `connection.isCameraIntrinsicMatrixDeliveryEnabled = true`).
    init(intrinsics: matrix_float3x3, imageSize: CGSize) {
        let fx = Double(intrinsics[0][0])
        let fy = Double(intrinsics[1][1])
        self.imageWidthPixels  = Double(imageSize.width)
        self.imageHeightPixels = Double(imageSize.height)
        self.focalPixels = fy
        self.vFovDeg = 2 * atan(Double(imageSize.height) / 2 / fy).degrees
        self.hFovDeg = 2 * atan(Double(imageSize.width)  / 2 / fx).degrees
    }

    /// Fallback khi không có intrinsics. videoFieldOfView là FOV theo CHIỀU DÀI
    /// cảm biến — cầm dọc thì đó là chiều DỌC ảnh.
    init(device: AVCaptureDevice, imageSize: CGSize) {
        let fovLong = Double(device.activeFormat.videoFieldOfView)
        let shortSide = min(imageSize.width, imageSize.height)
        let longSide  = max(imageSize.width, imageSize.height)
        let fovShort = 2 * atan(tan(fovLong.radians / 2) * Double(shortSide / longSide)).degrees
        self.vFovDeg = fovLong
        self.hFovDeg = fovShort
        self.imageWidthPixels  = Double(imageSize.width)
        self.imageHeightPixels = Double(imageSize.height)
        self.focalPixels = (Double(imageSize.height) / 2) / tan(fovLong.radians / 2)
    }

    /// Góc lệch (độ) của một điểm so với tâm khung, theo chiều DỌC.
    /// Dương = điểm nằm phía TRÊN tâm khung (y < 0.5).
    func elevationOffsetDeg(normalizedY y: Double) -> Double {
        atan((0.5 - y) * imageHeightPixels / focalPixels).degrees
    }
    /// Tương tự theo chiều NGANG. Dương = phía phải tâm.
    func azimuthOffsetDeg(normalizedX x: Double) -> Double {
        atan((x - 0.5) * imageWidthPixels / focalPixels).degrees
    }
}

/// Kết quả đo trên 1 frame. nil = KHÔNG ĐO ĐƯỢC (khác "sai").
struct Measurement {
    var timestamp: Double = 0
    var hasSubject: Bool = false

    var bodyYawDeg: Double?
    var bodyYawIsFrontalFlat: Bool = false

    var scaleValue: Double?
    var centerX: Double?
    var centerY: Double?
    /// Góc nhìn (độ) từ máy tới mốc của lớp khung hình (mục 3). Xem
    /// `CameraOptics.elevationOffsetDeg` + `cameraPitchDeg` — độc lập với mục 4.
    var elevationDeg: Double?
    var cameraPitchDeg: Double = 0     // gốc = mặt phẳng ngang, từ vector trọng lực
    var rollDeg: Double = 0
    var angularSpeedDegPerSec: Double = 0

    var jointAngles: [JointName: Double] = [:]
    var spineTiltDeg: Double?
    var headYawDeg: Double?

    /// Toàn bộ keypoint thô (gốc dưới-trái của Vision) — vẽ skeleton overlay.
    var jointPoints: [VNHumanBodyPoseObservation.JointName: JointPoint] = [:]
}

/// A single detected body joint kept for display purposes.
struct JointPoint {
    let location: CGPoint
    let confidence: Float
}

struct Violation {
    enum Actor { case model, shooter }
    let criterion: Criterion
    let actor: Actor
    let error: Double
    let normalizedError: Double
    let detail: String
    let cue: String
}

struct GuidanceResult {
    let violations: [Violation]
    let passedCount: Int
    let readyToCapture: Bool
    let worstNormalizedError: Double
    let debug: [Criterion: String]

    var primaryCue: String?   { violations.first?.cue }
    var secondaryCue: String? { violations.count > 1 ? violations[1].cue : nil }
    var isAligned: Bool { violations.isEmpty }
}

// =====================================================================
// MARK: - 2. LỌC NHIỄU
// =====================================================================

final class OneEuroFilter {
    private var xPrev: Double?, dxPrev: Double = 0, tPrev: Double?
    private let minCutoff: Double, beta: Double, dCutoff: Double

    init(minCutoff: Double = 1.0, beta: Double = 0.015, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff; self.beta = beta; self.dCutoff = dCutoff
    }
    private func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1.0 / (2 * .pi * cutoff); return 1.0 / (1.0 + tau / dt)
    }
    func filter(_ x: Double, timestamp t: Double) -> Double {
        guard let xp = xPrev, let tp = tPrev, t > tp else { xPrev = x; tPrev = t; return x }
        let dt = t - tp
        let dx = (x - xp) / dt
        let dxHat = dxPrev + alpha(dCutoff, dt) * (dx - dxPrev)
        let cutoff = minCutoff + beta * abs(dxHat)
        let xHat = xp + alpha(cutoff, dt) * (x - xp)
        xPrev = xHat; dxPrev = dxHat; tPrev = t
        return xHat
    }
    func reset() { xPrev = nil; dxPrev = 0; tPrev = nil }
}

struct RollingMedian {
    private var buf: [Double] = []
    let size: Int
    init(size: Int = 5) { self.size = size }
    mutating func push(_ v: Double) -> Double {
        buf.append(v); if buf.count > size { buf.removeFirst() }
        return buf.sorted()[buf.count / 2]
    }
    mutating func reset() { buf.removeAll() }
}

// =====================================================================
// MARK: - 3. ĐO ĐẠC TỪ FRAME (Vision + CoreMotion)
// =====================================================================

final class Measurer {

    private let cfg: GuidanceConfig
    private let poseRequest = VNDetectHumanBodyPoseRequest()
    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3
        return r
    }()

    private var rFront: Double?
    private var rFrontSamples: [Double] = []

    private var lastFace: VNFaceObservation?
    private var lastFaceTime: Double = -1

    private var fShoulderRatio = OneEuroFilter(minCutoff: 0.8, beta: 0.010)
    private var fScale         = OneEuroFilter(minCutoff: 1.0, beta: 0.015)
    private var fCenterX       = OneEuroFilter(minCutoff: 1.0, beta: 0.020)
    private var fElevation     = OneEuroFilter(minCutoff: 1.0, beta: 0.015)
    private var fPitch         = OneEuroFilter(minCutoff: 1.2, beta: 0.010)
    private var mSpine         = RollingMedian(size: 5)

    private var validFrames = 0

    init(config: GuidanceConfig) { self.cfg = config }

    func reset() {
        rFront = nil; rFrontSamples.removeAll()
        lastFace = nil; lastFaceTime = -1
        validFrames = 0
        fShoulderRatio.reset(); fScale.reset(); fCenterX.reset()
        fElevation.reset(); fPitch.reset(); mSpine.reset()
    }

    /// Đo 1 frame LIVE (camera đang chạy) — có lọc mượt + IMU.
    func measure(pixelBuffer: CVPixelBuffer,
                 deviceMotion: CMDeviceMotion?,
                 optics: CameraOptics,
                 orientation: CGImagePropertyOrientation,
                 timestamp: Double,
                 framing: FramingClass,
                 runFace: Bool) -> Measurement {

        var m = Measurement(timestamp: timestamp)

        // ---------- Góc máy từ TRỌNG LỰC (không dùng attitude.pitch — bị
        // gimbal lock khi cầm máy dựng đứng, và phụ thuộc reference frame) ----------
        if let dm = deviceMotion {
            let g = dm.gravity
            let rawPitch = asin(max(-1, min(1, g.z))).degrees
            m.cameraPitchDeg = fPitch.filter(rawPitch, timestamp: timestamp)
            m.rollDeg = atan2(g.x, -g.y).degrees
            let rr = dm.rotationRate
            m.angularSpeedDegPerSec = sqrt(rr.x*rr.x + rr.y*rr.y + rr.z*rr.z).degrees
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        var requests: [VNRequest] = [poseRequest]
        if runFace { requests.append(faceRequest) }
        try? handler.perform(requests)

        if runFace, let f = faceRequest.results?.first { lastFace = f; lastFaceTime = timestamp }
        let face: VNFaceObservation? =
            (timestamp - lastFaceTime <= cfg.faceCacheSeconds) ? lastFace : nil

        guard let obs = poseRequest.results?.first,
              let pts = try? obs.recognizedPoints(.all) else {
            validFrames = 0
            return m
        }

        measureCore(pts: pts, face: face, framing: framing, timestamp: timestamp,
                    optics: optics, filtered: true, into: &m)
        return m
    }

    /// Phân tích ẢNH MẪU khi CHƯA BIẾT lớp khung hình: chạy Vision 1 lần, suy
    /// `FramingClass` từ khung bao chủ thể, rồi đo lại theo ĐÚNG mốc của lớp đó.
    /// Dùng cho `TemplateAnalyzer`.
    func analyzeStillWithFraming(cgImage: CGImage) -> (Measurement, FramingClass)? {
        let poseReq = VNDetectHumanBodyPoseRequest()
        let faceReq = faceRequest
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        try? handler.perform([poseReq, faceReq])
        guard let obs = poseReq.results?.first,
              let pts = try? obs.recognizedPoints(.all) else { return nil }
        guard let box = Measurer.subjectBox(pts: pts, minConf: cfg.minKeypointConfidenceLimb) else { return nil }

        let cls = FramingClass.detect(subjectBox: box)
        let face = faceReq.results?.first
        let optics = CameraOptics(hFovDeg: cfg.referenceVFOVDegrees * 0.6,
                                  vFovDeg: cfg.referenceVFOVDegrees,
                                  focalPixels: 1000, imageWidthPixels: 1000, imageHeightPixels: 1000)
        var m = Measurement(timestamp: 0)
        measureCore(pts: pts, face: face, framing: cls, timestamp: 0, optics: optics, filtered: false, into: &m)
        return (m, cls)
    }

    /// Khung bao chủ thể (0...1, gốc trên-trái) — dùng để suy FramingClass.
    /// Lọc CẢ confidence LẪN toạ độ y trong 0...1 (Vision ngoại suy điểm ngoài
    /// khung với confidence thấp — bẫy tài liệu §3 cảnh báo).
    static func subjectBox(pts: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
                           minConf: Float) -> CGRect? {
        var xs: [Double] = [], ys: [Double] = []
        for (_, p) in pts where p.confidence >= minConf {
            let y = 1.0 - Double(p.location.y)
            guard y >= 0, y <= 1, p.location.x >= 0, p.location.x <= 1 else { continue }
            xs.append(Double(p.location.x)); ys.append(y)
        }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // -------------------------------------------------------------
    // Lõi đo dùng chung cho live + still
    // -------------------------------------------------------------
    private func measureCore(pts: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
                             face: VNFaceObservation?,
                             framing: FramingClass,
                             timestamp: Double,
                             optics: CameraOptics,
                             filtered: Bool,
                             into m: inout Measurement) {

        func p(_ n: VNHumanBodyPoseObservation.JointName, _ minConf: Float) -> SIMD2<Double>? {
            guard let q = pts[n], q.confidence >= minConf else { return nil }
            return SIMD2(Double(q.location.x), 1.0 - Double(q.location.y))
        }
        let core = cfg.minKeypointConfidenceCore
        let limb = cfg.minKeypointConfidenceLimb

        if filtered {
            m.jointPoints = pts.reduce(into: [:]) { dict, entry in
                let (name, point) = entry
                guard point.confidence >= 0.1 else { return }
                dict[name] = JointPoint(location: point.location, confidence: point.confidence)
            }
        }

        guard let lSh = p(.leftShoulder, core), let rSh = p(.rightShoulder, core) else {
            if filtered { validFrames = 0 }
            return
        }
        let lHip = p(.leftHip, core), rHip = p(.rightHip, core)
        let hips: SIMD2<Double>? = (lHip != nil && rHip != nil) ? (lHip! + rHip!) / 2 : nil

        if filtered {
            validFrames += 1
            guard validFrames >= cfg.minValidFramesBeforeUse else { return }
        }

        m.hasSubject = true
        let neck = (lSh + rSh) / 2
        let nose = p(.nose, limb)
        let torsoHeight = hips.map { abs(neck.y - $0.y) } ?? 0

        // ---------- Đỉnh đầu — ưu tiên face box, sau đó nhân trắc ----------
        var headTopY: Double?
        if let f = face {
            headTopY = 1.0 - Double(f.boundingBox.origin.y + f.boundingBox.height)
        } else if torsoHeight > 0.02 {
            headTopY = neck.y - 0.62 * torsoHeight
        } else if let nose = nose {
            headTopY = nose.y - 0.6 * abs(nose.y - neck.y)
        }

        // ---------- Tâm chủ thể (mục 5) — ĐÚNG MỐC CỦA LỚP ----------
        switch framing.centerAnchor {
        case .torsoCenter:
            if let hips = hips { let c = (neck + hips) / 2; m.centerX = c.x; m.centerY = c.y }
            else { m.centerX = neck.x; m.centerY = neck.y }
        case .shoulderCenter:
            m.centerX = neck.x; m.centerY = neck.y
        case .faceCenter:
            if let f = face { m.centerX = Double(f.boundingBox.midX); m.centerY = 1.0 - Double(f.boundingBox.midY) }
            else { m.centerX = neck.x; m.centerY = neck.y }
        }
        if filtered, let cx = m.centerX { m.centerX = fCenterX.filter(cx, timestamp: timestamp) }

        // ---------- Tỉ lệ chủ thể (mục 2) — ĐÚNG MỐC CỦA LỚP ----------
        let ankleY = [p(.leftAnkle, limb)?.y, p(.rightAnkle, limb)?.y].compactMap { $0 }.max()
        let kneeY  = [p(.leftKnee,  limb)?.y, p(.rightKnee,  limb)?.y].compactMap { $0 }.max()
        var scale: Double?
        switch framing.scaleAnchor {
        case .headToAnkle:
            if let top = headTopY, let a = ankleY, a > top { scale = a - top }
        case .headToKnee:
            if let top = headTopY, let k = kneeY, k > top { scale = k - top }
        case .headToHip:
            if let top = headTopY, let h = hips?.y, h > top { scale = h - top }
        case .faceHeight:
            if let f = face { scale = Double(f.boundingBox.height) }
            else { scale = abs(lSh.x - rSh.x) * 0.55 }   // dự phòng: suy từ bề ngang vai
        }
        if let s = scale {
            m.scaleValue = filtered ? fScale.filter(s, timestamp: timestamp) : s
        }

        // ---------- Hướng mẫu (mục 1) — nguồn ĐÚNG THEO LỚP ----------
        switch framing.yawSource {
        case .shoulderForeshortening:
            if torsoHeight >= cfg.bodyYawMinTorsoHeight {
                let rawR = abs(lSh.x - rSh.x) / torsoHeight
                let r = filtered ? fShoulderRatio.filter(rawR, timestamp: timestamp) : rawR

                if rFront == nil, let f = face, let yaw = f.yaw?.doubleValue, abs(yaw.degrees) < 10 {
                    rFrontSamples.append(r)
                    if rFrontSamples.count >= 10 {
                        rFront = rFrontSamples.sorted()[rFrontSamples.count / 2]
                    }
                }
                let base = rFront ?? cfg.rFrontDefault
                let ratio = min(max(r / base, 0), 1)

                if ratio >= cfg.bodyYawFrontalDeadZone {
                    m.bodyYawDeg = 0
                    m.bodyYawIsFrontalFlat = true
                } else {
                    let absYaw = acos(ratio).degrees
                    var signedYaw = absYaw
                    if let nose = nose { signedYaw = (nose.x > neck.x) ? absYaw : -absYaw }
                    let seeingFront = (face != nil) || (lSh.x > rSh.x)
                    m.bodyYawDeg = seeingFront ? signedYaw
                        : (signedYaw >= 0 ? 180 - absYaw : -180 + absYaw)
                }
            }
        case .faceYaw:
            if let f = face, let yaw = f.yaw?.doubleValue { m.bodyYawDeg = yaw.degrees }
        }
        if let f = face, let yaw = f.yaw?.doubleValue { m.headYawDeg = yaw.degrees }

        // ---------- Góc nhìn tới mốc (mục 3) — ĐỘC LẬP với mục 4 ----------
        // elevation = pitch_máy + (0.5 − y_mốc) × vFOV. Hai phương trình
        // (mục 3 + mục 4) độc lập, cùng xác định đủ độ cao máy lẫn độ chúc.
        var anchorY: Double?
        switch framing.elevationAnchor {
        case .midHip:   anchorY = hips?.y
        case .midTorso: anchorY = hips.map { (neck.y + $0.y) / 2 } ?? neck.y
        case .eyeLine:  anchorY = face.map { 1.0 - Double($0.boundingBox.midY) } ?? nose?.y
        }
        if let ay = anchorY {
            let offset = optics.elevationOffsetDeg(normalizedY: ay)
            let raw = m.cameraPitchDeg + offset
            m.elevationDeg = filtered ? fElevation.filter(raw, timestamp: timestamp) : raw
        }

        // ---------- Dáng ----------
        if let hips = hips {
            let rawSpine = atan2(neck.x - hips.x, max(torsoHeight, 1e-6)).degrees
            m.spineTiltDeg = filtered ? mSpine.push(rawSpine) : rawSpine
        }
        m.jointAngles = Self.jointAngles(pts: pts, minConf: limb)
    }

    static func jointAngles(pts: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
                            minConf: Float) -> [JointName: Double] {
        func p(_ n: VNHumanBodyPoseObservation.JointName) -> SIMD2<Double>? {
            guard let q = pts[n], q.confidence >= minConf else { return nil }
            return SIMD2(Double(q.location.x), 1.0 - Double(q.location.y))
        }
        func angle(_ a: SIMD2<Double>?, _ v: SIMD2<Double>?, _ b: SIMD2<Double>?) -> Double? {
            guard let a = a, let v = v, let b = b else { return nil }
            let u = a - v, w = b - v
            let denom = length(u) * length(w)
            guard denom > 1e-6 else { return nil }
            return acos(min(max(dot(u, w) / denom, -1), 1)).degrees
        }
        var out: [JointName: Double] = [:]
        out[.leftElbow]     = angle(p(.leftShoulder), p(.leftElbow),   p(.leftWrist))
        out[.rightElbow]    = angle(p(.rightShoulder), p(.rightElbow), p(.rightWrist))
        out[.leftShoulder]  = angle(p(.leftElbow), p(.leftShoulder),   p(.leftHip))
        out[.rightShoulder] = angle(p(.rightElbow), p(.rightShoulder), p(.rightHip))
        out[.leftKnee]      = angle(p(.leftHip), p(.leftKnee),   p(.leftAnkle))
        out[.rightKnee]     = angle(p(.rightHip), p(.rightKnee), p(.rightAnkle))
        return out.compactMapValues { $0 }
    }
}

// =====================================================================
// MARK: - 4. TRẠNG THÁI TỪNG MỤC — vùng chết, trễ, khoá, chống kẹt
// =====================================================================

final class CriterionGate {
    enum Status { case unknown, passing, failing }

    private(set) var status: Status = .unknown
    private(set) var locked = false
    private var candidateSince: Double?
    private var blockedGateSince: Double?

    let band: ThresholdBand
    let config: GuidanceConfig

    init(band: ThresholdBand, config: GuidanceConfig) {
        self.band = band; self.config = config
    }

    func reset() {
        status = .unknown; locked = false
        candidateSince = nil; blockedGateSince = nil
    }

    @discardableResult
    func update(error: Double?, action: Double, now: Double) -> (failing: Bool, showCue: Bool) {
        guard let raw = error, raw.isFinite else {
            candidateSince = nil
            return (false, false)
        }
        let e = abs(raw)

        if action < band.actionFloor {
            markPassing(now: now)
            return (false, false)
        }

        let failThreshold: Double = locked ? band.unlock : band.enter

        if e > failThreshold {
            if status != .failing {
                if candidateSince == nil { candidateSince = now }
                if now - candidateSince! >= config.cueEnterHoldSeconds {
                    status = .failing; locked = false; candidateSince = nil
                }
            } else { candidateSince = nil }
        } else if e <= band.accept {
            markPassing(now: now)
        } else {
            candidateSince = nil
            if status == .unknown { status = .failing }
        }

        let gateOK = (status == .passing) && e <= band.enter
        if gateOK { blockedGateSince = nil }
        else if blockedGateSince == nil { blockedGateSince = now }
        if let since = blockedGateSince, now - since > config.stallTimeoutSeconds {
            status = .failing; locked = false; blockedGateSince = nil
        }

        let failing = (status == .failing)
        return (failing, failing)
    }

    private func markPassing(now: Double) {
        if status != .passing {
            if candidateSince == nil { candidateSince = now }
            if now - candidateSince! >= config.cueExitHoldSeconds {
                status = .passing; locked = true; candidateSince = nil
            }
        } else { candidateSince = nil }
    }

    var passesCaptureGate: Bool { status == .passing }
}

// =====================================================================
// MARK: - 5. SINH CÂU CUE (có làm tròn số)
// =====================================================================

enum CueFactory {

    static func quantize(_ v: Double, step: Double) -> Double {
        guard step > 0 else { return v }
        return (v / step).rounded() * step
    }

    // --- Mục 1 ---
    static func bodyYaw(delta d: Double, targetYaw: Double, cfg: GuidanceConfig) -> String {
        if abs(targetYaw) > 150 { return "Bảo mẫu quay lưng lại" }
        if abs(abs(targetYaw) - 90) < 30 {
            return targetYaw > 0 ? "Bảo mẫu quay nghiêng sang phải" : "Bảo mẫu quay nghiêng sang trái"
        }
        if abs(targetYaw) < 25 { return "Bảo mẫu quay mặt về phía máy" }
        let deg = quantize(abs(d), step: cfg.quantizeDegrees)
        return d > 0 ? "Bảo mẫu xoay người sang trái \(Int(deg)) độ"
                     : "Bảo mẫu xoay người sang phải \(Int(deg)) độ"
    }

    // --- Mục 2 ---
    static func distance(relError err: Double, distanceMeters d: Double?, cfg: GuidanceConfig) -> String {
        let meters = abs((d ?? 2.0) * err)
        if meters < 0.55 {
            return err > 0 ? "Lùi lại nửa bước" : "Tiến lên nửa bước"
        }
        let steps = max(1, min(3, Int((meters / 0.7).rounded())))
        return err > 0 ? "Lùi \(steps) bước" : "Tiến \(steps) bước"
    }

    // --- Mục 3 — góc nhìn (độ), universal mọi lớp ---
    //
    // ⚠️ CHIỀU DẤU: elevationDeg = pitch_máy + (0.5 − y_mốc)×vFOV là góc TUYỆT
    // ĐỐI (so mặt phẳng ngang) từ máy tới mốc. Với một điểm mốc CỐ ĐỊNH trong
    // không gian, góc này CÀNG LỚN khi máy đặt CÀNG THẤP (phải ngẩng lên nhiều
    // hơn để thấy mốc) — nghịch biến với độ cao máy. Vậy delta = live − template:
    //   delta > 0  ⇒  máy hiện đang THẤP hơn lúc chụp mẫu ⇒ cần NÂNG lên.
    //   delta < 0  ⇒  máy hiện đang CAO hơn lúc chụp mẫu ⇒ cần HẠ xuống.
    // Suy từ hình học thuần, CHƯA kiểm trên máy thật (mục 9 tài liệu verify-v3).
    // Nếu test thực tế thấy cue nâng/hạ bị ngược, đảo `d > 0` ↔ `d < 0` dưới đây.
    static func cameraElevation(delta d: Double, anchorLabel: String, cfg: GuidanceConfig) -> String {
        let deg = quantize(abs(d), step: cfg.quantizeDegrees)
        if deg < cfg.quantizeDegrees {
            return d > 0 ? "Nâng ống kính lên một chút (\(anchorLabel))"
                         : "Hạ ống kính xuống một chút (\(anchorLabel))"
        }
        return d > 0 ? "Nâng ống kính lên \(Int(deg))° (\(anchorLabel))"
                     : "Hạ ống kính xuống \(Int(deg))° (\(anchorLabel))"
    }

    // --- Mục 4 ---
    static func cameraPitch(delta d: Double, cfg: GuidanceConfig) -> String {
        let deg = quantize(abs(d), step: cfg.quantizeDegrees)
        if deg < cfg.quantizeDegrees {
            return d > 0 ? "Chúc điện thoại xuống một chút" : "Ngửa điện thoại lên một chút"
        }
        return d > 0 ? "Chúc điện thoại xuống \(Int(deg)) độ"
                     : "Ngửa điện thoại lên \(Int(deg)) độ"
    }

    // --- Mục 5 ---
    static func horizontal(offset: Double, optics: CameraOptics, cfg: GuidanceConfig,
                           panVsStepThreshold: Double = 0.15) -> String {
        if abs(offset) >= panVsStepThreshold {
            return offset > 0 ? "Bước sang phải 1 bước" : "Bước sang trái 1 bước"
        }
        let deg = quantize(abs(optics.azimuthOffsetDeg(normalizedX: 0.5 + offset)), step: cfg.quantizeDegrees)
        if deg < cfg.quantizeDegrees {
            return offset > 0 ? "Đưa điện thoại sang phải một chút" : "Đưa điện thoại sang trái một chút"
        }
        return offset > 0 ? "Xoay điện thoại sang phải \(Int(deg)) độ"
                          : "Xoay điện thoại sang trái \(Int(deg)) độ"
    }
}

// =====================================================================
// MARK: - 6. ĐIỀU PHỐI HIỂN THỊ CUE
// =====================================================================

final class CuePresenter {
    private var currentCriterion: Criterion?
    private var currentText: String?
    private var shownAt: Double = 0
    private var lastNumberUpdate: Double = 0
    private let cfg: GuidanceConfig

    init(config: GuidanceConfig) { self.cfg = config }
    func reset() { currentCriterion = nil; currentText = nil; shownAt = 0; lastNumberUpdate = 0 }

    func present(_ v: Violation?, now: Double, frozen: Bool) -> String? {
        if frozen { return currentText }
        guard let v = v else { currentCriterion = nil; currentText = nil; return nil }

        let higherPriority = currentCriterion.map { v.criterion.rawValue < $0.rawValue } ?? true
        let displayedLongEnough = now - shownAt >= cfg.cueMinDisplaySeconds

        if currentCriterion != v.criterion {
            guard higherPriority || displayedLongEnough else { return currentText }
            currentCriterion = v.criterion
            currentText = v.cue
            shownAt = now
            lastNumberUpdate = now
            return currentText
        }
        if v.cue != currentText, now - lastNumberUpdate >= cfg.cueNumberRefreshSeconds {
            currentText = v.cue
            lastNumberUpdate = now
        }
        return currentText
    }
}

// =====================================================================
// MARK: - 7. ĐÁNH GIÁ THEO THỨ TỰ 1→6
// =====================================================================

final class GuidanceEngine {

    private let cfg: GuidanceConfig
    private var gates: [Criterion: CriterionGate] = [:]
    private var currentClass: FramingClass = .full

    init(config: GuidanceConfig = .default) {
        self.cfg = config
        rebuildGates(for: .full)
    }

    private func rebuildGates(for cls: FramingClass) {
        let t = cfg.thresholds(for: cls)
        gates[.bodyYaw]    = CriterionGate(band: t.bodyYaw,    config: cfg)
        gates[.distance]   = CriterionGate(band: t.distance,   config: cfg)
        gates[.elevation]  = CriterionGate(band: t.elevation,  config: cfg)
        gates[.pitch]      = CriterionGate(band: t.pitch,      config: cfg)
        gates[.horizontal] = CriterionGate(band: t.horizontal, config: cfg)
        gates[.pose]       = CriterionGate(band: t.jointAngle, config: cfg)
        currentClass = cls
    }

    func reset() { rebuildGates(for: currentClass) }

    func evaluate(_ m: Measurement, _ t: Template, _ optics: CameraOptics) -> GuidanceResult {

        if t.framing != currentClass { rebuildGates(for: t.framing) }
        let bands = cfg.thresholds(for: t.framing)
        let now = m.timestamp
        var violations: [Violation] = []
        var debug: [Criterion: String] = [:]

        guard m.hasSubject else {
            let v = Violation(criterion: .bodyYaw, actor: .shooter, error: 0,
                              normalizedError: 99, detail: "no subject", cue: "Đưa mẫu vào khung")
            return GuidanceResult(violations: [v], passedCount: 0, readyToCapture: false,
                                  worstNormalizedError: 99, debug: debug)
        }

        // ---------------- MỤC 1: HƯỚNG MẪU ----------------
        var yawErr: Double?
        if let yaw = m.bodyYawDeg {
            if m.bodyYawIsFrontalFlat && abs(t.bodyYawDeg) < bands.bodyYaw.accept {
                yawErr = 0
            } else {
                yawErr = signedAngleDelta(yaw, t.bodyYawDeg)
            }
        }
        let g1 = gates[.bodyYaw]!.update(error: yawErr, action: abs(yawErr ?? 0), now: now)
        debug[.bodyYaw] = fmt(yawErr, bands.bodyYaw.accept, "°")
        if g1.failing {
            let d = yawErr ?? 0
            violations.append(Violation(
                criterion: .bodyYaw, actor: .model, error: d,
                normalizedError: abs(d) / bands.bodyYaw.accept,
                detail: String(format: "lệch %.0f°", d),
                cue: CueFactory.bodyYaw(delta: d, targetYaw: t.bodyYawDeg, cfg: cfg)))
            // Mẫu quay sai hướng ⇒ mọi phép so trái/phải bên dưới vô nghĩa. DỪNG.
            return GuidanceResult(violations: violations, passedCount: 0, readyToCapture: false,
                                  worstNormalizedError: abs(d) / bands.bodyYaw.accept, debug: debug)
        }

        // ---------------- MỤC 2: XA/GẦN — ĐÚNG MỐC CỦA LỚP ----------------
        var sizeErr: Double?
        var sizeAction: Double = 0
        if let live = m.scaleValue, t.scaleValue > 0 {
            sizeErr = live / t.scaleValue - 1.0
            let distanceMeters = estimateDistanceMeters(m, t, optics)
            sizeAction = abs(distanceMeters * sizeErr!)
        }
        let g2 = gates[.distance]!.update(error: sizeErr, action: sizeAction, now: now)
        debug[.distance] = fmt(sizeErr, bands.distance.accept, "")
        if g2.failing, let e = sizeErr {
            violations.append(Violation(
                criterion: .distance, actor: .shooter, error: e,
                normalizedError: abs(e) / bands.distance.accept,
                detail: String(format: "chênh %.0f%% (%.2fm)", e * 100, sizeAction),
                cue: CueFactory.distance(relError: e, distanceMeters: estimateDistanceMeters(m, t, optics), cfg: cfg)))
        }

        // ---------------- MỤC 3: MÁY CAO/THẤP — GÓC NHÌN (độ) ----------------
        var elevErr: Double?
        if let live = m.elevationDeg { elevErr = live - t.elevationDeg }
        let g3 = gates[.elevation]!.update(error: elevErr, action: abs(elevErr ?? 0), now: now)
        debug[.elevation] = fmt(elevErr, bands.elevation.accept, "°")
        if g3.failing, let e = elevErr {
            violations.append(Violation(
                criterion: .elevation, actor: .shooter, error: e,
                normalizedError: abs(e) / bands.elevation.accept,
                detail: String(format: "lệch %.1f°", e),
                cue: CueFactory.cameraElevation(delta: e, anchorLabel: t.framing.elevationAnchor.cueLabel, cfg: cfg)))
        }

        // ---------------- MỤC 4: NGỬA/CHÚC ----------------
        let pitchErr = m.cameraPitchDeg - t.cameraPitchDeg
        let g4 = gates[.pitch]!.update(error: pitchErr, action: abs(pitchErr), now: now)
        debug[.pitch] = fmt(pitchErr, bands.pitch.accept, "°")
        if g4.failing {
            violations.append(Violation(
                criterion: .pitch, actor: .shooter, error: pitchErr,
                normalizedError: abs(pitchErr) / bands.pitch.accept,
                detail: String(format: "lệch %.1f°", pitchErr),
                cue: CueFactory.cameraPitch(delta: pitchErr, cfg: cfg)))
        }

        // ---------------- MỤC 5: TRÁI/PHẢI ----------------
        var offErr: Double?
        if let cx = m.centerX { offErr = cx - t.centerX }
        let g5 = gates[.horizontal]!.update(error: offErr, action: abs(offErr ?? 0), now: now)
        debug[.horizontal] = fmt(offErr, bands.horizontal.accept, "W")
        if g5.failing, let e = offErr {
            violations.append(Violation(
                criterion: .horizontal, actor: .shooter, error: e,
                normalizedError: abs(e) / bands.horizontal.accept,
                detail: String(format: "lệch %.1f%% khung", e * 100),
                cue: CueFactory.horizontal(offset: e, optics: optics, cfg: cfg)))
        }

        // ---------------- MỤC 6: DÁNG (chỉ khi 1-5 sạch, chỉ nhóm thuộc lớp) ----------------
        if violations.isEmpty {
            if let (err, cue, name) = poseDeviation(m, t, bands: bands) {
                let g6 = gates[.pose]!.update(error: err, action: abs(err), now: now)
                debug[.pose] = fmt(err, bands.jointAngle.accept, "° \(name)")
                if g6.failing {
                    violations.append(Violation(
                        criterion: .pose, actor: .model, error: err,
                        normalizedError: abs(err) / bands.jointAngle.accept,
                        detail: String(format: "%@ lệch %.0f°", name, err), cue: cue))
                }
            } else {
                gates[.pose]!.update(error: 0, action: 0, now: now)
                debug[.pose] = "ok"
            }
        }

        // ---------------- TỔNG HỢP ----------------
        let passed = Criterion.allCases.filter { gates[$0]!.passesCaptureGate }.count
        let calmEnough = m.angularSpeedDegPerSec <= cfg.maxAngularSpeedDegPerSec
        let ready = violations.isEmpty
            && Criterion.allCases.allSatisfy { gates[$0]!.passesCaptureGate }
            && calmEnough
        let worst = violations.map { $0.normalizedError }.max() ?? 0

        return GuidanceResult(violations: violations.sorted { $0.criterion.rawValue < $1.criterion.rawValue },
                              passedCount: passed, readyToCapture: ready,
                              worstNormalizedError: worst, debug: debug)
    }

    /// Ước lượng thô khoảng cách (mét) — CHỈ để đổi % → "bước" trong câu chữ.
    private func estimateDistanceMeters(_ m: Measurement, _ t: Template, _ optics: CameraOptics) -> Double {
        guard let scale = m.scaleValue, scale > 0, t.framing.scaleAnchor != .faceHeight else { return 2.0 }
        let fullHeightPx = scale * optics.imageHeightPixels
        guard fullHeightPx > 1 else { return 2.0 }
        return optics.focalPixels * cfg.assumedBodyHeightMeters / fullHeightPx
    }

    /// Dáng: chỉ chấm các nhóm khớp thuộc `t.framing.poseGroups` — trục thân →
    /// đầu → tay → chân. Trả về sai lệch NẶNG NHẤT theo thứ tự.
    private func poseDeviation(_ m: Measurement, _ t: Template, bands: ClassThresholds) -> (Double, String, String)? {
        let groups = Set(t.framing.poseGroups)

        if groups.contains(.spine), let s = m.spineTiltDeg {
            let d = s - t.spineTiltDeg
            if abs(d) > bands.spineTilt.enter {
                return (d, d > 0 ? "Bảo mẫu nghiêng người sang trái"
                                 : "Bảo mẫu nghiêng người sang phải", "trục thân")
            }
        }
        if groups.contains(.head), let tH = t.headYawDeg, let mH = m.headYawDeg {
            let d = signedAngleDelta(mH, tH)
            if abs(d) > bands.headYaw.enter {
                return (d, d > 0 ? "Bảo mẫu quay mặt sang trái"
                                 : "Bảo mẫu quay mặt sang phải", "hướng đầu")
            }
        }
        if groups.contains(.arms) {
            for j: JointName in [.leftShoulder, .rightShoulder, .leftElbow, .rightElbow] {
                guard let cur = m.jointAngles[j], let target = t.jointAngles[j] else { continue }
                if abs(cur - target) > bands.jointAngle.enter {
                    return (cur - target, t.cueForModel, j.rawValue)
                }
            }
        }
        if groups.contains(.legs) {
            for j: JointName in [.leftKnee, .rightKnee] {
                guard let cur = m.jointAngles[j], let target = t.jointAngles[j] else { continue }
                if abs(cur - target) > bands.jointAngle.enter {
                    return (cur - target, t.cueForModel, j.rawValue)
                }
            }
        }
        return nil
    }

    private func fmt(_ v: Double?, _ accept: Double, _ unit: String) -> String {
        guard let v = v else { return "n/a" }
        return String(format: "%.3f%@ / ngưỡng %.3f (x%.2f)", v, unit, accept, abs(v) / accept)
    }
}

// =====================================================================
// MARK: - 8. CỔNG CHỤP: DWELL → ĐẾM NGƯỢC → GHI
// =====================================================================

final class CaptureTrigger {
    enum State { case guiding, dwelling(since: Double), countingDown(until: Double), recording }
    private(set) var state: State = .guiding
    private var lostAlignedSince: Double?
    private let cfg: GuidanceConfig

    init(config: GuidanceConfig) { self.cfg = config }

    func update(ready: Bool, now: Double) -> Bool {
        switch state {
        case .guiding:
            if ready { state = .dwelling(since: now) }
            return false

        case .dwelling(let since):
            if !ready { state = .guiding; return false }
            if now - since >= cfg.dwellSeconds {
                state = .countingDown(until: now + cfg.countdownSeconds)
                return true
            }
            return false

        case .countingDown(let until):
            if !ready {
                if lostAlignedSince == nil { lostAlignedSince = now }
                if now - lostAlignedSince! > cfg.countdownGraceSeconds {
                    state = .guiding; lostAlignedSince = nil
                }
            } else { lostAlignedSince = nil }
            if now >= until { state = .recording }
            return false

        case .recording:
            return false
        }
    }

    var countdownRemaining: Int? {
        if case .countingDown(let until) = state {
            return max(0, Int((until - CACurrentMediaTime()).rounded(.up)))
        }
        return nil
    }
    func reset() { state = .guiding; lostAlignedSince = nil }
}

// =====================================================================
// MARK: - Tiện ích
// =====================================================================

extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}

func signedAngleDelta(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}
