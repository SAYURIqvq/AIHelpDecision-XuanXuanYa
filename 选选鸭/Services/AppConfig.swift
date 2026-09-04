import Foundation

struct AppConfig {
    let openRouterAPIKey: String
    let openRouterModel: String
    let openRouterVisionModel: String
    let openRouterSTTModel: String
    let liveKitURL: String
    let liveKitToken: String
    /// 阿里云百炼 DashScope API Key（Qwen Omni Realtime 语音/视频）
    let dashScopeAPIKey: String
    let qwenOmniModel: String
    let qwenOmniVoice: String
    let qwenOmniWSURL: String

    static var current: AppConfig {
        AppConfig(
            openRouterAPIKey: Bundle.main.configValue("OPENROUTER_API_KEY"),
            openRouterModel: Bundle.main.configValue("OPENROUTER_MODEL", fallback: "qwen/qwen3.5-flash-02-23"),
            openRouterVisionModel: Bundle.main.configValue("OPENROUTER_VISION_MODEL", fallback: "qwen/qwen3-vl-30b-a3b-instruct"),
            openRouterSTTModel: Bundle.main.configValue("OPENROUTER_STT_MODEL", fallback: "openai/gpt-4o-mini-transcribe"),
            liveKitURL: Bundle.main.configValue("LIVEKIT_WS_URL"),
            liveKitToken: Bundle.main.configValue("LIVEKIT_PARTICIPANT_TOKEN"),
            dashScopeAPIKey: Bundle.main.configValue("DASHSCOPE_API_KEY"),
            qwenOmniModel: Bundle.main.configValue("QWEN_OMNI_MODEL", fallback: "qwen3.5-omni-flash-realtime"),
            // Qiao「小乔妹」：甜+个性（qwen3.5 可用）；Cherry 仅旧版 Flash 支持会 400
            qwenOmniVoice: Bundle.main.configValue("QWEN_OMNI_VOICE", fallback: "Qiao"),
            qwenOmniWSURL: Self.normalizedWebSocketURL(
                Bundle.main.configValue(
                    "QWEN_OMNI_WS_URL",
                    fallback: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
                )
            )
        )
    }

    var hasOpenRouterKey: Bool { !openRouterAPIKey.isEmpty }
    var hasLiveKitCredentials: Bool { !liveKitURL.isEmpty && !liveKitToken.isEmpty }
    var hasDashScopeRealtime: Bool { !dashScopeAPIKey.isEmpty }

    /// xcconfig 会把 `//` 当成注释，导致 `wss://...` 变成 `wss:`；这里自动修复。
    private static func normalizedWebSocketURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("wss://"), trimmed.count > 8 {
            return trimmed
        }
        if trimmed == "wss:" || trimmed == "wss:/" || trimmed.hasPrefix("wss:") && !trimmed.contains("aliyuncs.com") {
            return "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
        }
        if trimmed.hasPrefix("wss:"), !trimmed.hasPrefix("wss://") {
            // wss:dashscope... → wss://dashscope...
            let rest = String(trimmed.dropFirst(4))
            if rest.hasPrefix("//") { return "wss:" + rest }
            if rest.hasPrefix("/") { return "wss:/" + rest }
            return "wss://" + rest
        }
        if trimmed.isEmpty {
            return "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
        }
        return trimmed
    }
}

private extension Bundle {
    func configValue(_ key: String, fallback: String = "") -> String {
        guard let value = object(forInfoDictionaryKey: key) as? String else { return fallback }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("$(") {
            return fallback
        }
        return trimmed
    }
}
