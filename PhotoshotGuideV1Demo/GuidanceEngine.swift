//
//  GuidanceEngine.swift
//  Thuật toán kiểm 6 tiêu chí và sinh cue hướng dẫn realtime
//
//  Đầu vào : 1 frame ảnh (CVPixelBuffer) + attitude từ CoreMotion + thông số ống kính
//  Đầu ra  : danh sách vi phạm theo đúng thứ tự ưu tiên 1→6, kèm cue cho mục đầu tiên
//
//  Công nghệ: Vision framework (VNDetectHumanBodyPoseRequest, VNDetectFaceRectanglesRequest)
//             CoreMotion (CMDeviceMotion.attitude.pitch)
//  Không train model, không gọi server.
//

import Vision
import CoreMotion
import AVFoundation
import simd

// =====================================================================
// MARK: - 1. KIỂU DỮ LIỆU
// =====================================================================

enum LensKind { case ultraWide, wide }   // 0.5x / 1x

enum JointName: String, CaseIterable {
    case leftElbow, rightElbow, leftShoulder, rightShoulder
    case leftKnee, rightKnee, leftHip, rightHip
}

/// Template đã được phân tích sẵn (xem TemplateAnalyzer.swift) từ ảnh mẫu người dùng chọn.
struct Template {
    // Mục 1 — hướng mẫu
    let bodyYawDeg: Double            // -180...180. 0 = chính diện, 180 = quay lưng
    // Mục 2 — xa/gần
    let subjectHeightRatio: Double    // chiều cao mẫu / chiều cao khung (0...1)
    // Mục 3 — máy cao/thấp
    let cameraHeightBucket: Int       // 0 rất thấp · 1 thấp · 2 ngang mắt · 3 cao · 4 rất cao
    // Mục 4 — ngửa/chúc
    let pitchDeg: Double              // âm = chúc xuống, dương = ngửa lên
    let pitchBucket: Int              // 0...4
    // Mục 5 — trái/phải
    let hipCenterX: Double            // 0...1, tính từ mép trái khung
    // Ống kính
    let lens: LensKind
    // Mục 6 — dáng
    let jointAngles: [JointName: Double]
    let spineTiltDeg: Double
    let headYawDeg: Double?           // nil nếu template không thấy mặt (ảnh quay lưng)
    // Câu đọc cho mẫu ở pha đầu
    let cueForModel: String
}

/// Thông số quang học của camera đang dùng.
struct CameraOptics {
    let hFovDeg: Double               // FOV ngang
    let vFovDeg: Double               // FOV dọc
    let focalPixels: Double           // tiêu cự quy ra pixel (từ intrinsicMatrix)
    let imageHeightPixels: Double

    /// Tính từ AVCaptureDevice. imageSize PHẢI ở dạng dọc (height = cạnh dài) vì
    /// videoFieldOfView là FOV theo chiều dài cảm biến — cầm dọc thì đó là chiều dọc ảnh.
    init(device: AVCaptureDevice, imageSize: CGSize) {
        let fovLong = Double(device.activeFormat.videoFieldOfView)
        let shortOverLong = min(imageSize.width, imageSize.height) / max(imageSize.width, imageSize.height)
        let fovShort = 2 * atan(tan(fovLong.radians / 2) * shortOverLong).degrees
        self.vFovDeg = fovLong
        self.hFovDeg = fovShort
        self.imageHeightPixels = imageSize.height
        self.focalPixels = (imageSize.height / 2) / tan(fovLong.radians / 2)
    }
}

/// A single detected body joint kept for display purposes.
struct JointPoint {
    let location: CGPoint   // Vision-native, origin bottom-left, normalized 0-1
    let confidence: Float
}

/// Kết quả đo được trên 1 frame. nil = không đo được (KHÁC với "sai").
struct Measurement {
    var bodyYawDeg: Double?
    var subjectHeightRatio: Double?
    var distanceMeters: Double?
    var cameraHeightBucket: Int?
    var cameraHeightDiffMeters: Double?   // dương = máy cao hơn đầu mẫu
    var pitchDeg: Double
    var pitchBucket: Int
    var hipCenterX: Double?
    var jointAngles: [JointName: Double] = [:]
    var spineTiltDeg: Double?
    var headYawDeg: Double?
    var hasSubject: Bool = false
    /// Toàn bộ keypoint thô (hệ gốc dưới-trái của Vision) — dùng để vẽ skeleton overlay.
    var jointPoints: [VNHumanBodyPoseObservation.JointName: JointPoint] = [:]
}

/// Một vi phạm tiêu chí.
struct Violation {
    let criterionIndex: Int           // 1...6
    let name: String
    let actor: Actor                  // ai phải làm
    let deltaDescription: String      // lệch bao nhiêu (log/debug)
    let cue: String                   // câu hiện lên màn hình
    enum Actor { case model, shooter }
}

struct GuidanceResult {
    let violations: [Violation]       // đã sắp theo thứ tự 1→6
    var primaryCue: String?  { violations.first?.cue }
    var secondaryCue: String? { violations.count > 1 ? violations[1].cue : nil }
    var isAligned: Bool { violations.isEmpty }
}

// =====================================================================
// MARK: - 2. NGƯỠNG DUNG SAI
// =====================================================================

struct Tolerance {
    static let bodyYawDeg          = 30.0    // mục 1
    static let subjectSizeRatio    = 0.10    // mục 2 — chênh 10%
    static let cameraHeightBucket  = 0       // mục 3 — phải đúng mức
    static let pitchBucket         = 0       // mục 4 — phải đúng mức
    static let horizontalOffset    = 0.05    // mục 5 — 5% bề ngang khung
    static let jointAngleDeg       = 15.0    // mục 6
    static let spineTiltDeg        = 8.0

    static let lockedMultiplier    = 1.5     // đã đạt thì nới 1.5 lần
    static let resetMultiplier     = 3.0     // lệch gấp 3 mới quay lại mục trước

    static let panVsStepThreshold  = 0.15
    static let metersPerStep       = 0.7
    static let assumedBodyHeightM  = 1.70
    static let minKeypointConf: Float = 0.3
    /// Lower bar just for the on-screen skeleton — this is visual only and doesn't feed
    /// guidance math, so it's fine to show a joint Vision is only somewhat sure about.
    static let minDisplayConf: Float = 0.1
}

// =====================================================================
// MARK: - 3. ĐO ĐẠC TỪ FRAME (Vision + CoreMotion)
// =====================================================================

final class Measurer {

    private let poseRequest = VNDetectHumanBodyPoseRequest()
    private let faceRequest = VNDetectFaceRectanglesRequest()

    /// Hệ số hiệu chuẩn r_front, đo 1 lần đầu phiên khi mẫu còn nhìn vào máy.
    private var rFront: Double?
    private var rFrontSamples: [Double] = []

    /// Đo 1 frame. `orientation` PHẢI phản ánh đúng chiều cầm máy (fix so với bản gốc luôn
    /// hardcode .up — sai với buffer cảm biến vốn ở dạng ngang khi cầm máy dọc).
    func measure(pixelBuffer: CVPixelBuffer,
                 attitudePitchDeg: Double,
                 optics: CameraOptics,
                 orientation: CGImagePropertyOrientation,
                 runFaceThisFrame: Bool) -> Measurement {

        var m = Measurement(pitchDeg: attitudePitchDeg,
                            pitchBucket: Self.pitchBucket(attitudePitchDeg))

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        var requests: [VNRequest] = [poseRequest]
        if runFaceThisFrame { requests.append(faceRequest) }
        try? handler.perform(requests)

        guard let obs = poseRequest.results?.first else { return m }
        guard let pts = try? obs.recognizedPoints(.all) else { return m }

        // Show every joint Vision returns at all (even low-confidence ones, dimmed in the
        // overlay) — "all body points" means all ~19, not just the handful used in the math.
        m.jointPoints = pts.reduce(into: [:]) { dict, entry in
            let (name, point) = entry
            guard point.confidence >= Tolerance.minDisplayConf else { return }
            dict[name] = JointPoint(location: point.location, confidence: point.confidence)
        }

        // --- Lấy keypoint, đã LẬT Y (Vision gốc dưới-trái, ta dùng gốc trên-trái) ---
        func pt(_ name: VNHumanBodyPoseObservation.JointName) -> SIMD2<Double>? {
            guard let p = pts[name], p.confidence >= Tolerance.minKeypointConf else { return nil }
            return SIMD2(Double(p.location.x), 1.0 - Double(p.location.y))
        }

        guard let lSh = pt(.leftShoulder), let rSh = pt(.rightShoulder),
              let lHip = pt(.leftHip), let rHip = pt(.rightHip) else { return m }

        m.hasSubject = true

        let neck  = (lSh + rSh) / 2
        let hips  = (lHip + rHip) / 2
        let nose  = pt(.nose)

        // ---------- MỤC 5: lệch trái/phải ----------
        m.hipCenterX = hips.x

        // ---------- MỤC 1: hướng mẫu (foreshortening 2D) ----------
        let W = abs(lSh.x - rSh.x)                  // bề ngang vai biểu kiến
        let H = abs(neck.y - hips.y)                // chiều cao thân — thước chuẩn hóa
        if H > 0.02 {
            let r = W / H

            if rFront == nil, runFaceThisFrame,
               let face = faceRequest.results?.first,
               let faceYaw = face.yaw?.doubleValue,
               abs(faceYaw.degrees) < 10 {
                rFrontSamples.append(r)
                if rFrontSamples.count >= 10 {
                    rFront = rFrontSamples.sorted()[rFrontSamples.count / 2]  // median
                }
            }

            let base = rFront ?? 0.62
            let absYaw = acos(min(max(r / base, 0), 1)).degrees

            var signedYaw = absYaw
            if let nose = nose {
                signedYaw = (nose.x > neck.x) ? absYaw : -absYaw
            }

            let seeingFront = lSh.x > rSh.x
            m.bodyYawDeg = seeingFront ? signedYaw
                                       : (signedYaw >= 0 ? 180 - absYaw : -180 + absYaw)
        }

        // ---------- MỤC 2: xa/gần ----------
        let headTopY: Double? = nose.map { $0.y - 0.6 * abs($0.y - neck.y) }
        let feetY = [pt(.leftAnkle)?.y, pt(.rightAnkle)?.y].compactMap { $0 }.max()

        if let top = headTopY, let feet = feetY, feet > top {
            let ratio = feet - top
            m.subjectHeightRatio = ratio
            let heightPx = ratio * optics.imageHeightPixels
            if heightPx > 1 {
                m.distanceMeters = optics.focalPixels * Tolerance.assumedBodyHeightM / heightPx
            }
        } else {
            m.subjectHeightRatio = nil
        }

        // ---------- MỤC 3: máy cao/thấp ----------
        if let top = headTopY, let d = m.distanceMeters {
            let headOffsetDeg = (0.5 - top) * optics.vFovDeg
            let elevationDeg = attitudePitchDeg + headOffsetDeg
            let diff = -d * tan(elevationDeg.radians)
            m.cameraHeightDiffMeters = diff
            m.cameraHeightBucket = Self.heightBucket(diff)
        }

        // ---------- MỤC 6: dáng ----------
        m.spineTiltDeg = atan2(neck.x - hips.x, abs(neck.y - hips.y)).degrees
        m.jointAngles = Self.jointAngles(pts: pts)
        if runFaceThisFrame, let face = faceRequest.results?.first {
            m.headYawDeg = face.yaw?.doubleValue.degrees
        }

        return m
    }

    func resetCalibration() { rFront = nil; rFrontSamples.removeAll() }

    static func pitchBucket(_ deg: Double) -> Int {
        if deg >  20 { return 4 }
        if deg >   8 { return 3 }
        if deg >= -8 { return 2 }
        if deg > -20 { return 1 }
        return 0
    }

    /// diff dương = máy cao hơn đầu mẫu (mét)
    static func heightBucket(_ diff: Double) -> Int {
        if diff >  0.30 { return 4 }
        if diff > -0.10 { return 3 }
        if diff > -0.45 { return 2 }
        if diff > -0.90 { return 1 }
        return 0
    }

    static func jointAngles(pts: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> [JointName: Double] {
        func p(_ n: VNHumanBodyPoseObservation.JointName) -> SIMD2<Double>? {
            guard let q = pts[n], q.confidence >= Tolerance.minKeypointConf else { return nil }
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
        out[.leftElbow]     = angle(p(.leftShoulder), p(.leftElbow),  p(.leftWrist))
        out[.rightElbow]    = angle(p(.rightShoulder), p(.rightElbow), p(.rightWrist))
        out[.leftShoulder]  = angle(p(.leftElbow), p(.leftShoulder),  p(.leftHip))
        out[.rightShoulder] = angle(p(.rightElbow), p(.rightShoulder), p(.rightHip))
        out[.leftKnee]      = angle(p(.leftHip), p(.leftKnee),  p(.leftAnkle))
        out[.rightKnee]     = angle(p(.rightHip), p(.rightKnee), p(.rightAnkle))
        return out.compactMapValues { $0 }
    }
}

// =====================================================================
// MARK: - 4. ĐÁNH GIÁ THEO THỨ TỰ 1→6 + SINH CUE
// =====================================================================

final class GuidanceEngine {

    private var locked: Set<Int> = []
    private var modelPhaseDone = false

    func reset() { locked.removeAll(); modelPhaseDone = false }

    private func tol(_ base: Double, _ index: Int) -> Double {
        locked.contains(index) ? base * Tolerance.lockedMultiplier : base
    }
    private func resetTol(_ base: Double) -> Double { base * Tolerance.resetMultiplier }

    func evaluate(_ m: Measurement, _ t: Template, _ optics: CameraOptics) -> GuidanceResult {

        guard m.hasSubject else {
            return GuidanceResult(violations: [Violation(
                criterionIndex: 0, name: "Không thấy người", actor: .shooter,
                deltaDescription: "no subject", cue: "Đưa mẫu vào khung")])
        }

        var vs: [Violation] = []

        // ---------- MỤC 1: hướng mẫu ----------
        if let yaw = m.bodyYawDeg {
            let d = signedAngleDelta(yaw, t.bodyYawDeg)
            if abs(d) > tol(Tolerance.bodyYawDeg, 1) {
                locked.remove(1)
                vs.append(Violation(
                    criterionIndex: 1, name: "Hướng mẫu", actor: .model,
                    deltaDescription: String(format: "lệch %.0f°", d),
                    cue: Self.cueBodyYaw(deltaDeg: d, targetYaw: t.bodyYawDeg)))
                return GuidanceResult(violations: vs)
            } else if abs(d) <= Tolerance.bodyYawDeg {
                locked.insert(1)
            }
        }

        // ---------- MỤC 2: xa/gần ----------
        if let ratio = m.subjectHeightRatio {
            let err = ratio / t.subjectHeightRatio - 1.0
            if abs(err) > tol(Tolerance.subjectSizeRatio, 2) {
                if abs(err) > resetTol(Tolerance.subjectSizeRatio) { locked.remove(2) }
                let steps = Self.stepsToMove(err: err, distance: m.distanceMeters)
                vs.append(Violation(
                    criterionIndex: 2, name: "Xa/gần", actor: .shooter,
                    deltaDescription: String(format: "chênh %.0f%%", err * 100),
                    cue: err > 0 ? "Lùi \(steps) bước" : "Tiến \(steps) bước"))
            } else { locked.insert(2) }
        }

        // ---------- MỤC 3: máy cao/thấp ----------
        if let bucket = m.cameraHeightBucket {
            let d = bucket - t.cameraHeightBucket
            if abs(d) > (locked.contains(3) ? 1 : Tolerance.cameraHeightBucket) {
                if abs(d) >= 2 { locked.remove(3) }
                vs.append(Violation(
                    criterionIndex: 3, name: "Máy cao/thấp", actor: .shooter,
                    deltaDescription: "lệch \(d) mức",
                    cue: Self.cueCameraHeight(deltaBucket: d,
                                              deltaMeters: m.cameraHeightDiffMeters,
                                              target: t.cameraHeightBucket)))
            } else { locked.insert(3) }
        }

        // ---------- MỤC 4: ngửa/chúc ----------
        let pitchDelta = m.pitchDeg - t.pitchDeg
        let bucketDelta = m.pitchBucket - t.pitchBucket
        if abs(bucketDelta) > (locked.contains(4) ? 1 : Tolerance.pitchBucket) {
            if abs(bucketDelta) >= 2 { locked.remove(4) }
            vs.append(Violation(
                criterionIndex: 4, name: "Ngửa/chúc", actor: .shooter,
                deltaDescription: String(format: "lệch %.0f°", pitchDelta),
                cue: pitchDelta > 0
                     ? String(format: "Chúc điện thoại xuống %.0f độ", abs(pitchDelta))
                     : String(format: "Ngửa điện thoại lên %.0f độ", abs(pitchDelta))))
        } else { locked.insert(4) }

        // ---------- MỤC 5: lệch trái/phải ----------
        if let cx = m.hipCenterX {
            let off = cx - t.hipCenterX
            if abs(off) > tol(Tolerance.horizontalOffset, 5) {
                if abs(off) > resetTol(Tolerance.horizontalOffset) { locked.remove(5) }
                vs.append(Violation(
                    criterionIndex: 5, name: "Trái/phải", actor: .shooter,
                    deltaDescription: String(format: "lệch %.0f%% khung", off * 100),
                    cue: Self.cueHorizontal(offset: off, hFov: optics.hFovDeg)))
            } else { locked.insert(5) }
        }

        // ---------- MỤC 6: dáng (chỉ khi mục 1-5 đã sạch) ----------
        if vs.isEmpty {
            if let v = poseViolation(m, t) { vs.append(v) }
        }

        return GuidanceResult(violations: vs)
    }

    private func poseViolation(_ m: Measurement, _ t: Template) -> Violation? {
        if let s = m.spineTiltDeg {
            let d = s - t.spineTiltDeg
            if abs(d) > Tolerance.spineTiltDeg {
                return Violation(criterionIndex: 6, name: "Trục thân", actor: .model,
                    deltaDescription: String(format: "%.0f°", d),
                    cue: d > 0 ? "Bảo mẫu nghiêng người sang trái" : "Bảo mẫu nghiêng người sang phải")
            }
        }
        if let tHead = t.headYawDeg, let mHead = m.headYawDeg {
            let d = signedAngleDelta(mHead, tHead)
            if abs(d) > Tolerance.jointAngleDeg + 20 {
                return Violation(criterionIndex: 6, name: "Hướng đầu", actor: .model,
                    deltaDescription: String(format: "%.0f°", d),
                    cue: d > 0 ? "Bảo mẫu quay mặt sang trái" : "Bảo mẫu quay mặt sang phải")
            }
        }
        let order: [JointName] = [.leftShoulder, .rightShoulder, .leftElbow, .rightElbow,
                                  .leftKnee, .rightKnee]
        for j in order {
            guard let cur = m.jointAngles[j], let target = t.jointAngles[j] else { continue }
            if abs(cur - target) > Tolerance.jointAngleDeg {
                return Violation(criterionIndex: 6, name: "Dáng \(j.rawValue)", actor: .model,
                    deltaDescription: String(format: "%.0f°", cur - target),
                    cue: t.cueForModel)
            }
        }
        return nil
    }

    // ------------------- SINH CÂU CUE -------------------

    static func cueBodyYaw(deltaDeg d: Double, targetYaw: Double) -> String {
        if abs(targetYaw) > 150 { return "Bảo mẫu quay lưng lại" }
        if abs(abs(targetYaw) - 90) < 30 {
            return targetYaw > 0 ? "Bảo mẫu quay nghiêng sang phải" : "Bảo mẫu quay nghiêng sang trái"
        }
        if abs(targetYaw) < 25 { return "Bảo mẫu quay mặt về phía máy" }
        return d > 0 ? String(format: "Bảo mẫu xoay người sang trái %.0f độ", abs(d))
                     : String(format: "Bảo mẫu xoay người sang phải %.0f độ", abs(d))
    }

    static func stepsToMove(err: Double, distance: Double?) -> Int {
        guard let d = distance else { return 1 }
        let meters = abs(d * err)
        return max(1, min(3, Int((meters / Tolerance.metersPerStep).rounded())))
    }

    static func cueCameraHeight(deltaBucket d: Int, deltaMeters: Double?, target: Int) -> String {
        let anchor: String
        switch target {
        case 4: anchor = "cao quá đầu"
        case 3: anchor = "ngang đầu"
        case 2: anchor = "ngang mắt"
        case 1: anchor = "ngang hông"
        default: anchor = "sát mặt đất"
        }
        if let cm = deltaMeters.map({ abs($0) * 100 }), cm > 15 {
            return d > 0 ? String(format: "Hạ điện thoại xuống ~%.0fcm (%@)", cm, anchor)
                         : String(format: "Nâng điện thoại lên ~%.0fcm (%@)", cm, anchor)
        }
        return d > 0 ? "Hạ điện thoại xuống \(anchor)" : "Giơ điện thoại lên \(anchor)"
    }

    static func cueHorizontal(offset: Double, hFov: Double) -> String {
        if abs(offset) >= Tolerance.panVsStepThreshold {
            return offset > 0 ? "Bước sang phải 1 bước" : "Bước sang trái 1 bước"
        }
        let deg = abs(offset) * hFov
        if deg < 3 {
            return offset > 0 ? "Đưa điện thoại sang phải một chút" : "Đưa điện thoại sang trái một chút"
        }
        return offset > 0 ? String(format: "Xoay điện thoại sang phải %.0f độ", deg)
                          : String(format: "Xoay điện thoại sang trái %.0f độ", deg)
    }
}

// =====================================================================
// MARK: - 5. LÀM MƯỢT + DWELL + ĐẾM NGƯỢC
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
}

/// Quản lý: đủ 6 mục → giữ ổn định 0,8s → đếm ngược 3s → chụp/ghi NGAY TỪ LÚC ĐẾM.
final class CaptureTrigger {
    enum State { case guiding, dwelling(since: Double), countingDown(until: Double), recording }
    private(set) var state: State = .guiding

    private let dwellSeconds = 0.8
    private let countdownSeconds = 3.0
    private var lostAlignedSince: Double?

    /// Trả về true tại đúng frame cần BẮT ĐẦU chụp/ghi.
    func update(isAligned: Bool, now: Double) -> Bool {
        switch state {
        case .guiding:
            if isAligned { state = .dwelling(since: now) }
            return false

        case .dwelling(let since):
            if !isAligned { state = .guiding; return false }
            if now - since >= dwellSeconds {
                state = .countingDown(until: now + countdownSeconds)
                return true
            }
            return false

        case .countingDown(let until):
            if !isAligned {
                if lostAlignedSince == nil { lostAlignedSince = now }
                if now - lostAlignedSince! > 1.0 { state = .guiding; lostAlignedSince = nil }
            } else {
                lostAlignedSince = nil
            }
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

/// Hiệu góc có dấu, chuẩn hóa về -180...180 (tránh lỗi khi qua mốc ±180).
func signedAngleDelta(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}
