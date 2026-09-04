import SwiftData
import SwiftUI
import UIKit

struct ProfileView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]
    @Query(sort: \DecisionRecord.createdAt, order: .reverse) private var decisions: [DecisionRecord]
    @Query(sort: \ChatMessage.createdAt) private var messages: [ChatMessage]
    @State private var nickname = ""
    @State private var signature = ""
    @State private var preferences = ""
    @State private var scenarios = ""
    @State private var selectedStyle = DecisionStyle.fallback
    @State private var decisionTags: [String] = []
    @State private var customTagDraft = ""
    @State private var showInsightSheet = false
    @State private var insightLoading = false
    @State private var insightText = ""
    @State private var insightError: String?
    @State private var showStyleQuiz = false
    @State private var showQuizResults = false
    @State private var pendingDelete: DecisionRecord?
    @State private var isEditing = false
    @State private var showCustomTagInput = false
    @State private var showDeleteSummaryConfirm = false
    @State private var decisionPage = 0
    @State private var showAvatarSourceDialog = false
    @State private var avatarPickerMode: SystemMediaPickerMode?
    @State private var cropSourceImage: UIImage?
    @State private var avatarError: String?
    @FocusState private var focusedField: ProfileField?

    private enum ProfileField: Hashable {
        case nickname, signature, preferences, scenarios, customTag
    }

    private let decisionPageSize = 5

    private var profile: UserProfile? { profiles.first }

    private var displayedDuckSummary: String {
        let raw = profile?.duckSummary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            return "还没有画像总结。点下方按钮，鸭鸭会根据你的用户画像重新认识你。"
        }
        let cleaned = DuckTextSanitizer.duckEyeSummary(from: raw)
        return cleaned.isEmpty ? raw : cleaned
    }

    private var decisionPageCount: Int {
        max(1, Int(ceil(Double(decisions.count) / Double(decisionPageSize))))
    }

    private var pagedDecisions: [DecisionRecord] {
        let start = decisionPage * decisionPageSize
        guard start < decisions.count else { return [] }
        return Array(decisions[start..<min(start + decisionPageSize, decisions.count)])
    }

    private var availablePresetChips: [String] {
        var styles = DecisionStyle.presets
        for tag in decisionTags where !styles.contains(tag) {
            styles.append(tag)
        }
        return styles
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HeaderBar()
                ScrollView {
                    VStack(spacing: 18) {
                        ProfileHero(
                            profile: profile,
                            isEditing: isEditing,
                            onAvatarTap: { showAvatarSourceDialog = true },
                            onEditTap: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if isEditing {
                                        focusedField = nil
                                        showCustomTagInput = false
                                        customTagDraft = ""
                                        loadProfile()
                                        isEditing = false
                                    } else {
                                        loadProfile()
                                        showCustomTagInput = false
                                        customTagDraft = ""
                                        isEditing = true
                                    }
                                }
                            }
                        )
                        editorCard
                        summaryCard
                        historyCard
                    }
                    .padding(20)
                }
                .background(DuckTheme.pageGradient)
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture { focusedField = nil }
            }
            .navigationBarHidden(true)
            .onAppear(perform: loadProfile)
            .onChange(of: showStyleQuiz) { _, open in
                if !open { loadProfile() }
            }
            .onChange(of: showQuizResults) { _, open in
                if !open { loadProfile() }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { focusedField = nil }
                        .fontWeight(.bold)
                        .foregroundStyle(DuckTheme.duckOrange)
                }
            }
            .sheet(isPresented: $showInsightSheet) {
                ProfileInsightSheet(
                    nickname: nickname.isEmpty ? (profile?.nickname ?? "你") : nickname,
                    isLoading: insightLoading,
                    text: insightText,
                    errorMessage: insightError
                )
            }
            .navigationDestination(isPresented: $showStyleQuiz) {
                QuizHubView()
            }
            .navigationDestination(isPresented: $showQuizResults) {
                QuizResultsView()
            }
            .alert("删除鸭鸭眼中的你？", isPresented: $showDeleteSummaryConfirm) {
                Button("先留着", role: .cancel) {}
                Button("确认删除", role: .destructive) {
                    profile?.duckSummary = ""
                    profile?.updatedAt = .now
                    try? modelContext.save()
                }
            } message: {
                Text("鸭鸭再确认一遍：真的要清空这段画像总结吗？偏好和决策历史不会被删掉。")
            }
            .confirmationDialog("更换头像", isPresented: $showAvatarSourceDialog, titleVisibility: .visible) {
                Button("拍照") { avatarPickerMode = .cameraPhoto }
                Button("从相册选择") { avatarPickerMode = .libraryPhoto }
                if profile?.hasCustomAvatar == true {
                    Button("恢复默认头像", role: .destructive) {
                        profile?.clearCustomAvatar()
                        try? modelContext.save()
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .fullScreenCover(item: $avatarPickerMode) { mode in
                SystemMediaPicker(
                    mode: mode,
                    onPicked: { url, _ in
                        avatarPickerMode = nil
                        if let image = UIImage(contentsOfFile: url.path) ?? AttachmentStore.loadImage(fileURL: url) {
                            cropSourceImage = image
                        } else {
                            avatarError = "读不到这张图，换一张试试鸭～"
                        }
                    },
                    onCancel: { avatarPickerMode = nil }
                )
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: Binding(
                get: { cropSourceImage != nil },
                set: { if !$0 { cropSourceImage = nil } }
            )) {
                if let cropSourceImage {
                    AvatarCropView(
                        image: cropSourceImage,
                        onCancel: { self.cropSourceImage = nil },
                        onCropped: { cropped in
                            self.cropSourceImage = nil
                            saveCroppedAvatar(cropped)
                        }
                    )
                }
            }
            .alert("头像更新失败", isPresented: Binding(
                get: { avatarError != nil },
                set: { if !$0 { avatarError = nil } }
            )) {
                Button("好的", role: .cancel) { avatarError = nil }
            } message: {
                Text(avatarError ?? "")
            }
        }
    }

    private func saveCroppedAvatar(_ image: UIImage) {
        do {
            let path = try AttachmentStore.persistJPEG(image, preferredName: "avatar-\(UUID().uuidString).jpg")
            let target = profile ?? {
                let p = UserProfile()
                modelContext.insert(p)
                return p
            }()
            if target.hasCustomAvatar {
                if let old = AttachmentStore.fileURL(relativePath: target.avatarRelativePath) {
                    try? FileManager.default.removeItem(at: old)
                }
            }
            target.setCustomAvatar(relativePath: path)
            try modelContext.save()
        } catch {
            avatarError = error.localizedDescription
        }
    }

    private var editorCard: some View {
        DuckCard {
            HStack {
                Text("我的决策画像")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(DuckTheme.inkBlue)
                Spacer()
                if isEditing {
                    Text("编辑中")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(DuckTheme.skyBlue)
                }
            }

            profileField(title: "昵称") {
                if isEditing {
                    TextField("你的昵称", text: $nickname)
                        .textFieldStyle(DuckTextFieldStyle())
                        .focused($focusedField, equals: .nickname)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .signature }
                } else {
                    readOnlyValue(nickname.isEmpty ? "未设置昵称" : nickname)
                }
            }

            profileField(title: "个性签名") {
                if isEditing {
                    TextField("写一句个性签名，比如：纠结星人的自救日志", text: $signature, axis: .vertical)
                        .textFieldStyle(DuckTextFieldStyle())
                        .lineLimit(2...4)
                        .focused($focusedField, equals: .signature)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                } else {
                    readOnlyValue(signature.isEmpty ? "还没写个性签名" : signature)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("决策风格 / 标签")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(DuckTheme.mutedText)
                    Spacer()
                    Button {
                        showQuizResults = true
                    } label: {
                        Text("测试结果库")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(DuckTheme.skyBlue)
                    }
                    .buttonStyle(.plain)
                }

                if isEditing {
                    DecisionTagGrid(tags: decisionTags, onDelete: { tag in
                        decisionTags.removeAll { $0 == tag }
                        selectedStyle = decisionTags.first ?? DecisionStyle.fallback
                    })

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                        ForEach(availablePresetChips, id: \.self) { style in
                            Chip(style, isSelected: decisionTags.contains(style)) {
                                if decisionTags.contains(style) {
                                    decisionTags.removeAll { $0 == style }
                                } else {
                                    decisionTags.append(style)
                                }
                                selectedStyle = decisionTags.first ?? DecisionStyle.fallback
                            }
                        }
                    }

                    if showCustomTagInput {
                        HStack(spacing: 8) {
                            TextField("输入自定义标签", text: $customTagDraft)
                                .textFieldStyle(DuckTextFieldStyle())
                                .focused($focusedField, equals: .customTag)
                                .submitLabel(.done)
                                .onSubmit { confirmCustomTag() }
                            Button("确定") { confirmCustomTag() }
                                .font(.subheadline.weight(.heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(DuckTheme.duckOrange)
                                .clipShape(Capsule())
                                .buttonStyle(.plain)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showCustomTagInput = true
                                focusedField = .customTag
                            }
                        } label: {
                            Label("添加标签", systemImage: "plus")
                                .font(.subheadline.weight(.heavy))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .foregroundStyle(DuckTheme.inkBlue)
                                .background(DuckTheme.softBlue)
                                .clipShape(Capsule())
                                .overlay {
                                    Capsule()
                                        .stroke(DuckTheme.skyBlue.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                                }
                        }
                        .buttonStyle(.plain)
                    }
                } else if decisionTags.isEmpty {
                    readOnlyValue(selectedStyle)
                } else {
                    DecisionTagGrid(tags: decisionTags)
                }

                if !isEditing {
                    Button {
                        focusedField = nil
                        _ = saveProfileReturning()
                        showStyleQuiz = true
                    } label: {
                        Label("测测你的决策风格", systemImage: "sparkles")
                            .font(.subheadline.weight(.heavy))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(.white)
                            .background(DuckTheme.heroGradient)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }

            profileField(title: "偏好") {
                if isEditing {
                    TextField("例如：预算敏感、喜欢简单直接、重视健康", text: $preferences, axis: .vertical)
                        .lineLimit(3...5)
                        .textFieldStyle(DuckTextFieldStyle())
                        .focused($focusedField, equals: .preferences)
                } else {
                    readOnlyValue(preferences.isEmpty ? "还没填写偏好" : preferences)
                }
            }

            profileField(title: "常纠结的场景") {
                if isEditing {
                    TextField("例如：吃什么、买哪个、要不要换工作", text: $scenarios, axis: .vertical)
                        .lineLimit(3...5)
                        .textFieldStyle(DuckTextFieldStyle())
                        .focused($focusedField, equals: .scenarios)
                } else {
                    readOnlyValue(scenarios.isEmpty ? "还没填写常纠结场景" : scenarios)
                }
            }

            if isEditing {
                Button {
                    focusedField = nil
                    showCustomTagInput = false
                    customTagDraft = ""
                    _ = saveProfileReturning()
                    withAnimation { isEditing = false }
                } label: {
                    Label("保存修改", systemImage: "checkmark.circle.fill")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .foregroundStyle(.white)
                        .background(
                            LinearGradient(
                                colors: [DuckTheme.warmYellow, DuckTheme.skyBlue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(Capsule())
                        .shadow(color: DuckTheme.skyBlue.opacity(0.28), radius: 12, y: 7)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var summaryCard: some View {
        DuckCard {
            HStack(alignment: .center) {
                Text("鸭鸭眼中的你")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(DuckTheme.inkBlue)
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        focusedField = nil
                        Task { await refreshDuckSummaryFromChat() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(DuckTheme.skyBlue)
                            .padding(10)
                            .background(DuckTheme.softBlue)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("根据聊天记录更新")

                    if profile?.duckSummary.isEmpty == false {
                        Button {
                            showDeleteSummaryConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(DuckTheme.duckOrange)
                                .padding(10)
                                .background(DuckTheme.warmYellow.opacity(0.22))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除鸭鸭眼中的你")
                    }
                }
            }
            Text(displayedDuckSummary)
                .font(.subheadline)
                .foregroundStyle(DuckTheme.mutedText)

            Button {
                focusedField = nil
                Task {
                    await saveAndAnalyze()
                    isEditing = false
                    showCustomTagInput = false
                }
            } label: {
                Label("根据你的用户画像让鸭鸭分析", systemImage: "sparkles")
                    .font(.subheadline.weight(.heavy))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundStyle(.white)
                    .background(DuckTheme.heroGradient)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
    }

    private var historyCard: some View {
        DuckCard {
            HStack {
                Text("决策历史")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(DuckTheme.inkBlue)
                Spacer()
                if decisions.count > decisionPageSize {
                    Text("\(decisionPage + 1)/\(decisionPageCount) 页")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(DuckTheme.mutedText)
                }
            }

            if decisions.isEmpty {
                Text("还没有决策记录。去聊天页问鸭鸭，点选最终决定后才会记入这里。")
                    .font(.subheadline)
                    .foregroundStyle(DuckTheme.mutedText)
            } else {
                ForEach(pagedDecisions) { decision in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(decision.title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(DuckTheme.inkBlue)
                            Text("最终选择：\(decision.finalChoice.isEmpty ? decision.recommendation : decision.finalChoice)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DuckTheme.duckOrange)
                            Text(decision.reasonSummary)
                                .font(.caption)
                                .foregroundStyle(DuckTheme.mutedText)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        Button {
                            pendingDelete = decision
                        } label: {
                            Image(systemName: "trash")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(DuckTheme.duckOrange)
                                .padding(10)
                                .background(DuckTheme.warmYellow.opacity(0.22))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除这条决策")
                    }
                    .padding(.vertical, 8)
                    Divider()
                }

                if decisions.count > decisionPageSize {
                    HStack(spacing: 12) {
                        Button {
                            withAnimation {
                                decisionPage = max(0, decisionPage - 1)
                            }
                        } label: {
                            Label("上一页", systemImage: "chevron.left")
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(decisionPage > 0 ? DuckTheme.inkBlue : DuckTheme.mutedText.opacity(0.45))
                        .background(DuckTheme.softBlue)
                        .clipShape(Capsule())
                        .disabled(decisionPage <= 0)

                        Button {
                            withAnimation {
                                decisionPage = min(decisionPageCount - 1, decisionPage + 1)
                            }
                        } label: {
                            Label("下一页", systemImage: "chevron.right")
                                .font(.subheadline.weight(.bold))
                                .labelStyle(.titleAndIcon)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(decisionPage < decisionPageCount - 1 ? .white : DuckTheme.mutedText.opacity(0.45))
                        .background(decisionPage < decisionPageCount - 1 ? DuckTheme.duckOrange : Color.gray.opacity(0.18))
                        .clipShape(Capsule())
                        .disabled(decisionPage >= decisionPageCount - 1)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .onChange(of: decisions.count) { _, count in
            let maxPage = max(0, Int(ceil(Double(count) / Double(decisionPageSize))) - 1)
            if decisionPage > maxPage {
                decisionPage = maxPage
            }
        }
        .alert("鸭鸭确认一下", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("先留着", role: .cancel) {
                pendingDelete = nil
            }
            Button("确认删除", role: .destructive) {
                if let pendingDelete {
                    modelContext.delete(pendingDelete)
                    try? modelContext.save()
                }
                pendingDelete = nil
            }
        } message: {
            Text(deleteConfirmMessage)
        }
    }

    private var deleteConfirmMessage: String {
        guard let pendingDelete else { return "要删除这条决策记录吗？" }
        let choice = pendingDelete.finalChoice.isEmpty ? pendingDelete.recommendation : pendingDelete.finalChoice
        return "鸭鸭再确认一遍：真的要删除「\(pendingDelete.title)」里最终选择「\(choice)」这条记录吗？删了就找不回来啦。"
    }

    private func profileField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(DuckTheme.mutedText)
            content()
        }
    }

    private func readOnlyValue(_ text: String) -> some View {
        Text(text)
            .font(.body.weight(.medium))
            .foregroundStyle(DuckTheme.inkBlue)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(DuckTheme.softBlue.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func loadProfile() {
        guard let profile else { return }
        if profile.avatarAssetName.isEmpty || profile.avatarAssetName == "MascotChat" {
            profile.avatarAssetName = "UserAvatar"
            try? modelContext.save()
        }
        let shortLegacy = ["果断型", "谨慎型", "直觉型", "分析型", "随缘型", "随和型"]
        if shortLegacy.contains(profile.decisionStyleRaw) {
            profile.decisionStyleRaw = DecisionStyle.fallback
            try? modelContext.save()
        }
        nickname = profile.nickname
        signature = profile.signature
        preferences = profile.preferences
        scenarios = profile.commonScenarios
        if profile.decisionTags.isEmpty {
            let seed = profile.decisionStyleRaw.isEmpty ? DecisionStyle.fallback : profile.decisionStyleRaw
            profile.setDecisionTags([seed])
            try? modelContext.save()
        }
        decisionTags = profile.decisionTags
        selectedStyle = decisionTags.first ?? DecisionStyle.fallback
        customTagDraft = ""
    }

    private func confirmCustomTag() {
        let tag = customTagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else {
            withAnimation(.easeInOut(duration: 0.2)) {
                showCustomTagInput = false
                focusedField = nil
            }
            return
        }
        if !decisionTags.contains(tag) {
            decisionTags.append(tag)
        }
        selectedStyle = decisionTags.first ?? tag
        customTagDraft = ""
        focusedField = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            showCustomTagInput = false
        }
    }

    @discardableResult
    private func saveProfileReturning() -> UserProfile? {
        let target = profile ?? UserProfile()
        target.nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "选选鸭用户" : nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        nickname = target.nickname
        target.signature = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        signature = target.signature
        if decisionTags.isEmpty {
            decisionTags = [selectedStyle.isEmpty ? DecisionStyle.fallback : selectedStyle]
        }
        target.setDecisionTags(decisionTags)
        selectedStyle = target.decisionStyleRaw
        target.preferences = preferences
        target.commonScenarios = scenarios
        target.updatedAt = .now
        if profile == nil {
            modelContext.insert(target)
        }
        try? modelContext.save()
        return target
    }

    private func saveAndAnalyze() async {
        guard let target = saveProfileReturning() else { return }
        await runDuckSummaryStream(for: target, refreshFromChat: false)
    }

    private func refreshDuckSummaryFromChat() async {
        guard let target = saveProfileReturning() else { return }
        await runDuckSummaryStream(for: target, refreshFromChat: true)
    }

    private func runDuckSummaryStream(for target: UserProfile, refreshFromChat: Bool) async {
        insightText = ""
        insightError = nil
        insightLoading = true
        showInsightSheet = true

        let client = OpenRouterClient()
        do {
            for try await chunk in await client.streamProfileInsight(
                profile: target,
                messages: messages,
                decisions: decisions,
                refreshFromChat: refreshFromChat
            ) {
                insightLoading = false
                insightText += chunk
            }
            target.duckSummary = DuckTextSanitizer.duckEyeSummary(from: insightText)
            target.updatedAt = .now
            try? modelContext.save()
        } catch {
            insightLoading = false
            insightError = error.localizedDescription
        }
    }
}

private struct ProfileInsightSheet: View {
    let nickname: String
    let isLoading: Bool
    let text: String
    let errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var displayText: String {
        let cleaned = DuckTextSanitizer.duckEyeSummary(from: text)
        return cleaned.isEmpty ? text : cleaned
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image("MascotChat")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text("鸭鸭的画像洞察")
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(DuckTheme.inkBlue)
                            Text("关于 \(nickname)")
                                .font(.subheadline)
                                .foregroundStyle(DuckTheme.mutedText)
                        }
                    }

                    if isLoading && text.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("鸭鸭正在了解你…")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DuckTheme.mutedText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 24)
                    }

                    if !displayText.isEmpty {
                        Text(displayText)
                            .font(.body)
                            .foregroundStyle(DuckTheme.inkBlue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
                .padding(22)
            }
            .background(DuckTheme.pageGradient)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.bold)
                        .foregroundStyle(DuckTheme.duckOrange)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ProfileHero: View {
    let profile: UserProfile?
    let isEditing: Bool
    let onAvatarTap: () -> Void
    let onEditTap: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onAvatarTap) {
                ZStack(alignment: .bottomTrailing) {
                    ProfileAvatarView(profile: profile, size: 86, strokeColor: .white, strokeWidth: 3)
                    Image(systemName: "camera.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, DuckTheme.duckOrange)
                        .background(Circle().fill(.white).padding(2))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更换头像")

            VStack(alignment: .leading, spacing: 7) {
                Text(profile?.nickname ?? "选选鸭用户")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.white)
                let sig = profile?.signature.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Text(sig.isEmpty ? "点击编辑，写一句个性签名" : sig)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(sig.isEmpty ? 0.7 : 0.92))
                    .lineLimit(2)
            }
            Spacer()
            Button(action: onEditTap) {
                Image(systemName: isEditing ? "xmark.circle.fill" : "square.and.pencil")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.white.opacity(0.18))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isEditing ? "取消编辑" : "修改资料")
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(DuckTheme.heroGradient)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: DuckTheme.skyBlue.opacity(0.2), radius: 12, y: 7)
    }
}

private struct DecisionTagGrid: View {
    let tags: [String]
    var onDelete: ((String) -> Void)? = nil

    var body: some View {
        DuckTagCloud(tags: tags, onDelete: onDelete)
    }
}
