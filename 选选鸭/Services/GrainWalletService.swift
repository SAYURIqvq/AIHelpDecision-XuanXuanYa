import Foundation
import SwiftData

enum GrainSpendResult: Equatable {
    case ok(usedFree: Bool, grainsSpent: Int)
    case exhausted
}

@MainActor
enum GrainWalletService {
    static func ensureWallet(in context: ModelContext) -> GrainWallet {
        let descriptor = FetchDescriptor<GrainWallet>()
        if let existing = try? context.fetch(descriptor).first {
            refreshFreeQuotaIfNeeded(existing)
            return existing
        }
        let wallet = GrainWallet()
        context.insert(wallet)
        try? context.save()
        return wallet
    }

    static func refreshFreeQuotaIfNeeded(_ wallet: GrainWallet) {
        let today = GrainWallet.dayKey(Date())
        guard wallet.freeQuotaDayKey != today else { return }
        wallet.freeQuotaDayKey = today
        wallet.freeChatLeft = GrainCosts.freeChatPerDay
        wallet.freeCallMinutesLeft = GrainCosts.freeCallMinutesPerDay
        wallet.updatedAt = .now
    }

    static func activeCards(in context: ModelContext) -> [MonthCardRecord] {
        let now = Date()
        let descriptor = FetchDescriptor<MonthCardRecord>(
            predicate: #Predicate { $0.expiresAt > now },
            sortBy: [SortDescriptor(\.expiresAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func remainingDays(for planID: String, in context: ModelContext) -> Int {
        activeCards(in: context)
            .filter { $0.planID == planID }
            .map(\.remainingDays)
            .max() ?? 0
    }

    static func claimableDailyTotal(in context: ModelContext) -> Int {
        let today = GrainWallet.dayKey(Date())
        return activeCards(in: context)
            .filter { $0.lastClaimDayKey != today }
            .compactMap { GrainCatalog.monthCard(id: $0.planID)?.dailyGrains }
            .reduce(0, +)
    }

    static func claimDailyGrains(wallet: GrainWallet, context: ModelContext) -> Int {
        refreshFreeQuotaIfNeeded(wallet)
        let today = GrainWallet.dayKey(Date())
        var gained = 0
        for card in activeCards(in: context) where card.lastClaimDayKey != today {
            guard let plan = GrainCatalog.monthCard(id: card.planID) else { continue }
            wallet.memberGiftGrains += plan.dailyGrains
            card.lastClaimDayKey = today
            gained += plan.dailyGrains
            context.insert(GrainLedgerEntry(
                kind: .monthDaily,
                grainDelta: plan.dailyGrains,
                detail: "\(plan.cardName) 每日口粮"
            ))
        }
        if gained > 0 {
            wallet.updatedAt = .now
            try? context.save()
        }
        return gained
    }

    static func purchasePack(_ pack: GrainPack, wallet: GrainWallet, context: ModelContext) {
        refreshFreeQuotaIfNeeded(wallet)
        let isFirst = !wallet.firstChargePackIDs.contains(pack.id)
        let paid = isFirst ? pack.grains * 2 : pack.grains
        let gift = isFirst ? pack.giftGrains * 2 : pack.giftGrains
        wallet.paidGrains += paid
        wallet.rechargeGiftGrains += gift
        if isFirst { wallet.markFirstCharge(packID: pack.id) }
        wallet.updatedAt = .now
        context.insert(GrainLedgerEntry(
            kind: .packPurchase,
            grainDelta: paid,
            detail: "\(pack.name)\(isFirst ? " · 首充双倍" : "")"
        ))
        if gift > 0 {
            context.insert(GrainLedgerEntry(
                kind: .packGift,
                grainDelta: gift,
                detail: "\(pack.name) 赠送\(isFirst ? " · 首充双倍" : "")"
            ))
        }
        try? context.save()
    }

    static func purchaseMonthCard(_ plan: MonthCardPlan, wallet: GrainWallet, context: ModelContext) {
        refreshFreeQuotaIfNeeded(wallet)
        let sameTier = activeCards(in: context).filter { $0.planID == plan.id }
        let base = sameTier.map(\.expiresAt).max() ?? Date()
        let start = max(base, Date())
        let expires = Calendar.current.date(byAdding: .day, value: plan.durationDays, to: start) ?? start.addingTimeInterval(TimeInterval(plan.durationDays * 86400))
        let record = MonthCardRecord(planID: plan.id, expiresAt: expires)
        context.insert(record)

        wallet.memberGiftGrains += plan.instantGrains
        wallet.updatedAt = .now
        context.insert(GrainLedgerEntry(
            kind: .monthInstant,
            grainDelta: plan.instantGrains,
            detail: "\(plan.cardName) 即时到账"
        ))
        try? context.save()
    }

    /// 聊天一轮：先免费用次，再按优先级扣谷粒。
    static func consumeChatRound(wallet: GrainWallet, context: ModelContext) -> GrainSpendResult {
        refreshFreeQuotaIfNeeded(wallet)
        if wallet.freeChatLeft > 0 {
            wallet.freeChatLeft -= 1
            wallet.updatedAt = .now
            try? context.save()
            return .ok(usedFree: true, grainsSpent: 0)
        }
        guard spendGrains(GrainCosts.chatRound, wallet: wallet) else {
            return .exhausted
        }
        context.insert(GrainLedgerEntry(
            kind: .chatConsume,
            grainDelta: -GrainCosts.chatRound,
            detail: "一轮决策问答"
        ))
        wallet.updatedAt = .now
        try? context.save()
        return .ok(usedFree: false, grainsSpent: GrainCosts.chatRound)
    }

    /// 通话计费：免费分钟优先；语音 2 谷粒/分钟，视频 5 谷粒/分钟。
    static func consumeCall(
        seconds: TimeInterval,
        mode: DuckCallMode,
        wallet: GrainWallet,
        context: ModelContext
    ) -> GrainSpendResult {
        refreshFreeQuotaIfNeeded(wallet)
        let rate = mode == .voice ? GrainCosts.voiceCallPerMinute : GrainCosts.videoCallPerMinute
        let minutes = max(1, Int(ceil(max(0, seconds) / 60.0)))
        let freeAvailable = wallet.freeCallMinutesLeft
        let freeUsed = min(freeAvailable, minutes)
        let billable = minutes - freeUsed
        let cost = billable * rate

        wallet.freeCallMinutesLeft = freeAvailable - freeUsed

        if cost > 0, wallet.totalGrains < cost {
            wallet.updatedAt = .now
            try? context.save()
            return .exhausted
        }

        if cost > 0 {
            _ = spendGrains(cost, wallet: wallet)
            let kindLabel = mode == .voice ? "语音通话" : "视频通话"
            context.insert(GrainLedgerEntry(
                kind: .callConsume,
                grainDelta: -cost,
                detail: "\(kindLabel) \(minutes) 分钟（免费抵扣后计费 \(billable) 分钟 · \(rate)谷粒/分钟）"
            ))
        }
        wallet.updatedAt = .now
        try? context.save()
        return .ok(usedFree: freeUsed > 0, grainsSpent: cost)
    }

    static func canStartChat(wallet: GrainWallet) -> Bool {
        refreshFreeQuotaIfNeeded(wallet)
        return wallet.freeChatLeft > 0 || wallet.totalGrains >= GrainCosts.chatRound
    }

    static func canStartCall(wallet: GrainWallet, mode: DuckCallMode = .voice) -> Bool {
        refreshFreeQuotaIfNeeded(wallet)
        let rate = mode == .voice ? GrainCosts.voiceCallPerMinute : GrainCosts.videoCallPerMinute
        return wallet.freeCallMinutesLeft > 0 || wallet.totalGrains >= rate
    }

    /// 消耗顺序：会员赠送 → 充值赠送 → 付费购买
    @discardableResult
    private static func spendGrains(_ amount: Int, wallet: GrainWallet) -> Bool {
        guard amount > 0, wallet.totalGrains >= amount else { return false }
        var left = amount
        let member = min(wallet.memberGiftGrains, left)
        wallet.memberGiftGrains -= member
        left -= member
        let gift = min(wallet.rechargeGiftGrains, left)
        wallet.rechargeGiftGrains -= gift
        left -= gift
        wallet.paidGrains -= left
        return true
    }
}
