import SwiftData
import SwiftUI

struct QuizHubView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedKind: QuizKind?
    @State private var showResults = false

    var body: some View {
        VStack(spacing: 0) {
            hubHeader
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        Image("QuizStyleDuck")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("鸭鸭试题库")
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(DuckTheme.inkBlue)
                            Text("选一套测测，结果会变成决策标签哦")
                                .font(.subheadline)
                                .foregroundStyle(DuckTheme.mutedText)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(DuckTheme.softWhite)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    Button {
                        showResults = true
                    } label: {
                        HStack {
                            Image(systemName: "tray.full.fill")
                            Text("我的测试结果")
                                .font(.headline.weight(.bold))
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .foregroundStyle(DuckTheme.inkBlue)
                        .padding(16)
                        .background(DuckTheme.softBlue)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    ForEach(QuizCatalog.all) { quiz in
                        Button {
                            selectedKind = quiz.kind
                        } label: {
                            QuizTypeCard(quiz: quiz)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .background(DuckTheme.pageGradient)
        }
        .navigationBarHidden(true)
        .navigationDestination(item: $selectedKind) { kind in
            QuizSessionView(kind: kind)
        }
        .navigationDestination(isPresented: $showResults) {
            QuizResultsView()
        }
    }

    private var hubHeader: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.white.opacity(0.22))
                    .clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("测测你的决策风格")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.white)
                Text("多套试题 · 进度可视 · 标签回填")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(DuckTheme.headerChromeGradient)
    }
}

private struct QuizTypeCard: View {
    let quiz: QuizDefinition

    var body: some View {
        HStack(spacing: 14) {
            Image(quiz.imageName)
                .resizable()
                .scaledToFill()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white, lineWidth: 2)
                }
                .shadow(color: DuckTheme.skyBlue.opacity(0.18), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(quiz.kind.accentLabel)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(DuckTheme.duckOrange)
                    .clipShape(Capsule())
                Text(quiz.title)
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(DuckTheme.inkBlue)
                Text(quiz.subtitle)
                    .font(.caption)
                    .foregroundStyle(DuckTheme.mutedText)
                    .lineLimit(2)
                Text("\(quiz.questions.count) 题")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DuckTheme.skyBlue)
            }
            Spacer(minLength: 4)
            Image(systemName: "play.circle.fill")
                .font(.title)
                .foregroundStyle(DuckTheme.duckOrange)
        }
        .padding(14)
        .background(DuckTheme.softWhite)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(DuckTheme.warmYellow.opacity(0.5), lineWidth: 1.2)
        }
    }
}

struct QuizSessionView: View {
    let kind: QuizKind

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]

    @State private var currentIndex = 0
    @State private var answers: [Int]
    @State private var phase: Phase = .answering
    @State private var streamedText = ""
    @State private var errorMessage: String?
    @State private var primaryTag = ""
    @State private var resultTags: [String] = []
    @State private var localDetail = ""
    @State private var saved = false

    private enum Phase { case answering, analyzing, done }

    init(kind: QuizKind) {
        self.kind = kind
        let count = QuizCatalog.definition(for: kind).questions.count
        // 必须在首帧渲染前就初始化，否则 questionCard 访问 answers[currentIndex] 会闪退
        _answers = State(initialValue: Array(repeating: -1, count: max(count, 1)))
    }

    private var quiz: QuizDefinition { QuizCatalog.definition(for: kind) }
    private var progress: Double {
        guard !quiz.questions.isEmpty else { return 0 }
        if phase != .answering { return 1 }
        return Double(currentIndex) / Double(quiz.questions.count)
    }

    /// 偏好雷达标签：只取本地答题映射，最多 5 个，不去读 AI。
    private var preferenceDisplayTags: [String] {
        let fromState = QuizText.normalizeTags(resultTags, limit: 5)
        if !fromState.isEmpty { return fromState }
        let local = QuizLocalScorer.score(kind: .preference, questions: quiz.questions, answers: answers)
        return QuizText.normalizeTags(local.tags, limit: 5)
    }

    var body: some View {
        VStack(spacing: 0) {
            sessionHeader
            progressBar
            ScrollView {
                Group {
                    switch phase {
                    case .answering:
                        questionCard
                    case .analyzing, .done:
                        resultCard
                    }
                }
                .padding(20)
            }
            .background(DuckTheme.pageGradient)
        }
        .navigationBarHidden(true)
    }

    private var sessionHeader: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(DuckTheme.duckOrange)
            }
            Image(quiz.imageName)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay(Circle().stroke(DuckTheme.warmYellow, lineWidth: 2))
            VStack(alignment: .leading, spacing: 2) {
                Text(quiz.title)
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(DuckTheme.inkBlue)
                Text(phase == .answering
                     ? "第 \(min(currentIndex + 1, quiz.questions.count))/\(quiz.questions.count) 题"
                     : "鸭鸭出结果中")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DuckTheme.mutedText)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(DuckTheme.softWhite)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DuckTheme.softBlue)
                Capsule()
                    .fill(DuckTheme.heroGradient)
                    .frame(width: max(8, geo.size.width * progress))
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: progress)
            }
        }
        .frame(height: 8)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(DuckTheme.softWhite)
    }

    @ViewBuilder
    private var questionCard: some View {
        if quiz.questions.indices.contains(currentIndex),
           answers.indices.contains(currentIndex) {
            let question = quiz.questions[currentIndex]
            let selected = answers[currentIndex]
            VStack(spacing: 14) {
                Image(quiz.imageName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: DuckTheme.skyBlue.opacity(0.2), radius: 10, y: 5)

                DuckCard {
                    Text(question.title)
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(DuckTheme.inkBlue)

                    VStack(spacing: 10) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                            Button {
                                guard answers.indices.contains(currentIndex) else { return }
                                answers[currentIndex] = index
                                goNext()
                            } label: {
                                HStack {
                                    Text(option)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(DuckTheme.inkBlue)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    if selected == index {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(DuckTheme.duckOrange)
                                    }
                                }
                                .padding(14)
                                .background(DuckTheme.warmYellow.opacity(selected == index ? 0.35 : 0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(DuckTheme.duckOrange.opacity(0.45), lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        } else {
            Text("题目加载失败，返回重试鸭～")
                .foregroundStyle(DuckTheme.mutedText)
        }
    }

    /// 结果页只展示分析正文，避免和橙色标题重复叠字。
    private var analysisDisplayText: String {
        QuizText.analysisBody(from: streamedText)
    }

    private var resultCard: some View {
        DuckCard {
            VStack(alignment: .leading, spacing: 16) {
                if kind == .preference {
                    preferenceResultContent
                } else {
                    standardResultContent
                }
            }
        }
    }

    /// 偏好雷达专用结果：彩色标签最多 5 个，全部来自本地答题，不读 AI 拼接串。
    @ViewBuilder
    private var preferenceResultContent: some View {
        if phase == .analyzing && streamedText.isEmpty {
            HStack(spacing: 12) {
                ProgressView()
                Text("鸭鸭正在分析…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DuckTheme.mutedText)
            }
            .padding(.vertical, 12)
        }

        let title = preferenceDisplayTags.first ?? primaryTag
        if !title.isEmpty {
            Text(title)
                .font(.title2.weight(.heavy))
                .foregroundStyle(DuckTheme.duckOrange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !preferenceDisplayTags.isEmpty {
            QuizTagFlow(tags: preferenceDisplayTags)
        }

        if !analysisDisplayText.isEmpty {
            Text(analysisDisplayText)
                .font(.body)
                .foregroundStyle(DuckTheme.inkBlue)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .bottomTrailing) {
                    if phase == .analyzing {
                        Text("▌")
                            .font(.body.weight(.bold))
                            .foregroundStyle(DuckTheme.duckOrange.opacity(0.7))
                            .offset(x: 2, y: 2)
                    }
                }
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.subheadline)
                .foregroundStyle(.red)
        }

        if phase == .done {
            PrimaryDuckButton(title: saved ? "已写入决策标签" : "采用并回填标签", systemImage: "checkmark.seal.fill") {
                applyToProfile()
            }
            .disabled(saved)
            .opacity(saved ? 0.7 : 1)

            Button("返回试题库") { dismiss() }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(DuckTheme.mutedText)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var standardResultContent: some View {
        if phase == .analyzing && streamedText.isEmpty {
            HStack(spacing: 12) {
                ProgressView()
                Text("鸭鸭正在分析…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DuckTheme.mutedText)
            }
            .padding(.vertical, 12)
        }

        if !primaryTag.isEmpty {
            Text(primaryTag)
                .font(.title2.weight(.heavy))
                .foregroundStyle(DuckTheme.duckOrange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if phase == .done, !resultTags.isEmpty {
            QuizTagFlow(tags: Array(QuizText.normalizeTags(resultTags, limit: 5).prefix(5)))
        }

        if !localDetail.isEmpty, analysisDisplayText.isEmpty {
            Text(localDetail)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DuckTheme.skyBlue)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !analysisDisplayText.isEmpty {
            Text(analysisDisplayText)
                .font(.body)
                .foregroundStyle(DuckTheme.inkBlue)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .bottomTrailing) {
                    if phase == .analyzing {
                        Text("▌")
                            .font(.body.weight(.bold))
                            .foregroundStyle(DuckTheme.duckOrange.opacity(0.7))
                            .offset(x: 2, y: 2)
                    }
                }
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.subheadline)
                .foregroundStyle(.red)
        }

        if phase == .done {
            PrimaryDuckButton(title: saved ? "已写入决策标签" : "采用并回填标签", systemImage: "checkmark.seal.fill") {
                applyToProfile()
            }
            .disabled(saved)
            .opacity(saved ? 0.7 : 1)

            Button("返回试题库") { dismiss() }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(DuckTheme.mutedText)
                .padding(.top, 4)
        }
    }

    private func goNext() {
        if currentIndex < quiz.questions.count - 1 {
            withAnimation { currentIndex += 1 }
        } else {
            Task { await finishQuiz() }
        }
    }

    private func finishQuiz() async {
        phase = .analyzing
        streamedText = ""
        errorMessage = nil
        saved = false

        let local = QuizLocalScorer.score(kind: kind, questions: quiz.questions, answers: answers)
        primaryTag = local.primary
        // 偏好题：标签只认本地答题，最多 5 个；全程不跟 AI 流
        resultTags = QuizText.normalizeTags(local.tags, limit: 5)
        localDetail = local.detail

        let paired = zip(quiz.questions, answers).compactMap { question, answerIndex -> (String, String)? in
            guard answerIndex >= 0, answerIndex < question.options.count else { return nil }
            return (question.title, question.options[answerIndex])
        }

        let client = OpenRouterClient()
        do {
            var assembled = ""
            for try await chunk in await client.streamQuizAnalysis(
                kind: kind,
                nickname: profiles.first?.nickname ?? "你",
                answers: paired.map { (question: $0.0, answer: $0.1) },
                localHint: local.detail
            ) {
                assembled += chunk
                streamedText = kind == .preference ? QuizText.stripTagSection(assembled) : assembled
                if kind != .preference {
                    refreshTagsFromStream()
                }
                await Task.yield()
            }
            if kind == .preference {
                primaryTag = local.primary
                resultTags = QuizText.normalizeTags(local.tags, limit: 5)
                streamedText = QuizText.stripTagSection(streamedText)
            } else {
                if primaryTag.isEmpty {
                    primaryTag = Self.extractBracket(from: streamedText, key: "【专属风格】")
                        ?? Self.extractBracket(from: streamedText, key: "【结果】")
                        ?? quiz.title
                }
                if resultTags.isEmpty {
                    resultTags = QuizText.normalizeTags([primaryTag], limit: 5)
                } else {
                    resultTags = QuizText.normalizeTags(resultTags, limit: 5)
                }
            }
            persistResult()
            phase = .done
        } catch {
            if primaryTag.isEmpty { primaryTag = local.primary.isEmpty ? quiz.title : local.primary }
            if kind == .preference {
                primaryTag = local.primary
                resultTags = QuizText.normalizeTags(local.tags, limit: 5)
            } else if resultTags.isEmpty {
                resultTags = local.tags.isEmpty ? [primaryTag] : local.tags
                resultTags = QuizText.normalizeTags(resultTags, limit: 5)
            }
            if streamedText.isEmpty { streamedText = local.detail }
            errorMessage = error.localizedDescription
            persistResult()
            phase = .done
        }
    }

    private func refreshTagsFromStream() {
        guard kind != .preference else { return }
        if kind == .decisionStyle,
           let name = Self.extractBracket(from: streamedText, key: "【专属风格】"),
           !name.isEmpty {
            primaryTag = name
            resultTags = QuizText.normalizeTags([name], limit: 5)
        } else if let name = Self.extractBracket(from: streamedText, key: "【结果】"),
                  primaryTag.isEmpty || primaryTag == localDetail {
            primaryTag = name
        }
    }

    private func persistResult() {
        let cleanedTags = QuizText.normalizeTags(resultTags, limit: 5)
        resultTags = cleanedTags
        if kind == .preference, primaryTag.isEmpty {
            primaryTag = cleanedTags.first ?? primaryTag
        }
        let result = QuizResult(
            kind: kind,
            title: quiz.title,
            primaryTag: primaryTag,
            tags: cleanedTags,
            summary: streamedText.isEmpty ? localDetail : streamedText,
            detail: localDetail
        )
        modelContext.insert(result)
        try? modelContext.save()
    }

    private func applyToProfile() {
        let profile = profiles.first ?? {
            let p = UserProfile()
            modelContext.insert(p)
            return p
        }()
        let cleaned = QuizText.normalizeTags(resultTags, limit: 5)
        resultTags = cleaned
        var tags = QuizText.normalizeTags(profile.decisionTags, limit: 16)
        for tag in cleaned where !tags.contains(tag) {
            tags.append(tag)
        }
        if !primaryTag.isEmpty,
           kind != .preference,
           !tags.contains(primaryTag) {
            tags.insert(primaryTag, at: 0)
        }
        if kind != .preference, !primaryTag.isEmpty,
           let idx = tags.firstIndex(of: primaryTag), idx != 0 {
            tags.remove(at: idx)
            tags.insert(primaryTag, at: 0)
        }
        profile.setDecisionTags(Array(tags.prefix(16)))
        if kind == .decisionStyle, !streamedText.isEmpty {
            profile.duckSummary = DuckTextSanitizer.duckEyeSummary(from: streamedText)
        }
        if kind == .preference {
            let prefLine = cleaned.joined(separator: "、")
            if profile.preferences.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !prefLine.isEmpty {
                profile.preferences = prefLine
            }
        }
        try? modelContext.save()
        saved = true
    }

    private static func extractBracket(from text: String, key: String) -> String? {
        guard let range = text.range(of: key) else { return nil }
        let after = text[range.upperBound...]
        let line = after.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? String(after)
        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func extractTags(from text: String) -> [String] {
        guard let range = text.range(of: "【标签】") else { return [] }
        let after = text[range.upperBound...]
        let line = after.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? String(after)
        return QuizText.splitTagLine(line)
    }
}

/// 测试结果标签：彩色横排；展示前强制拆分去重，硬性最多 5 个。
struct QuizTagFlow: View {
    let tags: [String]

    var body: some View {
        let cleaned = Array(QuizText.normalizeTags(tags, limit: 5).prefix(5))
        if !cleaned.isEmpty {
            DuckTagCloud(tags: cleaned)
        }
    }
}

struct QuizResultsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \QuizResult.createdAt, order: .reverse) private var results: [QuizResult]
    @Query private var profiles: [UserProfile]
    @State private var pendingDelete: QuizResult?
    @State private var selectedResultID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(DuckTheme.duckOrange)
                }
                Text("我的测试结果")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(DuckTheme.inkBlue)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(DuckTheme.softWhite)

            ScrollView {
                LazyVStack(spacing: 12) {
                    if results.isEmpty {
                        Text("还没有测试结果，去试题库测一套吧～")
                            .font(.subheadline)
                            .foregroundStyle(DuckTheme.mutedText)
                            .padding(.top, 40)
                    }
                    ForEach(results) { result in
                        quizResultRow(result)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedResultID = result.id
                            }
                    }
                }
                .padding(20)
            }
            .background(DuckTheme.pageGradient)
        }
        .navigationBarHidden(true)
        .navigationDestination(item: $selectedResultID) { id in
            if let result = results.first(where: { $0.id == id }) {
                QuizResultDetailView(result: result) {
                    apply(result)
                }
            } else {
                Text("结果不存在或已删除")
                    .foregroundStyle(DuckTheme.mutedText)
            }
        }
        .alert("删除这条测试结果？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let pendingDelete {
                    modelContext.delete(pendingDelete)
                    try? modelContext.save()
                }
                pendingDelete = nil
            }
        }
    }

    private func quizResultRow(_ result: QuizResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(result.kind.imageName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(DuckTheme.inkBlue)
                    Text(result.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(DuckTheme.mutedText)
                }
                Spacer()
                Button {
                    pendingDelete = result
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(DuckTheme.duckOrange)
                }
                .buttonStyle(.plain)
            }

            Text(result.primaryTag)
                .font(.title3.weight(.heavy))
                .foregroundStyle(DuckTheme.duckOrange)
                .fixedSize(horizontal: false, vertical: true)

            let chips = QuizText.displayTags(for: result)
            if !chips.isEmpty {
                QuizTagFlow(tags: chips)
            }

            Text(QuizText.previewSummary(result.summary))
                .font(.caption)
                .foregroundStyle(DuckTheme.mutedText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("查看完整结果")
                    .font(.subheadline.weight(.heavy))
                Spacer()
                Image(systemName: "chevron.right")
            }
            .foregroundStyle(DuckTheme.skyBlue)
            .padding(.top, 2)
        }
        .padding(14)
        .background(DuckTheme.softWhite)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func apply(_ result: QuizResult) {
        guard let profile = profiles.first else { return }
        let cleaned = QuizText.displayTags(for: result)
        var tags = QuizText.normalizeTags(profile.decisionTags, limit: 16)
        for tag in cleaned where !tags.contains(tag) {
            tags.append(tag)
        }
        if result.kind != .preference, !result.primaryTag.isEmpty {
            tags.removeAll { $0 == result.primaryTag }
            tags.insert(result.primaryTag, at: 0)
        }
        profile.setDecisionTags(Array(tags.prefix(16)))
        try? modelContext.save()
    }
}

struct QuizResultDetailView: View {
    let result: QuizResult
    var onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var applied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(DuckTheme.duckOrange)
                }
                Text("测试结果详情")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(DuckTheme.inkBlue)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(DuckTheme.softWhite)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(result.kind.imageName)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title)
                                .font(.headline.weight(.heavy))
                                .foregroundStyle(DuckTheme.inkBlue)
                            Text(result.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(DuckTheme.mutedText)
                        }
                    }

                    DuckCard {
                        Text(result.primaryTag)
                            .font(.title2.weight(.heavy))
                            .foregroundStyle(DuckTheme.duckOrange)
                            .fixedSize(horizontal: false, vertical: true)

                        let chips = QuizText.displayTags(for: result)
                        if !chips.isEmpty {
                            QuizTagFlow(tags: chips)
                        }

                        // 偏好题已有标签芯片时，不再重复展示「你更偏向：…」说明行
                        if !result.detail.isEmpty,
                           !(result.kind == .preference && !chips.isEmpty) {
                            Text(result.detail)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DuckTheme.skyBlue)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text(QuizText.displaySummary(result.summary))
                            .font(.body)
                            .foregroundStyle(DuckTheme.inkBlue)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)

                        PrimaryDuckButton(
                            title: applied ? "已回填决策标签" : "回填到决策标签",
                            systemImage: "checkmark.seal.fill"
                        ) {
                            onApply()
                            applied = true
                        }
                        .disabled(applied)
                        .opacity(applied ? 0.7 : 1)
                    }
                }
                .padding(20)
            }
            .background(DuckTheme.pageGradient)
        }
        .navigationBarHidden(true)
    }
}

enum QuizText {
    static func previewSummary(_ text: String) -> String {
        let body = analysisBody(from: text)
        let compact = body
            .replacingOccurrences(of: "【鸭鸭分析】", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty ? text : compact
    }

    static func displaySummary(_ text: String) -> String {
        let body = analysisBody(from: text)
        return body.isEmpty ? text : body
    }

    /// 展示用标签：最多 5 个；旧偏好结果若只存了 1 个，尝试从 detail 行还原。
    static func displayTags(for result: QuizResult) -> [String] {
        let stored = normalizeTags(result.tags, limit: 5)
        if result.kind != .preference {
            return stored
        }
        if stored.count >= 2 {
            return stored
        }
        let detail = result.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.hasPrefix("你更偏向：") {
            let rest = String(detail.dropFirst("你更偏向：".count))
            let recovered = normalizeTags(
                rest.components(separatedBy: CharacterSet(charactersIn: "、，,")),
                limit: 5
            )
            if !recovered.isEmpty { return recovered }
        }
        if !stored.isEmpty { return stored }
        let primary = result.primaryTag.trimmingCharacters(in: .whitespacesAndNewlines)
        return primary.isEmpty ? [] : normalizeTags([primary], limit: 5)
    }

    static func analysisBody(from text: String) -> String {
        var body = stripTagSection(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "" }

        let headerKeys = ["【专属风格】", "【结果】", "【标签】"]
        for key in headerKeys {
            if let range = body.range(of: key) {
                let after = body[range.upperBound...]
                if let nl = after.firstIndex(of: "\n") {
                    body = String(after[after.index(after: nl)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    body = ""
                    break
                }
            }
        }

        if let range = body.range(of: "【鸭鸭分析】") {
            body = String(body[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            body = "【鸭鸭分析】\n" + body
        }
        return body
    }

    /// 删除模型可能输出的【标签】整行，避免污染展示。
    static func stripTagSection(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.hasPrefix("【标签】") || t.hasPrefix("标签：") || t.hasPrefix("标签:")
        }
        return lines.joined(separator: "\n")
    }

    /// 把「健康清淡 · 品牌控 · …」这类拼接串拆成短标签。
    static func splitTagLine(_ line: String) -> [String] {
        var normalized = line
        // 显式替换各种「看起来像点」的分隔符，避免 CharacterSet 源码字符不一致
        let dots = ["·", "•", "・", "･", "∙", "⋅", "‧", "ㆍ", "●", "．", "·", "･"]
        for dot in dots {
            normalized = normalized.replacingOccurrences(of: dot, with: ",")
        }
        for sep in [",", "，", "、", ";", "；", "|", "｜", "/", "／", "+", "—", "–", "-"] {
            normalized = normalized.replacingOccurrences(of: sep, with: ",")
        }

        var pieces: [String] = []
        var current = ""
        for ch in normalized {
            if ch == "," || ch.isWhitespace || ch.isNewline || ch.isPunctuation || ch.isSymbol {
                let part = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !part.isEmpty { pieces.append(part) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }

    /// 去重保序；每个标签必须短且互不相同；默认最多 5 个。
    static func normalizeTags(_ raw: [String], limit: Int = 5) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        for item in raw {
            for piece in splitTagLine(item) {
                let tag = piece
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "\u{00A0}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "【】[]「」#*"))
                guard !tag.isEmpty else { continue }
                guard (2...8).contains(tag.count) else { continue }
                guard !tag.contains("标签") else { continue }
                guard !tag.contains("分析") else { continue }
                guard !tag.hasPrefix("【") else { continue }
                // 任何标点/符号都不允许进标签（挡住各种 · 变体）
                guard tag.allSatisfy({ $0.isLetter || $0.isNumber }) else { continue }

                let key = tag.lowercased()
                guard !seen.contains(key) else { continue }

                if let idx = ordered.firstIndex(where: {
                    let old = $0.lowercased()
                    return old != key && (old.contains(key) || key.contains(old))
                }) {
                    if tag.count < ordered[idx].count {
                        seen.remove(ordered[idx].lowercased())
                        ordered.remove(at: idx)
                    } else {
                        continue
                    }
                }

                seen.insert(key)
                ordered.append(tag)
                if ordered.count >= limit { return ordered }
            }
        }
        return Array(ordered.prefix(limit))
    }
}