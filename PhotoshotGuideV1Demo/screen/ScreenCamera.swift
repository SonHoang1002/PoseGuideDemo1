import SwiftUI
import AVFoundation
import CoreMotion
import CoreMedia
import Vision
import PhotosUI
import UIKit
internal import Combine

/// Key attachment của CMSampleBuffer chứa ma trận intrinsic 3x3 (48 byte simd_float3x3).
/// Không được expose sang Swift nên khai báo lại đúng giá trị trong CMSampleBuffer.h.
private let kCameraIntrinsicDataKey = "CameraIntrinsicData" as CFString

// MARK: - Models

struct AppliedProperty: Identifiable, Equatable, Hashable {
    let id = UUID()
    let title: String
}

/// A frame (from live preview, a manual tap, or an extracted video frame) scored against
/// the reference template. This is the "temporary storage" pool the 5-best-match retrieval
/// draws from — kept in memory only, capped, never written to Photos unless the user saves it.
struct ScoredCapture: Identifiable {
    let id = UUID()
    let image: UIImage
    let score: Double // 0...1, higher = closer match to the reference pose
}

// MARK: - Camera manager

class CameraManager: NSObject, ObservableObject {
    @Published var session = AVCaptureSession()
    @Published var isAuthorized = false

    // Guidance pipeline output
    @Published var guidanceResult: GuidanceResult?
    /// Cue đã qua CuePresenter (chống nhảy mục + nhảy số) — UI nên ưu tiên cái này.
    @Published var stableCue: String?
    /// true khi ảnh mẫu không phân tích được người → hướng dẫn không thể chạy.
    @Published var isTemplateMissing = false
    /// Điểm khớp của ảnh mẫu để vẽ khung mẫu (ghost) lên preview.
    @Published var templateGhostJoints: [VNHumanBodyPoseObservation.JointName: CGPoint]?
    /// Tỉ lệ w/h của ảnh mẫu — ghost được aspect-fit theo tỉ lệ này.
    @Published var templateSampleAspect: Double?
    /// Lớp khung hình + mode (full / upper) suy từ ảnh mẫu — driver cho dialog & UI.
    @Published var templateFraming: FramingClass?
    @Published var templateCaptureMode: CaptureMode?
    /// Hiện dialog 1 lần khi mẫu là khung hình PARTIAL (chỉ lấy phần trên cơ thể).
    private var didShowPartialNotice = false
    @Published var showPartialTemplateNotice = false
    /// Chế độ chân dung: khung VUÔNG, chỉ lấy phần TRÊN của người. Bật bằng nút trên UI.
    @Published var isPortraitMode = false
    @Published var countdown: Int?
    @Published var jointPoints: [VNHumanBodyPoseObservation.JointName: JointPoint]?
    @Published var detectedJointCount: Int = 0
    /// true khi frame hiện tại đo ĐỦ khớp thân để chạy hướng dẫn (khác với
    /// "có vẽ skeleton" — vẽ chỉ cần confidence ≥ mức hiển thị rất thấp).
    @Published var hasLiveSubject = false

    // Manually-tapped "keeper" shots (shown at bottom-left)
    @Published var lastCapturedImage: UIImage?
    @Published var capturedItems: [UIImage] = []

    // Continuously scored pool used to retrieve the best matches (temp, in-memory)
    @Published var scoredCaptures: [ScoredCapture] = []

    // Video mode
    @Published var isRecording = false
    @Published var lastVideoURL: URL?
    @Published var recordCountdown: Int?

    // Pinch-to-zoom
    @Published var currentZoomFactor: CGFloat = 1.0
    private var zoomGestureStartFactor: CGFloat = 1.0

    static let maxRecordSeconds = 30

    private var photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "camera.sessionQueue")
    private var videoInput: AVCaptureDeviceInput?
    private var activeDevice: AVCaptureDevice?
    private var currentPosition: AVCaptureDevice.Position = .back

    // Guidance state — mọi ngưỡng nằm trong GuidanceConfig (v2)
    private let guidanceConfig = GuidanceConfig()
    private var template: Template?
    private var optics: CameraOptics?
    private var triedEnablingIntrinsics = false
    private lazy var measurer = Measurer(config: guidanceConfig)
    private lazy var engine = GuidanceEngine(config: guidanceConfig)
    private lazy var trigger = CaptureTrigger(config: guidanceConfig)
    private let motion = CMMotionManager()
    private var countdownTimer: Timer?
    private var frameCounter = 0

    // Burst-capture scoring pool
    private let ciContext = CIContext()
    private var lastMeasurement: Measurement?
    private var lastBurstCaptureTime: Double = 0
    private let burstInterval: Double = 0.6
    private let maxScoredCaptures = 60

    // MARK: - Chế độ chân dung (khung vuông, lấy phần trên người)

    /// Khung vuông chân dung theo toạ độ CHUẨN HOÁ của toàn vùng preview (0...1).
    /// Được CameraScreen cập nhật mỗi khi kích thước màn hình đổi.
    var portraitCropNormalized: CGRect?
    /// Tỉ lệ w/h của vùng preview — dùng để quy khung màn hình sang pixel ảnh
    /// (preview hiển thị aspect-FILL nên phải trừ phần ảnh bị crop khỏi màn hình).
    var previewViewAspect: CGFloat?

    private static let portraitSideInset: CGFloat = 14      // lề hai bên khung vuông
    private static let portraitTopFraction: CGFloat = 0.14  // đỉnh khung cách mép trên

    func updatePortraitLayout(viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        previewViewAspect = viewSize.width / viewSize.height
        let side = min(viewSize.width - Self.portraitSideInset * 2,
                       viewSize.height * 0.55)
        let x = (viewSize.width - side) / 2
        let y = viewSize.height * Self.portraitTopFraction
        portraitCropNormalized = CGRect(x: x / viewSize.width,
                                        y: y / viewSize.height,
                                        width: side / viewSize.width,
                                        height: side / viewSize.height)
    }

    /// Quy khung chuẩn hoá TRÊN MÀN HÌNH sang pixel của ảnh, tính đúng phần ảnh
    /// bị aspect-fill cắt mất (đây là chỗ khiến crop khớp với những gì user thấy).
    static func cropRect(normalizedViewRect: CGRect,
                         viewAspect: CGFloat,
                         imageSize: CGSize) -> CGRect {
        let bufferAspect = imageSize.width / imageSize.height
        var uRange: CGFloat = 1, vRange: CGFloat = 1   // độ dài vùng ảnh HIỂN THỊ được
        var u0: CGFloat = 0, v0: CGFloat = 0
        if bufferAspect > viewAspect {
            uRange = viewAspect / bufferAspect         // ảnh rộng hơn → crop trái/phải
            u0 = (1 - uRange) / 2
        } else {
            vRange = bufferAspect / viewAspect         // ảnh cao hơn → crop trên/dưới
            v0 = (1 - vRange) / 2
        }
        let x = (normalizedViewRect.minX - u0) / uRange * imageSize.width
        let y = (normalizedViewRect.minY - v0) / vRange * imageSize.height
        let w = normalizedViewRect.width / uRange * imageSize.width
        let h = normalizedViewRect.height / vRange * imageSize.height
        return CGRect(x: x, y: y, width: w, height: h)
            .intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Cắt ảnh về khung chân dung nếu mode đang bật; ngược lại trả nguyên bản.
    private func applyPortraitCropIfNeeded(_ image: UIImage) -> UIImage {
        guard isPortraitMode,
              let nRect = portraitCropNormalized,
              let aspect = previewViewAspect else { return image }
        let rect = Self.cropRect(normalizedViewRect: nRect,
                                 viewAspect: aspect,
                                 imageSize: image.size)
        guard rect.width >= 40, rect.height >= 40 else { return image }
        return UIGraphicsImageRenderer(size: rect.size).image { _ in
            image.draw(at: CGPoint(x: -rect.minX, y: -rect.minY))
        }
    }

    override init() {
        super.init()
        checkAuthorization()
    }

    func checkAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isAuthorized = granted
                    if granted { self?.setupSession() }
                }
            }
        default:
            isAuthorized = false
        }
    }

    private func setupSession() {
        // Vector trọng lực cần chạy NGAY từ đầu: pitch (mục 4) phụ thuộc nó.
        // Nếu chỉ bật trong startGuidance thì template phân tích fail → mất luôn cảm biến.
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        if motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive {
            motion.startDeviceMotionUpdates()
        }

        session.beginConfiguration()
        // .high (not .photo) so photo capture, live pose analysis, and movie recording
        // can all share the same session.
        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentPosition),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            session.commitConfiguration()
            return
        }
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            activeDevice = camera
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        videoDataOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        }

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }

        session.commitConfiguration()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func flipCamera() {
        guard let currentInput = videoInput else { return }
        session.beginConfiguration()
        session.removeInput(currentInput)

        let newPosition: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
        guard let newCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
              let newInput = try? AVCaptureDeviceInput(device: newCamera) else {
            session.addInput(currentInput)
            session.commitConfiguration()
            return
        }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            videoInput = newInput
            activeDevice = newCamera
            currentPosition = newPosition
            optics = nil
            // New physical device → its zoom range is independent, reset baseline.
            currentZoomFactor = 1.0
            zoomGestureStartFactor = 1.0
        } else {
            session.addInput(currentInput)
        }
        session.commitConfiguration()
    }

    // MARK: - Zoom

    var minZoomFactor: CGFloat {
        activeDevice?.minAvailableVideoZoomFactor ?? 1.0
    }

    var maxZoomFactor: CGFloat {
        guard let device = activeDevice else { return 1.0 }
        // Some devices report absurdly high max factors (100x+) where image quality is
        // unusable well before that — cap to something sane for a pinch gesture.
        return min(device.maxAvailableVideoZoomFactor, 8.0)
    }

    /// Call when a pinch gesture begins, so the next gesture is relative to the current zoom
    /// rather than snapping back to 1.0x.
    func beginZoomGesture() {
        zoomGestureStartFactor = currentZoomFactor
    }

    /// Call continuously with MagnificationGesture's `value` (a multiplier starting at 1.0).
    func updateZoomGesture(scale: CGFloat) {
        setZoom(factor: zoomGestureStartFactor * scale)
    }

    func setZoom(factor: CGFloat) {
        guard let device = activeDevice else { return }
        let clamped = min(max(factor, minZoomFactor), maxZoomFactor)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.currentZoomFactor = clamped }
        } catch {
            // Silently ignore — zoom just won't update this frame.
        }
    }

    // MARK: - Photo capture

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: PhotoCaptureDelegate { [weak self] image in
            guard let self, let image else { completion(image); return }
            // Chế độ chân dung: cắt về khung vuông NGAY tại đây để cả ảnh lưu,
            // ảnh hiện thumbnail và ảnh vào pool điểm số đều là bản đã cắt.
            let finalImage = applyPortraitCropIfNeeded(image)
            // A manual tap also gets scored so it competes fairly for the top-5 pool.
            if let m = self.lastMeasurement, let template = self.template {
                let score = PoseSimilarity.score(m, template)
                DispatchQueue.main.async { self.addScoredCapture(ScoredCapture(image: finalImage, score: score)) }
            }
            completion(finalImage)
        })
    }

    // MARK: - Video recording

    func startRecording() {
        guard !movieOutput.isRecording else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
        DispatchQueue.main.async {
            self.isRecording = true
            self.startRecordCountdown()
        }
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        DispatchQueue.main.async {
            self.cancelRecordCountdown()
        }
        movieOutput.stopRecording()
    }

    /// Đếm ngược 30 giây khi bắt đầu ghi; về 0 thì tự động dừng.
    private func startRecordCountdown() {
        cancelRecordCountdown()
        var remaining = Self.maxRecordSeconds
        recordCountdown = remaining
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                self.recordCountdown = nil
                self.stopRecording()
            } else {
                self.recordCountdown = remaining
            }
        }
    }

    private func cancelRecordCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        recordCountdown = nil
    }

    // MARK: - Guidance

    /// Call whenever the reference/sample image (or a newly picked one) has been analyzed.
    func startGuidance(template: Template) {
        self.template = template
        // Dữ liệu vẽ khung mẫu (ghost) cho người chụp ướm người vào.
        templateGhostJoints = template.ghostJoints
        templateSampleAspect = template.sampleAspectRatio
        templateFraming = template.framing
        templateCaptureMode = template.captureMode
        // Dialog "chỉ lấy phần trên cơ thể" — báo 1 lần mỗi phiên camera khi mẫu là PARTIAL.
        if template.captureMode == .upper, !didShowPartialNotice {
            didShowPartialNotice = true
            showPartialTemplateNotice = true
        }
        measurer.reset()
        engine.reset()
        trigger.reset()
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        if motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive {
            motion.startDeviceMotionUpdates()
        }
    }

    /// Best N frames captured so far (live burst + manual taps + extracted video frames),
    /// ranked by closeness to the reference pose.
    func topMatches(_ n: Int = 5) -> [UIImage] {
        topScoredMatches(n).map(\.image)
    }

    /// Same as `topMatches` but keeps each frame's pose score, so downstream screens
    /// can blend it with frame quality instead of guessing a neutral 0.5.
    func topScoredMatches(_ n: Int = 5) -> [ScoredCapture] {
        Array(scoredCaptures.sorted { $0.score > $1.score }.prefix(n))
    }

    private func addScoredCapture(_ capture: ScoredCapture) {
        scoredCaptures.append(capture)
        if scoredCaptures.count > maxScoredCaptures {
            scoredCaptures.sort { $0.score > $1.score }
            scoredCaptures.removeLast(scoredCaptures.count - maxScoredCaptures)
        }
    }

    private func handleAutoCapture() {
        capturePhoto { [weak self] image in
            guard let self, let image else { return }
            LocalCacheManager.shared.saveImage(image)
            DispatchQueue.main.async {
                self.lastCapturedImage = image
                self.capturedItems.append(image)
            }
        }
    }

    private func imageFromPixelBuffer(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// Runs the 6-criteria guidance pipeline on live frames (throttled), publishes cues, and
// periodically snapshots + scores the frame into the temp match pool.
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Body-point detection must NOT depend on a reference template — it should work
        // the moment the camera is on, with or without a sample picked. Previously this
        // whole delegate bailed out at the top if `template` was nil, which silently
        // killed the skeleton overlay (and everything else) whenever the reference photo
        // hadn't been analyzed yet.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        frameCounter += 1
        let cfg = guidanceConfig
        let runFace = frameCounter % max(1, cfg.faceEveryNFrames) == 0

        // Bật giao intrinsics 1 lần — tiêu cự thật từ cảm biến (chính xác hơn videoFieldOfView).
        if !triedEnablingIntrinsics {
            triedEnablingIntrinsics = true
            if let connection = videoDataOutput.connection(with: .video),
               connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
        }

        if optics == nil {
            let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
            // Buffer cảm biến là landscape; quy về dạng DỌC cho thống nhất với Vision.
            let portraitSize = CGSize(width: CGFloat(min(w, h)), height: CGFloat(max(w, h)))
            var mode: CMAttachmentMode = 0
            if let cf = CMGetAttachment(sampleBuffer,
                                        key: kCameraIntrinsicDataKey,
                                        attachmentModeOut: &mode),
               let data = cf as? Data,
               data.count == MemoryLayout<simd_float3x3>.size {
                // Rotation chỉ đổi w/h, tiêu cự giữ nguyên → fy dùng trực tiếp với kích thước dọc.
                let k = data.withUnsafeBytes { $0.load(as: simd_float3x3.self) }
                optics = CameraOptics(intrinsics: k, imageSize: portraitSize)
            } else if let device = activeDevice {
                optics = CameraOptics(device: device, imageSize: portraitSize)
            }
        }
        guard let optics else { return }

        let orientation: CGImagePropertyOrientation = currentPosition == .front ? .leftMirrored : .right

        // v2: pitch lấy từ VECTOR TRỌNG LỰC + mọi bộ lọc nằm trong Measurer.
        let now = CACurrentMediaTime()
        let m = measurer.measure(pixelBuffer: pixelBuffer,
                                 deviceMotion: motion.deviceMotion,
                                 optics: optics,
                                 orientation: orientation,
                                 timestamp: now,
                                 runFace: runFace,
                                 framing: template?.framing ?? .full)

        lastMeasurement = m

        // Always publish the skeleton — independent of whether guidance is running yet.
        DispatchQueue.main.async { [weak self] in
            self?.jointPoints = m.jointPoints
            self?.detectedJointCount = m.jointPoints.count
            self?.hasLiveSubject = m.hasSubject
        }

        // Everything below needs a reference template; skip it gracefully if there isn't one yet.
        guard let template else { return }

        let result = engine.evaluate(m, template, optics)
        // Đang lắc mạnh → đóng băng cue cũ (user đang di chuyển theo hướng dẫn).
        let frozen = m.angularSpeedDegPerSec > cfg.freezeCueAngularSpeedDegPerSec
        let stable = engine.stablePrimaryCue(for: result, now: now, frozen: frozen)
        let shouldCapture = trigger.update(ready: result.readyToCapture, now: now)
        let countdownValue = trigger.countdownRemaining

        // Burst-capture + score into the temp match pool (throttled, off the main thread).
        if m.hasSubject, now - lastBurstCaptureTime > burstInterval,
           let uiImage = imageFromPixelBuffer(pixelBuffer, orientation: orientation) {
            lastBurstCaptureTime = now
            let score = PoseSimilarity.score(m, template)
            let finalImage = applyPortraitCropIfNeeded(uiImage)
            DispatchQueue.main.async { [weak self] in
                self?.addScoredCapture(ScoredCapture(image: finalImage, score: score))
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.guidanceResult = result
            self.stableCue = stable
            self.countdown = countdownValue
            if shouldCapture { self.handleAutoCapture() }
        }
    }
}

// Handles a finished video recording: copies the clip into the app-local cache
// (lives only while the app is running, wiped on exit) and hands the cached URL to
// the processing screen, which extracts + scores frames.
extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        guard error == nil else {
            DispatchQueue.main.async { self.isRecording = false }
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let savedURL = LocalCacheManager.shared.saveVideo(at: outputFileURL) ?? outputFileURL
            if savedURL != outputFileURL {
                try? FileManager.default.removeItem(at: outputFileURL)
            }
            DispatchQueue.main.async {
                self?.isRecording = false
                self?.lastVideoURL = savedURL
            }
        }
    }
}

class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (UIImage?) -> Void

    init(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            completion(nil)
            return
        }
        completion(image)
    }
}

// MARK: - Camera preview

final class VideoPreviewContainer: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> VideoPreviewContainer {
        let view = VideoPreviewContainer()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: VideoPreviewContainer, context: Context) {
        uiView.previewLayer.session = session
    }
}

// MARK: - Camera Screen

struct CameraScreen: View {

    let initialReferenceImage: UIImage?
    let referenceProperties: [AppliedProperty]
    /// Đẩy màn tiếp theo qua path trung tâm của ScreenImport (Processing / Result).
    let onNavigate: (AppRoute) -> Void
    /// Kết thúc phiên → xoá sạch path, về màn ban đầu để chọn mẫu khác.
    let onFinish: () -> Void

    @State private var mode: Int = 1 // 0 = Video, 1 = Photo
    @State private var currentReferenceImage: UIImage?
    @State private var appliedProperties: [AppliedProperty] = []
    @State private var showPreviewGrid: Bool = false
    @State private var showBodyPoints: Bool = true
    // Khung mẫu (ghost) từ ảnh mẫu — bật mặc định, tắt bằng nút trên màn hình.
    @State private var showPoseGuide: Bool = true

    // Changing the sample photo from inside the camera screen
    @State private var showChangeSample = false
    @State private var samplePickerItem: PhotosPickerItem?

    // Pinch-to-zoom badge
    @State private var showZoomBadge = false
    @State private var zoomBadgeHideTask: Task<Void, Never>?

    @StateObject private var cameraManager = CameraManager()

    init(referenceImage: UIImage? = nil,
         referenceProperties: [AppliedProperty] = [],
         onNavigate: @escaping (AppRoute) -> Void = { _ in },
         onFinish: @escaping () -> Void = {}) {
        self.initialReferenceImage = referenceImage
        self.referenceProperties = referenceProperties
        self.onNavigate = onNavigate
        self.onFinish = onFinish
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if cameraManager.isAuthorized {
                cameraContent
            } else {
                permissionView
            }
        }
        .onAppear {
            appliedProperties = referenceProperties
            currentReferenceImage = initialReferenceImage
            cameraManager.checkAuthorization()
        }
        .onChange(of: currentReferenceImage) { _, newImage in
            guard let newImage else { return }
            cameraManager.isTemplateMissing = false
            Task.detached(priority: .userInitiated) {
                if let template = TemplateAnalyzer.analyze(image: newImage) {
                    await MainActor.run { cameraManager.startGuidance(template: template) }
                } else {
                    await MainActor.run { cameraManager.isTemplateMissing = true }
                }
            }
        }
        .photosPicker(isPresented: $showChangeSample, selection: $samplePickerItem, matching: .images)
        .onChange(of: samplePickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                guard let data = try? await newItem.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                await MainActor.run { currentReferenceImage = image }
            }
        }
        // Ghi xong video → tự động sang màn Processing để trích xuất + chấm điểm khung hình
        .onChange(of: cameraManager.lastVideoURL) { _, newURL in
            guard let newURL else { return }
            onNavigate(.processing(videoURL: newURL, referenceImage: currentReferenceImage))
        }
    }

    private var cameraContent: some View {
        ZStack {
            // GeometryReader phủ toàn màn hình (kể cả safe area) để tính khung chân
            // dung theo đúng hệ toạ độ của preview layer.
            GeometryReader { geo in
                CameraPreviewView(session: cameraManager.session)
                    .onAppear {
                        cameraManager.updatePortraitLayout(viewSize: geo.size)
                    }
                    .onChange(of: geo.size) { _, newSize in
                        cameraManager.updatePortraitLayout(viewSize: newSize)
                    }
            }
            .ignoresSafeArea()
            // Two-finger pinch to zoom. Kept directly on the preview layer (not on the
            // outer ZStack) so it doesn't fight with sheet/nav-swipe gestures elsewhere
            // on screen.
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        cameraManager.updateZoomGesture(scale: value)
                        flashZoomBadge()
                    }
                    .onEnded { _ in
                        cameraManager.beginZoomGesture()
                    }
            )

            if showBodyPoints {
                SkeletonOverlayView(jointPoints: cameraManager.jointPoints)
                    .ignoresSafeArea()
                    // Explicit here too (SkeletonOverlayView already sets this internally):
                    // this view sits directly on top of the preview layer, so it must never
                    // intercept touches or the pinch gesture below it would silently stop
                    // working the moment a body is detected.
                    .allowsHitTesting(false)
            }

            // Khung mẫu từ ảnh mẫu — người chụp ướm người thật vào khung này.
            if showPoseGuide,
               let ghostJoints = cameraManager.templateGhostJoints,
               let sampleAspect = cameraManager.templateSampleAspect {
                TemplateGhostOverlayView(joints: ghostJoints, sampleAspect: sampleAspect)
                    .ignoresSafeArea()
            }

            // Chế độ chân dung: làm tối ngoài khung vuông, chỉ lấy phần trên người.
            if cameraManager.isPortraitMode,
               let squareRect = cameraManager.portraitCropNormalized {
                PortraitFrameOverlayView(square: squareRect)
                    .ignoresSafeArea()
            }

            VStack {
                topBar
                if showBodyPoints {
                    HStack {
                        bodyPointsBadge
                        Spacer()
                    }
                    .padding(.top, 6)
                }
                // Bảng gợi ý LIÊN TỤC theo 6 tiêu chí — mỗi mục tự có câu hướng dẫn
                // riêng, không phụ thuộc mục ưu tiên cao nhất đang hiển thị ở pill dưới.
                if currentReferenceImage != nil && !cameraManager.isTemplateMissing {
                    HStack(alignment: .top) {
                        criteriaChecklist
                        Spacer()
                    }
                    .padding(.top, 6)
                }
                if cameraManager.recordCountdown != nil {
                    recordCountdownPill.padding(.top, 10)
                }
                Spacer()
                if showZoomBadge {
                    zoomBadge
                        .transition(.opacity)
                        .padding(.bottom, 8)
                }
                guidancePill.padding(.bottom, 12)
                modeSwitcher.padding(.bottom, 16)
                bottomControls.padding(.bottom, 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // Số đếm lớn khi còn ≤5 giây cuối của 30s ghi hình
            if let seconds = cameraManager.recordCountdown, seconds <= 5 {
                Text("\(seconds)")
                    .font(.system(size: 130, weight: .heavy))
                    .foregroundColor(.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.4), radius: 8)
                    .id(seconds)
                    .transition(.scale(scale: 1.4).combined(with: .opacity))
                    .animation(.easeOut(duration: 0.3), value: cameraManager.recordCountdown)
            }
        }
        .sheet(isPresented: $showPreviewGrid) {
            PreviewGridView(capturedItems: cameraManager.capturedItems)
        }
        .alert("Chỉ lấy phần trên cơ thể", isPresented: $cameraManager.showPartialTemplateNotice) {
            Button("Đã hiểu") { }
        } message: {
            Text("Mẫu của bạn là khung hình bán thân (chân dung). Hướng dẫn chỉ chấm phần trên cơ thể; hãy ướm người thật vào khung hình được hiển thị.")
        }
    }

    // Small pill showing the current zoom factor, flashed while pinching and faded out
    // shortly after the gesture stops.
    private var zoomBadge: some View {
        Text(String(format: "%.1fx", cameraManager.currentZoomFactor))
            .font(.system(size: 13, weight: .bold))
            .monospacedDigit()
            .foregroundColor(.white)
            .padding(.vertical, 6)
            .padding(.horizontal, 14)
            .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    private func flashZoomBadge() {
        withAnimation(.easeOut(duration: 0.15)) { showZoomBadge = true }
        zoomBadgeHideTask?.cancel()
        zoomBadgeHideTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) { showZoomBadge = false }
            }
        }
    }

    // Pill hiển thị thời gian ghi + đếm ngược 30s
    private var recordCountdownPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)

            Text("REC")
                .font(.system(size: 13, weight: .bold))

            if let seconds = cameraManager.recordCountdown {
                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule()
                            .fill(Color.red)
                            .frame(width: geo.size.width * CGFloat(seconds) / CGFloat(CameraManager.maxRecordSeconds))
                    }
                }
                .frame(width: 56, height: 5)
            }
        }
        .foregroundColor(.white)
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    private var permissionView: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 32))
                .foregroundColor(.white.opacity(0.8))
            Text("Cần quyền truy cập Camera")
                .foregroundColor(.white)
                .font(.headline)
            Text("Vui lòng cấp quyền camera trong Cài đặt để tiếp tục.")
                .foregroundColor(.white.opacity(0.7))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Mở Cài đặt") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .padding(.top, 8)
            .foregroundColor(.blue)
        }
    }

    // Small live readout so it's obvious detection is actually running (or isn't yet —
    // e.g. subject not fully in frame).
    private var bodyPointsBadge: some View {
        let count = cameraManager.detectedJointCount
        let hasSubject = cameraManager.hasLiveSubject
        return HStack(spacing: 6) {
            Circle()
                .fill(hasSubject ? Color.green : (count > 0 ? Color.yellow : Color.gray))
                .frame(width: 7, height: 7)
            Text(hasSubject ? "\(count) điểm cơ thể"
                            : count > 0 ? "Tín hiệu yếu — đưa người vào khung rõ hơn"
                                        : "Chưa nhận diện được người")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(.white)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Capsule().fill(Color.black.opacity(0.5)))
    }

    // MARK: - Checklist 6 tiêu chí (gợi ý liên tục từng mục)

    @ViewBuilder
    private func statusIcon(_ state: CriterionStatus.State) -> some View {
        switch state {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .violated:
            Image(systemName: "exclamationmark.circle.fill").foregroundColor(.yellow)
        case .waiting:
            Image(systemName: "clock.fill").foregroundColor(.white.opacity(0.55))
        case .unknown:
            Image(systemName: "questionmark.circle").foregroundColor(.white.opacity(0.45))
        }
    }

    private var criteriaChecklist: some View {
        let statuses = cameraManager.guidanceResult?.statuses ?? []
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(statuses) { s in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    statusIcon(s.state)
                        .font(.system(size: 11))
                    Text(s.criterion.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(s.suggestion ?? (s.state == .waiting ? "chờ hướng mẫu đúng" : "đang đo…"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(s.suggestion != nil ? .yellow : .white.opacity(0.75))
                        .lineLimit(2)
                }
            }
            if statuses.isEmpty {
                Text("Đang phân tích mẫu…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
            }
        }
        .foregroundColor(.white)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.45)))
    }

    // MARK: - Live guidance cue

    private var guidancePill: some View {
        Group {
            if let countdown = cameraManager.countdown {
                VStack(spacing: 4) {
                    Text("\(countdown)")
                        .font(.system(size: 22, weight: .bold))
                    Text("Giữ nguyên tư thế…")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.vertical, 12)
                .padding(.horizontal, 24)
                .background(Capsule().fill(Color.blue))
            } else if cameraManager.isTemplateMissing {
                Label("Không thấy người trong ảnh mẫu — chọn ảnh khác", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .background(Capsule().fill(Color.orange))
            } else if let primary = cameraManager.stableCue ?? cameraManager.guidanceResult?.primaryCue {
                VStack(spacing: 4) {
                    Text(primary)
                        .font(.system(size: 15, weight: .semibold))
                    // Cue phụ lấy từ danh sách vi phạm gốc, chỉ hiện khi khác cue chính.
                    if let secondary = cameraManager.guidanceResult?.secondaryCue, secondary != primary {
                        Text(secondary)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.black.opacity(0.45))
                    }
                }
                .foregroundColor(.black)
                .padding(.vertical, 12)
                .padding(.horizontal, 20)
                .background(Capsule().fill(Color.white))
            } else if cameraManager.guidanceResult?.isAligned == true {
                Label("Đã đạt — giữ nguyên", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    .background(Capsule().fill(Color.green))
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("V2 · 02 Camera realtime")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))

                if currentReferenceImage != nil {
                    ForEach(appliedProperties) { property in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                            Text(property.title)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(.white)
                    }
                }
            }

            Spacer()

            HStack(spacing: 10) {
                doneButton
                sampleThumbnail
            }
        }
    }

    // Finish the session: a recorded clip goes through the Processing screen (frame
    // extraction + quality scoring → top 5); photo-only sessions go straight to results
    // with the best matches from the live-scored pool.
    private var doneButton: some View {
        Button {
            if cameraManager.isRecording {
                cameraManager.stopRecording()
            } else if let videoURL = cameraManager.lastVideoURL {
                onNavigate(.processing(videoURL: videoURL,
                                       referenceImage: currentReferenceImage))
            } else {
                onNavigate(.result(
                    videoURL: nil,
                    frames: cameraManager.topScoredMatches(5).map { capture in
                        AnalyzedFrame(image: capture.image,
                                      time: 0,
                                      poseScore: capture.score,
                                      quality: ImageQualityAnalyzer.analyze(image: capture.image))
                    },
                    referenceImage: currentReferenceImage
                ))
            }
        } label: {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26))
                .foregroundColor(.white)
                .background(Circle().fill(Color.black.opacity(0.35)).padding(-4))
        }
    }

    // Top-right: the actual sample/reference photo. Tapping it lets the user swap the
    // sample (previously this was wired to open the captured-photos grid — wrong action).
    private var sampleThumbnail: some View {
        Button {
            showChangeSample = true
        } label: {
            ZStack(alignment: .top) {
                if let currentReferenceImage {
                    Image(uiImage: currentReferenceImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 84)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 64, height: 84)
                        .overlay(
                            Image(systemName: "photo.badge.plus")
                                .foregroundColor(.white.opacity(0.8))
                        )
                }

                Text("MẪU")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(.top, 4)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
            )
        }
    }

    private var modeSwitcher: some View {
        StyledSegmentedControl(items: ["Video", "Photo"], selectedIndex: $mode)
            .frame(width: 180, height: 44)
    }

    private var bottomControls: some View {
        HStack {
            Button {
                showPreviewGrid = true
            } label: {
                Group {
                    if let lastCapturedImage = cameraManager.lastCapturedImage {
                        Image(uiImage: lastCapturedImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo.on.rectangle")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(10)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1.5))
                .overlay(alignment: .topTrailing) {
                    if !cameraManager.capturedItems.isEmpty {
                        Text("\(cameraManager.capturedItems.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Circle().fill(Color.blue))
                            .offset(x: 4, y: -4)
                    }
                }
            }

            Spacer()

            Button {
                if mode == 0 {
                    if cameraManager.isRecording {
                        cameraManager.stopRecording()
                    } else {
                        cameraManager.startRecording()
                    }
                } else {
                    cameraManager.capturePhoto { image in
                        guard let image else { return }
                        LocalCacheManager.shared.saveImage(image)
                        DispatchQueue.main.async {
                            cameraManager.lastCapturedImage = image
                            cameraManager.capturedItems.append(image)
                        }
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(mode == 0 ? Color.red : Color.white)
                        .frame(width: 72, height: 72)
                    if mode == 0 && cameraManager.isRecording {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white)
                            .frame(width: 28, height: 28)
                    }
                    Circle()
                        .stroke(Color.white.opacity(0.6), lineWidth: 4)
                        .frame(width: 84, height: 84)
                }
            }

            Spacer()

            VStack(spacing: 10) {
                Button {
                    cameraManager.isPortraitMode.toggle()
                } label: {
                    Image(systemName: cameraManager.isPortraitMode ? "person.crop.square" : "person.crop.rectangle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color.white.opacity(cameraManager.isPortraitMode ? 0.3 : 0.15)))
                }
                .accessibilityLabel("Chế độ chân dung")

                Button {
                    showPoseGuide.toggle()
                } label: {
                    Image(systemName: showPoseGuide ? "person.fill.viewfinder" : "person.crop.artframe")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color.white.opacity(showPoseGuide ? 0.3 : 0.15)))
                }
                .accessibilityLabel("Bật/tắt khung mẫu")

                Button {
                    cameraManager.flipCamera()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }

                Button {
                    showBodyPoints.toggle()
                } label: {
                    Image(systemName: showBodyPoints ? "figure.walk.circle.fill" : "figure.walk.circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color.white.opacity(showBodyPoints ? 0.3 : 0.15)))
                }
            }
        }
    }
}

// MARK: - Portrait grid

/// Khung vuông chế độ chân dung: làm tối phần NGOÀI khung, viền góc trắng,
/// nhãn "CHÂN DUNG". `square` là toạ độ chuẩn hoá trên toàn màn hình — cùng hệ
/// với `CameraManager.portraitCropNormalized` nên ảnh cắt ra khớp khung user thấy.
struct PortraitFrameOverlayView: View {
    let square: CGRect

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(x: square.minX * geo.size.width,
                              y: square.minY * geo.size.height,
                              width: square.width * geo.size.width,
                              height: square.height * geo.size.height)

            ZStack {
                // Làm tối ngoài khung: 4 dải phủ quanh hình vuông
                Path { path in
                    path.addRect(CGRect(x: 0, y: 0, width: geo.size.width, height: rect.minY))
                    path.addRect(CGRect(x: 0, y: rect.maxY,
                                        width: geo.size.width,
                                        height: geo.size.height - rect.maxY))
                    path.addRect(CGRect(x: 0, y: rect.minY, width: rect.minX, height: rect.height))
                    path.addRect(CGRect(x: rect.maxX, y: rect.minY,
                                        width: geo.size.width - rect.maxX,
                                        height: rect.height))
                }
                .fill(Color.black.opacity(0.55))

                // Góc bracket
                CornerBracketsShape()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                Text("CHÂN DUNG")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .position(x: rect.midX, y: rect.minY + 14)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CornerBracketsShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let len: CGFloat = min(rect.width, rect.height) * 0.12
        // Trên-trái
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + len))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))
        // Trên-phải
        p.move(to: CGPoint(x: rect.maxX - len, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))
        // Dưới-phải
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - len))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - len, y: rect.maxY))
        // Dưới-trái
        p.move(to: CGPoint(x: rect.minX + len, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - len))
        return p
    }
}

// MARK: - Preview grid

struct PreviewGridView: View {
    let capturedItems: [UIImage]

    var body: some View {
        NavigationView {
            ScrollView {
                if capturedItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("Chưa có ảnh/video nào được lưu")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                        ForEach(Array(capturedItems.enumerated()), id: \.offset) { _, image in
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 140)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Ảnh đã chụp")
        }
    }
}

#Preview {
    CameraScreen(onNavigate: { _ in }, onFinish: {})
}
