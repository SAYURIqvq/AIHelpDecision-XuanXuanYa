import SwiftData
import SwiftUI

struct ProfileView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]
    @Query(sort: \DecisionRecord.createdAt, order: .reverse) private var decisions: [DecisionRecord]
    @Query(sort: \ChatMessage.createdAt) private var messages: [ChatMessage]
    @StateObject private var chatViewModel = ChatViewModel()
    @State private var nickname = ""
    @State private var preferences = ""
    @State private var scenarios = ""
    @State private var selectedStyle: DecisionStyle = .analytical

    private var profile: UserProfile? { profiles.first }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HeaderBar()
                ScrollView {
                    VStack(spacing: 18) {
                        ProfileHero(profile: profile)
                        editorCard
                        summaryCard
                        historyCard
                    }
                    .padding(20)
                }
                .background(DuckTheme.pageGradient)
            }
            .navigationBarHidden(true)
            .onAppear(perform: loadProfile)
        }
    }

    private var editorCard: some View {
        DuckCard {
            Text("我的决策画像")
                .font(.title3.weight(.heavy))
                .foregroundStyle(DuckTheme.inkBlue)

            VStack(alignment: .leading, spacing: 8) {
                Text("昵称")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DuckTheme.mutedText)
                TextField("你的昵称", text: $nickname)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("决策风格")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DuckTheme.mutedText)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], spacing: 8) {
                    ForEach(DecisionStyle.allCases) { style in
                        Chip(style.rawValue, isSelected: selectedStyle == style) {
                            selectedStyle = style
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("偏好")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DuckTheme.mutedText)
                TextField("例如：预算敏感、喜欢简单直接、重视健康", text: $preferences, axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("常纠结的场景")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DuckTheme.mutedText)
                TextField("例如：吃什么、买哪个、要不要换工作", text: $scenarios, axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 12) {
                PrimaryDuckButton(title: "保存画像", systemImage: "tray.and.arrow.down.fill") {
                    saveProfile()
                }
                Button {
                    if let profile {
                        Task {
                            await chatViewModel.summarizeProfile(profile, modelContext: modelContext, messages: messages, decisions: decisions)
                            loadProfile()
                        }
                    }
                } label: {
                    Label(chatViewModel.isThinking ? "总结中" : "鸭鸭自动总结", systemImage: "sparkles")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DuckTheme.skyBlue)
                .background(DuckTheme.softWhite)
                .clipShape(Capsule())
                .overlay { Capsule().stroke(DuckTheme.skyBlue.opacity(0.7), lineWidth: 1) }
            }
        }
    }

    private var summaryCard: some View {
        DuckCard {
            Text("鸭鸭眼中的你")
                .font(.headline.weight(.heavy))
                .foregroundStyle(DuckTheme.inkBlue)
            Text(profile?.duckSummary.isEmpty == false ? profile!.duckSummary : "还没有画像总结。多和鸭鸭聊几次决策，或点击“鸭鸭自动总结”生成你的专属画像。")
                .font(.subheadline)
                .foregroundStyle(DuckTheme.mutedText)
        }
    }

    private var historyCard: some View {
        DuckCard {
            Text("决策历史")
                .font(.headline.weight(.heavy))
                .foregroundStyle(DuckTheme.inkBlue)
            if decisions.isEmpty {
                Text("还没有决策记录。去聊天页问鸭鸭第一个纠结吧。")
                    .font(.subheadline)
                    .foregroundStyle(DuckTheme.mutedText)
            } else {
                ForEach(decisions.prefix(8)) { decision in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(decision.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(DuckTheme.inkBlue)
                        Text("推荐：\(decision.recommendation)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DuckTheme.duckOrange)
                        Text(decision.reasonSummary)
                            .font(.caption)
                            .foregroundStyle(DuckTheme.mutedText)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
            }
        }
    }

    private func loadProfile() {
        guard let profile else { return }
        nickname = profile.nickname
        preferences = profile.preferences
        scenarios = profile.commonScenarios
        selectedStyle = profile.decisionStyle
    }

    private func saveProfile() {
        let target = profile ?? UserProfile()
        target.nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "选选鸭用户" : nickname
        target.decisionStyle = selectedStyle
        target.preferences = preferences
        target.commonScenarios = scenarios
        target.updatedAt = .now
        if profile == nil {
            modelContext.insert(target)
        }
        try? modelContext.save()
    }
}

private struct ProfileHero: View {
    let profile: UserProfile?

    var body: some View {
        HStack(spacing: 16) {
            Image("MascotChat")
                .resizable()
                .scaledToFill()
                .frame(width: 86, height: 86)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white, lineWidth: 3))
            VStack(alignment: .leading, spacing: 7) {
                Text(profile?.nickname ?? "选选鸭用户")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.white)
                Text(profile?.decisionStyleRaw ?? DecisionStyle.analytical.rawValue)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.86))
            }
            Spacer()
            Image(systemName: "square.and.pencil")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(DuckTheme.heroGradient)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: DuckTheme.skyBlue.opacity(0.2), radius: 12, y: 7)
    }
}

