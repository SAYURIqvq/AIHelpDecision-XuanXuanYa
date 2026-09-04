import AVFoundation
import Foundation
import LiveKit

enum DuckCallMode: String, Equatable {
    case voice
    case video

    var title: String {
        switch self {
        case .voice: return "和鸭鸭打电话商量"
        case .video: return "和鸭鸭打视频商量"
        }
    }

    var shortLabel: String {
        switch self {
        case .voice: return "语音通话"
        case .video: return "视频通话"
        }
    }

    var grainsPerMinute: Int {
        switch self {
        case .voice: return GrainCosts.voiceCallPerMinute
        case .video: return GrainCosts.videoCallPerMinute
        }
    }
}

@MainActor
final class LiveKitCallViewModel: ObservableObject {
    enum CallState: Equatable {
        case idle
        case connecting
        case connected
        case permissionDenied
        case failed(String)
    }

    @Published var state: CallState = .idle
    @Published var mode: DuckCallMode = .video
    @Published var isMuted = false
    @Published var cameraEnabled = true
    @Published var usingFrontCamera = true
    @Published var room = Room()
    @Published var localVideoTrack: VideoTrack?
    @Published var remoteVideoTrack: VideoTrack?
    /// 无 LiveKit 凭证时用系统摄像头预览，避免 LiveKit 本地轨在部分机型闪退。
    @Published var useLocalPreview = false
    @Published var elapsedSeconds: Int = 0

    let localCamera = LocalCameraPreviewController()

    private let config = AppConfig.current
    private var standaloneCameraTrack: LocalVideoTrack?
    private var callStartedAt: Date?
    private var elapsedTimer: Timer?

    var billableSeconds: TimeInterval {
        guard let callStartedAt else { return 0 }
        return max(0, Date().timeIntervalSince(callStartedAt))
    }

    var formattedElapsed: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    func startCall(mode: DuckCallMode) async {
        self.mode = mode

        let audioMode: AVAudioSession.Mode = mode == .voice ? .voiceChat : .videoChat
        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord,
            mode: audioMode,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try? AVAudioSession.sharedInstance().setActive(true)

        let microphone = await Self.authorized(for: .audio)
        let cameraOK: Bool
        if mode == .video {
            cameraOK = await Self.authorized(for: .video)
        } else {
            cameraOK = true
        }
        guard microphone && cameraOK else {
            state = .permissionDenied
            return
        }

        state = .connecting
        isMuted = false
        cameraEnabled = mode == .video
        // 视频首次默认后置，方便对准实物选项
        usingFrontCamera = mode != .video
        callStartedAt = Date()
        elapsedSeconds = 0
        remoteVideoTrack = nil
        localVideoTrack = nil
        startElapsedTimer()

        do {
            if mode == .voice {
                useLocalPreview = false
                if config.hasLiveKitCredentials {
                    try await startLiveKitVoiceCall()
                }
                // 无凭证时也进入「已连接」演示态：本地语音通话 UI
                state = .connected
                return
            }

            if config.hasLiveKitCredentials {
                useLocalPreview = false
                try await startLiveKitCall(position: .back)
            } else {
                useLocalPreview = true
                let ok = await localCamera.start(position: .back)
                guard ok else {
                    stopElapsedTimer()
                    callStartedAt = nil
                    state = localCamera.errorMessage.map { .failed($0) } ?? .permissionDenied
                    return
                }
                usingFrontCamera = localCamera.usingFrontCamera
            }
            state = .connected
        } catch {
            stopElapsedTimer()
            callStartedAt = nil
            await cleanupLocalPreview()
            localCamera.stop()
            useLocalPreview = false
            state = .failed(error.localizedDescription)
        }
    }

    /// 通话页出现时预热后置摄像头，缩短首次视频通话等待。
    func prepareIfNeeded() async {
        guard !config.hasLiveKitCredentials else { return }
        guard !localCamera.isPrepared else { return }
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        guard camera == .authorized, mic == .authorized else { return }
        await localCamera.prepare(position: .back)
    }

    private static func authorized(for media: AVMediaType) async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: media)
        if status == .authorized { return true }
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: media)
        }
        return false
    }

    func endCall() async {
        // 先切回大厅，避免 stopRunning / disconnect 阻塞时卡在黑屏
        leaveCallUI()
        await teardownMedia()
    }

    /// 立即退出通话 UI（不阻塞摄像头释放）
    func leaveCallUI() {
        stopElapsedTimer()
        let started = callStartedAt
        callStartedAt = nil
        elapsedSeconds = 0
        useLocalPreview = false
        localVideoTrack = nil
        remoteVideoTrack = nil
        isMuted = false
        cameraEnabled = true
        usingFrontCamera = true
        state = .idle
        // 保留 started 仅供调用方已读 billableSeconds；这里已清零计时
        _ = started
    }

    /// 后台释放摄像头 / LiveKit（此时 UI 已离开通话页）
    func teardownMedia() async {
        if config.hasLiveKitCredentials {
            await room.disconnect()
        }
        await cleanupLocalPreview()
        await localCamera.stopAsync()
    }

    func setMuted(_ muted: Bool) async {
        isMuted = muted
        if config.hasLiveKitCredentials, room.connectionState == .connected {
            try? await room.localParticipant.setMicrophone(enabled: !muted)
        }
    }

    func setCameraEnabled(_ enabled: Bool) async {
        guard mode == .video else { return }
        cameraEnabled = enabled
        if useLocalPreview {
            if enabled {
                _ = await localCamera.start(position: usingFrontCamera ? .front : .back)
            } else {
                localCamera.stop()
            }
            return
        }
        if let standaloneCameraTrack {
            if enabled {
                try? await standaloneCameraTrack.start()
                localVideoTrack = standaloneCameraTrack
            } else {
                try? await standaloneCameraTrack.stop()
                localVideoTrack = nil
            }
        }
        if config.hasLiveKitCredentials, room.connectionState == .connected {
            try? await room.localParticipant.setCamera(enabled: enabled)
            refreshTracks()
        }
    }

    func switchCamera() async {
        guard mode == .video, cameraEnabled else { return }
        if useLocalPreview {
            await localCamera.switchCamera()
            usingFrontCamera = localCamera.usingFrontCamera
            return
        }
        if let capturer = standaloneCameraTrack?.capturer as? CameraCapturer {
            do {
                _ = try await capturer.switchCameraPosition()
                usingFrontCamera = capturer.position != .back
                localVideoTrack = standaloneCameraTrack
                return
            } catch {
                // Fall through to recreate track.
            }
        }

        let next: AVCaptureDevice.Position = usingFrontCamera ? .back : .front
        await cleanupLocalPreview()
        do {
            let cameraTrack = LocalVideoTrack.createCameraTrack(
                options: CameraCaptureOptions(position: next, dimensions: .h1080_169, fps: 30)
            )
            try await cameraTrack.start()
            standaloneCameraTrack = cameraTrack
            localVideoTrack = cameraTrack
            usingFrontCamera = next == .front
            cameraEnabled = true
        } catch {
            state = .failed("切换摄像头失败：\(error.localizedDescription)")
        }
    }

    func refreshTracks() {
        if let roomLocal = room.localParticipant.firstCameraVideoTrack {
            localVideoTrack = roomLocal
        } else if cameraEnabled {
            localVideoTrack = standaloneCameraTrack
        }
        remoteVideoTrack = room.remoteParticipants.values.compactMap(\.firstCameraVideoTrack).first
    }

    private func startLiveKitCall(position: AVCaptureDevice.Position = .back) async throws {
        let cameraTrack = LocalVideoTrack.createCameraTrack(
            options: CameraCaptureOptions(position: position, dimensions: .h1080_169, fps: 30)
        )
        try await cameraTrack.start()
        standaloneCameraTrack = cameraTrack
        localVideoTrack = cameraTrack
        usingFrontCamera = position == .front

        try await room.connect(url: config.liveKitURL, token: config.liveKitToken)
        try await room.localParticipant.setCamera(enabled: true)
        try await room.localParticipant.setMicrophone(enabled: true)
        refreshTracks()
    }

    private func startLiveKitVoiceCall() async throws {
        try await room.connect(url: config.liveKitURL, token: config.liveKitToken)
        try await room.localParticipant.setMicrophone(enabled: true)
        try await room.localParticipant.setCamera(enabled: false)
        refreshTracks()
    }

    private func cleanupLocalPreview() async {
        if let standaloneCameraTrack {
            try? await standaloneCameraTrack.stop()
        }
        standaloneCameraTrack = nil
        localVideoTrack = nil
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.callStartedAt else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(started))
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}
