import Foundation

/// 阿里云百炼 Qwen Omni Realtime（WebSocket）客户端。
@MainActor
final class QwenOmniRealtimeClient: NSObject {
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    var onStateChange: ((ConnectionState) -> Void)?
    var onAssistantTranscript: ((String, Bool) -> Void)?
    var onUserTranscript: ((String, Bool) -> Void)?
    var onAudioDelta: ((Data) -> Void)?
    var onSpeechStarted: (() -> Void)?
    var onSpeechStopped: (() -> Void)?
    var onResponseStarted: (() -> Void)?
    var onResponseFinished: (() -> Void)?
    var onError: ((String) -> Void)?

    private let config: AppConfig
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveLoopRunning = false
    private var eventCounter = 0
    private var connectionGeneration = 0
    private var isSocketOpen = false
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var sessionCreatedContinuation: CheckedContinuation<Void, Error>?
    private var handshakeStatusCode: Int?
    private var lastCloseMessage: String?
    /// 百炼要求：必须先 append 过音频，才能 append 图片
    private(set) var hasAppendedAudio = false
    /// 服务端是否正在生成回复（用于安全 cancel，避免 none active response）
    private(set) var hasActiveResponse = false
    /// 鸭鸭播报期间暂停麦克风上行，避免回采/环境音把回复立刻打断导致无声
    var suppressMicrophoneUplink = false
    /// 主动挂断时忽略后续 close/cancel 回调，避免误报「连接已断开」
    private var isIntentionallyClosing = false
    private var lastKeepaliveAt: Date = .distantPast
    private var pingTimer: Timer?

    private(set) var state: ConnectionState = .idle {
        didSet { onStateChange?(state) }
    }

    init(config: AppConfig = .current) {
        self.config = config
        super.init()
    }

    func connect() async throws {
        guard config.hasDashScopeRealtime else {
            throw makeError(code: 1, message: "未配置 DASHSCOPE_API_KEY，无法接通鸭鸭实时通话")
        }

        // 单飞：避免连按两次把上一路 socket 清成 nil
        if state == .connecting {
            throw makeError(code: 4, message: "正在接通鸭鸭，请稍等…")
        }

        await hardResetSocket()
        state = .connecting
        isSocketOpen = false
        hasAppendedAudio = false
        hasActiveResponse = false
        suppressMicrophoneUplink = false
        isIntentionallyClosing = false
        lastKeepaliveAt = .distantPast
        handshakeStatusCode = nil
        lastCloseMessage = nil
        connectionGeneration += 1
        let generation = connectionGeneration

        var components = URLComponents(string: config.qwenOmniWSURL)
        var items = components?.queryItems ?? []
        items.removeAll { $0.name == "model" }
        items.append(URLQueryItem(name: "model", value: config.qwenOmniModel))
        components?.queryItems = items

        guard let url = components?.url else {
            state = .failed("Realtime 地址无效")
            throw makeError(code: 2, message: "Realtime WebSocket 地址无效")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // 百炼握手鉴权：必须带 Bearer
        request.setValue("Bearer \(config.dashScopeAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.dashScopeAPIKey, forHTTPHeaderField: "X-DashScope-API-Key")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.webSocket = task
        receiveLoopRunning = true
        task.resume()
        startReceiveLoop()

        do {
            try await waitForSocketOpen(generation: generation, timeoutSeconds: 12)
            try await sendSessionUpdate()
            try await waitForSessionCreated(generation: generation, timeoutSeconds: 8)
            // 先垫一小段静音音频，满足「先音频后图片」；视频抽帧才不会报错
            try await sendPrimerAudio()
            try await sendGreeting()
            guard generation == connectionGeneration, webSocket != nil else {
                throw makeError(code: 5, message: "接通被取消，请再点一次通话")
            }
            state = .connected
            // 打招呼期间先压住上行，等鸭鸭说完再听（否则环境音会立刻 interrupt 导致无声）
            suppressMicrophoneUplink = true
            startPingLoop()
        } catch {
            let message = prettier(error)
            await hardResetSocket()
            state = .failed(message)
            throw makeError(code: 6, message: message)
        }
    }

    func disconnect() {
        isIntentionallyClosing = true
        connectionGeneration += 1
        failOpenWaiters(makeError(code: 7, message: "连接已断开"))
        if state != .idle {
            state = .idle
        }
        Task { await hardResetSocket() }
    }

    func appendAudioPCM(_ pcm: Data) {
        guard !pcm.isEmpty, state == .connected, isSocketOpen else { return }
        if suppressMicrophoneUplink {
            // 半双工时也要偶尔送静音，否则服务端 idle 会把通话掐掉并报「连接已断开」
            sendKeepaliveSilenceIfNeeded()
            return
        }
        let b64 = pcm.base64EncodedString()
        sendJSON([
            "event_id": nextEventID(),
            "type": "input_audio_buffer.append",
            "audio": b64
        ])
        hasAppendedAudio = true
        lastKeepaliveAt = Date()
    }

    func appendJPEGImage(_ jpeg: Data) {
        guard !jpeg.isEmpty, state == .connected, isSocketOpen else { return }
        // 服务端硬规则：append image 前必须先 append 过 audio
        guard hasAppendedAudio else { return }
        let b64 = jpeg.base64EncodedString()
        sendJSON([
            "event_id": nextEventID(),
            "type": "input_image_buffer.append",
            "image": b64
        ])
    }

    /// 手动打断：仅在有活动回复时 cancel，避免报「none active response」
    @discardableResult
    func cancelResponse() -> Bool {
        guard state == .connected, isSocketOpen else { return false }
        guard hasActiveResponse else { return false }
        sendJSON([
            "event_id": nextEventID(),
            "type": "response.cancel"
        ])
        // 乐观更新；若服务端已结束，会回 none-active，我们当非致命忽略
        hasActiveResponse = false
        return true
    }

    /// 打断后立刻恢复听筒上行
    func resumeListening() {
        suppressMicrophoneUplink = false
    }

    /// 用户说完/静音后：立刻灌一段静音，帮服务端 VAD 收束本轮并触发回复
    func flushTurnWithSilence() {
        guard state == .connected, isSocketOpen, !isIntentionallyClosing else { return }
        suppressMicrophoneUplink = false
        // ~1.0s 静音 > silence_duration_ms(600)
        let silence = Data(count: 16_000 * 2)
        sendJSON([
            "event_id": nextEventID(),
            "type": "input_audio_buffer.append",
            "audio": silence.base64EncodedString()
        ])
        hasAppendedAudio = true
        lastKeepaliveAt = Date()
    }

    /// VAD 卡住时的兜底：主动要一轮回复（无活动回复时才发）
    @discardableResult
    func requestResponseIfNeeded() -> Bool {
        guard state == .connected, isSocketOpen, !isIntentionallyClosing else { return false }
        guard !hasActiveResponse else { return false }
        suppressMicrophoneUplink = false
        // 乐观占位，降低与随后到来的 response.created / 第二次 create 撞车
        hasActiveResponse = true
        sendJSON([
            "event_id": nextEventID(),
            "type": "response.create"
        ])
        return true
    }

    // MARK: - Private

    private func hardResetSocket() async {
        stopPingLoop()
        receiveLoopRunning = false
        isSocketOpen = false
        hasAppendedAudio = false
        hasActiveResponse = false
        suppressMicrophoneUplink = false
        let socket = webSocket
        let session = session
        webSocket = nil
        self.session = nil
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    private func startPingLoop() {
        stopPingLoop()
        // URLSession WebSocket 在弱网下需要应用层心跳，否则会被中间设备掐掉
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      !self.isIntentionallyClosing,
                      self.state == .connected,
                      let webSocket = self.webSocket else { return }
                webSocket.sendPing { _ in }
                // 仅半双工压制上行时才塞静音保活；听筒阶段乱塞会打乱 VAD「说完」判定
                if self.suppressMicrophoneUplink {
                    self.sendKeepaliveSilenceIfNeeded()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func stopPingLoop() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func waitForSocketOpen(generation: Int, timeoutSeconds: Double) async throws {
        if isSocketOpen { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    if self.isSocketOpen {
                        cont.resume()
                        return
                    }
                    self.openContinuation = cont
                }
            }
            group.addTask { @MainActor in
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw self.makeError(
                    code: 8,
                    message: self.handshakeTimeoutMessage()
                )
            }
            try await group.next()
            group.cancelAll()
        }
        guard generation == connectionGeneration else {
            throw makeError(code: 5, message: "接通被取消，请再点一次通话")
        }
    }

    private func waitForSessionCreated(generation: Int, timeoutSeconds: Double) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.sessionCreatedContinuation = cont
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        if let waiting = self.sessionCreatedContinuation {
                            self.sessionCreatedContinuation = nil
                            waiting.resume()
                        }
                    }
                }
            }
            group.addTask { @MainActor in
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw self.makeError(code: 9, message: "会话配置超时，请检查网络后重试")
            }
            try await group.next()
            group.cancelAll()
        }
        guard generation == connectionGeneration else {
            throw makeError(code: 5, message: "接通被取消，请再点一次通话")
        }
    }

    private func handshakeTimeoutMessage() -> String {
        if let code = handshakeStatusCode {
            if code == 400 {
                return "通话握手失败（HTTP 400）：音色或会话参数不被当前模型接受。qwen3.5 请用 Qiao/Serena/Tina，不要用 Cherry"
            }
            return "通话握手失败（HTTP \(code)），请检查百炼 API Key 是否有效"
        }
        if let lastCloseMessage, !lastCloseMessage.isEmpty {
            return "通话连接失败：\(lastCloseMessage)"
        }
        return "通话连接超时。请确认用的是国内百炼 Key，地址为 wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
    }

    private func sendSessionUpdate() async throws {
        // 参数对齐官方 session.update；多余字段在 3.5 上可能直接 400
        let sessionBody: [String: Any] = [
            "modalities": ["text", "audio"],
            "voice": config.qwenOmniVoice,
            "input_audio_format": "pcm",
            "output_audio_format": "pcm",
            "instructions": DuckSpeech.callPersona,
            "input_audio_transcription": [
                "model": "qwen3-asr-flash-realtime"
            ],
            "turn_detection": [
                "type": "server_vad",
                "threshold": 0.5,
                "silence_duration_ms": 600,
                "prefix_padding_ms": 300,
                "create_response": true,
                "interrupt_response": true,
                "idle_timeout_ms": 30_000
            ]
        ]
        try await sendJSONAsync([
            "event_id": nextEventID(),
            "type": "session.update",
            "session": sessionBody
        ])
    }

    /// 发送约 200ms 近静音 PCM，解锁后续视频帧上传。
    private func sendPrimerAudio() async throws {
        // 16kHz * 0.2s * 2 bytes = 6400
        let silence = Data(count: 6_400)
        let b64 = silence.base64EncodedString()
        try await sendJSONAsync([
            "event_id": nextEventID(),
            "type": "input_audio_buffer.append",
            "audio": b64
        ])
        hasAppendedAudio = true
    }

    private func sendGreeting() async throws {
        try await sendJSONAsync([
            "event_id": nextEventID(),
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": "鸭鸭你好，我打来找你实时商量纠结的事，先用一两句软萌地打个招呼，然后问我现在最纠结什么。"
                    ]
                ]
            ]
        ])
        try await sendJSONAsync([
            "event_id": nextEventID(),
            "type": "response.create"
        ])
    }

    /// 半双工保活：约每 3 秒送 100ms 近静音，避免长时间无上行
    private func sendKeepaliveSilenceIfNeeded() {
        guard state == .connected, isSocketOpen, !isIntentionallyClosing else { return }
        guard Date().timeIntervalSince(lastKeepaliveAt) >= 3 else { return }
        lastKeepaliveAt = Date()
        // 16kHz * 0.1s * 2 bytes = 3200
        let silence = Data(count: 3_200)
        sendJSON([
            "event_id": nextEventID(),
            "type": "input_audio_buffer.append",
            "audio": silence.base64EncodedString()
        ])
        hasAppendedAudio = true
    }

    private func nextEventID() -> String {
        eventCounter += 1
        return "evt_\(Int(Date().timeIntervalSince1970))_\(eventCounter)"
    }

    private func sendJSON(_ object: [String: Any]) {
        guard !isIntentionallyClosing,
              isSocketOpen,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8),
              let webSocket else { return }
        webSocket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, !self.isIntentionallyClosing else { return }
                // 单次发送失败不立刻挂断；真正断线由 receive / didClose 处理
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
                self.lastCloseMessage = error.localizedDescription
            }
        }
    }

    private func sendJSONAsync(_ object: [String: Any]) async throws {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            throw makeError(code: 10, message: "消息编码失败")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw makeError(code: 10, message: "消息编码失败")
        }
        guard isSocketOpen, let webSocket else {
            throw makeError(code: 3, message: "通话通道还没就绪，请重试")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webSocket.send(.string(text)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func startReceiveLoop() {
        guard let webSocket else { return }
        webSocket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.receiveLoopRunning else { return }
                switch result {
                case .failure(let error):
                    guard !self.isIntentionallyClosing else { return }
                    let message = self.prettier(error)
                    self.lastCloseMessage = message
                    self.failOpenWaiters(self.makeError(code: 11, message: message))
                    if self.state == .connecting || self.state == .connected {
                        self.state = .failed(message)
                        self.onError?(message)
                    }
                case .success(let message):
                    self.handle(message: message)
                    self.startReceiveLoop()
                }
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(data: data, encoding: .utf8)
        @unknown default:
            text = nil
        }
        guard let text,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "session.created", "session.updated":
            // 部分 iOS 版本不一定回调 didOpen，收到服务端事件也视为已连通
            if !isSocketOpen {
                isSocketOpen = true
                if let openContinuation {
                    self.openContinuation = nil
                    openContinuation.resume()
                }
            }
            if let waiting = sessionCreatedContinuation {
                sessionCreatedContinuation = nil
                waiting.resume()
            }

        case "error":
            let message = ((json["error"] as? [String: Any])?["message"] as? String)
                ?? (json["message"] as? String)
                ?? "Realtime 服务报错"
            if Self.isNonFatalRealtimeError(message) {
                return
            }
            lastCloseMessage = message
            failOpenWaiters(makeError(code: 12, message: message))
            // 参数错误等应展示原文，不要吞成「通道断开」
            state = .failed(message)
            onError?(message)

        case "input_audio_buffer.speech_started":
            onSpeechStarted?()

        case "input_audio_buffer.speech_stopped":
            onSpeechStopped?()

        case "response.created":
            hasActiveResponse = true
            onResponseStarted?()

        case "response.audio.delta":
            if let b64 = json["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                onAudioDelta?(pcm)
            }

        case "response.audio_transcript.delta":
            if let delta = json["delta"] as? String {
                onAssistantTranscript?(delta, false)
            }

        case "response.audio_transcript.done":
            if let transcript = json["transcript"] as? String {
                onAssistantTranscript?(transcript, true)
            }

        case "conversation.item.input_audio_transcription.delta":
            // 百炼流式预览：text=已确认前缀，stash=待确认后缀（不是 OpenAI 的 delta）
            let text = (json["text"] as? String) ?? ""
            let stash = (json["stash"] as? String) ?? ""
            let preview = text + stash
            if !preview.isEmpty {
                onUserTranscript?(preview, false)
            } else if let delta = json["delta"] as? String, !delta.isEmpty {
                onUserTranscript?(delta, false)
            }

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String {
                onUserTranscript?(transcript, true)
            }

        case "conversation.item.input_audio_transcription.failed":
            // 转写失败不挂断通话
            break

        case "response.done":
            hasActiveResponse = false
            onResponseFinished?()

        case "response.audio.done":
            // 音频流结束，但整轮 response 可能尚未 done；播放侧自行处理队列清空
            break

        default:
            break
        }
    }

    private static func isNonFatalRealtimeError(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("append image before append audio") || lower.contains("image before") {
            return true
        }
        // cancel / 重复 create 都属于竞态，绝不能挂断通话
        if lower.contains("none active response")
            || lower.contains("no active response")
            || lower.contains("without an active response")
            || (lower.contains("active response") && lower.contains("none")) {
            return true
        }
        if lower.contains("already has an active response")
            || lower.contains("active response in progress")
            || (lower.contains("active response") && lower.contains("already")) {
            return true
        }
        return false
    }

    private func failOpenWaiters(_ error: Error) {
        if let openContinuation {
            self.openContinuation = nil
            openContinuation.resume(throwing: error)
        }
        if let sessionCreatedContinuation {
            self.sessionCreatedContinuation = nil
            sessionCreatedContinuation.resume(throwing: error)
        }
    }

    private func makeError(code: Int, message: String) -> NSError {
        NSError(domain: "QwenOmni", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func prettier(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "QwenOmni" { return ns.localizedDescription }
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("unauthorized") || text.contains("401") {
            return "API Key 无效或无权限，请到百炼控制台检查 DASHSCOPE_API_KEY"
        }
        // 只映射明确的断连文案；保留服务端/系统原文便于定位
        if text.contains("连接已断开")
            || text.contains("连接已关闭")
            || text.localizedCaseInsensitiveContains("socket is not connected")
            || text.localizedCaseInsensitiveContains("not connected to")
            || (ns.domain == NSURLErrorDomain && (
                ns.code == NSURLErrorNetworkConnectionLost
                || ns.code == NSURLErrorTimedOut
                || ns.code == NSURLErrorCannotConnectToHost
            )) {
            if let lastCloseMessage, !lastCloseMessage.isEmpty,
               lastCloseMessage != text,
               !lastCloseMessage.hasPrefix("连接已") {
                return "通话通道断开了（\(lastCloseMessage)），请再点一次接通"
            }
            return "通话通道断开了，请再点一次接通"
        }
        return text
    }
}

extension QwenOmniRealtimeClient: URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            self.isSocketOpen = true
            if let openContinuation {
                self.openContinuation = nil
                openContinuation.resume()
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let message = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "连接已关闭(\(closeCode.rawValue))"
        Task { @MainActor in
            self.isSocketOpen = false
            self.lastCloseMessage = message
            // 主动挂断 / goingAway：不当成通话失败弹「连接已断开」
            if self.isIntentionallyClosing || closeCode == .goingAway || closeCode == .normalClosure {
                self.failOpenWaiters(self.makeError(code: 13, message: message))
                if self.state == .connecting || self.state == .connected {
                    self.state = .idle
                }
                return
            }
            self.failOpenWaiters(self.makeError(code: 13, message: message))
            if self.state == .connected || self.state == .connecting {
                let pretty = self.prettier(self.makeError(code: 13, message: message))
                self.state = .failed(pretty)
                self.onError?(pretty)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        Task { @MainActor in
            if let status {
                self.handshakeStatusCode = status
            }
            if let error {
                let message = self.prettier(error)
                self.lastCloseMessage = message
                if self.state == .connecting {
                    self.failOpenWaiters(self.makeError(code: 14, message: message))
                }
            } else if let status, status >= 400 {
                let message = "通话握手失败（HTTP \(status)）"
                self.lastCloseMessage = message
                if self.state == .connecting {
                    self.failOpenWaiters(self.makeError(code: 14, message: message))
                }
            }
        }
    }
}
