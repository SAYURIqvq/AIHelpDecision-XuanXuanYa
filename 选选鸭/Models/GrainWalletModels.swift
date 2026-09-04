import Foundation
import SwiftData

@Model
final class GrainWallet {
    var id: UUID
    var paidGrains: Int
    var rechargeGiftGrains: Int
    var memberGiftGrains: Int
    /// 原有积分：仅展示/商城用，不可兑换谷粒
    var points: Int
    var freeChatLeft: Int
    var freeCallMinutesLeft: Int
    var freeQuotaDayKey: String
    var firstChargePackIDsRaw: String
    var updatedAt: Date

    init(
        paidGrains: Int = 0,
        rechargeGiftGrains: Int = 0,
        memberGiftGrains: Int = 0,
        points: Int = 120,
        freeChatLeft: Int = GrainCosts.freeChatPerDay,
        freeCallMinutesLeft: Int = GrainCosts.freeCallMinutesPerDay
    ) {
        self.id = UUID()
        self.paidGrains = paidGrains
        self.rechargeGiftGrains = rechargeGiftGrains
        self.memberGiftGrains = memberGiftGrains
        self.points = points
        self.freeChatLeft = freeChatLeft
        self.freeCallMinutesLeft = freeCallMinutesLeft
        self.freeQuotaDayKey = Self.dayKey(Date())
        self.firstChargePackIDsRaw = ""
        self.updatedAt = .now
    }

    var totalGrains: Int { paidGrains + rechargeGiftGrains + memberGiftGrains }

    var firstChargePackIDs: Set<String> {
        Set(firstChargePackIDsRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    func markFirstCharge(packID: String) {
        var ids = firstChargePackIDs
        ids.insert(packID)
        firstChargePackIDsRaw = ids.sorted().joined(separator: ",")
    }

    static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

@Model
final class MonthCardRecord {
    var id: UUID
    var planID: String
    var purchasedAt: Date
    var expiresAt: Date
    var lastClaimDayKey: String
    var createdAt: Date

    init(planID: String, purchasedAt: Date = .now, expiresAt: Date, lastClaimDayKey: String = "") {
        self.id = UUID()
        self.planID = planID
        self.purchasedAt = purchasedAt
        self.expiresAt = expiresAt
        self.lastClaimDayKey = lastClaimDayKey
        self.createdAt = .now
    }

    var isActive: Bool { expiresAt > Date() }

    var remainingDays: Int {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0
        return max(0, days + (expiresAt > Date() ? 1 : 0))
    }
}

enum GrainLedgerKind: String, Codable {
    case packPurchase
    case packGift
    case monthInstant
    case monthDaily
    case chatConsume
    case callConsume
    case pointsEarn
    case pointsSpend

    var title: String {
        switch self {
        case .packPurchase: return "直购谷粒"
        case .packGift: return "充值赠送谷粒"
        case .monthInstant: return "月卡即时发放谷粒"
        case .monthDaily: return "月卡每日领取谷粒"
        case .chatConsume: return "决策聊天消耗"
        case .callConsume: return "通话消耗"
        case .pointsEarn: return "积分收入"
        case .pointsSpend: return "积分支出"
        }
    }
}

@Model
final class GrainLedgerEntry {
    var id: UUID
    var createdAt: Date
    var kindRaw: String
    var title: String
    var grainDelta: Int
    var pointsDelta: Int
    var detail: String

    init(
        kind: GrainLedgerKind,
        title: String? = nil,
        grainDelta: Int = 0,
        pointsDelta: Int = 0,
        detail: String = "",
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.createdAt = createdAt
        self.kindRaw = kind.rawValue
        self.title = title ?? kind.title
        self.grainDelta = grainDelta
        self.pointsDelta = pointsDelta
        self.detail = detail
    }

    var kind: GrainLedgerKind { GrainLedgerKind(rawValue: kindRaw) ?? .packPurchase }
}
