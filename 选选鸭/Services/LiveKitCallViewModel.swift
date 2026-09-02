import AVFoundation
import Foundation
import LiveKit

@MainActor
final class LiveKitCallViewModel: ObservableObject {
    enum CallState: Equatable {
        case idle
        case connecting
        case connected
        case missingConfig
        case permissionDenied
        case failed(String)
    }

    @Published var state: CallState = .idle
    @Published var isMuted = false
    @Published var cameraEnabled = true
    @Published var room = Room()
    @Published var localVideoTrack: VideoTrack?
    @Published var remoteVideoTrack: VideoTrack?

    private let config = AppConfig.current

    var statusText: String {
        switch state {
        case .idle:
            return "直接发起 1v1 视频通话，房间由鸭鸭自动处理。"
        case .connecting:
            return "正在接入 LiveKit 演示通话..."
        case .connected:
            return "已进入 LiveKit 通话。好友加入同一演示房间后会显示远端画面。"
        case .missingConfig:
            return "缺少 LiveKit 配置，请在 Config.local.xcconfig 填入 WS URL 和 Participant Token。"
        case .permissionDenied:
            return "需要相机和麦克风权限才能视频通话。"
        case .failed(let message):
            return message
        }
    }

    func startCall() async {
        guard config.hasLiveKitCredentials else {
            state = .missingConfig
            return
        }

        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard camera && microphone else {
            state = .permissionDenied
            return
        }

        state = .connecting
        do {
            try await room.connect(url: config.liveKitURL, token: config.liveKitToken)
            try await room.localParticipant.setCamera(enabled: true)
            try await room.localParticipant.setMicrophone(enabled: true)
            refreshTracks()
            state = .connected
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func endCall() async {
        await room.disconnect()
        localVideoTrack = nil
        remoteVideoTrack = nil
        state = .idle
    }

    func setMuted(_ muted: Bool) async {
        isMuted = muted
        try? await room.localParticipant.setMicrophone(enabled: !muted)
    }

    func setCameraEnabled(_ enabled: Bool) async {
        cameraEnabled = enabled
        try? await room.localParticipant.setCamera(enabled: enabled)
        refreshTracks()
    }

    func refreshTracks() {
        localVideoTrack = room.localParticipant.firstCameraVideoTrack
        remoteVideoTrack = room.remoteParticipants.values.compactMap(\.firstCameraVideoTrack).first
    }
}
