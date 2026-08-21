import Foundation
import UIKit

final class LocalCacheManager {
    static let shared = LocalCacheManager()

    let directory: URL

    private init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoshotCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NotificationCenter.default.addObserver(self, selector: #selector(clearAll),
                                                name: UIApplication.willTerminateNotification, object: nil)
    }

    @discardableResult
    func saveImage(_ image: UIImage, name: String = UUID().uuidString) -> URL? {
        guard let data = image.jpegData(compressionQuality: 0.92) else { return nil }
        let url = directory.appendingPathComponent(name).appendingPathExtension("jpg")
        do { try data.write(to: url); return url } catch { return nil }
    }

    @discardableResult
    func saveVideo(at sourceURL: URL, name: String = UUID().uuidString) -> URL? {
        let destURL = directory.appendingPathComponent(name).appendingPathExtension("mov")
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            return destURL
        } catch { return nil }
    }

    @objc func clearAll() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items { try? FileManager.default.removeItem(at: item) }
    }
}
