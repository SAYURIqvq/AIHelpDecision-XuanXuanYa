import Foundation

struct AppConfig {
    let openRouterAPIKey: String
    let openRouterModel: String
    let openRouterSTTModel: String
    let liveKitURL: String
    let liveKitToken: String

    static var current: AppConfig {
        AppConfig(
            openRouterAPIKey: Bundle.main.configValue("OPENROUTER_API_KEY"),
            openRouterModel: Bundle.main.configValue("OPENROUTER_MODEL", fallback: "deepseek/deepseek-v4-flash-0731"),
            openRouterSTTModel: Bundle.main.configValue("OPENROUTER_STT_MODEL", fallback: "openai/gpt-4o-mini-transcribe"),
            liveKitURL: Bundle.main.configValue("LIVEKIT_WS_URL"),
            liveKitToken: Bundle.main.configValue("LIVEKIT_PARTICIPANT_TOKEN")
        )
    }

    var hasOpenRouterKey: Bool { !openRouterAPIKey.isEmpty }
    var hasLiveKitCredentials: Bool { !liveKitURL.isEmpty && !liveKitToken.isEmpty }
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

