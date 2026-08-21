import SwiftUI

struct ScreenProcessing: View {
    // Giả lập tiến trình
    var progress: Double = 0.6
    
    var body: some View {
        ZStack {
            // 1. Background full màn hình
            Color.white.ignoresSafeArea()
            
            // 2. Nội dung chính nằm chính xác ở giữa
            VStack(spacing: 24) {
                Spacer() // Đẩy nội dung xuống giữa theo trục dọc
                
                // ------- Phần xử lý ảnh (Processing View) -------
                
                // 1. Biểu tượng (Icon)
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
                
                // 2. Tiêu đề
                Text("Đang xử lý ảnh")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.15))
                
                // 3. Thanh tiến trình
                CustomProgressBar(value: progress, total: 1.0)
                    .frame(width: 260, height: 12)
                
                // ------- Hết phần xử lý ảnh -------
                
                Spacer() // Đẩy nội dung lên giữa theo trục dọc
            }
            .padding(40) // Tạo khoảng cách lề 2 bên để giao diện không sát cạnh quá mức
        }
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
    ScreenProcessing()
}
