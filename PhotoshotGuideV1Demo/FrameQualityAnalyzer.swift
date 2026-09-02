//
//  FrameQualityAnalyzer.swift
//  PhotoshotGuideV1Demo
//

import UIKit
import Vision

/// Điểm chất lượng của 1 khung hình theo các chuẩn ảnh phổ biến:
/// - Độ nét: phương sai Laplacian (focus measure của Pech-Pacheco et al., chuẩn industry cho blur detection)
/// - Độ sáng: trung bình luminance quanh mid-tone (~0.5) + phạt vùng cháy/đen (Apple khuyên ảnh đủ sáng, không cháy sáng chi tiết)
/// - Tương phản: độ lệch chuẩn luminance (RMS contrast)
/// - Màu sắc: colorfulness Hasler–Süsstrunk (metric chuẩn trong tài liệu imaging)
/// - Bố cục: quy tắc 1/3 (rule of thirds), tỷ lệ chủ thể trong khung, headroom — theo hướng dẫn chụp ảnh của Apple
nonisolated struct FrameQuality: Hashable {
    var sharpness: Double      // 0...1
    var motionBlur: Double     // 0...1 — 1 = ổn định, không vệt loang do máy di chuyển nhanh
    var exposure: Double       // 0...1
    var contrast: Double       // 0...1
    var color: Double          // 0...1
    var composition: Double    // 0...1

    var overall: Double {
        // Trọng số nghiêng hẳn về độ nét + chống nhòe/loang (tiêu chí chất lượng
        // người dùng quan tâm nhất); bố cục/màu chỉ còn vai trò phá hoà khi bằng điểm.
        0.35 * sharpness + 0.25 * motionBlur +
        0.15 * exposure + 0.10 * contrast + 0.05 * color + 0.10 * composition
    }

    static let neutral = FrameQuality(sharpness: 0.5, motionBlur: 0.5, exposure: 0.5,
                                      contrast: 0.5, color: 0.5, composition: 0.5)
}
/// Một khung hình đã được chấm điểm (chất lượng + độ khớp tư thế với mẫu).
nonisolated struct AnalyzedFrame: Identifiable, Hashable {
    let id = UUID()
    let image: UIImage
    let time: Double           // giây trong video gốc
    let poseScore: Double      // 0...1, khớp mẫu (nếu có)
    let quality: FrameQuality

    var totalScore: Double { 0.60 * quality.overall + 0.40 * poseScore }
}

nonisolated enum ImageQualityAnalyzer {

    nonisolated struct GrayBuffer {
        let pixels: [UInt8]
        let width: Int
        let height: Int

        func at(_ x: Int, _ y: Int) -> Double { Double(pixels[y * width + x]) / 255.0 }
    }

    static func analyze(image: UIImage) -> FrameQuality {
        guard let cgImage = orientedCGImage(image) else { return .neutral }
        guard let small = resized(cgImage, maxSide: 320),
              let gray = grayscaleBuffer(small) else { return .neutral }

        let stats = luminanceStats(gray)
        let color = colorfulnessScore(small)
        let composition = compositionScore(rgbSmall: small)

        return FrameQuality(
            sharpness: sharpnessScore(gray),
            motionBlur: motionBlurScore(gray),
            exposure: exposureScore(mean: stats.mean, clippedLow: stats.clippedLow, clippedHigh: stats.clippedHigh),
            contrast: contrastScore(std: stats.std),
            color: color,
            composition: composition
        )
    }

    // MARK: - Grayscale buffer

    private static func grayscaleBuffer(_ cgImage: CGImage) -> GrayBuffer? {
        let w = cgImage.width, h = cgImage.height
        guard w > 2, h > 2,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h)
        return GrayBuffer(pixels: Array(UnsafeBufferPointer(start: ptr, count: w * h)), width: w, height: h)
    }

    // MARK: - Sharpness (variance of Laplacian)

    private static func sharpnessScore(_ g: GrayBuffer) -> Double {
        var responses: [Double] = []
        responses.reserveCapacity((g.width - 2) * (g.height - 2))
        for y in 1..<(g.height - 1) {
            for x in 1..<(g.width - 1) {
                let lap = g.at(x, y - 1) + g.at(x, y + 1) + g.at(x - 1, y) + g.at(x + 1, y) - 4 * g.at(x, y)
                responses.append(lap)
            }
        }
        guard !responses.isEmpty else { return 0.5 }
        let mean = responses.reduce(0, +) / Double(responses.count)
        let variance = responses.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(responses.count)
        // Thang log: ~1e-5 = nhòe hoàn toàn → 3e-2 = rất nét
        let lo = log10(1e-5), hi = log10(3e-2)
        let v = variance < 1e-8 ? lo : log10(variance)
        return clamp((v - lo) / (hi - lo))
    }

    // MARK: - Motion blur / vệt loang do camera di chuyển nhanh

    /// Phát hiện vệt loang CÓ HƯỚNG: khi máy giật/lướt nhanh, pixel bị trung bình hoá
    /// theo hướng chuyển động → gradient PHÍA VUÔNG GÓC với hướng chạy bị triệt tiêu,
    /// gradient theo chiều song song vẫn còn. Khung nét thật có gradient phân bố
    /// gần ĐỀU hai chiều → tỉ lệ lệch (anisotropy) thấp. Kết hợp với Laplacian ở trên
    /// để bắt trọn bộ: nhòe đều (out-of-focus), nhòe cục bộ và vệt loang định hướng.
    private static func motionBlurScore(_ g: GrayBuffer) -> Double {
        var sumGx2 = 0.0, sumGy2 = 0.0
        for y in 1..<(g.height - 1) {
            for x in 1..<(g.width - 1) {
                let gx = g.at(x + 1, y - 1) + 2 * g.at(x + 1, y) + g.at(x + 1, y + 1)
                       - g.at(x - 1, y - 1) - 2 * g.at(x - 1, y) - g.at(x - 1, y + 1)
                let gy = g.at(x - 1, y + 1) + 2 * g.at(x, y + 1) + g.at(x + 1, y + 1)
                       - g.at(x - 1, y - 1) - 2 * g.at(x, y - 1) - g.at(x + 1, y - 1)
                sumGx2 += gx * gx
                sumGy2 += gy * gy
            }
        }
        let total = sumGx2 + sumGy2
        guard total > 1e-9 else { return 0 }   // ảnh phẳng hoặc mù đặc → coi như hỏng
        let anisotropy = abs(sumGx2 - sumGy2) / total   // 0 = cân bằng (nét), →1 = một hướng đã bị xoá
        return clamp(1.0 - anisotropy * 1.6)
    }

    // MARK: - Exposure & contrast

    private static func luminanceStats(_ g: GrayBuffer) -> (mean: Double, std: Double, clippedLow: Double, clippedHigh: Double) {
        let n = Double(g.pixels.count)
        var sum = 0.0
        for p in g.pixels { sum += Double(p) }
        let mean = sum / n / 255.0
        var sq = 0.0
        var low = 0.0
        var high = 0.0
        for p in g.pixels {
            let v = Double(p) / 255.0
            sq += (v - mean) * (v - mean)
            if Double(p) <= 6 { low += 1 }
            if Double(p) >= 249 { high += 1 }
        }
        return (mean, (sq / n).squareRoot(), low / n, high / n)
    }

    private static func exposureScore(mean: Double, clippedLow: Double, clippedHigh: Double) -> Double {
        let base = clamp(1.0 - abs(mean - 0.50) / 0.42)
        let clipPenalty = min(0.65, (clippedLow + clippedHigh) * 2.2)
        return clamp(base * (1.0 - clipPenalty))
    }

    private static func contrastScore(std: Double) -> Double {
        gaussian(std, center: 0.19, sigma: 0.10)
    }

    // MARK: - Colorfulness (Hasler & Süsstrunk)

    private static func colorfulnessScore(_ cgImage: CGImage) -> Double {
        let w = cgImage.width, h = cgImage.height
        guard w >= 4, h >= 4,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0.5 }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0.5 }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        var sumRG = 0.0, sumYB = 0.0
        let n = Double(w * h)
        var rgValues: [Double] = [], ybValues: [Double] = []
        rgValues.reserveCapacity(Int(n)); ybValues.reserveCapacity(Int(n))

        var i = 0
        let byteCount = w * h * 4
        while i < byteCount {
            let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
            let rg = r - g
            let yb = 0.5 * (r + g) - b
            rgValues.append(rg); ybValues.append(yb)
            sumRG += rg; sumYB += yb
            i += 4
        }
        let meanRG = sumRG / n, meanYB = sumYB / n
        var varRG = 0.0, varYB = 0.0
        for j in 0..<Int(n) {
            varRG += (rgValues[j] - meanRG) * (rgValues[j] - meanRG)
            varYB += (ybValues[j] - meanYB) * (ybValues[j] - meanYB)
        }
        varRG /= n; varYB /= n
        let stdRoot = (varRG + varYB).squareRoot()
        let meanRoot = (meanRG * meanRG + meanYB * meanYB).squareRoot()
        let m = stdRoot + 0.3 * meanRoot   // thang 0...~110
        return clamp(gaussian(m, center: 45, sigma: 26) * 1.15)
    }

    // MARK: - Composition (rule of thirds + subject size + headroom)

    private static func compositionScore(rgbSmall: CGImage) -> Double {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: rgbSmall, orientation: .up, options: [:])
        try? handler.perform([request])
        guard let obs = request.results?.first,
              let pts = try? obs.recognizedPoints(.all) else { return 0.5 }

        func pt(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = pts[name], p.confidence >= 0.3 else { return nil }
            return CGPoint(x: CGFloat(p.location.x), y: 1.0 - CGFloat(p.location.y)) // gốc trên-trái
        }

        var xs: [CGFloat] = [], ys: [CGFloat] = []
        for (_, vnPoint) in pts where vnPoint.confidence >= 0.3 {
            xs.append(CGFloat(vnPoint.location.x))
            ys.append(1.0 - CGFloat(vnPoint.location.y))
        }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return 0.5 }

        let centerX = (minX + maxX) / 2
        let subjectHeight = maxY - minY

        let goodLines: [CGFloat] = [0.5, 1.0 / 3.0, 2.0 / 3.0]
        let distToLine = goodLines.map { abs(centerX - $0) }.min() ?? 1.0
        let centering = clamp(1.0 - distToLine / 0.22)

        let size = gaussian(subjectHeight, center: 0.70, sigma: 0.20) * 1.1

        let headroom = minY
        let head = headroom < 0.01 ? headroom / 0.01
                 : headroom > 0.28 ? clamp(1.0 - (headroom - 0.28) / 0.35)
                 : 1.0

        let edges: [CGPoint?] = [pt(.nose), pt(.leftShoulder), pt(.rightShoulder),
                                 pt(.leftHip), pt(.rightHip)]
        var edgeClip = false
        for point in edges.compactMap({ $0 }) {
            if point.x <= 0.02 || point.x >= 0.98 || point.y <= 0.02 || point.y >= 0.98 { edgeClip = true }
        }

        let raw = 0.40 * centering + 0.40 * size + 0.20 * head
        return clamp(raw * (edgeClip ? 0.55 : 1.0))
    }

    // MARK: - Helpers

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

    private static func gaussian(_ x: Double, center: Double, sigma: Double) -> Double {
        exp(-pow(x - center, 2) / (2 * sigma * sigma))
    }

    private static func orientedCGImage(_ image: UIImage) -> CGImage? {
        guard let cgImage = image.cgImage else { return nil }
        switch image.imageOrientation {
        case .up, .upMirrored:
            return cgImage
        default:
            UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
            defer { UIGraphicsEndImageContext() }
            image.draw(in: CGRect(origin: .zero, size: image.size))
            return UIGraphicsGetImageFromCurrentImageContext()?.cgImage
        }
    }

    private static func resized(_ cgImage: CGImage, maxSide: CGFloat) -> CGImage? {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let scale = min(1, maxSide / max(w, h))
        guard scale < 1 else { return cgImage }
        let nw = max(4, Int(w * scale)), nh = max(4, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8,
                                  bytesPerRow: nw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }
}

// MARK: - Best-frame selection

nonisolated enum BestFrameSelector {

    /// Bậc ngưỡng "chuẩn mẫu" khi CÓ ảnh mẫu — khung được chọn BẮT BUỘC vượt qua
    /// một bậc nào đó trong danh sách này. Bắt đầu khắt khe (0.65); chỉ hạ bậc khi
    /// không đủ ứng viên, tuyệt đối không về 0 (khung sai tư thế không được vào kết quả).
    private static let poseTiers: [Double] = [0.65, 0.55, 0.45, 0.35]

    /// Sàn loại sớm ở pipeline: thấp hơn mức này thì frame bị bỏ ngay từ đầu,
    /// khỏi tốn công tính chất lượng (nét/sáng/màu) cho thứ chắc chắn bị loại.
    static let pipelinePoseFloor: Double = 0.30

    /// Thứ tự ưu tiên khi so 2 khung (true = a TỐT hơn b):
    ///   1. ĐỘ TRÙNG VỚI MẪU (poseScore) — ưu tiên số 1 tuyệt đối.
    ///   2. CHẤT LƯỢNG ẢNH (nét · không nhòe · không vỡ nét · không vệt loang).
    /// KHÔNG xét thời điểm chụp.
    static func isBetter(_ a: AnalyzedFrame, than b: AnalyzedFrame) -> Bool {
        if a.poseScore != b.poseScore { return a.poseScore > b.poseScore }
        return a.quality.overall > b.quality.overall
    }

    /// Chọn `count` khung tốt nhất theo đúng thứ tự ưu tiên trên.
    ///
    /// Khi `poseRequired == true` (có ảnh mẫu):
    ///   1. LỌC CỨNG theo bậc ngưỡng pose — khung sai tư thế bị loại trước.
    ///      Hạ bậc dần chỉ khi thiếu ứng viên; nếu ngay bậc chót cũng trống thì mới
    ///      buộc phải dùng toàn bộ (trường hợp cả video không có khung nào đúng mẫu).
    ///   2. Xếp hạng nghiêm ngặt: pose trước → chất lượng sau → lấy `count` khung đầu.
    static func select(_ frames: [AnalyzedFrame], count: Int = 5,
                       poseRequired: Bool) -> [AnalyzedFrame] {
        guard !frames.isEmpty else { return [] }

        var candidates = frames
        if poseRequired {
            var gated = frames
            for tier in poseTiers {
                let passing = frames.filter { $0.poseScore >= tier }
                if passing.count >= count {
                    gated = passing
                    break
                }
                if !passing.isEmpty { gated = passing }   // chưa đủ → nhớ lại, hạ bậc tiếp
            }
            candidates = gated
        }

        return Array(candidates.sorted { isBetter($0, than: $1) }.prefix(count))
    }
}

// MARK: - Full pipeline (extract → analyze → select)

nonisolated enum FrameAnalysisPipeline {

    /// Trích xuất khung hình từ video, chấm điểm từng khung rồi chọn 5 khung tốt nhất.
    /// Toàn bộ công việc nặng chạy trên thread nền (Task.detached).
    /// `progress` (0...1: 0→0.6 trích xuất, 0.6→1.0 phân tích) luôn được gọi lại trên main queue.
    static func run(videoURL: URL,
                    interval: Double,
                    referenceImage: UIImage?,
                    progress: @escaping (Double) -> Void) async -> [AnalyzedFrame] {
        await Task.detached(priority: .userInitiated) {
            await perform(videoURL: videoURL, interval: interval,
                          referenceImage: referenceImage, progress: progress)
        }.value
    }

    private static func perform(videoURL: URL,
                                interval: Double,
                                referenceImage: UIImage?,
                                progress: @escaping (Double) -> Void) async -> [AnalyzedFrame] {
        let template = referenceImage.flatMap { TemplateAnalyzer.analyze(image: $0) }
        let keepPoolSize = 30

        let rawFrames = await VideoFrameExtractor.extractFrames(url: videoURL, interval: interval) { frac in
            deliverProgress(frac * 0.6, to: progress)
        }

        var pool: [AnalyzedFrame] = []
        let total = Double(max(rawFrames.count, 1))

        for (offset, raw) in rawFrames.enumerated() {
            // POSE TRƯỚC — quyết định sống còn theo yêu cầu "bắt buộc đúng mẫu":
            // khung lệch mẫu quá xa bị loại SỚM, không tốn công tính chất lượng.
            var poseScore = 0.0
            if let template {
                if let frameTemplate = TemplateAnalyzer.analyze(image: raw.image) {
                    poseScore = PoseSimilarity.score(frameTemplate, against: template)
                }
                if poseScore < BestFrameSelector.pipelinePoseFloor {
                    deliverProgress(0.6 + 0.38 * Double(offset + 1) / total, to: progress)
                    continue   // sai tư thế quá xa — bỏ ngay
                }
            } else {
                poseScore = 0.5   // không có mẫu → pose trung tính, chỉ chấm chất lượng
            }

            let quality = ImageQualityAnalyzer.analyze(image: raw.image)

            let frame = AnalyzedFrame(image: raw.image, time: raw.time,
                                      poseScore: poseScore, quality: quality)
            if pool.count < keepPoolSize {
                pool.append(frame)
            } else if let weakestIdx = pool.indices.min(by: { BestFrameSelector.isBetter(pool[$1], than: pool[$0]) }),
                      BestFrameSelector.isBetter(frame, than: pool[weakestIdx]) {
                pool[weakestIdx] = frame
            }

            deliverProgress(0.6 + 0.38 * Double(offset + 1) / total, to: progress)
        }

        deliverProgress(1.0, to: progress)
        return BestFrameSelector.select(pool, count: 5, poseRequired: template != nil)
    }

    private static func deliverProgress(_ value: Double, to progress: @escaping (Double) -> Void) {
        if Thread.isMainThread {
            progress(value)
        } else {
            DispatchQueue.main.async { progress(value) }
        }
    }
}
