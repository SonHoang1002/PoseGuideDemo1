//
//  PhotoshotGuideV1DemoApp.swift
//  PhotoshotGuideV1Demo
//
//  Created by sonmac on 15/8/26.
//

import SwiftUI

@main
struct PhotoshotGuideV1DemoApp: App {
    init() {
        _ = LocalCacheManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ScreenImport()
        }
    }
}
