import SwiftUI

struct ScreenProcessing: View {
    let videoURL: URL?
    let referenceImage: UIImage?
    /// Đẩy màn Result qua path trung tâm của ScreenImport.
    let onNavigate: (AppRoute) -> Void

    @State private var progress: Double = 0
    @State private var stageText = "Đang trích xuất khung hình…"
    @State private var hasNavigated = false

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "5B8DEF"), Color(hex: "2C65E7")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)
                        .shadow(color: Color.blue.opacity(0.3), radius: 10, x: 0, y: 6)

                    Image(systemName: "wand.and.stars")
                        .foregroundColor(.white)
                        .font(.system(size: 36, weight: .medium))
                }
                .rotationEffect(.degrees(isWorking ? 360 : 0))
                .animation(isWorking ? .linear(duration: 3).repeatForever(autoreverses: false) : .default,
                           value: isWorking)

                Text("Đang xử lý video")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.15))

                Text(stageText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)

                CustomProgressBar(value: progress, total: 1.0)
                    .frame(width: 260, height: 12)

                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: "2C65E7"))
                    .monospacedDigit()

                Spacer()
            }
            .padding(40)
        }
        .navigationBarBackButtonHidden(true)
        .task { await runAnalysis() }
    }

    private var isWorking: Bool { !hasNavigated }

    private func runAnalysis() async {
        let frames: [AnalyzedFrame]
        if let videoURL {
            frames = await FrameAnalysisPipeline.run(
                videoURL: videoURL,
                interval: 0.5,
                referenceImage: referenceImage
            ) { frac in
                Task { @MainActor in
                    updateStage(for: frac)
                }
            }
        } else {
            updateStage(for: 1.0)
            frames = []
        }
        finish(frames: frames)
    }

    private func updateStage(for value: Double) {
        withAnimation(.easeInOut) { progress = value }
        if value < 0.55 {
            stageText = "Đang trích xuất khung hình…"
        } else if value < 0.97 {
            stageText = "Đang lọc khung đúng tư thế mẫu · chấm điểm độ nét…"
        } else {
            stageText = "Đang chọn 5 khung hình tốt nhất…"
        }
    }

    private func finish(frames: [AnalyzedFrame]) {
        updateStage(for: 1.0)
        guard !hasNavigated else { return }
        hasNavigated = true
        onNavigate(.result(videoURL: videoURL,
                           frames: frames,
                           referenceImage: referenceImage))
    }
}

// Component thanh tiến trình (Giữ nguyên không thay đổi)
struct CustomProgressBar: View {
    var value: Double
    var total: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(red: 0.91, green: 0.94, blue: 0.96))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "5B8DEF"), Color(hex: "2C65E7")],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * (value / total))
            }
        }
        .frame(height: 12)
    }
}

// Extension màu HEX (Giữ nguyên)
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// Preview
#Preview {
    NavigationStack {
        ScreenProcessing(videoURL: nil, referenceImage: nil, onNavigate: { _ in })
    }
}
