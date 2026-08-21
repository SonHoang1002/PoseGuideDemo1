//
//  ScreenResult.swift
//  PhotoshotGuideV1Demo
//

import SwiftUI

struct ResultScreen: View {
    @Environment(\.dismiss) private var dismiss

    let images: [UIImage]
    @State private var displayedImages: [UIImage] = []
    @State private var selectedIndex: Int = 0

    init(images: [UIImage] = []) {
        self.images = images
    }

    var body: some View {
        ZStack {
            Color(red: 0.96, green: 0.97, blue: 0.99).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.bottom, 16)

                ScrollView(.vertical, showsIndicators: false) {
                    if displayedImages.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 16) {
                            thumbnailRow
                            mainImage
                        }
                    }
                }

                Spacer()
                footer
            }
        }
        .onAppear { displayedImages = images }
    }

    private var header: some View {
        ZStack {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.black)
                }
                Spacer()
                Text("Result")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.top, 10)
                Spacer()
                Color.clear.frame(width: 20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
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

    private var thumbnailRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(displayedImages.enumerated()), id: \.offset) { index, image in
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(index == selectedIndex ? Color.blue : .clear, lineWidth: 3)
                        )
                        .onTapGesture { selectedIndex = index }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var mainImage: some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: displayedImages[min(selectedIndex, displayedImages.count - 1)])
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 400)
                .background(Color.gray.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 20))

            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text("\(displayedImages.count) ảnh khớp mẫu nhất")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.blue)
            .clipShape(Capsule())
            .padding(16)
        }
        .padding(.horizontal, 20)
    }

    private var footer: some View {
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
            .disabled(displayedImages.isEmpty)

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
            .disabled(displayedImages.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    private func deleteSelected() {
        guard displayedImages.indices.contains(selectedIndex) else { return }
        displayedImages.remove(at: selectedIndex)
        selectedIndex = max(0, min(selectedIndex, displayedImages.count - 1))
    }

    private func saveSelected() {
        guard displayedImages.indices.contains(selectedIndex) else { return }
        UIImageWriteToSavedPhotosAlbum(displayedImages[selectedIndex], nil, nil, nil)
    }
}

#Preview {
    ResultScreen()
}
