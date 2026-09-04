import Foundation

enum QuizKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case decisionStyle
    case mbti
    case choiceAnxiety
    case preference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .decisionStyle: return "决策风格人格"
        case .mbti: return "鸭鸭版 MBTI"
        case .choiceAnxiety: return "选择困难症指数"
        case .preference: return "个人偏好雷达"
        }
    }

    var subtitle: String {
        switch self {
        case .decisionStyle: return "测测你拍板时更像哪种鸭"
        case .mbti: return "16 型人格 × 决策口吻"
        case .choiceAnxiety: return "你纠结到什么程度了？"
        case .preference: return "吃喝玩乐买，偏好一眼看清"
        }
    }

    var imageName: String {
        switch self {
        case .decisionStyle: return "QuizStyleDuck"
        case .mbti: return "QuizMBTIDuck"
        case .choiceAnxiety: return "QuizChoiceDuck"
        case .preference: return "QuizPrefDuck"
        }
    }

    var accentLabel: String {
        switch self {
        case .decisionStyle: return "风格"
        case .mbti: return "MBTI"
        case .choiceAnxiety: return "纠结度"
        case .preference: return "偏好"
        }
    }
}

struct QuizQuestion: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let options: [String]
    /// Optional scoring axis for local result (e.g. MBTI E/I)
    var scores: [[String: Int]] = []
}

struct QuizDefinition: Identifiable {
    let kind: QuizKind
    let questions: [QuizQuestion]

    var id: String { kind.id }
    var title: String { kind.title }
    var subtitle: String { kind.subtitle }
    var imageName: String { kind.imageName }
}

enum QuizCatalog {
    static let all: [QuizDefinition] = [
        .init(kind: .decisionStyle, questions: decisionStyleQuestions),
        .init(kind: .mbti, questions: mbtiQuestions),
        .init(kind: .choiceAnxiety, questions: choiceAnxietyQuestions),
        .init(kind: .preference, questions: preferenceQuestions)
    ]

    static func definition(for kind: QuizKind) -> QuizDefinition {
        all.first { $0.kind == kind } ?? all[0]
    }

    static let decisionStyleQuestions: [QuizQuestion] = [
        .init(title: "朋友约你周末出门，你还在纠结去不去？", options: ["秒回“冲”，到了再说", "先看天气/通勤/钱，再决定", "想去但社恐，最后鸽了概率很高", "躺着刷手机，明天再说"]),
        .init(title: "点外卖选了十分钟还没下单，你会？", options: ["直接点上次那家，结束纠结", "开两家对比评分和配送", "问群友“你们吃啥”甩锅", "饿着等优惠券/满减更香"]),
        .init(title: "购物车里两件都想买但只能留一件？", options: ["闭眼买更贵的，贵有贵的道理", "算性价比，谁耐造选谁", "看评论区骂战，跟着风向走", "都先不加，过两天欲望降温"]),
        .init(title: "工作机会来了，但现在也还行，你？", options: ["机会不等人，先跳了再说", "列优缺点表，冷静分析一周", "问问信任的人，听完再定", "先睡一觉，梦到啥算啥"]),
        .init(title: "朋友让你帮选 A/B，你通常？", options: ["直接给答案，别给我整虚的", "两边都夸完再说“看你更在意啥”", "反问一堆细节再下结论", "说“都行”，把选择权扔回去"]),
        .init(title: "约会穿哪套衣服最纠结时？", options: ["凭第一眼感觉，穿上就出门", "对着镜子试到满意为止", "发朋友圈投票让网友决定", "随便套一件，颜值靠脸"]),
        .init(title: "看到限时优惠，你的第一反应？", options: ["怕错过，立刻下单", "冷静查比价，真香再买", "心动但怕踩坑，先收藏", "无视，省钱才是硬道理"]),
        .init(title: "团队意见不合，你怎么拍板？", options: ["我拍板我负责，冲就完了", "找数据说服大家", "先照顾气氛，慢慢统一", "能拖就拖，等形势明朗"]),
        .init(title: "情绪很差的时候做决定，你更容易？", options: ["上头乱选，事后后悔复盘", "知道状态差，强制推迟决定", "找人倾诉，靠情绪价值做选择", "用购物/吃喝转移注意力"]),
        .init(title: "如果鸭鸭给你一个“专属决策外号”，你希望它更像？", options: ["果断狠人，绝不内耗", "人间清醒，性价比战士", "温柔纠结怪，但终会落地", "随缘佛系，躺平但不彻底"])
    ]

    static let mbtiQuestions: [QuizQuestion] = [
        .init(title: "周末突然有空，你更想？", options: ["约人出门热闹一下", "一个人安静充电"], scores: [["E": 2], ["I": 2]]),
        .init(title: "做决定时你更信？", options: ["看得见的事实和细节", "脑内直觉和整体感觉"], scores: [["S": 2], ["N": 2]]),
        .init(title: "朋友哭着找你，你第一反应？", options: ["先讲道理帮 TA 拆解问题", "先共情抱抱，再慢慢说"], scores: [["T": 2], ["F": 2]]),
        .init(title: "旅行你会？", options: ["先排好行程表再出发", "走到哪玩到哪"], scores: [["J": 2], ["P": 2]]),
        .init(title: "群聊消息爆炸时？", options: ["基本秒回，气氛靠我撑", "默默已读，择机回复"], scores: [["E": 2], ["I": 2]]),
        .init(title: "学新东西更喜欢？", options: ["按步骤练到手会", "先搞懂为什么再动手"], scores: [["S": 2], ["N": 2]]),
        .init(title: "争论时你更在意？", options: ["谁更有道理、逻辑通不通", "关系会不会受伤"], scores: [["T": 2], ["F": 2]]),
        .init(title: "DDL 来临前你通常？", options: ["提前做完，心里踏实", "临门一脚爆发力"], scores: [["J": 2], ["P": 2]])
    ]

    static let choiceAnxietyQuestions: [QuizQuestion] = [
        .init(title: "点菜超过多久你会开始烦自己？", options: ["1 分钟内就定", "3–5 分钟", "10 分钟还在换", "别人都等急了我还在看"], scores: [["level": 0], ["level": 1], ["level": 2], ["level": 3]]),
        .init(title: "两个都还行的选项，你？", options: ["随便挑一个冲", "再找第三个对比", "反复横跳到最后随便", "干脆都不选"], scores: [["level": 0], ["level": 1], ["level": 2], ["level": 3]]),
        .init(title: "买完东西后你会？", options: ["几乎不后悔", "偶尔后悔但能接受", "经常翻评价自我攻击", "退货比呼吸还频繁"], scores: [["level": 0], ["level": 1], ["level": 2], ["level": 3]]),
        .init(title: "别人催你快点选，你？", options: ["更能快速落地", "心里更慌更选不动", "甩锅让别人定", "直接摆烂不选"], scores: [["level": 0], ["level": 2], ["level": 2], ["level": 3]]),
        .init(title: "重要决定你会拖多久？", options: ["当天搞定", "拖一两天", "拖一周以上", "能拖到黄花菜凉"], scores: [["level": 0], ["level": 1], ["level": 2], ["level": 3]]),
        .init(title: "信息越多你越？", options: ["越清晰", "有帮助但费劲", "越看越乱", "直接信息过载关机"], scores: [["level": 0], ["level": 1], ["level": 2], ["level": 3]]),
        .init(title: "如果有「鸭鸭代你选」按钮？", options: ["偶尔用用也好", "关键场合很想按", "日常就想外包决策", "求你每天帮我按"], scores: [["level": 0], ["level": 1], ["level": 2], ["level": 3]]),
        .init(title: "你觉得自己选择困难？", options: ["几乎没有", "一点点", "挺严重", "重度患者本鸭"], scores: [["level": 0], ["level": 1], ["level": 2], ["level": 3]])
    ]

    static let preferenceQuestions: [QuizQuestion] = [
        .init(title: "午饭你更倾向？", options: ["快、饱、不踩雷", "好吃优先，愿意多等", "清淡健康", "猎奇尝鲜"]),
        .init(title: "买电子产品你最看重？", options: ["性价比", "品牌口碑", "颜值和手感", "功能拉满"]),
        .init(title: "周末理想状态？", options: ["宅家回血", "短途走走", "热闹社交", "深度学习充电"]),
        .init(title: "花钱态度更接近？", options: ["能省则省", "该花就花但不冲动", "体验优先", "情绪消费选手"]),
        .init(title: "做决定时你最讨厌？", options: ["选项太多", "信息不足", "被人催", "选错被嘲笑"]),
        .init(title: "鸭鸭给你建议时，你希望？", options: ["直接给答案", "给理由再推荐", "多给备选", "先问清楚再拍板"]),
        .init(title: "衣服风格偏好？", options: ["基础百搭", "潮流好看", "舒适第一", "正式利落"]),
        .init(title: "一句话形容你的生活关键词？", options: ["效率至上", "松弛感", "精致一点", "随缘快乐"])
    ]
}

enum QuizLocalScorer {
    static func score(kind: QuizKind, questions: [QuizQuestion], answers: [Int]) -> (primary: String, tags: [String], detail: String) {
        switch kind {
        case .mbti:
            return scoreMBTI(questions: questions, answers: answers)
        case .choiceAnxiety:
            return scoreChoiceAnxiety(questions: questions, answers: answers)
        case .preference:
            return scorePreference(questions: questions, answers: answers)
        case .decisionStyle:
            return ("", [], "")
        }
    }

    private static func scoreMBTI(questions: [QuizQuestion], answers: [Int]) -> (String, [String], String) {
        var totals: [String: Int] = [:]
        for (q, a) in zip(questions, answers) where a >= 0 && a < q.scores.count {
            for (k, v) in q.scores[a] { totals[k, default: 0] += v }
        }
        let e = (totals["E"] ?? 0) >= (totals["I"] ?? 0) ? "E" : "I"
        let s = (totals["S"] ?? 0) >= (totals["N"] ?? 0) ? "S" : "N"
        let t = (totals["T"] ?? 0) >= (totals["F"] ?? 0) ? "T" : "F"
        let j = (totals["J"] ?? 0) >= (totals["P"] ?? 0) ? "J" : "P"
        let code = "\(e)\(s)\(t)\(j)"
        let nick = mbtiNickname(code)
        return (code, [code, nick, "MBTI·\(code)"], "鸭鸭判你更接近 \(code)（\(nick)）")
    }

    private static func mbtiNickname(_ code: String) -> String {
        switch code {
        case "INTJ": return "策略建筑师鸭"
        case "INTP": return "逻辑拆解鸭"
        case "ENTJ": return "指挥官冲锋鸭"
        case "ENTP": return "灵感抬杠鸭"
        case "INFJ": return "温柔洞察鸭"
        case "INFP": return "理想主义鸭"
        case "ENFJ": return "氛围团宠鸭"
        case "ENFP": return "热情火花鸭"
        case "ISTJ": return "靠谱清单鸭"
        case "ISFJ": return "细心守护鸭"
        case "ESTJ": return "执行落地鸭"
        case "ESFJ": return "热心管家鸭"
        case "ISTP": return "冷静动手鸭"
        case "ISFP": return "感观美学鸭"
        case "ESTP": return "现场行动鸭"
        case "ESFP": return "舞台快乐鸭"
        default: return "神秘人格鸭"
        }
    }

    private static func scoreChoiceAnxiety(questions: [QuizQuestion], answers: [Int]) -> (String, [String], String) {
        var sum = 0
        var count = 0
        for (q, a) in zip(questions, answers) where a >= 0 && a < q.scores.count {
            sum += q.scores[a]["level"] ?? a
            count += 1
        }
        let avg = count == 0 ? 0.0 : Double(sum) / Double(count)
        let level: String
        let tag: String
        switch avg {
        case ..<0.8:
            level = "轻度选择困难"
            tag = "偶尔纠结"
        case ..<1.6:
            level = "中度选择困难"
            tag = "选择困难·中度"
        case ..<2.3:
            level = "重度选择困难"
            tag = "选择困难·重度"
        default:
            level = "终极纠结体质"
            tag = "选择困难·拉满"
        }
        let score100 = Int(min(100, (avg / 3.0) * 100))
        return (level, [level, tag, "纠结指数\(score100)"], "纠结指数约 \(score100)/100 · \(level)")
    }

    private static func scorePreference(questions: [QuizQuestion], answers: [Int]) -> (String, [String], String) {
        var tags: [String] = []
        var seen = Set<String>()
        let map: [(Int, [String])] = [
            (0, ["效率干饭", "美食优先", "健康清淡", "猎奇尝鲜"]),
            (1, ["性价比党", "品牌控", "颜值控", "功能狂"]),
            (2, ["宅家回血", "短途出行", "社交达人", "学习充电"]),
            (3, ["省钱选手", "理性消费", "体验优先", "情绪消费"]),
            (5, ["要直接答案", "要理由推荐", "要多备选", "先问清楚"]),
            (7, ["效率至上", "松弛感", "精致生活", "随缘快乐"])
        ]
        for (idx, labels) in map {
            guard idx < answers.count, answers[idx] >= 0, answers[idx] < labels.count else { continue }
            let tag = labels[answers[idx]]
            guard seen.insert(tag).inserted else { continue }
            tags.append(tag)
            if tags.count >= 5 { break }
        }
        let primary = tags.first ?? "偏好待解锁"
        let summary = tags.isEmpty ? "还没形成稳定偏好标签" : "你更偏向：\(tags.joined(separator: "、"))"
        return (primary, tags, summary)
    }
}
