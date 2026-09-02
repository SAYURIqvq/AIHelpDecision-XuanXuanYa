import Foundation
import SwiftData

enum DecisionStyle: String, Codable, CaseIterable, Identifiable {
    case decisive = "果断型"
    case cautious = "谨慎型"
    case intuitive = "直觉型"
    case analytical = "分析型"
    case spontaneous = "随和型"

    var id: String { rawValue }
}

enum MessageRole: String, Codable {
    case user
    case assistant
}

enum AttachmentKind: String, Codable {
    case image
    case video
    case audio
}

@Model
final class UserProfile {
    var nickname: String
    var avatarAssetName: String
    var decisionStyleRaw: String
    var preferences: String
    var commonScenarios: String
    var duckSummary: String
    var updatedAt: Date

    init(
        nickname: String = "byesayuri",
        avatarAssetName: String = "MascotChat",
        decisionStyle: DecisionStyle = .analytical,
        preferences: String = "",
        commonScenarios: String = ""
    ) {
        self.nickname = nickname
        self.avatarAssetName = avatarAssetName
        self.decisionStyleRaw = decisionStyle.rawValue
        self.preferences = preferences
        self.commonScenarios = commonScenarios
        self.duckSummary = ""
        self.updatedAt = .now
    }

    var decisionStyle: DecisionStyle {
        get { DecisionStyle(rawValue: decisionStyleRaw) ?? .analytical }
        set {
            decisionStyleRaw = newValue.rawValue
            updatedAt = .now
        }
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

    init(
        role: MessageRole,
        text: String,
        attachmentKind: AttachmentKind? = nil,
        attachmentFileName: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.roleRaw = role.rawValue
        self.text = text
        self.createdAt = createdAt
        self.attachmentKindRaw = attachmentKind?.rawValue
        self.attachmentFileName = attachmentFileName
    }

    var role: MessageRole { MessageRole(rawValue: roleRaw) ?? .assistant }
    var attachmentKind: AttachmentKind? {
        guard let attachmentKindRaw else { return nil }
        return AttachmentKind(rawValue: attachmentKindRaw)
    }
}

@Model
final class DecisionRecord {
    var id: UUID
    var title: String
    var options: String
    var recommendation: String
    var reasonSummary: String
    var attachmentKindRaw: String?
    var createdAt: Date

    init(
        title: String,
        options: String,
        recommendation: String,
        reasonSummary: String,
        attachmentKind: AttachmentKind? = nil,
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.title = title
        self.options = options
        self.recommendation = recommendation
        self.reasonSummary = reasonSummary
        self.attachmentKindRaw = attachmentKind?.rawValue
        self.createdAt = createdAt
    }
}

