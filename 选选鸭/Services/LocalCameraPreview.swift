import AVFoundation
import SwiftUI

/// 本地摄像头预览（不依赖 LiveKit），用于没有房间凭证时的通话页。
final class LocalCameraPreviewController: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var usingFrontCamera = true
    @Published var errorMessage: String?
    @Published var isPrepared = false

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.xuanxuanya.local-camera")
    private var currentInput: AVCaptureDeviceInput?
    private var preferredPosition: AVCaptureDevice.Position = .front

    /// 进入通话页时预热：配好输入，但不 startRunning，避免首次点「发起通话」卡很久。
    func prepare(position: AVCaptureDevice.Position = .front) async {
        preferredPosition = position
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                do {
                    try Self.activateVideoAudioSession()
                    self.session.beginConfiguration()
                    Self.applyBestPreset(to: self.session)
                    self.session.inputs.forEach { self.session.removeInput($0) }
                    guard let device = Self.camera(at: position) else {
                        throw NSError(domain: "LocalCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到摄像头"])
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.currentInput = input
                    }
                    Self.configureDeviceForSharpPreview(device)
                    self.session.commitConfiguration()
                    DispatchQueue.main.async {
                        self.usingFrontCamera = position == .front
                        self.isPrepared = true
                        self.errorMessage = nil
                        continuation.resume()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isPrepared = false
                        self.errorMessage = error.localizedDescription
                        continuation.resume()
                    }
                }
            }
        }
    }

    func start(position: AVCaptureDevice.Position = .front) async -> Bool {
        let cameraOK = await Self.ensureVideoAccess()
        let micOK = await Self.ensureAudioAccess()
        guard cameraOK && micOK else {
            await MainActor.run {
                errorMessage = "需要相机和麦克风权限才能和鸭鸭视频通话鸭～"
            }
            return false
        }

        if !isPrepared || preferredPosition != position || currentInput == nil {
            await prepare(position: position)
        }

        return await withCheckedContinuation { continuation in
            sessionQueue.async {
                do {
                    try Self.activateVideoAudioSession()
                    // 确保已预热的会话也升到高清（避免一直停在 medium）
                    self.session.beginConfiguration()
                    Self.applyBestPreset(to: self.session)
                    if let device = self.currentInput?.device {
                        Self.configureDeviceForSharpPreview(device)
                    }
                    self.session.commitConfiguration()
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    DispatchQueue.main.async {
                        self.usingFrontCamera = position == .front
                        self.isRunning = true
                        self.errorMessage = nil
                        continuation.resume(returning: true)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.errorMessage = error.localizedDescription
                        self.isRunning = false
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }

    /// 可等待的停止：挂断时在后台调用，避免卡主线程 / 通话 UI
    func stopAsync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                DispatchQueue.main.async {
                    self.isRunning = false
                    continuation.resume()
                }
            }
        }
    }

    /// 完全释放（离开通话页时可调用）；日常挂断只 stopRunning，保留 prepare 结果。
    func teardown() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.commitConfiguration()
            self.currentInput = nil
            DispatchQueue.main.async {
                self.isRunning = false
                self.isPrepared = false
            }
        }
    }

    func switchCamera() async {
        let next: AVCaptureDevice.Position = usingFrontCamera ? .back : .front
        isPrepared = false
        _ = await start(position: next)
    }

    private static func ensureVideoAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .authorized { return true }
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .video)
        }
        return false
    }

    private static func ensureAudioAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return true }
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
        return false
    }

    private static func activateVideoAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: [])
    }

    /// 尽量贴近系统相机清晰度：优先 1080p，其次 720p / high
    private static func applyBestPreset(to session: AVCaptureSession) {
        let candidates: [AVCaptureSession.Preset] = [
            .hd1920x1080,
            .hd1280x720,
            .high,
            .medium
        ]
        for preset in candidates where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            return
        }
    }

    private static func configureDeviceForSharpPreview(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            device.unlockForConfiguration()
        } catch {
            // 预览仍可用，忽略个别机型配置失败
        }
    }

    private static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: position
        ).devices.first ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }
}

struct LocalCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var mirror: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.videoPreviewLayer.connection?.automaticallyAdjustsVideoMirroring = false
        view.videoPreviewLayer.connection?.isVideoMirrored = mirror
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
        uiView.videoPreviewLayer.connection?.automaticallyAdjustsVideoMirroring = false
        uiView.videoPreviewLayer.connection?.isVideoMirrored = mirror
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
