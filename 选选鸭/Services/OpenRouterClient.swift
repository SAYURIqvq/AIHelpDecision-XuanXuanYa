import Foundation

struct DecisionResponse: Codable, Equatable {
    let recommendation: String
    let reason: String
    let nextStep: String
    let title: String
    let options: [String]
}

struct StyleQuizResult: Codable {
    let styleName: String
    let analysis: String
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
        var full = ""
        for try await chunk in streamDecision(
            prompt: prompt,
            profile: profile,
            recentMessages: recentMessages,
            attachmentKind: attachmentKind
        ) {
            full += chunk
        }
        return DecisionStreamParser.parse(full).response ?? DecisionResponse(
            recommendation: full.prefix(120).description,
            reason: full,
            nextStep: "先按这个建议执行一个低成本试验。",
            title: "鸭鸭建议",
            options: []
        )
    }

    func streamDecision(
        prompt: String,
        profile: UserProfile?,
        recentMessages: [ChatMessage],
        attachmentKind: AttachmentKind?,
        attachmentRelativePath: String? = nil,
        attachmentRelativePaths: [String] = []
    ) -> AsyncThrowingStream<String, Error> {
        let profileText = profile.map {
            "用户昵称：\($0.nickname)。决策风格：\($0.decisionStyleRaw)。偏好：\($0.preferences)。常纠结场景：\($0.commonScenarios)。画像总结：\($0.duckSummary)。"
        } ?? "暂无用户画像。"

        let recent = recentMessages.suffix(8).map { message in
            "\(message.roleRaw): \(message.promptText)"
        }.joined(separator: "\n")

        let paths: [String] = {
            if !attachmentRelativePaths.isEmpty { return attachmentRelativePaths }
            if let attachmentRelativePath, !attachmentRelativePath.isEmpty {
                return attachmentRelativePath.components(separatedBy: "|||").filter { !$0.isEmpty }
            }
            return []
        }()
        let hasVision = attachmentKind == .image || attachmentKind == .video || !paths.isEmpty
        let system = """
        \(DuckSpeech.persona)
        立刻开始输出中文正文，不要先铺垫很长，不要使用任何 markdown 标记（禁止 ** *** # `）。
        如果用户发了图片/视频截图，请先简短说出你看到的关键内容，再结合用户文字回应。多图时请逐张概括关键差异。

        先判断用户意图，再决定要不要给按钮：

        【B 真正在纠结拍板】（最高优先！）
        一旦用户本句是在二选一/多选一拍板，必须走决策，禁止用续聊芯片搪塞：
        - 典型句式：A还是B、要不要、该不该、选哪个、吃X还是吃Y、买A还是买B
        - 例：「吃鸡蛋还是吃包子」→ 立刻给「吃鸡蛋 / 吃包子」决策按钮，不要改问「要不要鸡蛋做法」这类话题
        - 正文用决策格式：
        🦆 鸭鸭建议：...
        ✨ 理由：...
        👉 下一步：...
        然后温柔问：纠结好了吗？点下方按钮确认最终决定鸭～确认后才会记入决策历史哦。
        - 正文结束后必须追加（第一轮就要有，不要等用户再问一次）：
        <<<OPTIONS>>>
        {"title":"简短决策标题","recommendation":"明确推荐且必须是 options 之一","reason":"一句话理由摘要","options":["🍜 用户真实选项A","🥗 用户真实选项B"]}
        <<<END>>>
        - options 必须来自用户真实选项，至少 2 个、最多 4 个（不含「我还没有纠结好」）；每个选项前面加一个贴切 emoji。
        - 每个 option = 一个互斥结果。全场景通用硬规则：
          1) 禁止近义/换说法重复（如「不带耳机用免提」和「不带耳机，直接用免提」只能留一个）
          2) 禁止同一结果再加括号/破折号/冒号注解当成新选项（如「花菜」和「花菜 (健康软糯)」、「方案A」和「方案A：稳妥版」）
          3) 禁止把推荐短名和完整选项同时塞进 options
          4) 对立选项要保留（如「去」和「不去」、「带」和「不带」）
        - recommendation 必须原样复制某一个 option（含 emoji），禁止另写短名或近义句。
        - 严禁：用户已在 A/B 拍板时，却输出 <<<CHIPS>>> 去问做法/话题/下一步闲聊。

        【A 闲聊 / 提问求教 / 陪伴 / 找话题】
        - 正常聊天即可，不要逼用户做最终决定。
        - 不要输出「纠结好了吗」，不要记决策。
        - 正文结束后，尽量追加 3 个续聊芯片（除非纯寒暄一句就够）：
        <<<CHIPS>>>
        {"options":["🎯 顺着上文的下一步A","💬 顺着上文的下一步B","✨ 顺着上文的下一步C"]}
        <<<END>>>
        - CHIPS 硬规则（全场景）：
          1) 必须紧扣「你刚刚正文里讲到的内容」继续递进，像下一问/下一步/加深细节，不要跳到无关新话题。
          2) 用户已在聊某件事（如怎么做菜、红烧行不行）时，芯片只能围绕这件事深化（步骤、口味、替换做法、注意点），禁止推荐「聊别的」「换个话题」「今日心情」等冷启动话题。
          3) 芯片要短、可一点就发出去当用户下一句，每条前加贴切 emoji；彼此意思不要重复。
          4) 只有用户明确说「随便聊聊 / 换个话题 / 不知道聊啥」时，才给开阔找话题的芯片。

        重要：续聊递进用 CHIPS；真正二选一拍板用 OPTIONS。两者不要同时出现；若冲突，只保留 OPTIONS。
        用户只是问怎么做/求建议/继续聊、且没有 A还是B 这类拍板句时，用 CHIPS，绝不要用 OPTIONS。
        若用户消息里带有【用户正在引用/回复 …】，说明用户在针对某句前文回复，请结合被引用内容回应。
        """

        let userText = """
        \(profileText)

        最近对话：
        \(recent)

        当前问题：
        \(prompt)

        附件类型：\(attachmentKind?.rawValue ?? "none")
        附件数量：\(paths.count)
        """

        let imageDatas = hasVision ? AttachmentStore.jpegDatasForVision(relativePaths: paths) : []
        let model = imageDatas.isEmpty ? config.openRouterModel : config.openRouterVisionModel
        return streamChat(system: system, user: userText, imageJPEGDatas: imageDatas, model: model)
    }

    func streamConfirmChoice(
        choice: String,
        title: String,
        recommendation: String,
        reason: String,
        nickname: String
    ) -> AsyncThrowingStream<String, Error> {
        let system = """
        \(DuckSpeech.persona)
        用户已经点选了最终决定。请用一两句萌萌的中文确认，必须点名最终决定内容，可带 emoji。
        不要 JSON，不要 markdown。例如：收到收到！🦆 最终决定是「xxx」啦～鸭鸭已经帮你记进决策历史，冲冲冲💛
        """
        let user = """
        用户昵称：\(nickname)
        决策标题：\(title)
        鸭鸭原推荐：\(recommendation)
        理由摘要：\(reason)
        用户最终选择：\(choice)
        """
        return streamChat(system: system, user: user)
    }

    func streamStillUndecidedPrompt(nickname: String, title: String, options: [String]) -> AsyncThrowingStream<String, Error> {
        let system = """
        \(DuckSpeech.persona)
        用户点了「我还没有纠结好」，说明还没准备好拍板。
        请温柔追问，引导用户说出此刻最纠结的点。语气要像示例，但可自然改写并加 emoji：
        你现在最纠结的是什么呢？能不能告诉鸭鸭，鸭鸭帮你继续分析～
        不要给最终选项 JSON，不要 markdown，只输出追问。
        """
        let user = """
        用户昵称：\(nickname)
        当前决策标题：\(title)
        先前选项：\(options.joined(separator: " / "))
        """
        return streamChat(system: system, user: user)
    }


    func streamProfileInsight(
        profile: UserProfile,
        messages: [ChatMessage],
        decisions: [DecisionRecord],
        refreshFromChat: Bool = false
    ) -> AsyncThrowingStream<String, Error> {
        let decisionText = decisions.prefix(12).map {
            "\($0.title)：最终选择\($0.finalChoice.isEmpty ? $0.recommendation : $0.finalChoice)，理由：\($0.reasonSummary)"
        }.joined(separator: "\n")
        let messageText = messages.suffix(24).map { "\($0.roleRaw): \($0.displayText)" }.joined(separator: "\n")

        let system: String
        if refreshFromChat {
            system = """
            \(DuckSpeech.persona)
            请根据用户「最近聊天记录」和决策历史，更新「鸭鸭眼中的你」画像。
            重点从聊天里捕捉：反复纠结的点、拍板习惯、情绪倾向、新偏好。
            开头类似：「鸭鸭又看了看你们最近的聊天啦💛」
            然后更新：1) 从聊天看出的新习惯；2) 决策风格怎么表现；3) 鸭鸭接下来怎么帮你选。
            不要输出 JSON，不要用 markdown。篇幅约 180-280 字。
            """
        } else {
            system = """
            \(DuckSpeech.persona)
            用户刚保存了决策画像，请用萌萌口语做完整洞察，适度 emoji。
            开头类似：「鸭鸭已经了解你的\(profile.nickname)画像啦💛」
            然后总结：1) 偏好与常纠结场景；2) 决策风格怎么影响选择；3) 鸭鸭对你的分析和相处建议。
            不要输出 JSON，不要用 markdown 标题。篇幅约 180-280 字。
            """
        }

        let user = """
        昵称：\(profile.nickname)
        决策风格：\(profile.decisionStyleRaw)
        偏好：\(profile.preferences)
        常纠结场景：\(profile.commonScenarios)
        已有画像：\(profile.duckSummary)
        决策历史：\(decisionText)
        最近聊天：\(messageText.isEmpty ? "暂无聊天记录" : messageText)
        """

        return streamChat(
            system: system,
            user: user
        )
    }

    func streamStyleQuizAnalysis(nickname: String, answers: [(question: String, answer: String)]) -> AsyncThrowingStream<String, Error> {
        streamQuizAnalysis(kind: .decisionStyle, nickname: nickname, answers: answers, localHint: "")
    }

    func streamQuizAnalysis(
        kind: QuizKind,
        nickname: String,
        answers: [(question: String, answer: String)],
        localHint: String
    ) -> AsyncThrowingStream<String, Error> {
        let answerText = answers.enumerated().map { index, item in
            "Q\(index + 1) \(item.question)\n答：\(item.answer)"
        }.joined(separator: "\n\n")

        let system: String
        switch kind {
        case .decisionStyle:
            system = """
            \(DuckSpeech.persona)
            根据用户决策风格测试答案，用 OpenRouter SSE 流式输出中文结果，可带 emoji。
            立刻开始输出，边想边写，不要攒整段再发。
            严格按这个格式，每行写完就换行（不要 markdown）：
            【专属风格】四个字到十字以内的网络感风格名（可自创，如「人间清醒拖延型」，不要只用两个/三个字的短标签）
            【鸭鸭分析】对用户决策习惯的生动分析（偏好、纠结模式、拍板建议），约 150-220 字。
            风格名要好玩、像网络用词，但别低俗。先输出【专属风格】那一行，再流式输出【鸭鸭分析】。
            """
        case .mbti:
            system = """
            \(DuckSpeech.persona)
            用户刚完成鸭鸭版 MBTI 题。本地初判参考：\(localHint.isEmpty ? "无" : localHint)
            用 SSE 流式输出，立刻开写，不要攒稿。格式：
            【结果】四字母类型 + 可爱外号
            【鸭鸭分析】结合决策场景说明这个类型怎么纠结、怎么拍板，约 140-200 字。
            不要 markdown。先结果行，再分析。
            """
        case .choiceAnxiety:
            system = """
            \(DuckSpeech.persona)
            用户测了选择困难症。本地初判：\(localHint.isEmpty ? "无" : localHint)
            用 SSE 流式输出，立刻开写。格式：
            【结果】一句严重程度结论（可沿用初判）
            【鸭鸭分析】共情 + 给出 3 个可执行的减负拍板小技巧，约 140-200 字。
            不要 markdown。
            """
        case .preference:
            system = """
            \(DuckSpeech.persona)
            根据用户偏好题答案写分析。本地参考：\(localHint.isEmpty ? "无" : localHint)
            用 SSE 流式输出，立刻开写。严格格式：
            【结果】一句话偏好画像（短句，不要罗列标签）
            【鸭鸭分析】说明这些偏好如何影响日常决策，约 120-180 字。
            不要输出【标签】行。不要 markdown。不要用·把多个词拼在一行。
            """
        }

        let user = """
        用户昵称：\(nickname)
        测试类型：\(kind.title)
        测试答案：
        \(answerText)
        """

        return streamChat(system: system, user: user)
    }

    func summarizeProfile(profile: UserProfile, messages: [ChatMessage], decisions: [DecisionRecord]) async throws -> String {
        var text = ""
        for try await chunk in streamProfileInsight(profile: profile, messages: messages, decisions: decisions) {
            text += chunk
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func streamChat(
        system: String,
        user: String,
        imageJPEGData: Data? = nil,
        imageJPEGDatas: [Data] = [],
        model: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard config.hasOpenRouterKey else { throw OpenRouterError.missingKey }
                    let selectedModel = model ?? config.openRouterModel
                    var imageDatas = imageJPEGDatas
                    if imageDatas.isEmpty, let imageJPEGData {
                        imageDatas = [imageJPEGData]
                    }
                    let userMessage: ChatRequestMessage
                    if !imageDatas.isEmpty {
                        var parts: [ChatRequestMessage.ContentPart] = [.text(user)]
                        for data in imageDatas.prefix(9) {
                            let b64 = data.base64EncodedString()
                            parts.append(.imageURL("data:image/jpeg;base64,\(b64)"))
                        }
                        userMessage = .init(role: "user", content: .parts(parts))
                    } else {
                        userMessage = .init(role: "user", content: .text(user))
                    }
                    let body = ChatRequest(
                        model: selectedModel,
                        messages: [
                            .init(role: "system", content: .text(system)),
                            userMessage
                        ],
                        stream: true,
                        responseFormat: nil,
                        reasoning: ReasoningConfig(effort: "none", exclude: true),
                        provider: ProviderPreferences(sort: "throughput")
                    )
                    var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 120
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.setValue("Bearer \(config.openRouterAPIKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("XuanXuanYa", forHTTPHeaderField: "X-Title")
                    request.setValue("https://xuanxuanya.app", forHTTPHeaderField: "HTTP-Referer")
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode
                        let detail = code.map { "OpenRouter 流式请求失败（\($0)）。" } ?? "OpenRouter 流式请求失败。"
                        throw OpenRouterError.requestFailed(detail)
                    }

                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty || trimmed.hasPrefix(":") { continue }
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        if let chunk = try? JSONDecoder().decode(StreamChatChunk.self, from: data),
                           let delta = chunk.choices.first?.delta.content,
                           !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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
    let stream: Bool
    let responseFormat: ResponseFormat?
    let reasoning: ReasoningConfig?
    let provider: ProviderPreferences?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case responseFormat = "response_format"
        case reasoning
        case provider
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(stream, forKey: .stream)
        try container.encodeIfPresent(responseFormat, forKey: .responseFormat)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(provider, forKey: .provider)
    }
}

private struct ReasoningConfig: Encodable {
    let effort: String
    let exclude: Bool
}

private struct ProviderPreferences: Encodable {
    let sort: String
}

private struct ChatRequestMessage: Encodable {
    let role: String
    let content: MessageContent

    enum MessageContent: Encodable {
        case text(String)
        case parts([ContentPart])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value):
                try container.encode(value)
            case .parts(let parts):
                try container.encode(parts)
            }
        }
    }

    struct ContentPart: Encodable {
        let type: String
        let text: String?
        let imageURL: ImageURLPayload?

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }

        static func text(_ value: String) -> ContentPart {
            ContentPart(type: "text", text: value, imageURL: nil)
        }

        static func imageURL(_ url: String) -> ContentPart {
            ContentPart(type: "image_url", text: nil, imageURL: ImageURLPayload(url: url))
        }
    }

    struct ImageURLPayload: Encodable {
        let url: String
    }
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

private struct StreamChatChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta
    }
    let choices: [Choice]
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

enum DecisionStreamParser {
    struct Payload: Decodable {
        let title: String?
        let recommendation: String?
        let reason: String?
        let options: [String]?
    }

    struct ParseResult {
        let displayText: String
        let kind: MessageInteractionKind
        let response: DecisionResponse?
        let chipOptions: [String]
    }

    /// 流式过程中裁掉 OPTIONS / CHIPS 尾部。
    static func streamingDisplay(_ full: String) -> String {
        var clipped = full
        for marker in ["<<<OPTIONS>>>", "<<<CHIPS>>>"] {
            if let start = clipped.range(of: marker) {
                clipped = String(clipped[..<start.lowerBound])
            }
        }
        return DuckTextSanitizer.plain(clipped.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func parse(_ full: String) -> ParseResult {
        // OPTIONS 优先：模型偶发同时吐 CHIPS+OPTIONS 时，以拍板按钮为准
        if let decision = parseBlock(full, startMarker: "<<<OPTIONS>>>", endMarker: "<<<END>>>") {
            var options = dedupeOptions(decision.payload.options ?? [])
            let rawRecommendation = (decision.payload.recommendation ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // 近义推荐 → 映射到已有 option；真正不同的推荐才补进列表（避免只剩 1 个 option 时按钮全没）
            let recommendation: String
            if let matched = matchOption(rawRecommendation, in: options) {
                recommendation = matched
            } else if !rawRecommendation.isEmpty {
                options.insert(rawRecommendation, at: 0)
                options = dedupeOptions(options)
                recommendation = matchOption(rawRecommendation, in: options) ?? rawRecommendation
            } else if !options.isEmpty {
                recommendation = options[0]
            } else {
                recommendation = ""
            }

            // 至少 1 个真实选项即可展示（下方还会自动补「我还没有纠结好」）
            if !options.isEmpty {
                let response = DecisionResponse(
                    recommendation: recommendation.isEmpty ? options[0] : recommendation,
                    reason: decision.payload.reason ?? decision.display,
                    nextStep: "点选下方最终决定",
                    title: (decision.payload.title ?? "鸭鸭建议").trimmingCharacters(in: .whitespacesAndNewlines),
                    options: options
                )
                return ParseResult(
                    displayText: decision.display,
                    kind: .decision,
                    response: response,
                    chipOptions: []
                )
            }
            return ParseResult(displayText: decision.display, kind: .none, response: nil, chipOptions: [])
        }

        if let chips = parseBlock(full, startMarker: "<<<CHIPS>>>", endMarker: "<<<END>>>") {
            let options = dedupeOptions(chips.payload.options ?? [])
            if !options.isEmpty {
                return ParseResult(
                    displayText: chips.display,
                    kind: .chips,
                    response: nil,
                    chipOptions: options
                )
            }
        }

        return ParseResult(
            displayText: DuckTextSanitizer.plain(full),
            kind: .none,
            response: nil,
            chipOptions: []
        )
    }

    /// 全场景选项语义归一：去掉 emoji/标点/括号注解/破折号注解/语气填充后的核心义。
    static func normalizeOptionKey(_ text: String) -> String {
        let stripped = strippingAnnotations(from: text)
        let folded = stripped
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        return String(folded.filter { $0.isLetter || $0.isNumber })
    }

    /// 去掉括号注解，以及「选项——注解」「选项：注解」这类装饰尾巴。
    private static func strippingAnnotations(from text: String) -> String {
        var s = removingParenthetical(from: text)
        let separators = ["——", "—", "–", "：", ":", "·", " - ", "｜", "|"]
        for sep in separators {
            guard let range = s.range(of: sep) else { continue }
            let left = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(s[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            // 右侧短、或明显短于左侧时，当作装饰注解而不是另一个对立选项
            if !left.isEmpty, !right.isEmpty, right.count <= 6 || right.count <= left.count {
                s = left
                break
            }
        }
        return s
    }

    private static func removingParenthetical(from text: String) -> String {
        var result = ""
        var depth = 0
        for ch in text {
            if ch == "(" || ch == "（" {
                depth += 1
                continue
            }
            if ch == ")" || ch == "）" {
                depth = max(0, depth - 1)
                continue
            }
            if depth == 0 {
                result.append(ch)
            }
        }
        return result
    }

    /// 语气/程度填充词：去掉后再比，避免「直接/一下/比较」造成假不同。
    private static let fillerTokens = [
        "直接", "一下", "稍微", "比较", "更加", "有点", "有些", "那个", "这个", "那种", "这种",
        "感觉", "真的", "可以", "能够", "选择", "决定", "建议", "准备", "打算",
        "先", "再", "就", "吧", "呢", "呀", "啊", "哦", "嘛", "啦", "咯", "呗"
    ]

    static func coreOptionKey(_ text: String) -> String {
        var key = normalizeOptionKey(text)
        // 多轮去掉填充，避免「直接一下」这类叠词
        for _ in 0..<2 {
            for token in fillerTokens {
                key = key.replacingOccurrences(of: token, with: "")
            }
        }
        return key
    }

    /// 全场景近义判断：同义/缩写/注解变体 → true；否定对立 → false。
    static func optionsAreNearDuplicate(_ a: String, _ b: String) -> Bool {
        let trimmedA = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedB = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedA.isEmpty || trimmedB.isEmpty { return false }
        if trimmedA == trimmedB { return true }

        let coreA = coreOptionKey(trimmedA)
        let coreB = coreOptionKey(trimmedB)
        if coreA.isEmpty || coreB.isEmpty { return false }
        if coreA == coreB { return true }

        // 「去/不去」「带/不带」等对立选项必须保留
        if isContrastPair(coreA, coreB) { return false }

        let short = coreA.count <= coreB.count ? coreA : coreB
        let long = coreA.count <= coreB.count ? coreB : coreA
        let extra = long.count - short.count
        let ratio = Double(short.count) / Double(max(long.count, 1))

        // 缩写/加修饰：短句是长句的前缀或后缀
        if short.count >= 2, (long.hasPrefix(short) || long.hasSuffix(short)) {
            if ratio >= 0.55 { return true }
            if short.count >= 3, extra <= 5 { return true }
            if short.count >= 2, extra <= 4, ratio >= 0.4 { return true }
        }
        // 长句包含短句且短句足够长（中间插词后的近义）
        if short.count >= 5, long.contains(short) { return true }

        // 编辑距离：整体很像
        let maxLen = max(coreA.count, coreB.count)
        if maxLen >= 4 {
            let dist = levenshtein(coreA, coreB)
            if Double(dist) / Double(maxLen) <= 0.28 { return true }
        }

        // 字符 bigram 重合很高
        if maxLen >= 5, diceCoefficient(coreA, coreB) >= 0.8 { return true }

        return false
    }

    /// 兼容旧调用名。
    static func optionKeysSimilar(_ a: String, _ b: String) -> Bool {
        optionsAreNearDuplicate(a, b)
    }

    private static func isContrastPair(_ a: String, _ b: String) -> Bool {
        let marks = ["不", "没", "别", "非", "勿", "无"]
        for mark in marks {
            if a.replacingOccurrences(of: mark, with: "") == b { return true }
            if b.replacingOccurrences(of: mark, with: "") == a { return true }
        }
        return false
    }

    private static func diceCoefficient(_ a: String, _ b: String) -> Double {
        let ba = bigrams(a)
        let bb = bigrams(b)
        guard !ba.isEmpty || !bb.isEmpty else { return a == b ? 1 : 0 }
        let inter = ba.intersection(bb).count
        return (2.0 * Double(inter)) / Double(ba.count + bb.count)
    }

    private static func bigrams(_ text: String) -> Set<String> {
        let chars = Array(text)
        guard chars.count >= 2 else { return chars.isEmpty ? [] : [String(chars)] }
        var result: Set<String> = []
        for i in 0..<(chars.count - 1) {
            result.insert(String(chars[i...i + 1]))
        }
        return result
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aa = Array(a)
        let bb = Array(b)
        let n = aa.count
        let m = bb.count
        if n == 0 { return m }
        if m == 0 { return n }
        var prev = Array(0...m)
        var cur = Array(repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            for j in 1...m {
                let cost = aa[i - 1] == bb[j - 1] ? 0 : 1
                cur[j] = min(
                    prev[j] + 1,
                    cur[j - 1] + 1,
                    prev[j - 1] + cost
                )
            }
            prev = cur
        }
        return prev[m]
    }

    static func dedupeOptions(_ raw: [String]) -> [String] {
        var result: [String] = []
        for item in raw {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let idx = result.firstIndex(where: { optionsAreNearDuplicate($0, trimmed) }) {
                if richerOptionLabel(trimmed, than: result[idx]) {
                    result[idx] = trimmed
                }
                continue
            }
            result.append(trimmed)
        }
        return result
    }

    private static func richerOptionLabel(_ candidate: String, than existing: String) -> Bool {
        let c = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let cHasAnno = c.contains("(") || c.contains("（") || c.contains("：") || c.contains(":") || c.contains("—")
        let eHasAnno = e.contains("(") || e.contains("（") || e.contains("：") || e.contains(":") || e.contains("—")
        if cHasAnno != eHasAnno { return cHasAnno }
        return c.count > e.count
    }

    static func matchOption(_ recommendation: String, in options: [String]) -> String? {
        let rec = recommendation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rec.isEmpty else { return nil }
        if let exact = options.first(where: { $0 == rec }) { return exact }
        return options.first { optionsAreNearDuplicate($0, rec) }
    }

    private static func parseBlock(
        _ full: String,
        startMarker: String,
        endMarker: String
    ) -> (display: String, payload: Payload)? {
        guard let start = full.range(of: startMarker) else { return nil }
        let display = DuckTextSanitizer.plain(String(full[..<start.lowerBound]))
        var jsonPart = String(full[start.upperBound...])
        if let end = jsonPart.range(of: endMarker) {
            jsonPart = String(jsonPart[..<end.lowerBound])
        }
        jsonPart = jsonPart.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonPart.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return (display, Payload(title: nil, recommendation: nil, reason: nil, options: nil))
        }
        return (display, payload)
    }
}

/// 从用户原话识别「A还是B」类拍板意图，用于首轮强制出决策按钮。
enum UserChoiceIntent {
    static func isClearDecisionPrompt(_ raw: String) -> Bool {
        let text = normalize(raw)
        guard text.count >= 4 else { return false }
        if text.contains("还是") { return true }
        if text.contains("选哪个") || text.contains("选哪一个") || text.contains("选哪") { return true }
        if text.range(of: #"要不要|该不该|可不可以|行不行|好不好"#, options: .regularExpression) != nil {
            return true
        }
        if text.contains("或者"), text.count <= 40 {
            return true
        }
        return false
    }

    /// 从用户话里拆出可点选项；拆不出则返回空。
    static func extractOptions(from raw: String) -> [String] {
        var text = normalize(raw)
        for suffix in ["？", "?", "呢", "啊", "呀", "吗", "嘛", "啦"] {
            if text.hasSuffix(suffix) {
                text = String(text.dropLast(suffix.count))
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.contains("还是") {
            let parts = text
                .components(separatedBy: "还是")
                .map { cleanOptionPiece($0) }
                .filter { !$0.isEmpty && $0.count <= 24 }
            if parts.count >= 2 {
                return Array(dedupe(parts).prefix(4)).map(decorateEmoji)
            }
        }

        if text.contains("或者") {
            let parts = text
                .components(separatedBy: "或者")
                .map { cleanOptionPiece($0) }
                .filter { !$0.isEmpty && $0.count <= 24 }
            if parts.count >= 2 {
                return Array(dedupe(parts).prefix(4)).map(decorateEmoji)
            }
        }

        if text.range(of: #"要不要|该不该|可不可以|行不行|好不好"#, options: .regularExpression) != nil {
            let topic = text
                .replacingOccurrences(of: #"要不要|该不该|可不可以|行不行|好不好"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !topic.isEmpty, topic.count <= 20 {
                return [decorateEmoji("要\(topic)"), decorateEmoji("先不\(topic)")]
            }
            return ["👍 要", "🙅 先不要"]
        }

        return []
    }

    /// 用户明显在拍板，但模型给了续聊芯片/没给按钮时，补一套决策 OPTIONS。
    static func fallbackDecision(
        userPrompt: String,
        displayText: String,
        parsedKind: MessageInteractionKind
    ) -> DecisionResponse? {
        guard isClearDecisionPrompt(userPrompt) else { return nil }
        guard parsedKind != .decision else { return nil }
        let options = extractOptions(from: userPrompt)
        guard options.count >= 2 else { return nil }
        return DecisionResponse(
            recommendation: options[0],
            reason: displayText,
            nextStep: "点选下方最终决定",
            title: "帮你拍板",
            options: options
        )
    }

    private static func normalize(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"【用户正在引用[\s\S]*?】用户新说】\n?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"【用户正在引用/回复[\s\S]*?】\n?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"「[^」]*」\n?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanOptionPiece(_ piece: String) -> String {
        var s = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉句首口语填充
        for prefix in ["那", "嗯", "我是", "我想", "我该", "早上", "中午", "晚上", "今天", "明天"] {
            // 只剥「早上吃鸡蛋」里过长语境时保留动词：不在这里粗暴删「早上」
            _ = prefix
        }
        // 「请问吃鸡蛋」→「吃鸡蛋」
        for prefix in ["请问", "想问", "纠结", "帮我选", "帮我看看"] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dedupe(_ items: [String]) -> [String] {
        DecisionStreamParser.dedupeOptions(items)
    }

    private static func decorateEmoji(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first else { return trimmed }
        // 已有 emoji 则不加
        if first.properties.isEmoji, first.value >= 0x2600 {
            return trimmed
        }
        let lower = trimmed.lowercased()
        if lower.contains("蛋") { return "🥚 \(trimmed)" }
        if lower.contains("包子") || lower.contains("馒头") { return "🥟 \(trimmed)" }
        if lower.contains("面") { return "🍜 \(trimmed)" }
        if lower.contains("饭") { return "🍚 \(trimmed)" }
        if lower.contains("买") || lower.contains("不买") { return "🛒 \(trimmed)" }
        if lower.contains("去") || lower.contains("不去") { return "🚶 \(trimmed)" }
        if lower.hasPrefix("要") { return "👍 \(trimmed)" }
        if lower.hasPrefix("先不") || lower.hasPrefix("不") { return "🙅 \(trimmed)" }
        return "✨ \(trimmed)"
    }
}

private extension Data {
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
