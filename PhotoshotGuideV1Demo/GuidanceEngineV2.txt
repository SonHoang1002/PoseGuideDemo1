//
//  GuidanceEngine.swift  — v2
//  Thuật toán kiểm 6 tiêu chí và sinh cue hướng dẫn realtime
//
//  Đầu vào : CVPixelBuffer (1 frame) + CMDeviceMotion + thông số ống kính + Template
//  Đầu ra  : GuidanceResult — danh sách vi phạm theo thứ tự 1→6, cue chính + cue phụ,
//            và cờ readyToCapture (cổng cho phép bắt đầu ghi)
//
//  Công nghệ: Vision (VNDetectHumanBodyPoseRequest, VNDetectFaceRectanglesRequest)
//             CoreMotion (dùng VECTOR TRỌNG LỰC, không dùng attitude.pitch)
//  Không train model, không gọi server.
//
//  ---------------------------------------------------------------------------
//  KHÁC v1 (tóm tắt, chi tiết xem NGUONG_VA_GOC_QUY_CHIEU.md):
//   1. Mọi ngưỡng gom vào GuidanceConfig — 1 chỗ duy nhất, có đơn vị, có preset.
//   2. Mỗi mục có 4 số: accept / enterFactor / unlockFactor / actionFloor.
//      -> có vùng chết (dead-band) + trễ (hysteresis) + "hành động quá nhỏ thì im".
//   3. Mục 2 & 3 so SỐ LIÊN TỤC với template, không so bucket. Bucket chỉ để chọn CHỮ.
//   4. Mục 3 đo theo ĐƠN VỊ CHIỀU CAO MẪU, triệt tiêu sai số "giả định cao 1m70".
//   5. Pitch lấy từ vector trọng lực (gốc = mặt phẳng ngang), có lọc riêng.
//   6. Debounce thời gian: vi phạm phải kéo dài mới hiện cue; cue có thời gian
//      hiển thị tối thiểu; số trong cue được làm tròn và chỉ cập nhật 1 lần/giây.
//   7. Cổng chụp tách riêng khỏi ngưỡng nhắc, có chống kẹt (stall timeout).
//  ---------------------------------------------------------------------------

import Vision
import CoreMotion
import AVFoundation
import QuartzCore
import simd

// =====================================================================
// MARK: - 0. CẤU HÌNH NGƯỠNG  ***SỬA MỌI THỨ Ở ĐÂY***
// =====================================================================

/// Một dải ngưỡng cho 1 tiêu chí. Đơn vị của `accept` và `actionFloor`
/// là đơn vị riêng của tiêu chí đó (độ / % / phần khung / đơn-vị-chiều-cao-mẫu).
///
///   |err| <= accept                  -> ĐẠT. Im lặng. Được tính vào cổng chụp.
///   accept < |err| <= accept*enter   -> VÙNG XÁM. Giữ nguyên trạng thái trước đó.
///                                       Đang đạt thì vẫn coi là đạt (khỏi nhấp nháy),
///                                       đang nhắc thì vẫn nhắc (để user chỉnh nốt).
///   |err| > accept*enter             -> VI PHẠM, hiện cue.
///   |err| > accept*unlock            -> MỞ KHÓA: được phép quay lại mục này
///                                       kể cả khi đang làm mục dưới.
///   action < actionFloor             -> IM LẶNG dù err vượt ngưỡng: lượng phải
///                                       sửa quá nhỏ, người thật không làm nổi.
nonisolated struct ThresholdBand {
    var accept: Double
    var enterFactor: Double = 1.5
    var unlockFactor: Double = 3.0
    var actionFloor: Double = 0

    var enter: Double  { accept * enterFactor }
    var unlock: Double { accept * unlockFactor }
}

nonisolated struct GuidanceConfig {

    // -----------------------------------------------------------------
    // MỤC 1 — HƯỚNG MẪU (body yaw)
    // Góc xoay thân quanh trục đứng, suy từ tỉ lệ (vai biểu kiến / chiều cao thân).
    // Gốc quy chiếu: 0° = mẫu quay thẳng mặt vào máy; ±180° = quay lưng.
    // Điểm gốc hình học = trung điểm hai vai.
    // -----------------------------------------------------------------
    var bodyYaw = ThresholdBand(accept: 30, enterFactor: 1.4, unlockFactor: 2.5, actionFloor: 15)

    /// Vùng chết chính diện: khi r/rFront >= số này thì coi yaw = 0.
    /// Lý do: yaw = acos(r/rFront), gần chính diện đạo hàm của acos → vô cực,
    /// nhiễu 2% ở r biến thành 12° ở yaw. Đây là 1 trong các nguồn nháy cue của v1.
    var bodyYawFrontalDeadZone: Double = 0.93

    /// Chiều cao thân tối thiểu (phần khung) mới tin được số đo yaw.
    var bodyYawMinTorsoHeight: Double = 0.08

    /// Hệ số hiệu chuẩn r_front khi chưa đo được trên người thật
    /// (bề ngang vai biểu kiến / chiều cao thân của người chính diện).
    var defaultRFront: Double = 0.62

    // -----------------------------------------------------------------
    // MỤC 2 — XA/GẦN
    // err = (ratio_live / ratio_template) − 1, cùng mốc HeightAnchor.
    // actionFloor tính bằng MÉT.
    // -----------------------------------------------------------------
    var distance = ThresholdBand(accept: 0.10, enterFactor: 1.5, unlockFactor: 3.0, actionFloor: 0.35)

    // -----------------------------------------------------------------
    // MỤC 3 — MÁY CAO/THẤP
    // rel = (cao độ máy − đỉnh đầu mẫu) / chiều cao mẫu. Gốc = đỉnh đầu (0.0).
    // Âm = máy thấp hơn đỉnh đầu. Công thức KHÔNG phụ thuộc chiều cao thật của mẫu.
    // -----------------------------------------------------------------
    var cameraHeight = ThresholdBand(accept: 0.07, enterFactor: 1.5, unlockFactor: 3.0, actionFloor: 0.045)

    // -----------------------------------------------------------------
    // MỤC 4 — NGỬA/CHÚC
    // Góc ngẩng của TRỤC QUANG so với mặt phẳng ngang, lấy từ vector trọng lực.
    // Dương = ngửa lên trời, âm = chúc xuống đất.
    // -----------------------------------------------------------------
    var cameraPitch = ThresholdBand(accept: 5.0, enterFactor: 1.5, unlockFactor: 3.0, actionFloor: 4.0)

    // -----------------------------------------------------------------
    // MỤC 5 — LỆCH TRÁI/PHẢI: hiệu X tâm thân live − template (phần bề ngang khung).
    // Tâm thân = trung điểm của (trung điểm hai vai, trung điểm hai hông).
    // -----------------------------------------------------------------
    var horizontal = ThresholdBand(accept: 0.05, enterFactor: 1.5, unlockFactor: 3.0, actionFloor: 0.02)

    /// Lệch quá mức này thì bảo BƯỚC ngang, dưới mức này thì bảo XOAY máy quanh trục Oy.
    var panVsStepThreshold: Double = 0.15

    // -----------------------------------------------------------------
    // MỤC 6 — DÁNG: góc tại từng khớp (đỉnh góc = chính khớp đó); trục thân;
    // hướng đầu. Gốc quy chiếu là TEMPLATE ở từng góc/khớp tương ứng.
    // -----------------------------------------------------------------
    var jointAngle = ThresholdBand(accept: 15, enterFactor: 1.5, unlockFactor: 3.0, actionFloor: 12)
    var spineTilt  = ThresholdBand(accept: 10, enterFactor: 1.5, unlockFactor: 3.0, actionFloor: 8)
    var headYaw    = ThresholdBand(accept: 25, enterFactor: 1.4, unlockFactor: 3.0, actionFloor: 15)

    // -----------------------------------------------------------------
    // CHẤT LƯỢNG SỐ ĐO — dưới ngưỡng này coi là KHÔNG ĐO ĐƯỢC (bỏ qua mục),
    // KHÔNG phải là "sai". Nguyên tắc PRD: mục không đo được thì loại ra.
    // -----------------------------------------------------------------
    var minKeypointConfidenceCore: Float = 0.50    // vai, hông — dùng cho mục 1,2,3,5
    var minKeypointConfidenceLimb: Float = 0.40    // khuỷu, cổ tay, gối, cổ chân — mục 6
    /// Bậc mềm CHÓT cho vai/hông: dưới mức này mới kết luận "không có người".
    /// Skeleton hiển thị từ 0.10 nên bản cũ hay bị nghịch lý "vẫn thấy chấm xanh
    /// mà app báo không tìm thấy người" — ngưỡng đo và ngưỡng vẽ lệch nhau quá xa.
    var minKeypointConfidenceTorsoFloor: Float = 0.25
    var minKeypointConfidenceDisplay: Float = 0.10 // chỉ để vẽ skeleton, không tính toán
    var minValidFramesBeforeUse: Int = 3           // cần N frame liên tiếp đo được mới dùng
    var faceCacheSeconds: Double = 0.6             // face chạy thưa, dùng lại kết quả cũ

    // -----------------------------------------------------------------
    // THỜI GIAN — chống nháy cue (nguyên nhân số 1 của "cue chạy liên tục")
    // -----------------------------------------------------------------
    var cueEnterHoldSeconds: Double = 0.45        // vi phạm phải kéo dài mới hiện cue
    var cueExitHoldSeconds: Double = 0.20         // đạt phải giữ lâu mới tắt cue
    var cueMinDisplaySeconds: Double = 1.20       // cue đã hiện phải ở lại tối thiểu
    var cueNumberRefreshSeconds: Double = 1.00    // con số chỉ cập nhật mỗi giây một lần

    // -----------------------------------------------------------------
    // LÀM TRÒN CON SỐ TRONG CUE — số nhảy từng đơn vị làm user tưởng app loạn
    // -----------------------------------------------------------------
    var quantizeDegrees: Double = 5
    var quantizeCentimeters: Double = 5

    // -----------------------------------------------------------------
    // CỔNG CHỤP
    // -----------------------------------------------------------------
    var dwellSeconds: Double = 0.80           // đủ 6 mục → giữ ổn định ngần này
    var countdownSeconds: Double = 3.00       // rồi đếm ngược (GHI NGAY TỪ LÚC BẮT ĐẾM)
    var countdownGraceSeconds: Double = 1.00  // lệch giữa chừng: chờ ngần này mới huỷ
    /// Đang lắc máy mạnh hơn mức này thì không cho vào dwell (tránh chụp lúc tay đang đưa).
    var maxAngularSpeedDegPerSec: Double = 15
    /// Lắc mạnh hơn mức này thì ĐÓNG BĂNG cue đang hiện (user đang di chuyển theo hướng dẫn).
    var freezeCueAngularSpeedDegPerSec: Double = 45
    /// Chống kẹt: mục đã khóa trôi vào vùng xám quá lâu → mở khóa, nhắc lại.
    var stallTimeoutSeconds: Double = 2.50

    // -----------------------------------------------------------------
    // NHỊP XỬ LÝ
    // -----------------------------------------------------------------
    var poseEveryNFrames: Int = 1   // demo: pose chạy mỗi frame để skeleton mượt
    var faceEveryNFrames: Int = 3
    var assumedBodyHeightMeters: Double = 1.70  // CHỈ để đổi ra "bước"/"cm" trong câu chữ

    /// ***PHẢI KIỂM TRÊN MÁY THẬT.*** Buffer từ AVCapture là LANDSCAPE theo cảm biến.
    /// Cầm dọc + camera sau ⇒ `.right`. Truyền `.up` như v1 sẽ làm trục X/Y của Vision
    /// bị hoán đổi so với khung hình user nhìn thấy — mục 3 và 5 sai hệ thống.
    var visionOrientation: CGImagePropertyOrientation = .right

    // -----------------------------------------------------------------
    // PRESET
    // -----------------------------------------------------------------
    static let `default` = GuidanceConfig()

    /// Khắt khe hơn — dùng khi test độ chính xác, không dùng cho user thật.
    static var strict: GuidanceConfig {
        var c = GuidanceConfig()
        c.bodyYaw.accept = 20
        c.distance.accept = 0.06
        c.cameraHeight.accept = 0.045
        c.cameraPitch.accept = 3
        c.horizontal.accept = 0.03
        c.jointAngle.accept = 10
        return c
    }

    /// Dễ tính — cho template dễ, hoặc khi người cầm máy đã hết kiên nhẫn.
    /// PRD: live chỉ cần đúng 80%, sai số được "rửa" ở khâu chọn khung + tự cắt.
    static var relaxed: GuidanceConfig {
        var c = GuidanceConfig()
        c.bodyYaw.accept = 40
        c.distance.accept = 0.15
        c.cameraHeight.accept = 0.10
        c.cameraPitch.accept = 8
        c.horizontal.accept = 0.08
        c.jointAngle.accept = 22
        c.cueEnterHoldSeconds = 0.6
        return c
    }
}

// =====================================================================
// MARK: - 1. KIỂU DỮ LIỆU
// =====================================================================

nonisolated enum LensKind { case ultraWide, wide }   // 0.5x / 1x

nonisolated enum Criterion: Int, CaseIterable {
    case bodyYaw      = 1   // hướng mẫu          (mẫu làm)
    case distance     = 2   // xa/gần             (người chụp làm)
    case cameraHeight = 3   // máy cao/thấp       (người chụp làm)
    case cameraPitch  = 4   // ngửa/chúc          (người chụp làm)
    case horizontal   = 5   // lệch trái/phải     (người chụp làm)
    case pose         = 6   // dáng               (mẫu làm)

    var title: String {
        switch self {
        case .bodyYaw:      return "Hướng mẫu"
        case .distance:     return "Xa/gần"
        case .cameraHeight: return "Máy cao/thấp"
        case .cameraPitch:  return "Ngửa/chúc"
        case .horizontal:   return "Trái/phải"
        case .pose:         return "Dáng"
        }
    }

    var actor: Violation.Actor {
        switch self {
        case .bodyYaw, .pose: return .model
        default:              return .shooter
        }
    }
}

nonisolated enum JointName: String, CaseIterable {
    case leftElbow, rightElbow, leftShoulder, rightShoulder, leftKnee, rightKnee
}

/// Mốc đo chiều cao mẫu. Template và live PHẢI dùng cùng một mốc.
/// factorOfFullHeight = phần chiều cao toàn thân mà mốc đó chiếm (nhân trắc).
/// CHEST/HEAD dùng `faceHeight` (chiều cao khung mặt) — nhỏ, không quy đổi được
/// toàn thân nên `factorOfFullHeight` = 0 (không dùng để suy chiều cao).
nonisolated enum HeightAnchor: Int, Comparable, CaseIterable {
    case faceHeight    = 0   // chân dung/bán thân — chiều cao khung mặt
    case shoulderToHip = 1   // tệ nhất thân, dùng khi chỉ thấy nửa người
    case headToHip     = 2
    case headToKnee    = 3
    case headToAnkle   = 4   // tốt nhất

    var factorOfFullHeight: Double {
        switch self {
        case .faceHeight:    return 0
        case .headToAnkle:   return 0.96
        case .headToKnee:    return 0.715
        case .headToHip:     return 0.47
        case .shoulderToHip: return 0.29
        }
    }

    /// Có thể quy đổi ra chiều cao toàn thân không.
    var isFullHeightScalable: Bool { factorOfFullHeight > 0 }

    static func < (a: HeightAnchor, b: HeightAnchor) -> Bool { a.rawValue < b.rawValue }
}

// ---------------------------------------------------------------------
// LỚP KHUNG HÌNH — V3 (Phân lớp khung hình và tiêu chí theo từng lớp)
// Suy MỘT LẦN từ ảnh mẫu rồi áp nguyên xi cho mọi frame live/video.
// Quyết định toàn bộ cách đo + bộ phận được kiểm.
// ---------------------------------------------------------------------

/// Nhóm khớp được chấm ở mục "Dáng". Chân dung chỉ chấm các nhóm liên quan.
nonisolated enum PoseGroup: String, CaseIterable {
    case spine, head, arms, legs
}

/// Nguồn đo hướng mẫu (mục 1). CHEST/HEAD dùng face yaw vì hông khuất.
nonisolated enum FramingYawSource: String {
    case shoulderForeshortening
    case faceYaw
}

/// Năm lớp khung hình theo tài liệu V3.
nonisolated enum FramingClass: String, Codable, CaseIterable {
    case full   // toàn thân — thấy cổ chân
    case knee   // 3/4 người — cắt dưới gối
    case half   // nửa người — cắt dưới hông
    case chest  // bán thân — cắt trên hông
    case head   // chân dung cận — chỉ đầu + vai

    /// 2 MODE cao cấp đúng yêu cầu: FULL = toàn thân; còn lại = 1 phần cơ thể.
    var captureMode: CaptureMode {
        switch self {
        case .full: return .full
        case .knee, .half, .chest, .head: return .upper
        }
    }

    /// Có cần thấy hông (đủ cả thân dưới) để đo các mốc "toàn thân" không.
    var requiresHip: Bool {
        switch self {
        case .full, .knee, .half: return true
        case .chest, .head: return false
        }
    }

    /// Mốc tỉ lệ (mục 2) — DÙNG ĐÚNG MỐC của lớp, không "lấy mốc tốt nhất còn đo".
    var scaleAnchor: HeightAnchor {
        switch self {
        case .full:  return .headToAnkle
        case .knee:  return .headToKnee
        case .half:  return .headToHip
        case .chest, .head: return .faceHeight
        }
    }

    /// Nguồn đo hướng mẫu (mục 1).
    var yawSource: FramingYawSource {
        switch self {
        case .full, .knee, .half: return .shoulderForeshortening
        case .chest, .head:       return .faceYaw
        }
    }

    /// Các nhóm khớp được chấm ở mục Dáng — RẠCH RÒI: bỏ hẳn nhóm không liên quan.
    var poseGroups: [PoseGroup] {
        switch self {
        case .full:  return [.spine, .head, .arms, .legs]
        case .knee:  return [.spine, .head, .arms]
        case .half:  return [.spine, .head, .arms]
        case .chest: return [.head, .arms]
        case .head:  return [.head]
        }
    }

    /// Tên hiển thị tiếng Việt cho dialog/log.
    var title: String {
        switch self {
        case .full:  return "Toàn thân"
        case .knee:  return "¾ người"
        case .half:  return "Nửa người"
        case .chest: return "Bán thân"
        case .head:  return "Chân dung"
        }
    }
}

/// Hai mode cấp cao: toàn thân (full) hay 1 phần cơ thể (upper).
nonisolated enum CaptureMode: String, Codable, CaseIterable {
    case full
    case upper

    var title: String {
        switch self {
        case .full:  return "Toàn thân"
        case .upper: return "Một phần cơ thể (phần trên)"
        }
    }
}

/// Template đã phân tích sẵn offline (TemplateAnalyzer).
nonisolated struct Template {
    // V3 — lớp khung hình suy từ ảnh mẫu. Áp nguyên xi cho mọi frame live/video.
    let framing: FramingClass
    /// 2 mode cấp cao (full / upper) — tiện cho UI + dialog.
    let captureMode: CaptureMode
    // Mục 1
    let bodyYawDeg: Double                        // -180...180, 0 = chính diện
    // Mục 2 — LƯU NHIỀU MỐC để live chọn được mốc trùng
    let sizeRatioByAnchor: [HeightAnchor: Double] // chiều dài mốc / chiều cao khung
    // Mục 3 — đơn vị chiều cao mẫu, gốc = đỉnh đầu
    let cameraHeightRel: Double
    // Mục 4 — độ, gốc = mặt phẳng ngang
    let cameraPitchDeg: Double
    // Mục 5 — 0...1 từ mép trái khung
    let torsoCenterX: Double
    // Ống kính bị khoá theo template
    let lens: LensKind
    // Mục 6
    let jointAngles: [JointName: Double]
    let spineTiltDeg: Double
    let headYawDeg: Double?                       // nil nếu template quay lưng
    /// Câu nhắc dáng soạn sẵn theo template
    let cueForModel: String
    /// Điểm khớp thô của ảnh mẫu (hệ Vision gốc dưới-trái, chuẩn hoá 0...1) —
    /// dùng để vẽ khung mẫu (ghost) lên preview cho người chụp ướm người vào.
    let ghostJoints: [VNHumanBodyPoseObservation.JointName: CGPoint]
    /// Tỉ lệ w/h của ảnh mẫu — khung mẫu được letterbox đúng tỉ lệ này để
    /// dáng người trong khong bị méo so với ảnh gốc.
    let sampleAspectRatio: Double

    var cameraHeightBucket: Int { Buckets.height(cameraHeightRel) }
    var pitchBucket: Int        { Buckets.pitch(cameraPitchDeg) }
}

/// Thông số quang học của camera đang dùng.
nonisolated struct CameraOptics {
    let hFovDeg: Double
    let vFovDeg: Double
    let focalPixels: Double        // tiêu cự quy ra pixel theo CHIỀU DỌC ảnh
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

    /// Ưu tiên tuyệt đối: lấy từ intrinsicMatrix của sample buffer (chính xác thật).
    init(intrinsics: simd_float3x3, imageSize: CGSize) {
        let fx = Double(intrinsics[0][0])
        let fy = Double(intrinsics[1][1])
        self.imageWidthPixels  = Double(imageSize.width)
        self.imageHeightPixels = Double(imageSize.height)
        self.focalPixels = fy
        self.vFovDeg = 2 * atan(Double(imageSize.height) / 2 / fy).degrees
        self.hFovDeg = 2 * atan(Double(imageSize.width)  / 2 / fx).degrees
    }

    /// Fallback khi không có intrinsics. videoFieldOfView là FOV theo cạnh DÀI cảm biến;
    /// caller truyền imageSize ở dạng DỌC (height = cạnh dài) khi cầm máy dọc.
    init(device: AVCaptureDevice, imageSize: CGSize) {
        let fovLong = Double(device.activeFormat.videoFieldOfView)
        let vFov = fovLong > 0 ? fovLong : 75.0
        let shortSide = min(imageSize.width, imageSize.height)
        let longSide  = max(imageSize.width, imageSize.height)
        let fovShort = 2 * atan(tan(vFov.radians / 2) * Double(shortSide / longSide)).degrees
        self.vFovDeg = vFov
        self.hFovDeg = fovShort
        self.imageWidthPixels  = Double(imageSize.width)
        self.imageHeightPixels = Double(imageSize.height)
        self.focalPixels = (Double(imageSize.height) / 2) / tan(vFov.radians / 2)
    }

    /// Góc lệch (độ) của một điểm so với tâm khung, theo chiều DỌC. Dương = phía trên tâm.
    /// Dùng mô hình pinhole đúng, không xấp xỉ tuyến tính theo FOV như v1.
    func elevationOffsetDeg(normalizedY y: Double) -> Double {
        atan((0.5 - y) * imageHeightPixels / focalPixels).degrees
    }

    /// Tương tự theo chiều NGANG. Dương = phía phải tâm.
    func azimuthOffsetDeg(normalizedX x: Double) -> Double {
        atan((x - 0.5) * imageWidthPixels / focalPixels).degrees
    }
}

/// Một điểm khớp phục vụ hiển thị skeleton.
nonisolated struct JointPoint {
    let location: CGPoint   // Vision-native, origin bottom-left, normalized 0-1
    let confidence: Float
}

/// Kết quả đo trên 1 frame. nil = KHÔNG ĐO ĐƯỢC (khác hẳn với "sai").
nonisolated struct Measurement {
    var timestamp: Double = 0
    var hasSubject: Bool = false

    /// Lớp khung hình áp cho frame này (do template quyết định, trước khi đo).
    var framing: FramingClass = .full
    var captureMode: CaptureMode { framing.captureMode }
    var includesHip: Bool = false   // frame live có đo được hông không

    var bodyYawDeg: Double?
    var bodyYawIsFrontalFlat: Bool = false   // đang trong vùng chết chính diện

    var heightAnchor: HeightAnchor?
    var sizeRatio: Double?                   // theo heightAnchor
    var fullHeightPixels: Double?            // chiều cao toàn thân quy đổi, pixel
    var distanceMeters: Double?              // ước lượng thô — CHỈ để đổi ra "bước"

    var cameraHeightRel: Double?             // gốc = đỉnh đầu, đơn vị chiều cao mẫu
    var cameraPitchDeg: Double = 0           // gốc = mặt phẳng ngang
    var rollDeg: Double = 0                  // vẹo chân trời (chỉ để tự nắn ảnh)
    var angularSpeedDegPerSec: Double = 0

    var torsoCenterX: Double?
    var jointAngles: [JointName: Double] = [:]
    var spineTiltDeg: Double?
    var headYawDeg: Double?

    /// Toàn bộ keypoint thô (hệ gốc dưới-trái của Vision) — dùng để vẽ skeleton overlay.
    var jointPoints: [VNHumanBodyPoseObservation.JointName: JointPoint] = [:]
}

/// Một vi phạm tiêu chí.
nonisolated struct Violation {
    enum Actor { case model, shooter }
    let criterion: Criterion
    let actor: Actor
    let error: Double            // sai số thô (đơn vị của mục)
    let normalizedError: Double  // |error| / accept — 1.0 = đúng ngưỡng
    let detail: String           // log/debug
    let cue: String              // câu hiện lên màn hình
}

nonisolated struct GuidanceResult {
    let violations: [Violation]          // đã sắp theo thứ tự 1→6
    let passedCount: Int                 // số mục đã đạt (cho vòng tiến độ)
    let readyToCapture: Bool             // TẤT CẢ mục đạt → cổng chụp mở
    let worstNormalizedError: Double
    let debug: [Criterion: String]
    /// Trạng thái RIÊNG của từng tiêu chí 1→6 — cho bảng checklist hiển thị
    /// gợi ý liên tục theo từng mục (không chỉ mục ưu tiên cao nhất).
    let statuses: [CriterionStatus]

    var primaryCue: String?   { violations.first?.cue }
    var secondaryCue: String? { violations.count > 1 ? violations[1].cue : nil }
    var isAligned: Bool { violations.isEmpty }
}

/// Một dòng trong bảng checklist 6 tiêu chí.
nonisolated struct CriterionStatus: Identifiable {
    enum State {
        case ok         // đạt
        case violated   // sai — `suggestion` là câu gợi ý riêng của mục này
        case waiting    // tạm vô nghĩa vì mục phía trên chưa đúng (vd trái/phải khi mẫu quay lưng)
        case unknown    // không đo được frame này
    }
    var id: Int { criterion.rawValue }
    let criterion: Criterion
    let state: State
    let suggestion: String?
}

// =====================================================================
// MARK: - 2. PHÂN MỨC (chỉ dùng để CHỌN CHỮ, không dùng để so sánh)
// =====================================================================

nonisolated enum Buckets {
    /// rel = (cao độ máy − đỉnh đầu) / chiều cao mẫu.
    /// Mốc giải phẫu: mắt ≈ −0.06 · vai ≈ −0.18 · hông ≈ −0.47 · gối ≈ −0.72 · đất = −1.0
    static func height(_ rel: Double) -> Int {
        if rel >  0.25 { return 4 }   // rất cao, giơ quá đầu
        if rel >  0.02 { return 3 }   // cao, ngang đỉnh đầu
        if rel > -0.27 { return 2 }   // ngang mắt / ngang mặt
        if rel > -0.62 { return 1 }   // thấp, ngang hông
        return 0                       // rất thấp, ngang gối trở xuống
    }

    static func pitch(_ deg: Double) -> Int {
        if deg >  20 { return 4 }
        if deg >   8 { return 3 }
        if deg >= -8 { return 2 }
        if deg > -20 { return 1 }
        return 0
    }

    static func heightAnchorWord(_ bucket: Int) -> String {
        switch bucket {
        case 4:  return "cao quá đầu"
        case 3:  return "ngang đầu"
        case 2:  return "ngang mắt"
        case 1:  return "ngang hông"
        default: return "sát mặt đất"
        }
    }
}

// =====================================================================
// MARK: - 3. LỌC NHIỄU
// =====================================================================

/// One Euro Filter — mượt khi đứng yên, bám nhanh khi di chuyển thật.
nonisolated final class OneEuroFilter {
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

/// Median trượt — dùng cho đại lượng có outlier nhọn (keypoint nhảy 1 frame).
nonisolated struct RollingMedian {
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
// MARK: - 4. ĐO ĐẠC TỪ FRAME (Vision + CoreMotion)
// =====================================================================

nonisolated final class Measurer {

    private let cfg: GuidanceConfig
    private let poseRequest = VNDetectHumanBodyPoseRequest()
    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3   // revision 3 mới có yaw
        return r
    }()

    // Hiệu chuẩn tỉ lệ vai/thân khi mẫu chính diện
    private var rFront: Double?
    private var rFrontSamples: [Double] = []

    // Cache face (face chạy thưa hơn pose)
    private var lastFace: VNFaceObservation?
    private var lastFaceTime: Double = -1

    // Bộ lọc — pitch được lọc RIÊNG (v1 bỏ sót, gây rung mục 4)
    private var fShoulderRatio = OneEuroFilter(minCutoff: 0.8, beta: 0.010)
    private var fSizeRatio     = OneEuroFilter(minCutoff: 1.0, beta: 0.015)
    private var fCenterX       = OneEuroFilter(minCutoff: 1.0, beta: 0.020)
    private var fHeadTopY      = OneEuroFilter(minCutoff: 1.0, beta: 0.015)
    private var fPitch         = OneEuroFilter(minCutoff: 1.2, beta: 0.010)
    private var mSpine         = RollingMedian(size: 5)

    private var validFrames = 0
    private var missStreak = 0

    init(config: GuidanceConfig = .default) { self.cfg = config }

    func reset() {
        rFront = nil; rFrontSamples.removeAll()
        lastFace = nil; lastFaceTime = -1
        validFrames = 0; missStreak = 0
        fShoulderRatio.reset(); fSizeRatio.reset(); fCenterX.reset()
        fHeadTopY.reset(); fPitch.reset(); mSpine.reset()
    }

    /// Mất subject: chỉ reset chuỗi "frame hợp lệ" khi mất LIÊN TỤC ~0.3s.
    /// Detect yếu vài frame (che khuất, rung) không được phép tê liệt hướng dẫn.
    private func noteSubjectLost() {
        missStreak += 1
        if missStreak > 10 {
            validFrames = 0
            missStreak = 0
        }
    }

    /// Đo 1 frame.
    /// - parameter framing: lớp khung hình từ template (suy 1 lần, áp nguyên xi).
    ///   Với lớp chân dung (chest/head) KHÔNG đòi hông — chỉ cần vai + mặt.
    func measure(pixelBuffer: CVPixelBuffer,
                 deviceMotion: CMDeviceMotion?,
                 optics: CameraOptics,
                 orientation: CGImagePropertyOrientation,
                 timestamp: Double,
                 runFace: Bool,
                 framing: FramingClass) -> Measurement {

        var m = Measurement(timestamp: timestamp, framing: framing)

        // ---------- Góc máy từ TRỌNG LỰC ----------
        if let dm = deviceMotion {
            let g = dm.gravity
            // Trục quang camera sau = −z của device. Góc ngẩng so với mặt phẳng ngang:
            //   elevation = asin(g.z)   (hướng lên = −g)
            // KHÔNG dùng attitude.pitch: phụ thuộc reference frame, bị gimbal lock.
            let rawPitch = asin(max(-1, min(1, g.z))).degrees
            m.cameraPitchDeg = fPitch.filter(rawPitch, timestamp: timestamp)
            // Vẹo chân trời (cầm dọc): chỉ đọc để tự nắn ảnh, KHÔNG hướng dẫn.
            m.rollDeg = atan2(g.x, -g.y).degrees
            let rr = dm.rotationRate
            m.angularSpeedDegPerSec = sqrt(rr.x*rr.x + rr.y*rr.y + rr.z*rr.z).degrees
        }

        // ---------- Vision ----------
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: orientation, options: [:])
        var requests: [VNRequest] = [poseRequest]
        if runFace { requests.append(faceRequest) }
        try? handler.perform(requests)

        // Keypoint cho skeleton overlay — độc lập với việc có template hay không.
        if let allPts = try? poseRequest.results?.first?.recognizedPoints(.all), !allPts.isEmpty {
            m.jointPoints = allPts.reduce(into: [:]) { dict, entry in
                guard entry.value.confidence >= cfg.minKeypointConfidenceDisplay else { return }
                dict[entry.key] = JointPoint(location: entry.value.location,
                                             confidence: entry.value.confidence)
            }
        }

        if runFace, let f = faceRequest.results?.first {
            lastFace = f; lastFaceTime = timestamp
        }
        let face: VNFaceObservation? =
            (timestamp - lastFaceTime <= cfg.faceCacheSeconds) ? lastFace : nil

        guard let obs = poseRequest.results?.first,
              let pts = try? obs.recognizedPoints(.all) else {
            noteSubjectLost()
            return m
        }

        // Lấy keypoint, LẬT Y (Vision gốc dưới-trái → ta dùng gốc trên-trái)
        func p(_ n: VNHumanBodyPoseObservation.JointName, _ minConf: Float) -> SIMD2<Double>? {
            guard let q = pts[n], q.confidence >= minConf else { return nil }
            return SIMD2(Double(q.location.x), 1.0 - Double(q.location.y))
        }
        let core = cfg.minKeypointConfidenceCore
        let limb = cfg.minKeypointConfidenceLimb

        // Fallback mềm 2 bậc: core → limb → floor. Không có fallback này, chỉ 1 frame
        // detect yếu cũng tắt toàn bộ hướng dẫn (đây là lý do thực tế khiến cue
        // "biến mất" và badge báo "không tìm thấy người" dù người vẫn đứng trong khung).
        //
        // RẠCH RÒI THEO LỚP: chân dung (chest/head) chỉ cần VAI + (mặt), KHÔNG đòi hông.
        // Hông của ảnh bán thân thường ngoài khung → đòi hông sẽ làm hướng dẫn tê liệt.
        let torsoFloor = cfg.minKeypointConfidenceTorsoFloor
        guard let lSh = p(.leftShoulder, core) ?? p(.leftShoulder, limb) ?? p(.leftShoulder, torsoFloor),
              let rSh = p(.rightShoulder, core) ?? p(.rightShoulder, limb) ?? p(.rightShoulder, torsoFloor) else {
            noteSubjectLost()   // suy giảm êm — chỉ reset chuỗi khi mất thật sự
            return m
        }
        let needHip = framing.requiresHip
        let lHip = needHip ? (p(.leftHip, core) ?? p(.leftHip, limb) ?? p(.leftHip, torsoFloor)) : nil
        let rHip = needHip ? (p(.rightHip, core) ?? p(.rightHip, limb) ?? p(.rightHip, torsoFloor)) : nil
        guard !needHip || (lHip != nil && rHip != nil) else {
            noteSubjectLost()
            return m
        }
        missStreak = 0
        validFrames += 1
        guard validFrames >= cfg.minValidFramesBeforeUse else { return m }

        m.hasSubject = true
        m.includesHip = (lHip != nil && rHip != nil)
        let neck = (lSh + rSh) / 2
        let hips: SIMD2<Double>? = (lHip != nil && rHip != nil) ? (lHip! + rHip!) / 2 : nil
        let nose = p(.nose, limb)
        let torsoHeight = hips.map { abs(neck.y - $0.y) } ?? 0

        // ---------- MỤC 5: tâm thân theo chiều ngang — theo lớp ----------
        switch framing {
        case .head:
            if let f = face { m.torsoCenterX = fCenterX.filter(Double(f.boundingBox.midX), timestamp: timestamp) }
            else { m.torsoCenterX = fCenterX.filter(neck.x, timestamp: timestamp) }
        case .chest:
            m.torsoCenterX = fCenterX.filter(neck.x, timestamp: timestamp)
        case .full, .knee, .half:
            if let h = hips { m.torsoCenterX = fCenterX.filter((neck.x + h.x) / 2, timestamp: timestamp) }
            else { m.torsoCenterX = fCenterX.filter(neck.x, timestamp: timestamp) }
        }

        // ---------- Đỉnh đầu — ba đường lấy, ưu tiên giảm dần ----------
        var headTopY: Double?
        if let f = face {
            // boundingBox gốc dưới-trái → mép trên sau khi lật Y
            headTopY = 1.0 - Double(f.boundingBox.origin.y + f.boundingBox.height)
        } else if torsoHeight > 0.02 {
            // Nhân trắc: đỉnh đầu cách cổ 0.18H, vai→hông = 0.29H ⇒ hệ số 0.62
            headTopY = neck.y - 0.62 * torsoHeight
        } else if let nose = nose {
            headTopY = nose.y - 0.6 * abs(nose.y - neck.y)
        }
        if let h = headTopY { headTopY = fHeadTopY.filter(h, timestamp: timestamp) }

        // ---------- MỤC 1: hướng mẫu — theo nguồn của LỚP ----------
        switch framing.yawSource {
        case .faceYaw:
            // CHEST/HEAD: hông khuất nên dùng face yaw (chính xác hơn cả vai).
            if let f = face, let yaw = f.yaw?.doubleValue {
                m.bodyYawDeg = yaw.degrees
        } else if let nose, hips != nil, torsoHeight >= cfg.bodyYawMinTorsoHeight {
            m.bodyYawDeg = nose.x > neck.x ? 1 : -1   // dự phòng thô
        }
    case .shoulderForeshortening:
        if hips != nil, torsoHeight >= cfg.bodyYawMinTorsoHeight {
                let rawR = abs(lSh.x - rSh.x) / torsoHeight
                let r = fShoulderRatio.filter(rawR, timestamp: timestamp)   // LỌC TRƯỚC acos

                // Hiệu chuẩn r_front: khi thấy mặt gần chính diện
                if rFront == nil, let f = face,
                   let yaw = f.yaw?.doubleValue, abs(yaw.degrees) < 10 {
                    rFrontSamples.append(r)
                    if rFrontSamples.count >= 10 {
                        rFront = rFrontSamples.sorted()[rFrontSamples.count / 2]
                    }
                }
                let base = rFront ?? cfg.defaultRFront
                let ratio = min(max(r / base, 0), 1)

                if ratio >= cfg.bodyYawFrontalDeadZone {
                    // Vùng chết chính diện — acos ở đây khuếch đại nhiễu, không tính góc.
                    m.bodyYawDeg = 0
                    m.bodyYawIsFrontalFlat = true
                } else {
                    let absYaw = acos(ratio).degrees
                    var signedYaw = absYaw
                    if let nose = nose { signedYaw = (nose.x > neck.x) ? absYaw : -absYaw }
                    // Trước/sau: thấy mặt ⇒ chắc chắn nửa trước; không thì suy từ thứ tự vai
                    let seeingFront = (face != nil) || (lSh.x > rSh.x)
                    m.bodyYawDeg = seeingFront
                        ? signedYaw
                        : (signedYaw >= 0 ? 180 - absYaw : -180 + absYaw)
                }
            }
        }

        // ---------- MỤC 2: xa/gần — DÙNG ĐÚNG MỐC của LỚP ----------
        let ankleY = [p(.leftAnkle, limb)?.y, p(.rightAnkle, limb)?.y].compactMap { $0 }.max()
        let kneeY  = [p(.leftKnee,  limb)?.y, p(.rightKnee,  limb)?.y].compactMap { $0 }.max()
        let scaleAnchor = framing.scaleAnchor

        var span: Double?
        var anchor: HeightAnchor?
        if scaleAnchor == .faceHeight {
            // CHEST/HEAD: chiều cao khung mặt.
            if let f = face {
                span = Double(f.boundingBox.height); anchor = .faceHeight
            } else {
                span = abs(lSh.x - rSh.x) * 0.55; anchor = .faceHeight
            }
        } else if let top = headTopY {
            if scaleAnchor == .headToAnkle, let a = ankleY, a > top { span = a - top; anchor = .headToAnkle }
            else if scaleAnchor == .headToKnee, let k = kneeY, k > top { span = k - top; anchor = .headToKnee }
            else if scaleAnchor == .headToHip, let h = hips, h.y > top { span = h.y - top; anchor = .headToHip }
        }

        if let span = span, let anchor = anchor {
            let smoothed = fSizeRatio.filter(span, timestamp: timestamp)
            m.heightAnchor = anchor
            m.sizeRatio = smoothed
            if anchor.isFullHeightScalable {
                let fullPx = (smoothed / anchor.factorOfFullHeight) * optics.imageHeightPixels
                m.fullHeightPixels = fullPx
                if fullPx > 1 {
                    // Ước lượng thô, CHỈ dùng để đổi % → "bước". Không dùng để so ngưỡng.
                    m.distanceMeters = optics.focalPixels * cfg.assumedBodyHeightMeters / fullPx
                }

                // ---------- MỤC 3: máy cao/thấp, ĐƠN VỊ CHIỀU CAO MẪU ----------
                // rel = −f·tan(góc ngẩng tới đỉnh đầu) / chiều-cao-mẫu-pixel.
                if let top = headTopY, fullPx > 1 {
                    let elev = m.cameraPitchDeg + optics.elevationOffsetDeg(normalizedY: top)
                    m.cameraHeightRel = -optics.focalPixels * tan(elev.radians) / fullPx
                }
            }
        }

        // ---------- MỤC 6: dáng — CHỈ nhóm khớp THUỘC LỚP ----------
        if let h = hips, torsoHeight > 1e-6 {
            m.spineTiltDeg = mSpine.push(atan2(neck.x - h.x, max(torsoHeight, 1e-6)).degrees)
        } else {
            m.spineTiltDeg = mSpine.push(0)
        }
        m.jointAngles = Self.jointAngles(pts: pts, minConf: limb,
                                         groups: framing.poseGroups, includeHip: m.includesHip)
        if let f = face, let yaw = f.yaw?.doubleValue { m.headYawDeg = yaw.degrees }

        return m
    }

    /// Tính góc tại các khớp, giới hạn theo nhóm khớp THUỘC LỚP khung hình.
    /// - Parameters:
    ///   - groups: các nhóm được chấm (spine/head điều khiển bởi caller; ở đây arms/legs).
    ///   - includeHip: có điểm hông để tính góc vai không (chân dung hông khuất → bỏ vai).
    static func jointAngles(pts: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
                            minConf: Float,
                            groups: [PoseGroup] = [.spine, .head, .arms, .legs],
                            includeHip: Bool = true) -> [JointName: Double] {
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
        let arms = groups.contains(.arms)
        let legs = groups.contains(.legs)
        var out: [JointName: Double] = [:]
        if arms {
            // Góc vai cần hông làm đỉnh thứ 3 → chỉ tính khi có hông.
            if includeHip {
                out[.leftShoulder]  = angle(p(.leftElbow), p(.leftShoulder), p(.leftHip))
                out[.rightShoulder] = angle(p(.rightElbow), p(.rightShoulder), p(.rightHip))
            }
            out[.leftElbow]  = angle(p(.leftShoulder), p(.leftElbow), p(.leftWrist))
            out[.rightElbow] = angle(p(.rightShoulder), p(.rightElbow), p(.rightWrist))
        }
        if legs {
            out[.leftKnee]  = angle(p(.leftHip), p(.leftKnee), p(.leftAnkle))
            out[.rightKnee] = angle(p(.rightHip), p(.rightKnee), p(.rightAnkle))
        }
        return out.compactMapValues { $0 }
    }
}

// =====================================================================
// MARK: - 5. TRẠNG THÁI TỪNG MỤC — vùng chết, trễ, khóa, chống kẹt
// =====================================================================

/// Máy trạng thái cho MỘT tiêu chí. Đây là chỗ dập tắt hiện tượng cue nhấp nháy.
nonisolated final class CriterionGate {
    enum Status { case unknown, passing, failing }

    private(set) var status: Status = .unknown
    private(set) var locked = false               // đã từng đạt
    private var candidateSince: Double?           // thời điểm bắt đầu ở trạng thái ngược lại
    private var blockedGateSince: Double?         // đang chặn cổng chụp từ lúc nào

    let band: ThresholdBand
    let config: GuidanceConfig

    init(band: ThresholdBand, config: GuidanceConfig) {
        self.band = band; self.config = config
    }

    func reset() {
        status = .unknown; locked = false
        candidateSince = nil; blockedGateSince = nil
    }

    /// - Parameters:
    ///   - error: sai số theo đơn vị của mục. nil = không đo được → bỏ qua, coi như đạt.
    ///   - action: lượng phải sửa (cùng đơn vị với band.actionFloor).
    @discardableResult
    func update(error: Double?, action: Double, now: Double) -> (failing: Bool, showCue: Bool) {

        // Không đo được → không phán xét (nguyên tắc PRD: loại mục ra, không trừ điểm)
        guard let raw = error, raw.isFinite else {
            candidateSince = nil
            return (false, false)
        }
        let e = abs(raw)

        // Hành động cần sửa quá nhỏ → im, dù sai số có vượt ngưỡng.
        // ("Đưa máy sang phải 1cm" là câu vô nghĩa với người cầm máy.)
        if action < band.actionFloor {
            markPassing(now: now)
            return (false, false)
        }

        let failThreshold: Double = locked ? band.unlock : band.enter

        if e > failThreshold {
            // Ứng viên VI PHẠM — phải kéo dài đủ lâu mới đổi trạng thái
            if status != .failing {
                if candidateSince == nil { candidateSince = now }
                if now - candidateSince! >= config.cueEnterHoldSeconds {
                    status = .failing; locked = false; candidateSince = nil
                }
            } else { candidateSince = nil }
        } else if e <= band.accept {
            markPassing(now: now)
        } else {
            // VÙNG XÁM (accept < e <= failThreshold): giữ nguyên trạng thái.
            candidateSince = nil
            if status == .unknown { status = .failing }   // lần đầu thì vẫn nên chỉnh
        }

        // Chống kẹt: đã khóa nhưng trôi khỏi accept làm cổng chụp mãi không mở.
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

    /// Mục này có đang mở cổng chụp không.
    var passesCaptureGate: Bool { status == .passing }
}

// =====================================================================
// MARK: - 6. SINH CÂU CUE (có làm tròn số)
// =====================================================================

nonisolated enum CueFactory {

    static func quantize(_ v: Double, step: Double) -> Double {
        guard step > 0 else { return v }
        return (v / step).rounded() * step
    }

    // --- Mục 1 ---
    static func bodyYaw(delta d: Double, targetYaw: Double, cfg: GuidanceConfig) -> String {
        if abs(targetYaw) > 150 { return "Bảo mẫu quay lưng lại" }
        if abs(abs(targetYaw) - 90) < 30 {
            return targetYaw > 0 ? "Bảo mẫu quay nghiêng sang phải"
                                 : "Bảo mẫu quay nghiêng sang trái"
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

    // --- Mục 3 ---
    static func cameraHeight(relDelta d: Double, fullHeightMeters: Double,
                             targetBucket: Int, cfg: GuidanceConfig) -> String {
        let word = Buckets.heightAnchorWord(targetBucket)
        let cm = quantize(abs(d) * fullHeightMeters * 100, step: cfg.quantizeCentimeters)
        if cm >= 10 {
            return d > 0 ? "Hạ điện thoại xuống ~\(Int(cm))cm (\(word))"
                         : "Nâng điện thoại lên ~\(Int(cm))cm (\(word))"
        }
        return d > 0 ? "Hạ điện thoại xuống (\(word))" : "Nâng điện thoại lên (\(word))"
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
    static func horizontal(offset: Double, optics: CameraOptics, cfg: GuidanceConfig) -> String {
        // offset dương = mẫu đang nằm bên PHẢI chỗ cần → phải đưa máy sang phải
        if abs(offset) >= cfg.panVsStepThreshold {
            return offset > 0 ? "Bước sang phải 1 bước" : "Bước sang trái 1 bước"
        }
        let deg = quantize(abs(optics.azimuthOffsetDeg(normalizedX: 0.5 + offset)),
                           step: cfg.quantizeDegrees)
        if deg < cfg.quantizeDegrees {
            return offset > 0 ? "Đưa điện thoại sang phải một chút"
                              : "Đưa điện thoại sang trái một chút"
        }
        return offset > 0 ? "Xoay điện thoại sang phải \(Int(deg)) độ"
                          : "Xoay điện thoại sang trái \(Int(deg)) độ"
    }
}

// =====================================================================
// MARK: - 7. ĐIỀU PHỐI HIỂN THỊ CUE (thời gian tối thiểu, chống nhảy số)
// =====================================================================

nonisolated final class CuePresenter {
    private var currentCriterion: Criterion?
    private var currentText: String?
    private var shownAt: Double = 0
    private var lastNumberUpdate: Double = 0
    private let cfg: GuidanceConfig

    init(config: GuidanceConfig = .default) { self.cfg = config }

    func reset() { currentCriterion = nil; currentText = nil; shownAt = 0; lastNumberUpdate = 0 }

    /// - Parameter frozen: true khi máy đang bị lắc mạnh → giữ nguyên cue cũ.
    func present(_ v: Violation?, now: Double, frozen: Bool) -> String? {
        if frozen { return currentText }

        guard let v = v else {
            currentCriterion = nil; currentText = nil
            return nil
        }
        // Cue của mục ưu tiên cao hơn được chen ngang ngay lập tức.
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
        // Cùng mục: chỉ cho phép đổi CHỮ (thường là đổi con số) theo nhịp chậm.
        if v.cue != currentText, now - lastNumberUpdate >= cfg.cueNumberRefreshSeconds {
            currentText = v.cue
            lastNumberUpdate = now
        }
        return currentText
    }
}

// =====================================================================
// MARK: - 8. ĐÁNH GIÁ THEO THỨ TỰ 1→6
// =====================================================================

nonisolated final class GuidanceEngine {

    private let cfg: GuidanceConfig
    private var gates: [Criterion: CriterionGate] = [:]
    private let presenter: CuePresenter

    init(config: GuidanceConfig = .default) {
        self.cfg = config
        self.presenter = CuePresenter(config: config)
        let bands: [Criterion: ThresholdBand] = [
            .bodyYaw:      config.bodyYaw,
            .distance:     config.distance,
            .cameraHeight: config.cameraHeight,
            .cameraPitch:  config.cameraPitch,
            .horizontal:   config.horizontal,
            .pose:         config.jointAngle,
        ]
        for (c, band) in bands {
            gates[c] = CriterionGate(band: band, config: config)
        }
    }

    func reset() {
        gates.values.forEach { $0.reset() }
        presenter.reset()
    }

    /// Cue đã qua CuePresenter (chống nhảy mục/nhảy số) — dùng cho UI realtime.
    /// Gọi SAU evaluate với cùng timestamp.
    func stablePrimaryCue(for result: GuidanceResult, now: Double, frozen: Bool) -> String? {
        presenter.present(result.violations.first, now: now, frozen: frozen)
    }

    func evaluate(_ m: Measurement, _ t: Template, _ optics: CameraOptics) -> GuidanceResult {

        let now = m.timestamp
        var violations: [Violation] = []
        var debug: [Criterion: String] = [:]
        var cues: [Criterion: String] = [:]
        var horizontalWaiting = false

        guard m.hasSubject else {
            let v = Violation(criterion: .bodyYaw, actor: .shooter, error: 0,
                              normalizedError: 99, detail: "no subject",
                              cue: "Đưa mẫu vào khung")
            return GuidanceResult(violations: [v], passedCount: passedCount(),
                                  readyToCapture: false,
                                  worstNormalizedError: 99, debug: debug,
                                  statuses: Criterion.allCases.map {
                                      CriterionStatus(criterion: $0, state: .unknown, suggestion: nil)
                                  })
        }

        // ---------------- MỤC 1: HƯỚNG MẪU ----------------
        var yawErr: Double?
        if let yaw = m.bodyYawDeg {
            // Vùng chết chính diện + template cũng chính diện ⇒ khỏi so góc
            if m.bodyYawIsFrontalFlat && abs(t.bodyYawDeg) < cfg.bodyYaw.accept {
                yawErr = 0
            } else {
                yawErr = signedAngleDelta(yaw, t.bodyYawDeg)
            }
        }
        let g1 = gates[.bodyYaw]!.update(error: yawErr, action: abs(yawErr ?? 0), now: now)
        debug[.bodyYaw] = fmt(yawErr, cfg.bodyYaw.accept, "°")
        if g1.failing {
            let d = yawErr ?? 0
            let cue = CueFactory.bodyYaw(delta: d, targetYaw: t.bodyYawDeg, cfg: cfg)
            violations.append(Violation(
                criterion: .bodyYaw, actor: .model, error: d,
                normalizedError: abs(d) / cfg.bodyYaw.accept,
                detail: String(format: "lệch %.0f°", d),
                cue: cue))
            cues[.bodyYaw] = cue
            // v2 cũ DỪNG Ở ĐÂY (return sớm) → các mục dưới không bao giờ được gợi ý
            // khi hướng mẫu sai. Giờ vẫn đo tiếp để gợi ý LIÊN TỤC từng tiêu chí;
            // thứ tự ưu tiên 1→6 chỉ còn quyết định cue CHÍNH hiển thị to.
        }

        // ---------------- MỤC 2: XA/GẦN — so cùng mốc HeightAnchor ----------------
        var sizeErr: Double?
        var sizeAction: Double = 0
        if let anchor = m.heightAnchor, let live = m.sizeRatio,
           let tmpl = t.sizeRatioByAnchor[anchor], tmpl > 0 {
            sizeErr = live / tmpl - 1.0
            sizeAction = abs((m.distanceMeters ?? 2.0) * sizeErr!)   // mét cần đi
        }
        let g2 = gates[.distance]!.update(error: sizeErr, action: sizeAction, now: now)
        debug[.distance] = fmt(sizeErr, cfg.distance.accept, "") + " [\(m.heightAnchor.map { "\($0)" } ?? "n/a")]"
        if g2.failing, let e = sizeErr {
            violations.append(Violation(
                criterion: .distance, actor: .shooter, error: e,
                normalizedError: abs(e) / cfg.distance.accept,
                detail: String(format: "chênh %.0f%% (%.2fm)", e * 100, sizeAction),
                cue: CueFactory.distance(relError: e, distanceMeters: m.distanceMeters, cfg: cfg)))
        }

        // ---------------- MỤC 3: MÁY CAO/THẤP — so SỐ LIÊN TỤC (đơn vị H mẫu) --------
        var heightErr: Double?
        var heightAction: Double = 0
        if let rel = m.cameraHeightRel {
            heightErr = rel - t.cameraHeightRel
            heightAction = abs(heightErr!)   // cùng đơn vị với actionFloor: H mẫu
        }
        let g3 = gates[.cameraHeight]!.update(error: heightErr, action: heightAction, now: now)
        debug[.cameraHeight] = fmt(heightErr, cfg.cameraHeight.accept, "H")
        if g3.failing, let e = heightErr {
            let fullH = cfg.assumedBodyHeightMeters   // chỉ dùng để đổi ra cm trong CÂU CHỮ
            violations.append(Violation(
                criterion: .cameraHeight, actor: .shooter, error: e,
                normalizedError: abs(e) / cfg.cameraHeight.accept,
                detail: String(format: "lệch %.3fH (~%.0fcm)", e, e * fullH * 100),
                cue: CueFactory.cameraHeight(relDelta: e, fullHeightMeters: fullH,
                                             targetBucket: t.cameraHeightBucket, cfg: cfg)))
        }

        // ---------------- MỤC 4: NGỬA/CHÚC — so SỐ LIÊN TỰC (độ, gốc = ngang) --------
        let pitchErr = m.cameraPitchDeg - t.cameraPitchDeg
        let g4 = gates[.cameraPitch]!.update(error: pitchErr, action: abs(pitchErr), now: now)
        debug[.cameraPitch] = fmt(pitchErr, cfg.cameraPitch.accept, "°")
        if g4.failing {
            violations.append(Violation(
                criterion: .cameraPitch, actor: .shooter, error: pitchErr,
                normalizedError: abs(pitchErr) / cfg.cameraPitch.accept,
                detail: String(format: "lệch %.1f°", pitchErr),
                cue: CueFactory.cameraPitch(delta: pitchErr, cfg: cfg)))
        }

        // ---------------- MỤC 5: TRÁI/PHẢI — hiệu X tâm thân ----------------
        var offErr: Double?
        if let cx = m.torsoCenterX {
            if let ye = yawErr, abs(ye) > 90 {
                // Mẫu đang quay lưng/nghiêng quá nửa vòng ⇒ trục trái/phải nhìn thấy
                // bị ĐẢO NGƯỢC → không gợi ý mù, đánh dấu "chờ hướng đúng".
                horizontalWaiting = true
                debug[.horizontal] = "chờ hướng mẫu đúng"
            } else {
                offErr = cx - t.torsoCenterX
            }
        }
        let g5 = horizontalWaiting
            ? gates[.horizontal]!.update(error: nil, action: 0, now: now)
            : gates[.horizontal]!.update(error: offErr, action: abs(offErr ?? 0), now: now)
        if !horizontalWaiting {
            debug[.horizontal] = fmt(offErr, cfg.horizontal.accept, "W")
        }
        if g5.failing, let e = offErr {
            let cue = CueFactory.horizontal(offset: e, optics: optics, cfg: cfg)
            violations.append(Violation(
                criterion: .horizontal, actor: .shooter, error: e,
                normalizedError: abs(e) / cfg.horizontal.accept,
                detail: String(format: "lệch %.1f%% khung", e * 100),
                cue: cue))
            cues[.horizontal] = cue
        }

        // ---------------- MỤC 6: DÁNG — LUÔN ĐO (bản cũ bỏ qua khi 1–5 còn lỗi
        // nên bảng gợi ý liên tục thiếu mục quan trọng nhất) ----------------
        if let (err, cue, name) = poseDeviation(m, t) {
            let g6 = gates[.pose]!.update(error: err, action: abs(err), now: now)
            debug[.pose] = fmt(err, cfg.jointAngle.accept, "° \(name)")
            if g6.failing {
                violations.append(Violation(
                    criterion: .pose, actor: .model, error: err,
                    normalizedError: abs(err) / cfg.jointAngle.accept,
                    detail: String(format: "%@ lệch %.0f°", name, err),
                    cue: cue))
                cues[.pose] = cue
            }
        } else {
            gates[.pose]!.update(error: 0, action: 0, now: now)
            debug[.pose] = "ok"
        }

        let worst = violations.map { $0.normalizedError }.max() ?? 0
        return finalize(violations: violations, debug: debug, cues: cues,
                        horizontalWaiting: horizontalWaiting, worst: worst)
    }

    private func finalize(violations: [Violation], debug: [Criterion: String],
                          cues: [Criterion: String], horizontalWaiting: Bool,
                          worst: Double) -> GuidanceResult {
        let vs = violations.sorted { $0.criterion.rawValue < $1.criterion.rawValue }
        // Trạng thái từng mục cho checklist liên tục.
        let statuses: [CriterionStatus] = Criterion.allCases.sorted { $0.rawValue < $1.rawValue }
            .map { c in
                if let cue = cues[c] {
                    return CriterionStatus(criterion: c, state: .violated, suggestion: cue)
                }
                switch gates[c]!.status {
                case .passing:
                    return CriterionStatus(criterion: c, state: .ok, suggestion: nil)
                case .failing:
                    // Đang trong cửa sổ debounce — chưa đủ dữ kiện đổi trạng thái.
                    return CriterionStatus(criterion: c, state: .violated, suggestion: nil)
                case .unknown:
                    let state: CriterionStatus.State =
                        (horizontalWaiting && c == .horizontal) ? .waiting : .unknown
                    return CriterionStatus(criterion: c, state: state, suggestion: nil)
                }
            }
        let ready = vs.isEmpty
            && Criterion.allCases.allSatisfy { gates[$0]!.passesCaptureGate }
        return GuidanceResult(violations: vs, passedCount: passedCount(),
                              readyToCapture: ready,
                              worstNormalizedError: worst, debug: debug,
                              statuses: statuses)
    }

    private func passedCount() -> Int {
        Criterion.allCases.filter { gates[$0]!.passesCaptureGate }.count
    }

    /// Dáng: trục thân → đầu → tay → chân. Trả về sai lệch NẶNG NHẤT theo thứ tự.
    /// RẠCH RÒI THEO LỚP: chỉ chấm các nhóm khớp thuộc `t.framing.poseGroups`.
    private func poseDeviation(_ m: Measurement, _ t: Template) -> (Double, String, String)? {
        let groups = t.framing.poseGroups
        // 6a. Trục thân
        if groups.contains(.spine), let s = m.spineTiltDeg {
            let d = s - t.spineTiltDeg
            if abs(d) > cfg.spineTilt.enter {
                return (d, d > 0 ? "Bảo mẫu nghiêng người sang trái"
                                 : "Bảo mẫu nghiêng người sang phải", "trục thân")
            }
        }
        // 6b. Đầu
        if groups.contains(.head), let tH = t.headYawDeg, let mH = m.headYawDeg {
            let d = signedAngleDelta(mH, tH)
            if abs(d) > cfg.headYaw.enter {
                return (d, d > 0 ? "Bảo mẫu quay mặt sang trái"
                                 : "Bảo mẫu quay mặt sang phải", "hướng đầu")
            }
        }
        // 6c. Tay (nhóm .arms) rồi 6d. Chân (nhóm .legs) — chỉ khớp thuộc lớp.
        let order: [JointName] = [.leftShoulder, .rightShoulder, .leftElbow, .rightElbow,
                                  .leftKnee, .rightKnee]
        for j in order where Self.jointGroup(j) == .arms ? groups.contains(.arms) : groups.contains(.legs) {
            guard let cur = m.jointAngles[j], let target = t.jointAngles[j] else { continue }
            let d = cur - target
            if abs(d) > cfg.jointAngle.enter {
                return (d, t.cueForModel, j.rawValue)
            }
        }
        return nil
    }

    /// Một khớp thuộc nhóm nào (arms hay legs).
    private static func jointGroup(_ j: JointName) -> PoseGroup {
        switch j {
        case .leftKnee, .rightKnee: return .legs
        case .leftShoulder, .rightShoulder, .leftElbow, .rightElbow: return .arms
        }
    }

    private func fmt(_ v: Double?, _ accept: Double, _ unit: String) -> String {
        guard let v = v else { return "n/a" }
        return String(format: "%.3f%@ / ngưỡng %.3f (x%.2f)", v, unit, accept, abs(v) / accept)
    }
}

// =====================================================================
// MARK: - 9. CỔNG CHỤP: DWELL → ĐẾM NGƯỢC → GHI
// =====================================================================

/// Quản lý: đủ 6 mục → giữ ổn định `dwellSeconds` → đếm ngược → ghi NGAY TỪ LÚC ĐẾM.
nonisolated final class CaptureTrigger {
    enum State { case guiding, dwelling(since: Double), countingDown(until: Double), recording }
    private(set) var state: State = .guiding
    private var lostAlignedSince: Double?
    private let cfg: GuidanceConfig

    init(config: GuidanceConfig = .default) { self.cfg = config }

    /// Trả về true tại ĐÚNG frame cần BẮT ĐẦU GHI/CHỤP (ngay khi bắt đầu đếm ngược).
    func update(ready: Bool, now: Double) -> Bool {
        switch state {
        case .guiding:
            if ready { state = .dwelling(since: now) }
            return false

        case .dwelling(let since):
            if !ready { state = .guiding; return false }
            if now - since >= cfg.dwellSeconds {
                state = .countingDown(until: now + cfg.countdownSeconds)
                return true                       // ← GHI BẮT ĐẦU TỪ ĐÂY
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

nonisolated extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}

/// Hiệu góc có dấu, chuẩn hóa về -180...180 (tránh lỗi khi qua mốc ±180).
nonisolated func signedAngleDelta(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}
