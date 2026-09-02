import Foundation

struct DecisionResponse: Decodable {
    let recommendation: String
    let reason: String
    let nextStep: String
    let title: String
    let options: [String]
}

enum OpenRouterError: LocalizedError {
    case missingKey
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "缺少 OpenRouter API Key，请在 Config.local.xcconfig 中配置。"
        case .invalidResponse:
            return "鸭鸭收到了回复，但没有解析出明确建议。"
        case .requestFailed(let message):
            return message
        }
    }
}

actor OpenRouterClient {
    private let config: AppConfig
    private let session: URLSession

    init(config: AppConfig = .current, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func askDecision(prompt: String, profile: UserProfile?, recentMessages: [ChatMessage], attachmentKind: AttachmentKind?) async throws -> DecisionResponse {
        guard config.hasOpenRouterKey else { throw OpenRouterError.missingKey }

        let system = """
        你是“选选鸭”，一个帮助选择困难症用户下决定的中文 AI 决策搭子。
        必须直接给明确建议，不要只说看情况。
        输出必须是严格 JSON：
        {"recommendation":"明确推荐","reason":"2-4句理由","nextStep":"一个可执行下一步","title":"简短决策标题","options":["选项A","选项B"]}
        如果用户发了图片或视频但模型无法读取附件，就基于文字给出临时建议，并说明还需要用户补充的关键判断信息。
        """

        let profileText = profile.map {
            "用户昵称：\($0.nickname)。决策风格：\($0.decisionStyleRaw)。偏好：\($0.preferences)。常纠结场景：\($0.commonScenarios)。画像总结：\($0.duckSummary)。"
        } ?? "暂无用户画像。"

        let recent = recentMessages.suffix(8).map { message in
            "\(message.roleRaw): \(message.text)"
        }.joined(separator: "\n")

        let userContent = """
        \(profileText)

        最近对话：
        \(recent)

        当前问题：
        \(prompt)

        附件类型：\(attachmentKind?.rawValue ?? "none")
        """

        let body = ChatRequest(
            model: config.openRouterModel,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: userContent)
            ],
            responseFormat: .init(type: "json_object")
        )

        let text = try await postChat(body)
        guard let data = text.data(using: .utf8) else { throw OpenRouterError.invalidResponse }
        do {
            return try JSONDecoder().decode(DecisionResponse.self, from: data)
        } catch {
            return DecisionResponse(
                recommendation: text.prefix(120).description,
                reason: text,
                nextStep: "先按这个建议执行一个低成本试验，记录结果后再调整。",
                title: "鸭鸭建议",
                options: []
            )
        }
    }

    func summarizeProfile(profile: UserProfile, messages: [ChatMessage], decisions: [DecisionRecord]) async throws -> String {
        guard config.hasOpenRouterKey else { throw OpenRouterError.missingKey }

        let decisionText = decisions.prefix(12).map {
            "\($0.title)：推荐\($0.recommendation)，理由：\($0.reasonSummary)"
        }.joined(separator: "\n")
        let messageText = messages.suffix(16).map { "\($0.roleRaw): \($0.text)" }.joined(separator: "\n")

        let body = ChatRequest(
            model: config.openRouterModel,
            messages: [
                .init(role: "system", content: "你是选选鸭。请用 80 字以内总结用户画像，突出偏好、决策风格和常见纠结点，只输出中文摘要。"),
                .init(role: "user", content: "现有画像：\(profile.preferences)，\n常见场景：\(profile.commonScenarios)\n决策历史：\(decisionText)\n聊天：\(messageText)")
            ],
            responseFormat: nil
        )
        return try await postChat(body).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribeAudio(fileURL: URL) async throws -> String {
        guard config.hasOpenRouterKey else { throw OpenRouterError.missingKey }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.openRouterAPIKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendMultipartField(name: "model", value: config.openRouterSTTModel, boundary: boundary)
        let audio = try Data(contentsOf: fileURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenRouterError.requestFailed(String(data: data, encoding: .utf8) ?? "录音转文字失败。")
        }
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decoded.text
    }

    private func postChat(_ body: ChatRequest) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.openRouterAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("选选鸭 iOS Demo", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenRouterError.requestFailed(String(data: data, encoding: .utf8) ?? "OpenRouter 请求失败。")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw OpenRouterError.invalidResponse
        }
        return content
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatRequestMessage]
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
    }
}

private struct ChatRequestMessage: Encodable {
    let role: String
    let content: String
}

private struct ResponseFormat: Encodable {
    let type: String
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

private extension Data {
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}

