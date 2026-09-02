import Foundation
import SwiftData

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var draft = ""
    @Published var isThinking = false
    @Published var errorMessage: String?
    @Published var pendingAttachmentKind: AttachmentKind?
    @Published var pendingAttachmentFileName: String?

    private let client = OpenRouterClient()

    func attach(kind: AttachmentKind, fileName: String) {
        pendingAttachmentKind = kind
        pendingAttachmentFileName = fileName
    }

    func send(modelContext: ModelContext, profile: UserProfile?, recentMessages: [ChatMessage]) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || pendingAttachmentKind != nil else { return }

        let userText = text.isEmpty ? "我发了一个\(pendingAttachmentKind?.label ?? "附件")，请帮我做决定。" : text
        let attachmentKind = pendingAttachmentKind
        let attachmentFileName = pendingAttachmentFileName
        draft = ""
        pendingAttachmentKind = nil
        pendingAttachmentFileName = nil

        let userMessage = ChatMessage(role: .user, text: userText, attachmentKind: attachmentKind, attachmentFileName: attachmentFileName)
        modelContext.insert(userMessage)

        isThinking = true
        errorMessage = nil
        do {
            let response = try await client.askDecision(
                prompt: userText,
                profile: profile,
                recentMessages: recentMessages + [userMessage],
                attachmentKind: attachmentKind
            )
            let reply = """
            建议：\(response.recommendation)

            理由：\(response.reason)

            下一步：\(response.nextStep)
            """
            modelContext.insert(ChatMessage(role: .assistant, text: reply))
            modelContext.insert(DecisionRecord(
                title: response.title,
                options: response.options.joined(separator: " / "),
                recommendation: response.recommendation,
                reasonSummary: response.reason,
                attachmentKind: attachmentKind
            ))
            try modelContext.save()
        } catch {
            let fallback = """
            建议：先选成本更低、可逆性更强的那个。

            理由：当前 AI 请求没有完成，鸭鸭先给你一个稳妥规则：纠结时优先选试错成本低、能最快获得反馈的方案。

            下一步：把两个选项的价格、时间成本和后悔成本各写一句，我再帮你拍板。
            """
            modelContext.insert(ChatMessage(role: .assistant, text: fallback))
            errorMessage = error.localizedDescription
        }
        isThinking = false
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

