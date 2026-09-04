import Foundation
import SwiftData
import UIKit

enum DecisionStyle {
    static let presets: [String] = [
        "躺平但不彻底型",
        "人间清醒型",
        "社恐纠结型",
        "冲就完了型",
        "先睡一觉型",
        "情绪上头型",
        "性价比战士型"
    ]

    static let fallback = "人间清醒型"
}

enum DuckSpeech {
    static let stillUndecided = "我还没有纠结好"

    static let persona = """
    你是“选选鸭”，一只软萌、碎嘴但很会拍板的小黄鸭决策搭子。
    说话风格要求：
    - 像好朋友聊天，萌一点、口语一点，不要公文腔、不要太官方
    - 适度使用可爱 emoji（每段 2-5 个即可，如 🦆✨💭💛🥺👉），别刷屏
    - 常自称“鸭鸭”，可夹一点语气词：呀、啦、捏、鸭、嘿嘿、冲冲
    - 必须给明确建议，别只说“看情况”
    - 共情用户纠结，但最后还是要帮人落地
    - 严禁使用 markdown：不要用 ** *** # ` - 列表符号等任何标记，只用纯中文自然段落
    """
}

enum MessageRole: String, Codable {
    case user
    case assistant
}

enum MessageInteractionKind: String, Codable {
    case none
    case chips
    case decision
}

enum AttachmentKind: String, Codable {
    case image
    case video
    case audio
}

struct PendingAttachment: Identifiable, Equatable {
    let id: UUID
    let kind: AttachmentKind
    let relativePath: String

    init(id: UUID = UUID(), kind: AttachmentKind, relativePath: String) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
    }

    var fileName: String {
        (relativePath as NSString).lastPathComponent
    }
}

@Model
final class UserProfile {
    var nickname: String
    var avatarAssetName: String
    var decisionStyleRaw: String
    /// 决策标签（含测试回填 + 自定义），用 ||| 分隔
    var decisionTagsRaw: String = ""
    /// 用户自定义头像相对路径（Documents 下），优先于 avatarAssetName
    var avatarRelativePath: String = ""
    var preferences: String
    var commonScenarios: String
    var duckSummary: String
    /// 个性签名
    var signature: String = ""
    var updatedAt: Date

    init(
        nickname: String = "byesayuri",
        avatarAssetName: String = "UserAvatar",
        decisionStyle: String = DecisionStyle.fallback,
        preferences: String = "",
        commonScenarios: String = "",
        signature: String = ""
    ) {
        self.nickname = nickname
        self.avatarAssetName = avatarAssetName
        self.decisionStyleRaw = decisionStyle
        self.decisionTagsRaw = decisionStyle
        self.avatarRelativePath = ""
        self.preferences = preferences
        self.commonScenarios = commonScenarios
        self.duckSummary = ""
        self.signature = signature
        self.updatedAt = .now
    }

    var decisionTags: [String] {
        decisionTagsRaw
            .components(separatedBy: "|||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func setDecisionTags(_ tags: [String]) {
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var unique: [String] = []
        for tag in cleaned where !unique.contains(tag) {
            unique.append(tag)
        }
        decisionTagsRaw = unique.joined(separator: "|||")
        decisionStyleRaw = unique.first ?? DecisionStyle.fallback
        updatedAt = .now
    }

    func addDecisionTag(_ tag: String) {
        var tags = decisionTags
        let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !tags.contains(t) else { return }
        tags.append(t)
        setDecisionTags(tags)
    }

    func removeDecisionTag(_ tag: String) {
        setDecisionTags(decisionTags.filter { $0 != tag })
    }

    var hasCustomAvatar: Bool {
        !avatarRelativePath.isEmpty && AttachmentStore.fileURL(relativePath: avatarRelativePath) != nil
    }

    var avatarUIImage: UIImage? {
        if hasCustomAvatar {
            return AttachmentStore.loadImage(relativePath: avatarRelativePath)
        }
        let name = avatarAssetName.isEmpty ? "UserAvatar" : avatarAssetName
        return UIImage(named: name)
    }

    func setCustomAvatar(relativePath: String) {
        avatarRelativePath = relativePath
        avatarAssetName = "UserAvatar"
        updatedAt = .now
    }

    func clearCustomAvatar() {
        if let url = AttachmentStore.fileURL(relativePath: avatarRelativePath) {
            try? FileManager.default.removeItem(at: url)
        }
        avatarRelativePath = ""
        updatedAt = .now
    }
}

@Model
final class QuizResult {
    var id: UUID
    var kindRaw: String
    var title: String
    var primaryTag: String
    var tagsRaw: String
    var summary: String
    var detail: String
    var createdAt: Date

    init(
        kind: QuizKind,
        title: String,
        primaryTag: String,
        tags: [String],
        summary: String,
        detail: String = "",
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.title = title
        self.primaryTag = primaryTag
        self.tagsRaw = tags.joined(separator: "|||")
        self.summary = summary
        self.detail = detail
        self.createdAt = createdAt
    }

    var kind: QuizKind { QuizKind(rawValue: kindRaw) ?? .decisionStyle }

    var tags: [String] {
        tagsRaw.components(separatedBy: "|||").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

@Model
final class ChatMessage {
    var id: UUID
    var roleRaw: String
    var text: String
    var createdAt: Date
    var attachmentKindRaw: String?
    var attachmentFileName: String?
    /// Documents 相对路径，如 Attachments/duck-xxx.jpg
    var attachmentRelativePath: String?
    /// none / chips（闲聊话题） / decision（真正要拍板）
    var interactionKindRaw: String = MessageInteractionKind.none.rawValue
    var optionsRaw: String = ""
    var selectedOption: String = ""
    var recommendationRaw: String = ""
    var decisionTitle: String = ""
    var reasonSummary: String = ""
    /// 引用的原文（用户回复某条消息时）
    var quotedText: String = ""
    /// user / assistant
    var quotedFromRoleRaw: String = ""
    /// 流式输出未完成（含冷启动中断）；为 true 时应显示加载并尝试续传
    var isIncomplete: Bool = false

    init(
        role: MessageRole,
        text: String,
        attachmentKind: AttachmentKind? = nil,
        attachmentFileName: String? = nil,
        attachmentRelativePath: String? = nil,
        options: [String] = [],
        selectedOption: String = "",
        recommendation: String = "",
        decisionTitle: String = "",
        reasonSummary: String = "",
        quotedText: String = "",
        quotedFromRole: MessageRole? = nil,
        isIncomplete: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.roleRaw = role.rawValue
        self.text = text
        self.createdAt = createdAt
        self.attachmentKindRaw = attachmentKind?.rawValue
        self.attachmentFileName = attachmentFileName
        self.attachmentRelativePath = attachmentRelativePath
        self.interactionKindRaw = MessageInteractionKind.none.rawValue
        self.optionsRaw = options.joined(separator: "|||")
        self.selectedOption = selectedOption
        self.recommendationRaw = recommendation
        self.decisionTitle = decisionTitle
        self.reasonSummary = reasonSummary
        self.quotedText = quotedText
        self.quotedFromRoleRaw = quotedFromRole?.rawValue ?? ""
        self.isIncomplete = isIncomplete
    }

    var role: MessageRole { MessageRole(rawValue: roleRaw) ?? .assistant }
    var attachmentKind: AttachmentKind? {
        guard let attachmentKindRaw else { return nil }
        return AttachmentKind(rawValue: attachmentKindRaw)
    }

    var interactionKind: MessageInteractionKind {
        get {
            if let kind = MessageInteractionKind(rawValue: interactionKindRaw), kind != .none {
                return kind
            }
            // 兼容旧数据：以前有 options 但没有 kind，一律当真正决策
            return optionsRaw.isEmpty ? .none : .decision
        }
        set { interactionKindRaw = newValue.rawValue }
    }

    var options: [String] {
        guard !optionsRaw.isEmpty else { return [] }
        return optionsRaw
            .components(separatedBy: "|||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var displayText: String {
        var raw = text
        for marker in ["<<<OPTIONS>>>", "<<<CHIPS>>>"] {
            if let range = raw.range(of: marker) {
                raw = String(raw[..<range.lowerBound])
            }
        }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return role == .assistant ? DuckTextSanitizer.plain(raw) : raw
    }

    var hasQuote: Bool { !quotedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var quotedFromRole: MessageRole? {
        MessageRole(rawValue: quotedFromRoleRaw)
    }

    var quotedFromLabel: String {
        switch quotedFromRole {
        case .assistant: return "鸭鸭"
        case .user: return "我"
        case .none: return "消息"
        }
    }

    /// 发给模型时带上引用语境
    var promptText: String {
        let body = displayText
        guard hasQuote else { return body }
        let quote = quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return "【用户正在引用/回复 \(quotedFromLabel) 的这句话】\n「\(quote)」\n【用户新说】\n\(body)"
    }

    var hasInteractiveOptions: Bool { !options.isEmpty && interactionKind != .none }
    var hasDecisionOptions: Bool { interactionKind == .decision && !options.isEmpty }
    var hasChatChips: Bool { interactionKind == .chips && !options.isEmpty }

    var isStillUndecidedSelection: Bool {
        selectedOption == DuckSpeech.stillUndecided
    }

    var attachmentImage: UIImage? {
        AttachmentStore.loadImage(relativePath: attachmentPaths.first ?? attachmentRelativePath)
    }

    /// 支持多图：相对路径用 ||| 分隔。
    var attachmentPaths: [String] {
        guard let attachmentRelativePath, !attachmentRelativePath.isEmpty else { return [] }
        return attachmentRelativePath
            .components(separatedBy: "|||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var hasAttachments: Bool { !attachmentPaths.isEmpty || attachmentKind != nil }
}

@Model
final class DecisionRecord {
    var id: UUID
    var title: String
    var options: String
    var recommendation: String
    var reasonSummary: String
    var finalChoice: String = ""
    var attachmentKindRaw: String?
    var createdAt: Date

    init(
        title: String,
        options: String,
        recommendation: String,
        reasonSummary: String,
        finalChoice: String,
        attachmentKind: AttachmentKind? = nil,
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.title = title
        self.options = options
        self.recommendation = recommendation
        self.reasonSummary = reasonSummary
        self.finalChoice = finalChoice
        self.attachmentKindRaw = attachmentKind?.rawValue
        self.createdAt = createdAt
    }
}
