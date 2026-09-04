import Foundation
import SwiftData

@MainActor
final class ChatViewModel: ObservableObject {
    static let maxPendingImages = 9

    @Published var draft = ""
    @Published var quoteDraft: QuoteDraft?
    @Published var isThinking = false
    @Published var isStreaming = false
    @Published var errorMessage: String?
    @Published var pendingAttachments: [PendingAttachment] = []
    @Published var streamingMessageID: UUID?
    @Published var streamingText = ""
    @Published var activeDecisionMessageID: UUID?
    @Published var needsGrainRecharge = false

    private let client = OpenRouterClient()
    private var lastStreamPersistAt = Date.distantPast
    private var lastStreamUIAt = Date.distantPast
    private var pendingStreamFull: String?
    private var didAttemptRecover = false

    var pendingImageCount: Int { pendingAttachments.filter { $0.kind == .image }.count }
    var pendingVideo: PendingAttachment? { pendingAttachments.first { $0.kind == .video } }
    var hasPendingAttachments: Bool { !pendingAttachments.isEmpty }

    struct QuoteDraft: Equatable {
        let messageID: UUID
        let text: String
        let fromRole: MessageRole

        var fromLabel: String {
            switch fromRole {
            case .assistant: return "鸭鸭"
            case .user: return "我"
            }
        }
    }

    func setQuote(from message: ChatMessage, selectedText: String? = nil) {
        let raw = selectedText ?? message.displayText
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        quoteDraft = QuoteDraft(messageID: message.id, text: text, fromRole: message.role)
    }

    func clearQuote() {
        quoteDraft = nil
    }

    func copyTextToDraft(_ text: String) {
        let clipped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clipped.isEmpty else { return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = clipped
        } else {
            draft += clipped
        }
    }

    func deleteMessage(_ message: ChatMessage, modelContext: ModelContext) {
        if streamingMessageID == message.id {
            isStreaming = false
            isThinking = false
            streamingMessageID = nil
            streamingText = ""
        }
        if activeDecisionMessageID == message.id {
            activeDecisionMessageID = nil
        }
        if quoteDraft?.messageID == message.id {
            quoteDraft = nil
        }
        modelContext.delete(message)
        try? modelContext.save()
    }

    func attach(tempURL: URL, kind: AttachmentKind) {
        do {
            switch kind {
            case .image:
                if pendingVideo != nil || pendingAttachments.contains(where: { $0.kind == .audio }) {
                    clearAttachmentFiles()
                    pendingAttachments = []
                }
                guard pendingImageCount < Self.maxPendingImages else {
                    errorMessage = "一次最多发 \(Self.maxPendingImages) 张图片鸭～"
                    return
                }
                let relative = try AttachmentStore.persist(tempURL: tempURL)
                pendingAttachments.append(PendingAttachment(kind: .image, relativePath: relative))
            case .video:
                if pendingImageCount > 0 || pendingAttachments.contains(where: { $0.kind == .audio }) {
                    clearAttachmentFiles()
                    pendingAttachments = []
                }
                if pendingVideo != nil {
                    errorMessage = "视频一次只能发 1 个，先删掉再换鸭～"
                    return
                }
                let relative = try AttachmentStore.persist(tempURL: tempURL)
                pendingAttachments = [PendingAttachment(kind: .video, relativePath: relative)]
            case .audio:
                // 录音已改为实时转文字进输入框，不再作为附件。
                errorMessage = "语音请用麦克风实时转文字，不再支持录音附件鸭～"
                return
            }
        } catch {
            errorMessage = "附件保存失败：\(error.localizedDescription)"
        }
    }

    func removePendingAttachment(_ id: UUID) {
        if let item = pendingAttachments.first(where: { $0.id == id }),
           let url = AttachmentStore.fileURL(relativePath: item.relativePath) {
            try? FileManager.default.removeItem(at: url)
        }
        pendingAttachments.removeAll { $0.id == id }
    }

    func clearAttachment() {
        clearAttachmentFiles()
        pendingAttachments = []
    }

    private func clearAttachmentFiles() {
        for item in pendingAttachments {
            if let url = AttachmentStore.fileURL(relativePath: item.relativePath) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func clearChat(messages: [ChatMessage], modelContext: ModelContext) {
        for message in messages {
            modelContext.delete(message)
        }
        activeDecisionMessageID = nil
        streamingMessageID = nil
        streamingText = ""
        quoteDraft = nil
        isStreaming = false
        isThinking = false
        try? modelContext.save()
    }

    /// 冷启动：把中断的「加载中」气泡恢复出来，并自动续传（不重复扣米粒）。
    func recoverInterruptedGenerations(
        messages: [ChatMessage],
        modelContext: ModelContext,
        profile: UserProfile?
    ) async {
        guard !didAttemptRecover else { return }
        didAttemptRecover = true
        guard !isStreaming else { return }

        let sorted = messages.sorted { $0.createdAt < $1.createdAt }
        // 兼容旧数据：末尾空助手气泡视为未完成
        if let last = sorted.last,
           last.role == .assistant,
           !last.isIncomplete,
           last.displayText.isEmpty,
           !last.hasInteractiveOptions {
            last.isIncomplete = true
            try? modelContext.save()
        }

        // 非末尾的残留 incomplete：收成可读文案，避免列表里空白气泡
        for message in sorted.dropLast() where message.isIncomplete {
            finalizeInterrupted(message, modelContext: modelContext)
        }

        guard let assistant = sorted.last,
              assistant.role == .assistant,
              assistant.isIncomplete else { return }

        let prior = sorted.dropLast().last
        beginStreaming(into: assistant, modelContext: modelContext, resetText: true)

        if let user = prior, user.role == .user {
            let history = Array(sorted.dropLast().dropLast())
            await streamDecisionReply(
                into: assistant,
                userMessage: user,
                profile: profile,
                recentMessages: history,
                attachmentKind: user.attachmentKind,
                attachmentRelativePaths: user.attachmentPaths,
                modelContext: modelContext
            )
            return
        }

        if let decision = prior,
           decision.role == .assistant,
           decision.interactionKind == .decision,
           !decision.selectedOption.isEmpty {
            if decision.isStillUndecidedSelection {
                await streamUndecidedReply(
                    into: assistant,
                    decisionMessage: decision,
                    profile: profile,
                    modelContext: modelContext
                )
            } else {
                await streamConfirmReply(
                    into: assistant,
                    choice: decision.selectedOption,
                    decisionMessage: decision,
                    profile: profile,
                    modelContext: modelContext,
                    recordDecision: true
                )
            }
            return
        }

        finalizeInterrupted(assistant, modelContext: modelContext)
        endStreaming()
    }

    func send(modelContext: ModelContext, profile: UserProfile?, recentMessages: [ChatMessage]) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasPendingAttachments, text.isEmpty {
            errorMessage = "先写一点你的纠结，再和附件一起发给鸭鸭鸭～"
            return
        }
        guard !text.isEmpty || hasPendingAttachments else { return }
        guard !isStreaming else { return }

        let wallet = GrainWalletService.ensureWallet(in: modelContext)
        if case .exhausted = GrainWalletService.consumeChatRound(wallet: wallet, context: modelContext) {
            needsGrainRecharge = true
            return
        }

        let userText = text
        let quote = quoteDraft
        let attachments = pendingAttachments
        let attachmentKind = attachments.first?.kind
        let attachmentFileName = attachments.map(\.fileName).joined(separator: "|||")
        let attachmentRelativePath = attachments.map(\.relativePath).joined(separator: "|||")
        draft = ""
        quoteDraft = nil
        pendingAttachments = []

        let userMessage = ChatMessage(
            role: .user,
            text: userText,
            attachmentKind: attachmentKind,
            attachmentFileName: attachmentFileName.isEmpty ? nil : attachmentFileName,
            attachmentRelativePath: attachmentRelativePath.isEmpty ? nil : attachmentRelativePath,
            quotedText: quote?.text ?? "",
            quotedFromRole: quote?.fromRole
        )
        modelContext.insert(userMessage)

        let assistant = ChatMessage(role: .assistant, text: "", isIncomplete: true)
        modelContext.insert(assistant)
        beginStreaming(into: assistant, modelContext: modelContext, resetText: false)
        errorMessage = nil
        try? modelContext.save()

        await streamDecisionReply(
            into: assistant,
            userMessage: userMessage,
            profile: profile,
            recentMessages: recentMessages,
            attachmentKind: attachmentKind,
            attachmentRelativePaths: attachments.map(\.relativePath),
            modelContext: modelContext
        )
    }

    func handleOptionTap(_ choice: String, message: ChatMessage, modelContext: ModelContext, profile: UserProfile?, recentMessages: [ChatMessage]) async {
        guard message.selectedOption.isEmpty else { return }

        // 闲聊话题芯片：继续聊天，绝不写入决策历史
        if message.interactionKind == .chips {
            message.selectedOption = choice
            try? modelContext.save()
            draft = choice
            await send(modelContext: modelContext, profile: profile, recentMessages: recentMessages)
            return
        }

        // 真正决策才确认/记历史
        guard message.interactionKind == .decision else { return }
        if choice == DuckSpeech.stillUndecided {
            await continueAfterUndecided(message: message, modelContext: modelContext, profile: profile)
        } else {
            await confirmFinalChoice(choice, message: message, modelContext: modelContext, profile: profile)
        }
    }

    func confirmFinalChoice(_ choice: String, message: ChatMessage, modelContext: ModelContext, profile: UserProfile?) async {
        guard message.selectedOption.isEmpty else { return }
        guard message.interactionKind == .decision else { return }
        guard !isStreaming else { return }
        message.selectedOption = choice
        try? modelContext.save()

        let confirm = ChatMessage(role: .assistant, text: "", isIncomplete: true)
        modelContext.insert(confirm)
        beginStreaming(into: confirm, modelContext: modelContext, resetText: false)
        try? modelContext.save()

        await streamConfirmReply(
            into: confirm,
            choice: choice,
            decisionMessage: message,
            profile: profile,
            modelContext: modelContext,
            recordDecision: true
        )
    }

    private func continueAfterUndecided(message: ChatMessage, modelContext: ModelContext, profile: UserProfile?) async {
        guard !isStreaming else { return }
        message.selectedOption = DuckSpeech.stillUndecided
        activeDecisionMessageID = nil
        try? modelContext.save()

        let followUp = ChatMessage(role: .assistant, text: "", isIncomplete: true)
        modelContext.insert(followUp)
        beginStreaming(into: followUp, modelContext: modelContext, resetText: false)
        try? modelContext.save()

        await streamUndecidedReply(
            into: followUp,
            decisionMessage: message,
            profile: profile,
            modelContext: modelContext
        )
    }

    private func streamDecisionReply(
        into assistant: ChatMessage,
        userMessage: ChatMessage,
        profile: UserProfile?,
        recentMessages: [ChatMessage],
        attachmentKind: AttachmentKind?,
        attachmentRelativePaths: [String],
        modelContext: ModelContext
    ) async {
        do {
            var full = ""
            for try await chunk in await client.streamDecision(
                prompt: userMessage.promptText,
                profile: profile,
                recentMessages: recentMessages + [userMessage],
                attachmentKind: attachmentKind,
                attachmentRelativePaths: attachmentRelativePaths
            ) {
                isThinking = false
                full += chunk
                applyStreamChunk(full, to: assistant, modelContext: modelContext)
            }
            flushStreamChunk(to: assistant, modelContext: modelContext, forcePersist: true)

            let parsed = DecisionStreamParser.parse(full)
            assistant.text = parsed.displayText.isEmpty ? DuckTextSanitizer.plain(full) : parsed.displayText
            streamingText = assistant.text
            assistant.interactionKind = parsed.kind

            switch parsed.kind {
            case .decision:
                if let response = parsed.response {
                    applyDecision(response, to: assistant)
                    activeDecisionMessageID = assistant.id
                }
                if !assistant.text.contains("纠结好了吗") {
                    assistant.text += "\n\n纠结好了吗？点下方按钮确认最终决定鸭～确认后才会记入决策历史哦 💛"
                    streamingText = assistant.text
                }
            case .chips:
                assistant.optionsRaw = parsed.chipOptions.joined(separator: "|||")
                assistant.recommendationRaw = ""
                assistant.decisionTitle = ""
                assistant.reasonSummary = ""
                activeDecisionMessageID = nil
            case .none:
                assistant.optionsRaw = ""
                activeDecisionMessageID = nil
            }
            assistant.isIncomplete = false
            try modelContext.save()
        } catch {
            assistant.text = """
            呜呜网络卡住了 🥺 鸭鸭先缓缓：

            你是想随便聊聊，还是有件具体的事要鸭鸭帮你拍板呀？
            跟鸭鸭说说就好，我们一步步来～
            """
            streamingText = assistant.text
            assistant.interactionKind = .none
            assistant.isIncomplete = false
            activeDecisionMessageID = nil
            errorMessage = error.localizedDescription
            try? modelContext.save()
        }

        endStreaming()
    }

    private func streamConfirmReply(
        into confirm: ChatMessage,
        choice: String,
        decisionMessage: ChatMessage,
        profile: UserProfile?,
        modelContext: ModelContext,
        recordDecision: Bool
    ) async {
        do {
            var full = ""
            for try await chunk in await client.streamConfirmChoice(
                choice: choice,
                title: decisionMessage.decisionTitle,
                recommendation: decisionMessage.recommendationRaw,
                reason: decisionMessage.reasonSummary,
                nickname: profile?.nickname ?? "你"
            ) {
                isThinking = false
                full += chunk
                applyStreamChunk(full, to: confirm, modelContext: modelContext)
            }
            flushStreamChunk(to: confirm, modelContext: modelContext, forcePersist: true)
            if confirm.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                confirm.text = "收到收到！🦆 最终决定是「\(choice)」啦～鸭鸭已经帮你记进决策历史，冲冲冲💛"
                streamingText = confirm.text
            }
        } catch {
            confirm.text = "收到收到！🦆 最终决定是「\(choice)」啦～鸭鸭已经帮你记进决策历史，冲冲冲💛"
            streamingText = confirm.text
            errorMessage = error.localizedDescription
        }

        if recordDecision {
            modelContext.insert(DecisionRecord(
                title: decisionMessage.decisionTitle.isEmpty ? "鸭鸭帮你拍板" : decisionMessage.decisionTitle,
                options: decisionMessage.options.joined(separator: " / "),
                recommendation: decisionMessage.recommendationRaw,
                reasonSummary: decisionMessage.reasonSummary,
                finalChoice: choice,
                attachmentKind: nil
            ))
        }
        confirm.isIncomplete = false
        activeDecisionMessageID = nil
        try? modelContext.save()
        endStreaming()
    }

    private func streamUndecidedReply(
        into followUp: ChatMessage,
        decisionMessage: ChatMessage,
        profile: UserProfile?,
        modelContext: ModelContext
    ) async {
        do {
            var full = ""
            for try await chunk in await client.streamStillUndecidedPrompt(
                nickname: profile?.nickname ?? "你",
                title: decisionMessage.decisionTitle,
                options: decisionMessage.options
            ) {
                isThinking = false
                full += chunk
                applyStreamChunk(full, to: followUp, modelContext: modelContext)
            }
            flushStreamChunk(to: followUp, modelContext: modelContext, forcePersist: true)
            if followUp.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                followUp.text = "你现在最纠结的是什么呢？🥺 能不能告诉鸭鸭，鸭鸭帮你继续分析～ 💭"
                streamingText = followUp.text
            }
            followUp.isIncomplete = false
            try? modelContext.save()
        } catch {
            followUp.text = "你现在最纠结的是什么呢？🥺 能不能告诉鸭鸭，鸭鸭帮你继续分析～ 💭"
            streamingText = followUp.text
            followUp.isIncomplete = false
            errorMessage = error.localizedDescription
            try? modelContext.save()
        }

        endStreaming()
    }

    private func beginStreaming(into message: ChatMessage, modelContext: ModelContext, resetText: Bool) {
        if resetText {
            message.text = ""
            message.optionsRaw = ""
            message.interactionKind = .none
        }
        message.isIncomplete = true
        streamingMessageID = message.id
        streamingText = ""
        activeDecisionMessageID = nil
        isThinking = true
        isStreaming = true
        pendingStreamFull = nil
        try? modelContext.save()
    }

    private func endStreaming() {
        isThinking = false
        isStreaming = false
        streamingMessageID = nil
        streamingText = ""
        pendingStreamFull = nil
    }

    private func finalizeInterrupted(_ message: ChatMessage, modelContext: ModelContext) {
        if message.displayText.isEmpty {
            message.text = "刚才输出被打断了 🥺 你再跟鸭鸭说一句，我们接着聊～"
        }
        message.isIncomplete = false
        message.interactionKind = .none
        try? modelContext.save()
    }

    func summarizeProfile(_ profile: UserProfile, modelContext: ModelContext, messages: [ChatMessage], decisions: [DecisionRecord]) async {
        isThinking = true
        errorMessage = nil
        do {
            profile.duckSummary = try await client.summarizeProfile(profile: profile, messages: messages, decisions: decisions)
            profile.updatedAt = .now
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
        isThinking = false
    }

    func transcribeRecording(_ url: URL) async {
        isThinking = true
        errorMessage = nil
        do {
            draft = try await client.transcribeAudio(fileURL: url)
        } catch {
            errorMessage = error.localizedDescription
        }
        isThinking = false
    }

    private func applyDecision(_ response: DecisionResponse, to message: ChatMessage) {
        let cleaned = DecisionStreamParser.dedupeOptions(response.options)
            .filter { $0 != DuckSpeech.stillUndecided }
        let recommendation = DecisionStreamParser.matchOption(response.recommendation, in: cleaned)
            ?? cleaned.first
            ?? response.recommendation
        message.interactionKind = .decision
        message.optionsRaw = cleaned.joined(separator: "|||")
        message.recommendationRaw = recommendation
        message.decisionTitle = response.title
        message.reasonSummary = response.reason
    }

    /// 合并刷新：约 50ms 刷一次 UI，避免每个极小 token 都触发 SwiftUI 重绘导致一卡一卡。
    private func applyStreamChunk(_ full: String, to message: ChatMessage, modelContext: ModelContext) {
        pendingStreamFull = full
        message.text = full
        let now = Date()
        if now.timeIntervalSince(lastStreamUIAt) >= 0.05 || streamingText.isEmpty {
            flushStreamChunk(to: message, modelContext: modelContext, forcePersist: false)
        }
    }

    private func flushStreamChunk(to message: ChatMessage, modelContext: ModelContext, forcePersist: Bool) {
        guard let full = pendingStreamFull ?? Optional(message.text) else { return }
        let visible = DecisionStreamParser.streamingDisplay(full)
        streamingText = visible
        message.text = full
        pendingStreamFull = nil
        lastStreamUIAt = Date()
        if forcePersist || Date().timeIntervalSince(lastStreamPersistAt) >= 0.45 {
            lastStreamPersistAt = Date()
            try? modelContext.save()
        }
    }
}

extension AttachmentKind {
    var label: String {
        switch self {
        case .image: return "图片"
        case .video: return "视频"
        case .audio: return "录音"
        }
    }

    var systemImage: String {
        switch self {
        case .image: return "photo"
        case .video: return "video"
        case .audio: return "waveform"
        }
    }
}
