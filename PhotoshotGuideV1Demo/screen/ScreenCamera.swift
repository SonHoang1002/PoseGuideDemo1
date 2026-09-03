import SwiftUI
import AVFoundation
import CoreMotion
import Vision
import PhotosUI
import UIKit
internal import Combine

// MARK: - Models

struct AppliedProperty: Identifiable, Equatable {
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
    @Published var countdown: Int?
    @Published var jointPoints: [VNHumanBodyPoseObservation.JointName: JointPoint]?
    @Published var detectedJointCount: Int = 0

    // Manually-tapped "keeper" shots (shown at bottom-left)
    @Published var lastCapturedImage: UIImage?
    @Published var capturedItems: [UIImage] = []

    // Continuously scored pool used to retrieve the best matches (temp, in-memory)
    @Published var scoredCaptures: [ScoredCapture] = []

    // Video mode
    @Published var isRecording = false
    @Published var lastVideoURL: URL?
    @Published var isExtractingFrames = false

    private var photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "camera.sessionQueue")
    private var videoInput: AVCaptureDeviceInput?
    private var activeDevice: AVCaptureDevice?
    private var currentPosition: AVCaptureDevice.Position = .back

    // Guidance state
    private var template: Template?
    private var referenceImage: UIImage?   // ảnh mẫu gốc — cần cho BestShotSelector khi quay video
    private var optics: CameraOptics?
    private let measurer = Measurer(config: .default)
    private let engine = GuidanceEngine()
    private let trigger = CaptureTrigger(config: .default)
    private let motion = CMMotionManager()
    private var frameCounter = 0

    // Burst-capture scoring pool
    private let ciContext = CIContext()
    private var lastMeasurement: Measurement?
    private var lastBurstCaptureTime: Double = 0
    private let burstInterval: Double = 0.6
    private let maxScoredCaptures = 60

    // Log tốc độ góc song song lúc quay video — đề xuất bổ sung #2 tài liệu
    // verify-v3: loại frame chụp lúc máy đang di chuyển, chính xác hơn đoán
    // nhoè từ ảnh. Xem BestShotSelector.swift / AngularSpeedSample.
    private var recordingMotionLog: [AngularSpeedSample] = []

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
        } else {
            session.addInput(currentInput)
        }
        session.commitConfiguration()
    }

    // MARK: - Photo capture

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: PhotoCaptureDelegate { [weak self] image in
            guard let self, let image else { completion(image); return }
            // A manual tap also gets scored so it competes fairly for the top-5 pool.
            if let m = self.lastMeasurement, let template = self.template {
                let score = PoseSimilarity.score(m, template)
                DispatchQueue.main.async { self.addScoredCapture(ScoredCapture(image: image, score: score)) }
            }
            completion(image)
        })
    }

    // MARK: - Video recording

    func startRecording() {
        guard !movieOutput.isRecording else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        recordingMotionLog.removeAll()
        movieOutput.startRecording(to: url, recordingDelegate: self)
        DispatchQueue.main.async { self.isRecording = true }
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }

    // MARK: - Guidance

    /// Call whenever the reference/sample image (or a newly picked one) has been analyzed.
    /// `referenceImage` is kept for BestShotSelector, which re-analyzes the raw sample
    /// photo itself when a video finishes recording (it needs a CGImage, not `Template`).
    func startGuidance(template: Template, referenceImage: UIImage) {
        self.template = template
        self.referenceImage = referenceImage
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
        scoredCaptures.sorted { $0.score > $1.score }.prefix(n).map(\.image)
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
            DispatchQueue.main.async {
                self.lastCapturedImage = image
                self.capturedItems.append(image)
            }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
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
        let runFace = frameCounter % 3 == 0

        if optics == nil, let device = activeDevice {
            let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
            let portraitSize = CGSize(width: CGFloat(min(w, h)), height: CGFloat(max(w, h)))
            optics = CameraOptics(device: device, imageSize: portraitSize)
        }
        guard let optics else { return }

        let orientation: CGImagePropertyOrientation = currentPosition == .front ? .leftMirrored : .right
        let now = CACurrentMediaTime()
        // Chưa có mẫu thì tạm dùng .full — chỉ ảnh hưởng các đại lượng suy ra từ
        // template (scaleValue/centerX/elevationDeg), không ảnh hưởng skeleton
        // overlay (jointPoints luôn được đo và publish bất kể có mẫu hay chưa).
        let framing = template?.framing ?? .full

        let m = measurer.measure(pixelBuffer: pixelBuffer,
                                 deviceMotion: motion.deviceMotion,
                                 optics: optics,
                                 orientation: orientation,
                                 timestamp: now,
                                 framing: framing,
                                 runFace: runFace)

        lastMeasurement = m

        // Ghi log tốc độ góc song song lúc quay (đề xuất bổ sung #2 tài liệu
        // verify-v3) — BestShotSelector dùng để loại frame chụp lúc máy rung,
        // chính xác hơn đoán nhoè từ ảnh.
        if isRecording {
            recordingMotionLog.append(AngularSpeedSample(time: now, degPerSec: m.angularSpeedDegPerSec))
        }

        // Always publish the skeleton — independent of whether guidance is running yet.
        DispatchQueue.main.async { [weak self] in
            self?.jointPoints = m.jointPoints
            self?.detectedJointCount = m.jointPoints.count
        }

        // Everything below needs a reference template; skip it gracefully if there isn't one yet.
        guard let template else { return }

        let result = engine.evaluate(m, template, optics)
        let shouldCapture = trigger.update(ready: result.readyToCapture, now: now)
        let countdownValue = trigger.countdownRemaining

        // Burst-capture + score into the temp match pool (throttled, off the main thread).
        if m.hasSubject, now - lastBurstCaptureTime > burstInterval,
           let uiImage = imageFromPixelBuffer(pixelBuffer, orientation: orientation) {
            lastBurstCaptureTime = now
            let score = PoseSimilarity.score(m, template)
            DispatchQueue.main.async { [weak self] in
                self?.addScoredCapture(ScoredCapture(image: uiImage, score: score))
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.guidanceResult = result
            self.countdown = countdownValue
            if shouldCapture { self.handleAutoCapture() }
        }
    }
}

// Handles a finished video recording: saves the clip to Photos, then hands it to
// BestShotSelector (Documents/BestShotSelector.swift, tích hợp §7 tài liệu verify-v3)
// to pick the 5 best-matching, best-quality, diverse frames and crop them to the
// template's composition.
extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.lastVideoURL = outputFileURL
        }
        let motionLog = recordingMotionLog
        // BestShotSelector phân tích lại chính ảnh mẫu gốc (nó cần CGImage, không
        // dùng `Template` của GuidanceEngine — hai bộ phân tích độc lập với nhau).
        guard error == nil, let referenceImage, let referenceCGImage = referenceImage.cgImage else { return }

        UISaveVideoAtPathToSavedPhotosAlbum(outputFileURL.path, nil, nil, nil)

        DispatchQueue.main.async { self.isExtractingFrames = true }
        Task {
            let selector = BestShotSelector(config: .default)
            let shots = (try? await selector.selectBestShots(
                videoURL: outputFileURL,
                templateImage: referenceCGImage,
                angularSpeedLog: motionLog
            )) ?? []
            await MainActor.run {
                for shot in shots {
                    self.addScoredCapture(ScoredCapture(image: UIImage(cgImage: shot.image), score: shot.score.total))
                }
                self.isExtractingFrames = false
                try? FileManager.default.removeItem(at: outputFileURL) // temp file cleaned up after extraction
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

    @State private var mode: Int = 1 // 0 = Video, 1 = Photo
    @State private var currentReferenceImage: UIImage?
    @State private var appliedProperties: [AppliedProperty] = []
    @State private var showPreviewGrid: Bool = false
    @State private var showResult: Bool = false
    @State private var showBodyPoints: Bool = true

    // Changing the sample photo from inside the camera screen
    @State private var showChangeSample = false
    @State private var samplePickerItem: PhotosPickerItem?

    @StateObject private var cameraManager = CameraManager()

    init(referenceImage: UIImage? = nil, referenceProperties: [AppliedProperty] = []) {
        self.initialReferenceImage = referenceImage
        self.referenceProperties = referenceProperties
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
            Task.detached(priority: .userInitiated) {
                guard let template = TemplateAnalyzer.analyze(image: newImage) else { return }
                await MainActor.run { cameraManager.startGuidance(template: template, referenceImage: newImage) }
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
        .navigationDestination(isPresented: $showResult) {
            ResultScreen(images: cameraManager.topMatches(5))
        }
    }

    private var cameraContent: some View {
        ZStack {
            CameraPreviewView(session: cameraManager.session)
                .ignoresSafeArea()

            if showBodyPoints {
                SkeletonOverlayView(jointPoints: cameraManager.jointPoints)
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
                Spacer()
                if cameraManager.isExtractingFrames {
                    extractingBanner.padding(.bottom, 8)
                }
                guidancePill.padding(.bottom, 12)
                modeSwitcher.padding(.bottom, 16)
                bottomControls.padding(.bottom, 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .sheet(isPresented: $showPreviewGrid) {
            PreviewGridView(capturedItems: cameraManager.capturedItems)
        }
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
        return HStack(spacing: 6) {
            Circle()
                .fill(count > 0 ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
            Text(count > 0 ? "\(count) điểm cơ thể" : "Chưa nhận diện được người")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(.white)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Capsule().fill(Color.black.opacity(0.5)))
    }

    private var extractingBanner: some View {
        HStack(spacing: 8) {
            ProgressView().tint(.white)
            Text("Đang trích xuất khung hình từ video…")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(.white)
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Capsule().fill(Color.black.opacity(0.55)))
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
            } else if let result = cameraManager.guidanceResult, let primary = result.primaryCue {
                VStack(spacing: 4) {
                    Text(primary)
                        .font(.system(size: 15, weight: .semibold))
                    if let secondary = result.secondaryCue {
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

    // Finish the session: pick the 5 frames (live burst + taps + video frames) that
    // matched the reference pose best, and hand them to ResultScreen.
    private var doneButton: some View {
        Button {
            if cameraManager.isRecording { cameraManager.stopRecording() }
            showResult = true
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
                        DispatchQueue.main.async {
                            cameraManager.lastCapturedImage = image
                            cameraManager.capturedItems.append(image)
                        }
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
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
    CameraScreen()
}