import SwiftUI
import PhotosUI

struct ScreenImport: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @State private var showCamera = false
    @State private var showCameraRoll = false
    @State private var bottomCaptureState = 0

    @State private var navigateToCamera = false
    @State private var pendingReferenceImage: UIImage?
    @State private var pendingProperties: [AppliedProperty] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Chọn kiểu ảnh")
                                .font(.title2).bold()
                            Text("App sẽ chỉ người cầm máy chụp theo mẫu")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        importCard

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }

                        previewGrid
                    }
                    .padding()
                }

                bottomBar
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: pickerItem) { _, newValue in
                Task { await loadAndAnalyze(from: newValue) }
            }
            .sheet(isPresented: $showCamera) {
                // Open system camera with several properties
            }
            .navigationDestination(isPresented: $navigateToCamera) {
                // Bug fix: this used to call CameraScreen() with no arguments, so the
                // chosen sample image and its properties never reached the camera screen.
                CameraScreen(
                    referenceImage: pendingReferenceImage,
                    referenceProperties: pendingProperties
                )
            }
        }
    }

    // MARK: - Blue CTA card

    private var importCard: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.18))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "photo.badge.magnifyingglass")
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(isAnalyzing ? "Đang phân tích..." : "Import ảnh mẫu của bạn")
                        .font(.subheadline).bold()
                        .foregroundStyle(.white)
                    Text("App tự phân tích góc chụp")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }

                Spacer()

                if isAnalyzing {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(14)
            .background(Color.blue, in: RoundedRectangle(cornerRadius: 16))
        }
        .disabled(isAnalyzing)
    }

    // MARK: - 2x2 preview grid

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var previewGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(0..<4, id: \.self) { index in
                previewTile(index: index)
            }
        }
    }

    @ViewBuilder
    private func previewTile(index: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Image("Template 4")
                .resizable()
                .scaledToFill()

            Text("Dễ · 2 bước").tint(.black)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.9), in: Capsule())
                .padding(8)
        }
        .aspectRatio(0.78, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.05), lineWidth: 1))
        .onTapGesture {
            pendingReferenceImage = UIImage(named: "Template 4")
            pendingProperties = [
                AppliedProperty(title: "Hướng mẫu"),
                AppliedProperty(title: "Máy cao thấp")
            ]
            navigateToCamera = true
        }
    }

    // MARK: - Bottom bar (Chụp / Thư viện)

    private var bottomBar: some View {
        StyledSegmentedControl(items: ["Capture", "Gallery"], selectedIndex: $bottomCaptureState) { state in
            print("O")
        }
        .frame(width: 300, height: 70)
    }

    // MARK: - Loading + pose analysis

    private func loadAndAnalyze(from item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            await MainActor.run { errorMessage = "Không đọc được ảnh, vui lòng thử ảnh khác." }
            return
        }
        await loadAndAnalyze(image: image)
    }

    private func loadAndAnalyze(image: UIImage) async {
        isAnalyzing = true
        errorMessage = nil

        // ... analysis work ...

        isAnalyzing = false
        pendingReferenceImage = image
        pendingProperties = [
            AppliedProperty(title: "Hướng mẫu"),
            AppliedProperty(title: "Máy cao thấp")
        ]
        navigateToCamera = true
    }
}

struct StyledSegmentedControl: UIViewRepresentable {
    let items: [String]
    @Binding var selectedIndex: Int
    var onSelect: ((Int) -> Void)? = nil

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: items)
        control.selectedSegmentIndex = selectedIndex
        control.selectedSegmentTintColor = .black
        control.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        control.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .normal)
        control.layer.cornerRadius = 30
        control.clipsToBounds = true
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ uiView: UISegmentedControl, context: Context) {
        uiView.selectedSegmentIndex = selectedIndex
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject {
        let parent: StyledSegmentedControl
        init(_ parent: StyledSegmentedControl) { self.parent = parent }
        @objc func changed(_ sender: UISegmentedControl) {
            parent.selectedIndex = sender.selectedSegmentIndex
            parent.onSelect?(sender.selectedSegmentIndex)
        }
    }
}
