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
    /// 无 LiveKit 凭证 / 使用 Omni 时用系统摄像头预览。
    @Published var useLocalPreview = false
    @Published var elapsedSeconds: Int = 0
    @Published var assistantTranscript: String = ""
    @Published var userTranscript: String = ""
    @Published var isDuckSpeaking = false
    @Published var isUserSpeaking = false
    @Published var usesOmniRealtime = false
    /// 打断后的短提示（UI 展示用）
    @Published var turnHint: String = ""

    let localCamera = LocalCameraPreviewController()
    let pcmEngine = RealtimePCMEngine()

    private let config = AppConfig.current
    private let omniClient = QwenOmniRealtimeClient()
    private var frameSampler: CallFrameSampler?
    private var standaloneCameraTrack: LocalVideoTrack?
    private var callStartedAt: Date?
    private var elapsedTimer: Timer?
    /// 鸭鸭说话时，本地能量门控：连续明显人声才自动打断
    private var clearSpeechAccumulatedMs: Double = 0
    private var lastInterruptAt: Date = .distantPast
    /// 打断后丢弃旧回复残余音频，直到下一轮 response.created
    private var ignorePlaybackUntilNextResponse = false
    /// 本轮回复开始播放后的宽限期，避免一开口就被回采能量误打断
    private var duckSpeakStartedAt: Date?
    private var turnHintClearTask: Task<Void, Never>?
    /// 本地检测到用户说过话后的安静计时，用于兜底触发回复
    private var lastUserVoiceAt: Date?
    private var lastForcedResponseAt: Date = .distantPast
    private var awaitingUserReply = false

    var billableSeconds: TimeInterval {
        guard let callStartedAt else { return 0 }
        return max(0, Date().timeIntervalSince(callStartedAt))
    }

    var formattedElapsed: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// Omni 通话中常驻「轮次」按钮（打断 / 听你说），避免点完就消失
    var showsTurnControl: Bool {
        usesOmniRealtime && state == .connected
    }

    /// 当前是否可打断鸭鸭
    var canInterruptNow: Bool {
        isDuckSpeaking || pcmEngine.isDuckSpeaking || omniClient.hasActiveResponse
    }

    var turnControlLabel: String {
        if canInterruptNow { return "打断" }
        if isUserSpeaking { return "在听你" }
        return "听你说"
    }

    var turnControlSymbol: String {
        if canInterruptNow { return "hand.raised.fill" }
        if isUserSpeaking { return "waveform" }
        return "ear.fill"
    }

    init() {
        bindOmniCallbacks()
        pcmEngine.onCapturedPCM = { [weak self] pcm in
            self?.handleCapturedPCM(pcm)
        }
    }

    func startCall(mode: DuckCallMode) async {
        // 防止连点导致上一路 WebSocket 被清掉
        if state == .connecting || state == .connected {
            return
        }
        self.mode = mode
        assistantTranscript = ""
        userTranscript = ""
        isDuckSpeaking = false
        isUserSpeaking = false
        usesOmniRealtime = false
        clearSpeechAccumulatedMs = 0
        lastInterruptAt = .distantPast
        ignorePlaybackUntilNextResponse = false
        duckSpeakStartedAt = nil
        turnHint = ""
        turnHintClearTask?.cancel()
        turnHintClearTask = nil
        lastUserVoiceAt = nil
        awaitingUserReply = false
        lastForcedResponseAt = .distantPast

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
        usingFrontCamera = mode != .video
        callStartedAt = Date()
        elapsedSeconds = 0
        remoteVideoTrack = nil
        localVideoTrack = nil
        startElapsedTimer()

        do {
            // 优先走百炼 Qwen Omni Realtime（真正和鸭鸭说话）
            if config.hasDashScopeRealtime {
                try await startOmniCall(mode: mode)
                state = .connected
                return
            }

            if mode == .voice {
                useLocalPreview = false
                if config.hasLiveKitCredentials {
                    try await startLiveKitVoiceCall()
                }
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
            await cleanupOmni()
            await cleanupLocalPreview()
            localCamera.stop()
            useLocalPreview = false
            state = .failed(error.localizedDescription)
        }
    }

    /// 通话页出现时预热后置摄像头，缩短首次视频通话等待。
    func prepareIfNeeded() async {
        guard !config.hasLiveKitCredentials || config.hasDashScopeRealtime else { return }
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
        isDuckSpeaking = false
        isUserSpeaking = false
        assistantTranscript = ""
        userTranscript = ""
        turnHint = ""
        turnHintClearTask?.cancel()
        turnHintClearTask = nil
        state = .idle
        _ = started
    }

    /// 后台释放摄像头 / LiveKit / Omni
    func teardownMedia() async {
        await cleanupOmni()
        if config.hasLiveKitCredentials {
            await room.disconnect()
        }
        await cleanupLocalPreview()
        await localCamera.stopAsync()
    }

    func setMuted(_ muted: Bool) async {
        isMuted = muted
        pcmEngine.setMuted(muted)
        if muted {
            // 静音：清 UI 状态；只灌静音帮 VAD 收束，不要强制 response.create
            // （会和 server_vad 自动 create 撞车 → already has an active response → 误挂断）
            isUserSpeaking = false
            awaitingUserReply = false
            lastUserVoiceAt = nil
            if !omniClient.hasActiveResponse, !isDuckSpeaking, !pcmEngine.isDuckSpeaking {
                omniClient.flushTurnWithSilence()
            }
            flashTurnHint("已静音")
        }
        if config.hasLiveKitCredentials, room.connectionState == .connected {
            try? await room.localParticipant.setMicrophone(enabled: !muted)
        }
    }

    /// 用户点击「打断」：立刻停本地播报，恢复听筒；按钮切到「听你说」
    func interruptDuckSpeaking() {
        guard usesOmniRealtime, state == .connected else { return }
        guard canInterruptNow else {
            // 已在听你：再点一次只是强调听筒，不报错
            omniClient.resumeListening()
            flashTurnHint("鸭鸭在听，直接说就行")
            return
        }
        guard Date().timeIntervalSince(lastInterruptAt) > 0.35 else { return }
        lastInterruptAt = Date()
        clearSpeechAccumulatedMs = 0
        duckSpeakStartedAt = nil
        ignorePlaybackUntilNextResponse = true
        pcmEngine.clearPlayback()
        isDuckSpeaking = false
        isUserSpeaking = true
        _ = omniClient.cancelResponse()
        omniClient.resumeListening()
        flashTurnHint("已打断 · 现在轮到你说")
    }

    private func flashTurnHint(_ text: String) {
        turnHint = text
        turnHintClearTask?.cancel()
        turnHintClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            if self.turnHint == text {
                self.turnHint = ""
            }
        }
    }

    // MARK: - Local clear-speech barge-in

    private func handleCapturedPCM(_ pcm: Data) {
        guard usesOmniRealtime else { return }

        let duckTalking = isDuckSpeaking || pcmEngine.isDuckSpeaking || omniClient.hasActiveResponse
        if duckTalking {
            // 必须仍走 append：半双工里会发静音保活；之前直接 return 导致保活从未执行、会话被掐
            omniClient.appendAudioPCM(pcm)

            // 开播后 0.9s 内不打断，否则扬声器回采会把招呼直接掐掉
            let warmedUp: Bool = {
                guard let started = duckSpeakStartedAt else { return false }
                return Date().timeIntervalSince(started) >= 0.9
            }()
            if warmedUp {
                let frameMs = Double(pcm.count / 2) / 16.0
                let rms = Self.pcm16RMS(pcm)
                if rms >= 0.060 {
                    clearSpeechAccumulatedMs += frameMs
                } else if rms >= 0.040 {
                    clearSpeechAccumulatedMs += frameMs * 0.35
                } else {
                    clearSpeechAccumulatedMs = max(0, clearSpeechAccumulatedMs - frameMs)
                }
                if clearSpeechAccumulatedMs >= 400 {
                    interruptDuckSpeaking()
                }
            }
            return
        }

        clearSpeechAccumulatedMs = 0
        omniClient.appendAudioPCM(pcm)

        // 听筒阶段：本地侦测「说过话 → 安静约 1s」仍无回复时，兜底 request response
        let rms = Self.pcm16RMS(pcm)
        if !isMuted, rms >= 0.028 {
            lastUserVoiceAt = Date()
            awaitingUserReply = true
            isUserSpeaking = true
        } else if awaitingUserReply, let last = lastUserVoiceAt {
            let quietMs = Date().timeIntervalSince(last) * 1000
            // 安静更久再兜底，给 server_vad 足够时间自己 create，减少撞车
            if quietMs >= 1_800, !omniClient.hasActiveResponse, !pcmEngine.isDuckSpeaking {
                isUserSpeaking = false
                awaitingUserReply = false
                lastUserVoiceAt = nil
                omniClient.flushTurnWithSilence()
                scheduleForcedResponseIfNeeded(afterMs: 1_500)
            }
        }
    }

    private func scheduleForcedResponseIfNeeded(afterMs: Int) {
        let delay = UInt64(max(0, afterMs)) * 1_000_000
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard self.usesOmniRealtime, self.state == .connected else { return }
            guard !self.omniClient.hasActiveResponse else { return }
            guard !self.isDuckSpeaking, !self.pcmEngine.isDuckSpeaking else { return }
            guard Date().timeIntervalSince(self.lastForcedResponseAt) > 3.0 else { return }
            self.lastForcedResponseAt = Date()
            self.isUserSpeaking = false
            _ = self.omniClient.requestResponseIfNeeded()
        }
    }

    private static func pcm16RMS(_ data: Data) -> Float {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return 0 }
        var sum: Float = 0
        data.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<count {
                let v = Float(src[i]) / Float(Int16.max)
                sum += v * v
            }
        }
        return sqrt(sum / Float(count))
    }

    func setCameraEnabled(_ enabled: Bool) async {
        guard mode == .video else { return }
        // 先改 UI，立刻卸掉预览层，再动 AVCaptureSession
        cameraEnabled = enabled
        if useLocalPreview {
            if enabled {
                _ = await localCamera.start(position: usingFrontCamera ? .front : .back)
                if usesOmniRealtime {
                    startFrameSamplingIfNeeded()
                }
            } else {
                await stopFrameSamplingAsync()
                await localCamera.stopAsync()
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

    private func stopFrameSamplingAsync() async {
        let sampler = frameSampler
        frameSampler = nil
        await sampler?.stopAsync()
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

    // MARK: - Omni Realtime

    private func bindOmniCallbacks() {
        omniClient.onAssistantTranscript = { [weak self] text, isFinal in
            guard let self else { return }
            if isFinal {
                self.assistantTranscript = text
            } else {
                self.assistantTranscript += text
            }
        }
        omniClient.onUserTranscript = { [weak self] text, isFinal in
            guard let self else { return }
            // 流式预览已是完整 text+stash，直接覆盖；final 也覆盖
            self.userTranscript = text
            _ = isFinal
        }
        omniClient.onAudioDelta = { [weak self] pcm in
            guard let self else { return }
            // 仅丢弃「打断后」的旧包；不要用 isUserSpeaking 挡播放（容易粘住导致全程无声）
            if self.ignorePlaybackUntilNextResponse { return }
            if self.duckSpeakStartedAt == nil {
                self.duckSpeakStartedAt = Date()
            }
            self.isDuckSpeaking = true
            self.omniClient.suppressMicrophoneUplink = true
            self.pcmEngine.enqueuePlaybackPCM16(pcm)
        }
        omniClient.onSpeechStarted = { [weak self] in
            guard let self else { return }
            // 上行已压制时，服务端不应再因回采报 speech_started；若仍收到则忽略
            if self.omniClient.suppressMicrophoneUplink {
                return
            }
            self.isUserSpeaking = true
            self.clearSpeechAccumulatedMs = 0
            if self.pcmEngine.isDuckSpeaking || self.isDuckSpeaking || self.omniClient.hasActiveResponse {
                self.ignorePlaybackUntilNextResponse = true
                self.pcmEngine.clearPlayback()
                self.isDuckSpeaking = false
                self.duckSpeakStartedAt = nil
                _ = self.omniClient.cancelResponse()
                self.omniClient.resumeListening()
            }
        }
        omniClient.onSpeechStopped = { [weak self] in
            guard let self else { return }
            self.isUserSpeaking = false
            // server_vad 已 create_response=true，这里不再强制 response.create，避免撞车报错
        }
        omniClient.onResponseStarted = { [weak self] in
            guard let self else { return }
            self.assistantTranscript = ""
            self.isDuckSpeaking = true
            self.isUserSpeaking = false
            self.awaitingUserReply = false
            self.lastUserVoiceAt = nil
            self.ignorePlaybackUntilNextResponse = false
            self.clearSpeechAccumulatedMs = 0
            self.duckSpeakStartedAt = Date()
            self.omniClient.suppressMicrophoneUplink = true
            self.turnHint = ""
        }
        omniClient.onResponseFinished = { [weak self] in
            guard let self else { return }
            self.pcmEngine.onPlaybackQueueEmpty = { [weak self] in
                guard let self else { return }
                self.isDuckSpeaking = false
                self.duckSpeakStartedAt = nil
                self.clearSpeechAccumulatedMs = 0
                self.omniClient.resumeListening()
            }
            if !self.pcmEngine.isDuckSpeaking {
                self.isDuckSpeaking = false
                self.duckSpeakStartedAt = nil
                self.clearSpeechAccumulatedMs = 0
                self.omniClient.resumeListening()
            }
        }
        omniClient.onError = { [weak self] message in
            guard let self else { return }
            if Self.isNonFatalCallError(message) { return }
            if self.state == .connecting || self.state == .connected {
                self.state = .failed(message)
            }
        }
    }

    private static func isNonFatalCallError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("append image before append audio")
            || lower.contains("image before")
            || lower.contains("none active response")
            || lower.contains("no active response")
            || lower.contains("without an active response")
            || lower.contains("already has an active response")
            || lower.contains("active response in progress")
            || (lower.contains("active response") && lower.contains("already"))
    }

    private func startOmniCall(mode: DuckCallMode) async throws {
        usesOmniRealtime = true
        useLocalPreview = mode == .video

        if mode == .video {
            let ok = await localCamera.start(position: .back)
            guard ok else {
                throw NSError(
                    domain: "OmniCall",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: localCamera.errorMessage ?? "摄像头启动失败"]
                )
            }
            usingFrontCamera = localCamera.usingFrontCamera
        }

        try pcmEngine.start()
        pcmEngine.setMuted(false)
        try await omniClient.connect()

        // 等 primer audio / 握手完成后再抽帧，避免 image-before-audio
        if mode == .video {
            try? await Task.sleep(nanoseconds: 400_000_000)
            startFrameSamplingIfNeeded()
        }
    }

    private func startFrameSamplingIfNeeded() {
        frameSampler?.stop()
        frameSampler = nil
        let sampler = CallFrameSampler(session: localCamera.session, sessionQueue: localCamera.sessionQueue)
        sampler.onJPEG = { [weak self] jpeg in
            Task { @MainActor in
                guard let self, self.cameraEnabled, self.usesOmniRealtime else { return }
                self.omniClient.appendJPEGImage(jpeg)
            }
        }
        frameSampler = sampler
        sampler.start()
    }

    private func cleanupOmni() async {
        await stopFrameSamplingAsync()
        omniClient.disconnect()
        pcmEngine.stop()
        usesOmniRealtime = false
    }

    // MARK: - LiveKit

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
                self.isDuckSpeaking = self.pcmEngine.isDuckSpeaking
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}
