//
//  TemplateAnalyzer.swift
//  Phân tích ảnh mẫu (chọn từ thư viện hoặc template có sẵn) thành `Template`.
//  Chạy 1 LẦN khi vào màn Camera hoặc khi người dùng đổi ảnh mẫu — không chạy
//  realtime.
//
//  Suy FramingClass MỘT LẦN ở đây — mọi phép đo live/video sau đó PHẢI dùng
//  đúng mốc của lớp này (xem FramingClass.swift). Đây là điểm sửa "nguyên
//  nhân 8" trong tài liệu verify-v3: các bản trước để mỗi frame tự chọn "mốc
//  tốt nhất còn đo được", khiến live so nhầm đại lượng với mẫu.
//

import Vision
import UIKit

enum TemplateAnalyzer {

    static func analyze(image: UIImage) -> Template? {
        guard let cgImage = image.cgImage else { return nil }
        let measurer = Measurer(config: .default)
        guard let (m, framing) = measurer.analyzeStillWithFraming(cgImage: cgImage), m.hasSubject else {
            return nil
        }

        return Template(
            framing: framing,
            bodyYawDeg: m.bodyYawDeg ?? 0,
            scaleValue: m.scaleValue ?? defaultScaleValue(for: framing),
            centerX: m.centerX ?? 0.5,
            centerY: m.centerY ?? 0.5,
            elevationDeg: m.elevationDeg ?? 0,
            cameraPitchDeg: 0,   // ảnh mẫu tĩnh không có IMU — coi máy chụp mẫu là ngang
            jointAngles: m.jointAngles,
            spineTiltDeg: m.spineTiltDeg ?? 0,
            headYawDeg: m.headYawDeg,
            lens: .wide,
            cueForModel: "Bảo mẫu giữ dáng giống ảnh mẫu"
        )
    }

    /// Dự phòng khi không đo được tỉ lệ chủ thể (hiếm — thiếu keypoint bắt
    /// buộc). Tránh chia 0 ở mục 2; giá trị chỉ mang tính tạm, mục 2 sẽ luôn
    /// báo "chưa khớp" cho tới khi đo lại được ở frame live tiếp theo.
    private static func defaultScaleValue(for framing: FramingClass) -> Double {
        switch framing {
        case .full:  return 0.85
        case .knee:  return 0.65
        case .half:  return 0.45
        case .chest, .head: return 0.20
        }
    }
}