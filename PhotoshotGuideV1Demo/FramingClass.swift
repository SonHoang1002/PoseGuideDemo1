//
//  FramingClass.swift
//  Lớp khung hình — khái niệm hạng nhất dùng chung cho GuidanceEngine (realtime)
//  và bộ chọn ảnh đẹp nhất.
//
//  Nguồn: PoseCoach_Phan_Lop_Khung_Hinh_V3.docx — "Verify tài liệu ngưỡng v2".
//  Nguyên nhân 8 (lỗi khiến cue KHÔNG BAO GIỜ tắt được): các bản trước tự chọn
//  "mốc tốt nhất còn đo được" trên từng frame live, trong khi ảnh mẫu lại dùng
//  một mốc khác (vd. mẫu chân dung đo đỉnh đầu→hông, live toàn thân tự chọn
//  đỉnh đầu→cổ chân) — hai đại lượng khác bản chất, không ngưỡng nào cứu được.
//
//  Quy tắc: suy FramingClass MỘT LẦN từ ảnh mẫu (TemplateAnalyzer), rồi áp
//  NGUYÊN XI mốc đo tương ứng cho mọi frame live và mọi frame video sau đó.
//  Không bao giờ để live "tự chọn" mốc khác với mốc mà mẫu đã dùng.
//

import CoreGraphics

enum FramingClass: String, Codable, CaseIterable {
    case full   // toàn thân, thấy cổ chân
    case knee   // cắt dưới gối (3/4 người)
    case half   // cắt dưới hông (nửa người)
    case chest  // bán thân, cắt trên hông
    case head   // chân dung cận, chỉ đầu + vai

    /// Mốc đo tỉ lệ chủ thể trong khung (mục 2 — xa/gần).
    var scaleAnchor: ScaleAnchor {
        switch self {
        case .full:  return .headToAnkle
        case .knee:  return .headToKnee
        case .half:  return .headToHip
        case .chest: return .faceHeight
        case .head:  return .faceHeight
        }
    }

    /// Điểm mốc để đo góc nhìn của máy (mục 3 — máy cao/thấp).
    var elevationAnchor: ElevationAnchor {
        switch self {
        case .full, .knee: return .midHip
        case .half:        return .midTorso
        case .chest, .head: return .eyeLine
        }
    }

    /// Điểm mốc để đo lệch trái/phải (mục 5).
    var centerAnchor: CenterAnchor {
        switch self {
        case .full, .knee, .half: return .torsoCenter
        case .chest:              return .shoulderCenter
        case .head:               return .faceCenter
        }
    }

    /// Nguồn tin cậy nhất để đo hướng mẫu (mục 1). Chân dung/bán thân thường
    /// không thấy hông nên công thức bề-ngang-vai/chiều-cao-thân không tính
    /// được — dùng face yaw của Vision, vốn chính xác hơn (~3-5° so với 8-10°).
    var yawSource: YawSource {
        switch self {
        case .full, .knee, .half: return .shoulderForeshortening
        case .chest, .head:       return .faceYaw
        }
    }

    /// Các nhóm khớp được chấm ở mục 6 — chỉ chấm nhóm còn nằm trong khung.
    var poseGroups: [PoseGroup] {
        switch self {
        case .full:  return [.spine, .head, .arms, .legs]
        case .knee:  return [.spine, .head, .arms]
        case .half:  return [.spine, .head, .arms]
        case .chest: return [.head, .arms]
        case .head:  return [.head]
        }
    }

    var displayName: String {
        switch self {
        case .full:  return "Toàn thân"
        case .knee:  return "3/4 người"
        case .half:  return "Nửa người"
        case .chest: return "Bán thân"
        case .head:  return "Chân dung cận"
        }
    }

    /// Xác định lớp khung hình từ khung bao chủ thể (subject bounding box,
    /// 0...1, gốc trên-trái, đo trên ẢNH MẪU). Quy tắc: điểm thấp nhất của cơ
    /// thể còn NẰM TRONG khung (không sát mép) quyết định lớp.
    ///
    /// Bẫy: Vision vẫn trả keypoint NGOÀI khung bằng ngoại suy, confidence
    /// thấp. Nơi gọi hàm này phải tự lọc keypoint theo cả confidence LẪN toạ
    /// độ y nằm trong 0...1 trước khi tính subjectBox — nếu không, ảnh chân
    /// dung sẽ bị nhận nhầm thành toàn thân.
    static func detect(subjectBox: CGRect) -> FramingClass {
        let bottom = subjectBox.maxY
        let cutAtBottom = bottom > 0.97   // sát mép dưới => phần dưới đã bị cắt, không tin được
        if !cutAtBottom && bottom > 0.80 { return .full }
        if bottom > 0.72 { return .knee }
        if bottom > 0.55 { return .half }
        if subjectBox.height > 0.30 { return .chest }
        return .head
    }
}

enum ScaleAnchor: String, Codable { case headToAnkle, headToKnee, headToHip, faceHeight }

enum ElevationAnchor: String, Codable {
    case midHip, midTorso, eyeLine

    /// Từ dùng trong câu cue ("Hạ ống kính xuống ngang ...").
    var cueLabel: String {
        switch self {
        case .midHip:   return "ngang hông mẫu"
        case .midTorso: return "ngang thân mẫu"
        case .eyeLine:  return "ngang mắt mẫu"
        }
    }
}

enum CenterAnchor: String, Codable { case torsoCenter, shoulderCenter, faceCenter }
enum YawSource: String, Codable { case shoulderForeshortening, faceYaw }
enum PoseGroup: String, Codable { case spine, head, arms, legs }