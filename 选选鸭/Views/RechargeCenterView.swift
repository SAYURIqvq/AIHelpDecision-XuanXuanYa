import SwiftData
import SwiftUI

struct RechargeCenterView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var chrome: AppChrome
    @Query private var wallets: [GrainWallet]
    @Query(sort: \GrainLedgerEntry.createdAt, order: .reverse) private var ledger: [GrainLedgerEntry]

    @State private var bounceHero = false

    private var wallet: GrainWallet {
        GrainWalletService.ensureWallet(in: modelContext)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HeaderBar {
                    HStack(spacing: 6) {
                        Image("GrainCoin")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                        Text("\(wallet.totalGrains)")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.22))
                    .clipShape(Capsule())
                }

                ScrollView {
                    VStack(spacing: 18) {
                        heroCard
                        segmentControl
                        Group {
                            switch chrome.rechargeSegment {
                            case .packs:
                                packsSection
                            case .monthCards:
                                monthCardsSection
                            case .ledger:
                                ledgerSection
                            }
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 28)
                }
                .background(DuckTheme.pageGradient)
            }
            .navigationBarHidden(true)
            .onAppear {
                _ = GrainWalletService.ensureWallet(in: modelContext)
            }
        }
    }

    private var heroCard: some View {
        ZStack(alignment: .bottomLeading) {
            Image("GrainHero")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 168)
                .clipped()

            LinearGradient(
                colors: [.clear, DuckTheme.inkBlue.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("鸭鸭囤粮中心")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.white)
                Text("囤足谷粒，鸭鸭帮你搞定选择困难")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))

                HStack(spacing: 8) {
                    quotaChip(title: "今日聊天", value: "\(wallet.freeChatLeft)/\(GrainCosts.freeChatPerDay)")
                    quotaChip(title: "今日通话", value: "\(wallet.freeCallMinutesLeft)分钟")
                    if GrainWalletService.claimableDailyTotal(in: modelContext) > 0 {
                        Button {
                            let gained = GrainWalletService.claimDailyGrains(wallet: wallet, context: modelContext)
                            if gained > 0 {
                                chrome.celebratePurchase("🦆今日口粮 +\(gained) 谷粒已入袋")
                            }
                        } label: {
                            Text("领取今日谷粒")
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(DuckTheme.inkBlue)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(DuckTheme.warmYellow)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.55), lineWidth: 2)
        }
        .shadow(color: DuckTheme.skyBlue.opacity(0.2), radius: 14, y: 8)
        .scaleEffect(bounceHero ? 1.01 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                bounceHero = true
            }
        }
    }

    private func quotaChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text(value)
                .font(.caption.weight(.heavy))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var segmentControl: some View {
        HStack(spacing: 6) {
            segmentButton("囤谷粒", .packs)
            segmentButton("鸭粮月卡", .monthCards)
            segmentButton("账单", .ledger)
        }
        .padding(5)
        .background(DuckTheme.softWhite)
        .clipShape(Capsule())
        .overlay { Capsule().stroke(DuckTheme.skyBlue.opacity(0.2), lineWidth: 1) }
    }

    private func segmentButton(_ title: String, _ segment: AppChrome.RechargeSegment) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                chrome.rechargeSegment = segment
            }
        } label: {
            Text(title)
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(chrome.rechargeSegment == segment ? .white : DuckTheme.inkBlue)
                .background(chrome.rechargeSegment == segment ? DuckTheme.duckOrange : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var packsSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image("GrainCoin")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("临时补粮 · 立即囤粮")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(DuckTheme.inkBlue)
                    Text("每月卡为主，直购救急；每档独立首充双倍")
                        .font(.caption)
                        .foregroundStyle(DuckTheme.mutedText)
                }
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(GrainCatalog.packs) { pack in
                    GrainPackCard(
                        pack: pack,
                        isFirstCharge: !wallet.firstChargePackIDs.contains(pack.id)
                    ) {
                        GrainWalletService.purchasePack(pack, wallet: wallet, context: modelContext)
                        chrome.celebratePurchase()
                    }
                }
            }
        }
    }

    private var monthCardsSection: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image("MonthCardBadge")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("鸭鸭月卡系列")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(DuckTheme.inkBlue)
                    Text("即时谷粒 + 每日口粮 · 可叠加时长 · 谷粒永久保留")
                        .font(.caption)
                        .foregroundStyle(DuckTheme.mutedText)
                }
                Spacer()
            }

            ForEach(GrainCatalog.monthCards) { plan in
                MonthCardView(
                    plan: plan,
                    remainingDays: GrainWalletService.remainingDays(for: plan.id, in: modelContext)
                ) {
                    GrainWalletService.purchaseMonthCard(plan, wallet: wallet, context: modelContext)
                    chrome.celebratePurchase("🦆\(plan.cardName)开通成功！谷粒已到账")
                }
            }
        }
    }

    private var ledgerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DuckCard(padding: 14) {
                HStack {
                    Label("谷粒余额 \(wallet.totalGrains)", systemImage: "leaf.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(DuckTheme.duckOrange)
                    Spacer()
                    Label("积分 \(wallet.points)", systemImage: "star.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(DuckTheme.skyBlue)
                }
                Text("积分走原积分商城，不能兑换谷粒")
                    .font(.caption)
                    .foregroundStyle(DuckTheme.mutedText)
            }

            if ledger.isEmpty {
                Text("还没有账单，去囤一点谷粒吧～")
                    .font(.subheadline)
                    .foregroundStyle(DuckTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ForEach(ledger.prefix(40)) { entry in
                    LedgerRow(entry: entry)
                }
            }
        }
    }
}

private struct GrainPackCard: View {
    let pack: GrainPack
    let isFirstCharge: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image("GrainCoin")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                Spacer()
                if isFirstCharge {
                    Text("首充双倍")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DuckTheme.duckOrange)
                        .clipShape(Capsule())
                }
            }

            Text(pack.name)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(DuckTheme.inkBlue)
                .lineLimit(1)

            Text("\(pack.grains) 谷粒")
                .font(.title3.weight(.heavy))
                .foregroundStyle(DuckTheme.duckOrange)
            Text(isFirstCharge ? "首充到手 \(pack.totalGrains * 2)" : "另赠 +\(pack.giftGrains)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DuckTheme.mutedText)

            Button(action: action) {
                Text("立即囤粮 \(pack.priceLabel)")
                    .font(.caption.weight(.heavy))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(DuckTheme.skyBlue)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(DuckTheme.softWhite)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DuckTheme.warmYellow.opacity(0.55), lineWidth: 1.5)
        }
        .shadow(color: DuckTheme.warmYellow.opacity(0.16), radius: 8, y: 4)
    }
}

private struct MonthCardView: View {
    let plan: MonthCardPlan
    let remainingDays: Int
    let action: () -> Void

    private var isActive: Bool { remainingDays > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.seriesName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(DuckTheme.skyBlue)
                    Text(plan.cardName)
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(DuckTheme.inkBlue)
                    Text(plan.audience)
                        .font(.caption)
                        .foregroundStyle(DuckTheme.mutedText)
                }
                Spacer()
                Text(plan.priceLabel)
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(priceGradient)
                    .clipShape(Capsule())
            }

            HStack(spacing: 10) {
                grainPill("立即到账", "\(plan.instantGrains)")
                grainPill("每日可领", "\(plan.dailyGrains)")
                grainPill("月合计", "\(plan.monthlyTotal)")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("✨ 会员特权")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(DuckTheme.inkBlue)
                ForEach(plan.perks, id: \.self) { perk in
                    Text("· \(perk)")
                        .font(.caption)
                        .foregroundStyle(DuckTheme.mutedText)
                }
            }

            Button(action: action) {
                Text(isActive ? "已激活，剩余\(remainingDays)天 · 仍可叠加" : plan.openButtonTitle)
                    .font(.subheadline.weight(.heavy))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundStyle(isActive ? DuckTheme.mutedText : .white)
                    .background(isActive ? Color.gray.opacity(0.18) : DuckTheme.duckOrange)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            // 按 PRD：已开通置灰展示，但仍允许叠加购买
            .opacity(isActive ? 0.92 : 1)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [DuckTheme.softWhite, DuckTheme.softBlue.opacity(0.65)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(DuckTheme.skyBlue.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: DuckTheme.skyBlue.opacity(0.14), radius: 10, y: 5)
    }

    private var priceGradient: LinearGradient {
        switch plan.accent {
        case "plus":
            return LinearGradient(colors: [DuckTheme.skyBlue, Color(red: 0.25, green: 0.55, blue: 0.95)], startPoint: .leading, endPoint: .trailing)
        case "pro":
            return LinearGradient(colors: [Color(red: 0.95, green: 0.62, blue: 0.12), DuckTheme.duckOrange], startPoint: .leading, endPoint: .trailing)
        default:
            return LinearGradient(colors: [DuckTheme.warmYellow, DuckTheme.duckOrange], startPoint: .leading, endPoint: .trailing)
        }
    }

    private func grainPill(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DuckTheme.mutedText)
            Text(value)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(DuckTheme.duckOrange)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.white.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct LedgerRow: View {
    let entry: GrainLedgerEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.grainDelta >= 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .foregroundStyle(entry.grainDelta >= 0 ? DuckTheme.successGreen : DuckTheme.duckOrange)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(DuckTheme.inkBlue)
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(DuckTheme.mutedText)
                }
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(DuckTheme.mutedText.opacity(0.8))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if entry.grainDelta != 0 {
                    Text("\(entry.grainDelta > 0 ? "+" : "")\(entry.grainDelta) 谷粒")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(entry.grainDelta > 0 ? DuckTheme.successGreen : DuckTheme.duckOrange)
                }
                if entry.pointsDelta != 0 {
                    Text("\(entry.pointsDelta > 0 ? "+" : "")\(entry.pointsDelta) 积分")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(DuckTheme.skyBlue)
                }
            }
        }
        .padding(14)
        .background(DuckTheme.softWhite)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct GrainExhaustSheet: View {
    @EnvironmentObject private var chrome: AppChrome

    var body: some View {
        VStack(spacing: 18) {
            Image("GrainCoin")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
            Text("🦆谷粒用光啦！鸭鸭没有口粮帮你做决策啦")
                .font(.title3.weight(.heavy))
                .foregroundStyle(DuckTheme.inkBlue)
                .multilineTextAlignment(.center)
            Text("继续决策聊天、AI视频通话需要谷粒；开通月卡更划算")
                .font(.subheadline)
                .foregroundStyle(DuckTheme.mutedText)
                .multilineTextAlignment(.center)

            Button {
                chrome.openMonthCards()
            } label: {
                Text("去囤月卡")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(DuckTheme.duckOrange)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                chrome.openPacks()
            } label: {
                Text("去直购谷粒")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(DuckTheme.inkBlue)
                    .background(DuckTheme.softBlue)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button("返回") {
                chrome.showGrainExhaustSheet = false
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(DuckTheme.mutedText)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
