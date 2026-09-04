import Foundation

enum GrainCosts {
    static let chatRound = 1
    static let voiceCallPerMinute = 2
    static let videoCallPerMinute = 5
    static let freeChatPerDay = 8
    static let freeCallMinutesPerDay = 3
}

enum GrainBucket: String, CaseIterable {
    case memberGift
    case rechargeGift
    case paid

    var title: String {
        switch self {
        case .memberGift: return "会员赠送谷粒"
        case .rechargeGift: return "充值赠送谷粒"
        case .paid: return "付费谷粒"
        }
    }
}

struct GrainPack: Identifiable, Hashable {
    let id: String
    let name: String
    let priceYuan: Decimal
    let grains: Int
    let giftGrains: Int
    let accent: String

    var totalGrains: Int { grains + giftGrains }
    var priceLabel: String { "¥\(NSDecimalNumber(decimal: priceYuan).stringValue)" }
}

struct MonthCardPlan: Identifiable, Hashable {
    let id: String
    let seriesName: String
    let cardName: String
    let priceYuan: Decimal
    let instantGrains: Int
    let dailyGrains: Int
    let durationDays: Int
    let audience: String
    let perks: [String]
    let accent: String

    var monthlyTotal: Int { instantGrains + dailyGrains * durationDays }
    var priceLabel: String { "¥\(NSDecimalNumber(decimal: priceYuan).stringValue)" }
    var openButtonTitle: String { "\(priceLabel) 开通\(cardName)" }
}

enum GrainCatalog {
    static let packs: [GrainPack] = [
        .init(id: "pack_6", name: "小鸭小食包", priceYuan: 6, grains: 60, giftGrains: 5, accent: "seed"),
        .init(id: "pack_30", name: "河畔谷粮包", priceYuan: 30, grains: 300, giftGrains: 35, accent: "river"),
        .init(id: "pack_68", name: "丰谷乐享包", priceYuan: 68, grains: 680, giftGrains: 100, accent: "harvest"),
        .init(id: "pack_128", name: "金穗盛宴包", priceYuan: 128, grains: 1280, giftGrains: 220, accent: "gold"),
        .init(id: "pack_328", name: "水岸尊享包", priceYuan: 328, grains: 3280, giftGrains: 650, accent: "shore"),
        .init(id: "pack_648", name: "满仓典藏包", priceYuan: 648, grains: 6480, giftGrains: 1400, accent: "vault")
    ]

    static let monthCards: [MonthCardPlan] = [
        .init(
            id: "card_entry",
            seriesName: "入门鸭粮卡",
            cardName: "小鸭口粮卡",
            priceYuan: 9.9,
            instantGrains: 120,
            dailyGrains: 30,
            durationDays: 30,
            audience: "偶尔纠结、轻度聊天",
            perks: ["会员专属鸭鸭头像框", "排队优先", "去掉部分弹窗广告"],
            accent: "entry"
        ),
        .init(
            id: "card_plus",
            seriesName: "进阶鸭粮卡",
            cardName: "河畔丰谷卡",
            priceYuan: 19.9,
            instantGrains: 300,
            dailyGrains: 60,
            durationDays: 30,
            audience: "高频决策、每周多通视频",
            perks: ["包含入门全部特权", "视频通话画质提升", "会话历史保存 90 天"],
            accent: "plus"
        ),
        .init(
            id: "card_pro",
            seriesName: "尊享鸭粮卡",
            cardName: "金穗典藏卡",
            priceYuan: 32,
            instantGrains: 600,
            dailyGrains: 110,
            durationDays: 30,
            audience: "每天大量咨询与长通话",
            perks: ["包含进阶全部特权", "最高优先级响应", "会话永久云端保存", "专属反馈通道"],
            accent: "pro"
        )
    ]

    static func pack(id: String) -> GrainPack? { packs.first { $0.id == id } }
    static func monthCard(id: String) -> MonthCardPlan? { monthCards.first { $0.id == id } }
}
