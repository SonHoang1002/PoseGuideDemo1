//
//  ScreenResult.swift
//  PhotoshotGuideV1Demo
//

import SwiftUI
import AVKit
import UIKit

struct ResultScreen: View {
    let videoURL: URL?
    let initialFrames: [AnalyzedFrame]
    let referenceImage: UIImage?
    /// Nút back KHÔNG quay lại Processing/Camera mà xoá sạch stack điều hướng
    /// → về đúng màn ban đầu để chọn mẫu khác.
    let onFinish: () -> Void

    @State private var frames: [AnalyzedFrame] = []
    @State private var selectedIndex: Int = 0
    @State private var interval: Double = 0.5
    @State private var isAnalyzing = false
    @State private var player: AVPlayer?
    @State private var reanalysisTask: Task<Void, Never>?
    @State private var savedToast = false
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            Color(red: 0.96, green: 0.97, blue: 0.99).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        if let player {
                            videoPreview(player)
                        }

                        if videoURL != nil {
                            intervalSlider
                        }

                        if frames.isEmpty {
                            emptyState
                        } else {
                            mainImage
                            thumbnailRow
                        }
                    }
                    .padding(.bottom, 16)
                }

                footer
            }

            if isAnalyzing {
                analyzingOverlay
            }

            if savedToast {
                toast
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: setup)
        .onDisappear(perform: teardown)
    }

    // MARK: - Setup / teardown

    private func setup() {
        if frames.isEmpty {
            frames = initialFrames.sorted { $0.time < $1.time }
        }
        selectedIndex = min(selectedIndex, max(0, frames.count - 1))

        if let videoURL, player == nil {
            let item = AVPlayerItem(url: videoURL)
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            newPlayer.play()
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                newPlayer.seek(to: CMTime.zero)
                newPlayer.play()
            }
        }
    }

    private func teardown() {
        reanalysisTask?.cancel()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player?.pause()
    }

    // MARK: - Video preview + interval slider

    private func videoPreview(_ player: AVPlayer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VideoPlayer(player: player)
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)

            HStack(spacing: 6) {
                Image(systemName: "film")
                Text("Video gốc · \(Int(interval * 1000))ms/khung khi trích xuất")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 20)
    }

    private var intervalSlider: some View {
        VStack(spacing: 6) {
            HStack {
                Label("Khoảng cách trích xuất", systemImage: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(String(format: "%.1fs", interval))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(hex: "2C65E7"))
                    .monospacedDigit()
            }

            Slider(
                value: $interval,
                in: 0.2...2.0,
                step: 0.1
            ) { editing in
                guard !editing else { return }
                reanalyze()
            }
            .tint(Color(hex: "2C65E7"))

            HStack {
                Text("0.2s · dày hơn")
                Spacer()
                Text("thưa hơn · 2.0s")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Header / states

    private var header: some View {
        ZStack {
            HStack {
                Button(action: { onFinish() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.black)
                }
                .accessibilityLabel("Quay về màn chọn mẫu")
                Spacer()
                Text("Result")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.black)
                Spacer()
                Color.clear.frame(width: 20)
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("Chưa có ảnh nào khớp với mẫu")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var analyzingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text("Đang phân tích lại khung hình…")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundColor(.white)
        .padding(.vertical, 14)
        .padding(.horizontal, 22)
        .background(Capsule().fill(Color.black.opacity(0.75)))
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: isAnalyzing)
    }

    private var toast: some View {
        VStack {
            Spacer()
            Label("Đã lưu vào thư viện ảnh", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.vertical, 10)
                .padding(.horizontal, 18)
                .background(Capsule().fill(Color.green.opacity(0.95)))
                .padding(.bottom, 90)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: savedToast)
        .task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            savedToast = false
        }
    }

    // MARK: - Best images

    private var mainImage: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                Image(uiImage: frames[min(selectedIndex, frames.count - 1)].image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                Text("#\(selectedIndex + 1)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.blue))
                    .padding(12)
            }
            .padding(.horizontal, 20)

            qualityChips
        }
    }

    private var qualityChips: some View {
        let q = frames[min(selectedIndex, frames.count - 1)].quality
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(icon: "hand.raised.fill", label: "Chống rung", value: q.motionBlur)
                chip(icon: "camera.metering.center.weighted", label: "Bố cục", value: q.composition)
                chip(icon: "eye", label: "Độ nét", value: q.sharpness)
                chip(icon: "sun.max", label: "Sáng", value: q.exposure)
                chip(icon: "circle.lefthalf.filled", label: "Tương phản", value: q.contrast)
                chip(icon: "paintpalette", label: "Màu", value: q.color)
            }
            .padding(.horizontal, 20)
        }
    }

    private func chip(icon: String, label: String, value: Double) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(label)
                .font(.system(size: 11, weight: .medium))
            Text("\(Int((value * 100).rounded()))")
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
        }
        .foregroundColor(Color(hex: "2C65E7"))
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Capsule().fill(Color(hex: "2C65E7").opacity(0.1)))
    }

    private var thumbnailRow: some View {
        HStack(spacing: 10) {
            ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
                Button {
                    selectedIndex = index
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Image(uiImage: frame.image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 62, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        // Nhãn thời gian chỉ có ý nghĩa với khung trích từ video
                        if videoURL != nil {
                            Text("\(Int(frame.time))s")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.black.opacity(0.55)))
                                .padding(3)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(index == selectedIndex ? Color.blue : .clear, lineWidth: 3)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer controls

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button(action: deleteSelected) {
                    Text("Delete")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color(red: 1.0, green: 0.9, blue: 0.9))
                        .cornerRadius(27)
                }
                .disabled(frames.isEmpty)

                Button(action: saveSelected) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down")
                        Text("Save this image")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color.blue)
                    .cornerRadius(27)
                }
                .disabled(frames.isEmpty)
            }

            if videoURL != nil {
                Button(action: saveVideo) {
                    Label("Lưu video vào thư viện ảnh", systemImage: "arrow.down.to.line.compact")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Color.black.opacity(0.06))
                        .cornerRadius(20)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Actions

    private func deleteSelected() {
        guard frames.indices.contains(selectedIndex) else { return }
        frames.remove(at: selectedIndex)
        selectedIndex = max(0, min(selectedIndex, frames.count - 1))
    }

    private func saveSelected() {
        guard frames.indices.contains(selectedIndex) else { return }
        UIImageWriteToSavedPhotosAlbum(frames[selectedIndex].image, nil, nil, nil)
        savedToast = true
    }

    private func saveVideo() {
        guard let videoURL else { return }
        UISaveVideoAtPathToSavedPhotosAlbum(videoURL.path, nil, nil, nil)
        savedToast = true
    }

    /// Chạy lại pipeline trích xuất + chấm điểm với khoảng cách mới, rồi cập nhật 5 ảnh tốt nhất.
    private func reanalyze() {
        reanalysisTask?.cancel()
        guard let videoURL else { return }

        isAnalyzing = true
        let refImage = referenceImage
        let currentInterval = interval

        reanalysisTask = Task {
            let newFrames = await FrameAnalysisPipeline.run(
                videoURL: videoURL,
                interval: currentInterval,
                referenceImage: refImage
            ) { frac in
                _ = frac
            }

            await MainActor.run {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    frames = newFrames
                    selectedIndex = 0
                }
                isAnalyzing = false
            }
        }
    }
}

#Preview {
    NavigationStack {
        ResultScreen(videoURL: nil, initialFrames: [], referenceImage: nil, onFinish: {})
    }
}
