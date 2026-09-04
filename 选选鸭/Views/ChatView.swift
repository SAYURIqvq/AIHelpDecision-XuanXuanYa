import SwiftData
import SwiftUI
import UIKit

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var chrome: AppChrome
    @Query(sort: \ChatMessage.createdAt) private var messages: [ChatMessage]
    @Query private var profiles: [UserProfile]
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var recorder = AudioRecorder()
    @State private var showClearConfirm = false
    @State private var showImageSourceDialog = false
    @State private var showVideoSourceDialog = false
    @State private var activeMediaPicker: SystemMediaPickerMode?
    /// 聊天+输入栏整体上移量（offset，不压缩列表，跟手更像微信）
    @State private var keyboardLift: CGFloat = 0
    /// 未上移时，聊天区（含输入栏）底边的全局 Y
    @State private var chatDockMaxY: CGFloat = 0
    @FocusState private var inputFocused: Bool
    @State private var actionTarget: MessageActionTarget?

    private struct MessageActionTarget: Identifiable, Equatable {
        let id: UUID
        /// 当前拖选范围内的文字
        var text: String
        let fullText: String
        var selectedAll: Bool = false
        /// 递增以触发 UITextView 全选
        var selectAllNonce: Int = 0
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HeaderBar {
                    if !messages.isEmpty {
                        Button {
                            showClearConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(.white.opacity(0.22))
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("清除聊天记录")
                    }
                }

                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 14) {
                                EmptyChatHeader(showQuickPrompts: messages.isEmpty) { prompt in
                                    viewModel.draft = prompt
                                    inputFocused = true
                                }
                                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                    messageRow(message: message, index: index)
                                }
                            Color.clear
                                .frame(height: 20)
                                .id("chat-bottom")
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                            .padding(.bottom, 12)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                guard actionTarget != nil else { return }
                                inputFocused = false
                                withAnimation(.easeOut(duration: 0.15)) { actionTarget = nil }
                            }
                        )
                        .onAppear {
                            scrollToBottom(proxy: proxy, animated: false, force: true)
                        }
                        .onChange(of: inputFocused) { _, focused in
                            if focused, actionTarget != nil {
                                withAnimation(.easeOut(duration: 0.15)) { actionTarget = nil }
                            }
                        }
                        .task {
                            await viewModel.recoverInterruptedGenerations(
                                messages: messages,
                                modelContext: modelContext,
                                profile: profiles.first
                            )
                        }
                        .task(id: messages.last?.id) {
                            scrollToBottom(proxy: proxy, animated: false, force: true)
                            try? await Task.sleep(nanoseconds: 80_000_000)
                            scrollToBottom(proxy: proxy, animated: false, force: true)
                        }
                        .onChange(of: messages.count) { _, _ in
                            scrollToBottom(proxy: proxy)
                        }
                        .onChange(of: viewModel.streamingMessageID) { _, _ in
                            scrollToBottom(proxy: proxy)
                        }
                        .onChange(of: viewModel.streamingText) { _, _ in
                            if viewModel.isStreaming {
                                scrollToBottom(proxy: proxy, animated: false)
                            }
                        }
                    }

                    ChatInputBar(
                        draft: $viewModel.draft,
                        quoteDraft: viewModel.quoteDraft,
                        pendingAttachments: viewModel.pendingAttachments,
                        isRecording: recorder.isRecording,
                        isFocused: $inputFocused,
                        imageAction: { showImageSourceDialog = true },
                        videoAction: { showVideoSourceDialog = true },
                        removeAttachmentAction: { viewModel.removePendingAttachment($0) },
                        clearAttachmentAction: { viewModel.clearAttachment() },
                        clearQuoteAction: { viewModel.clearQuote() },
                        sendAction: {
                            inputFocused = false
                            actionTarget = nil
                            Task {
                                await viewModel.send(modelContext: modelContext, profile: profiles.first, recentMessages: messages)
                            }
                        },
                        recordAction: {
                            inputFocused = false
                            Task {
                                await recorder.toggleRecording(currentDraft: viewModel.draft)
                                if !recorder.isRecording {
                                    viewModel.draft = recorder.composedDraft
                                }
                            }
                        },
                        dismissKeyboard: { inputFocused = false }
                    )
                }
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ChatPageFrameKey.self,
                            value: geo.frame(in: .global).maxY
                        )
                    }
                }
                // 整体平移上移：列表高度不变，最新消息不会被输入栏裁切
                .offset(y: -keyboardLift)
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DuckTheme.pageGradient.ignoresSafeArea())
            .onPreferenceChange(ChatPageFrameKey.self) { chatDockMaxY = $0 }
            .ignoresSafeArea(.keyboard)
            .navigationBarHidden(true)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { inputFocused = false }
                        .fontWeight(.semibold)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                applyKeyboardLift(from: note)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
                applyKeyboardLift(from: note, forceHide: true)
            }
            .onChange(of: recorder.liveTranscript) { _, _ in
                guard recorder.isRecording else { return }
                viewModel.draft = recorder.composedDraft
            }
            .alert("鸭鸭提示", isPresented: Binding(
                get: { viewModel.errorMessage != nil || recorder.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil; recorder.errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? recorder.errorMessage ?? "")
            }
            .alert("清除聊天记录？", isPresented: $showClearConfirm) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) {
                    viewModel.clearChat(messages: messages, modelContext: modelContext)
                }
            } message: {
                Text("只会清空聊天界面消息，不会删除决策历史，也不会影响鸭鸭对你的画像分析。")
            }
            .confirmationDialog("添加图片（最多\(ChatViewModel.maxPendingImages)张）", isPresented: $showImageSourceDialog, titleVisibility: .visible) {
                Button("现在拍照") { activeMediaPicker = .cameraPhoto }
                Button("从相册选择") { activeMediaPicker = .libraryPhoto }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("添加视频（仅1个）", isPresented: $showVideoSourceDialog, titleVisibility: .visible) {
                Button("现在录制") { activeMediaPicker = .cameraVideo }
                Button("从相册选择") { activeMediaPicker = .libraryVideo }
                Button("取消", role: .cancel) {}
            }
            .fullScreenCover(item: $activeMediaPicker) { mode in
                SystemMediaPicker(
                    mode: mode,
                    onPicked: { url, kind in
                        viewModel.attach(tempURL: url, kind: kind)
                        activeMediaPicker = nil
                        inputFocused = true
                    },
                    onCancel: { activeMediaPicker = nil }
                )
                .ignoresSafeArea()
            }
            .onChange(of: viewModel.needsGrainRecharge) { _, needed in
                guard needed else { return }
                viewModel.needsGrainRecharge = false
                chrome.presentExhausted()
            }
        }
    }

    private func messageRow(message: ChatMessage, index: Int) -> some View {
        let expired = message.hasInteractiveOptions
            && message.selectedOption.isEmpty
            && index < messages.count - 1
        let isActioning = actionTarget?.id == message.id
        let fullText = (viewModel.streamingMessageID == message.id
            ? (viewModel.streamingText.isEmpty ? message.displayText : viewModel.streamingText)
            : message.displayText
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return MessageBubble(
            message: message,
            profile: profiles.first,
            isStreaming: viewModel.streamingMessageID == message.id || message.isIncomplete,
            streamingText: viewModel.streamingMessageID == message.id ? viewModel.streamingText : nil,
            isExpired: expired,
            showActionMenu: isActioning,
            isTextSelectedAll: isActioning && (actionTarget?.selectedAll == true),
            selectAllNonce: isActioning ? (actionTarget?.selectAllNonce ?? 0) : 0,
            onLongPress: {
                guard !fullText.isEmpty else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.easeOut(duration: 0.15)) {
                    actionTarget = MessageActionTarget(
                        id: message.id,
                        text: fullText,
                        fullText: fullText,
                        selectedAll: true,
                        selectAllNonce: 1
                    )
                }
            },
            onSelectionChange: { selected in
                guard actionTarget?.id == message.id else { return }
                let clipped = selected.trimmingCharacters(in: .whitespacesAndNewlines)
                let effective = clipped.isEmpty ? fullText : selected
                actionTarget?.text = effective
                actionTarget?.selectedAll = (effective == fullText)
            },
            onAction: { action in
                handleMessageAction(action, message: message)
            },
            onChoose: { choice in
                inputFocused = false
                actionTarget = nil
                Task {
                    await viewModel.handleOptionTap(
                        choice,
                        message: message,
                        modelContext: modelContext,
                        profile: profiles.first,
                        recentMessages: messages
                    )
                }
            }
        )
        .id(message.id)
        .zIndex(isActioning ? 2 : 0)
    }

    private func handleMessageAction(_ action: MessageMenuAction, message: ChatMessage) {
        let fullText = actionTarget?.fullText ?? message.displayText
        let selected = (actionTarget?.text ?? fullText).trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .selectAll:
            withAnimation(.easeOut(duration: 0.12)) {
                let nonce = (actionTarget?.selectAllNonce ?? 0) + 1
                actionTarget = MessageActionTarget(
                    id: message.id,
                    text: fullText,
                    fullText: fullText,
                    selectedAll: true,
                    selectAllNonce: nonce
                )
            }
        case .copy:
            viewModel.copyTextToDraft(selected)
            UIPasteboard.general.string = selected
            inputFocused = true
            withAnimation { actionTarget = nil }
        case .delete:
            viewModel.deleteMessage(message, modelContext: modelContext)
            withAnimation { actionTarget = nil }
        case .quote:
            viewModel.setQuote(from: message, selectedText: selected)
            inputFocused = true
            withAnimation { actionTarget = nil }
        }
    }

    private func applyKeyboardLift(from note: Notification, forceHide: Bool = false) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        var target: CGFloat = 0

        if !forceHide,
           let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
           let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) {
            let keyboardTop = window.convert(frame, from: nil).minY
            // offset 不改变 layout frame，chatDockMaxY 始终是「未上移」底边
            let dockBottom = chatDockMaxY > 1 ? chatDockMaxY : (window.bounds.maxY - (49 + window.safeAreaInsets.bottom))
            target = max(0, dockBottom - keyboardTop)
            if target < 6 { target = 0 }
        }

        // 跟手拖拽收起时 duration≈0，直接贴合；弹起时用系统近似曲线
        if duration < 0.05 {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { keyboardLift = target }
        } else {
            withAnimation(.timingCurve(0.17, 0.84, 0.44, 1.0, duration: duration)) {
                keyboardLift = target
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true, force: Bool = false) {
        let scroll = {
            if let streamingID = viewModel.streamingMessageID {
                proxy.scrollTo(streamingID, anchor: .bottom)
            } else if force || !messages.isEmpty {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.18), scroll)
            } else {
                scroll()
            }
        }
    }
}

private struct ChatPageFrameKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct EmptyChatHeader: View {
    var showQuickPrompts: Bool = true
    let choosePrompt: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image("MascotChat")
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipShape(Circle())
                .overlay(Circle().stroke(DuckTheme.warmYellow, lineWidth: 3))
                .shadow(color: DuckTheme.warmYellow.opacity(0.22), radius: 10, y: 5)

            DuckCard(padding: 16) {
                Text("嗨，你好呀！我是选选鸭")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(DuckTheme.inkBlue)
                Text("告诉我你在纠结什么，可以发图片或视频给我看，鸭鸭帮你果断拍板。")
                    .font(.subheadline)
                    .foregroundStyle(DuckTheme.mutedText)
            }
            .frame(maxWidth: 300)

            if showQuickPrompts {
                HStack(spacing: 8) {
                    Chip("中午吃啥") { choosePrompt("中午吃什么？我想快点决定。") }
                    Chip("买A还是买B") { choosePrompt("我在 A 和 B 之间纠结，帮我拍板。") }
                    Chip("要不要换工作") { choosePrompt("我在纠结要不要换工作，帮我分析。") }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }
}

private enum MessageMenuAction {
    case selectAll, copy, delete, quote
}

private struct MessageBubble: View {
    let message: ChatMessage
    var profile: UserProfile? = nil
    var isStreaming: Bool = false
    var streamingText: String? = nil
    /// 用户没点选项又继续聊了 → 旧选项过期，展示「未选择」且不可点
    var isExpired: Bool = false
    var showActionMenu: Bool = false
    var isTextSelectedAll: Bool = false
    var selectAllNonce: Int = 0
    var onLongPress: (() -> Void)?
    var onSelectionChange: ((String) -> Void)?
    var onAction: ((MessageMenuAction) -> Void)?
    var onChoose: ((String) -> Void)?

    private var visibleText: String {
        if isStreaming, let streamingText, !streamingText.isEmpty {
            return streamingText
        }
        return message.displayText
    }

    private var showLoadingState: Bool {
        let empty = visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return empty && (isStreaming || message.isIncomplete)
    }

    private var bubbleFill: Color {
        if message.role == .assistant {
            return isTextSelectedAll ? DuckTheme.warmYellow.opacity(0.35) : DuckTheme.softWhite
        }
        return isTextSelectedAll ? DuckTheme.skyBlue.opacity(0.72) : DuckTheme.skyBlue
    }

    private var bubbleTextColor: Color {
        message.role == .assistant ? DuckTheme.inkBlue : .white
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                assistantAvatar
            } else {
                Spacer(minLength: 28)
            }

            VStack(alignment: message.role == .assistant ? .leading : .trailing, spacing: 8) {
                if showActionMenu {
                    MessageActionMenuBar { onAction?($0) }
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: message.role == .assistant ? .bottomLeading : .bottomTrailing)))
                }

                if message.hasAttachments {
                    MessageAttachmentStrip(
                        paths: message.attachmentPaths,
                        kind: message.attachmentKind,
                        size: CGSize(width: 120, height: 120)
                    )
                }

                if showLoadingState {
                    DecisionLoadingBubble()
                } else if !visibleText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        if message.hasQuote {
                            QuoteSnippetView(
                                label: message.quotedFromLabel,
                                text: message.quotedText,
                                compact: true
                            )
                            .allowsHitTesting(false)
                        }

                        if showActionMenu {
                            SelectableChatText(
                                text: visibleText,
                                textColor: UIColor(bubbleTextColor),
                                selectAllNonce: selectAllNonce,
                                onSelectionChange: { onSelectionChange?($0) }
                            )
                            .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(visibleText)
                                .font(.body)
                                .foregroundStyle(bubbleTextColor)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                    .background(bubbleFill)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    // 气泡宽度随内容，最长不超过父级 300
                    .frame(maxWidth: 280, alignment: message.role == .assistant ? .leading : .trailing)
                    .shadow(color: .black.opacity(0.05), radius: 5, y: 3)
                    .overlay {
                        if showActionMenu {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(DuckTheme.duckOrange.opacity(0.8), lineWidth: 2)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        if !showActionMenu {
                            BubbleLongPressOverlay {
                                onLongPress?()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }

                if message.hasInteractiveOptions {
                    DecisionOptionsView(
                        options: message.options,
                        recommendation: message.recommendationRaw,
                        selectedOption: message.selectedOption,
                        kind: message.interactionKind,
                        enabled: !isExpired && message.selectedOption.isEmpty && !isStreaming,
                        isExpired: isExpired,
                        onChoose: { onChoose?($0) }
                    )
                }
            }
            .frame(maxWidth: 300, alignment: message.role == .assistant ? .leading : .trailing)

            if message.role == .user {
                userAvatar
            } else {
                Spacer(minLength: 28)
            }
        }
    }

    private var assistantAvatar: some View {
        Image("MascotChat")
            .resizable()
            .scaledToFill()
            .frame(width: 42, height: 42)
            .clipShape(Circle())
            .overlay(Circle().stroke(DuckTheme.warmYellow, lineWidth: 2))
    }

    private var userAvatar: some View {
        ProfileAvatarView(profile: profile, size: 42, strokeColor: DuckTheme.warmYellow, strokeWidth: 2)
    }
}

/// 覆盖在气泡上的长按检测，不挡住滚动（与 ScrollView pan 同时识别，移动超限则失败）。
private struct BubbleLongPressOverlay: UIViewRepresentable {
    var onLongPress: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLongPress: onLongPress)
    }

    func makeUIView(context: Context) -> UIView {
        let view = PassThroughLongPressView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.onLongPress = context.coordinator.onLongPress

        let gesture = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        gesture.minimumPressDuration = 0.35
        gesture.allowableMovement = 14
        gesture.cancelsTouchesInView = false
        gesture.delegate = context.coordinator
        view.addGestureRecognizer(gesture)
        context.coordinator.gesture = gesture
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onLongPress = onLongPress
        (uiView as? PassThroughLongPressView)?.onLongPress = onLongPress
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onLongPress: () -> Void
        weak var gesture: UILongPressGestureRecognizer?

        init(onLongPress: @escaping () -> Void) {
            self.onLongPress = onLongPress
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            onLongPress()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // 不要求其他手势失败，避免被 ScrollView 拖拽永久卡住
            false
        }
    }
}

private final class PassThroughLongPressView: UIView {
    var onLongPress: (() -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 整块气泡都可点；本身透明
        bounds.contains(point) ? self : nil
    }
}

/// 仅在菜单激活后使用：展示系统选区角标，供拖选局部文字。
private struct SelectableChatText: UIViewRepresentable {
    let text: String
    let textColor: UIColor
    let selectAllNonce: Int
    var onSelectionChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange)
    }

    func makeUIView(context: Context) -> ChatSelectableTextView {
        let tv = ChatSelectableTextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = true
        tv.bounces = false
        tv.showsVerticalScrollIndicator = false
        tv.showsHorizontalScrollIndicator = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.required, for: .vertical)
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.adjustsFontForContentSizeCategory = true
        tv.textColor = textColor
        tv.tintColor = UIColor(DuckTheme.duckOrange)
        tv.text = text
        tv.linkTextAttributes = [:]
        return tv
    }

    func updateUIView(_ uiView: ChatSelectableTextView, context: Context) {
        context.coordinator.onSelectionChange = onSelectionChange

        if uiView.textColor != textColor {
            uiView.textColor = textColor
        }
        if uiView.text != text {
            uiView.text = text
        }

        if selectAllNonce != context.coordinator.lastSelectAllNonce {
            context.coordinator.lastSelectAllNonce = selectAllNonce
            context.coordinator.suppressSelectionCallback = true
            DispatchQueue.main.async {
                _ = uiView.becomeFirstResponder()
                uiView.selectAll(nil)
                context.coordinator.suppressSelectionCallback = false
                if let range = uiView.selectedTextRange, !range.isEmpty,
                   let selected = uiView.text(in: range) {
                    context.coordinator.onSelectionChange(selected)
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ChatSelectableTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        let safeWidth = max(width > 1 ? width : 260, 40)
        let size = uiView.sizeThatFits(CGSize(width: safeWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: safeWidth, height: max(ceil(size.height), 22))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onSelectionChange: (String) -> Void
        var lastSelectAllNonce = 0
        var suppressSelectionCallback = false

        init(onSelectionChange: @escaping (String) -> Void) {
            self.onSelectionChange = onSelectionChange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !suppressSelectionCallback else { return }
            guard let range = textView.selectedTextRange, !range.isEmpty else { return }
            let selected = textView.text(in: range) ?? ""
            onSelectionChange(selected)
        }

        @available(iOS 16.0, *)
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            UIMenu(title: "", options: .displayInline, children: [])
        }
    }
}

private final class ChatSelectableTextView: UITextView {
    override var canBecomeFirstResponder: Bool { true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }

    override func buildMenu(with builder: UIMenuBuilder) {}
}

private struct MessageActionMenuBar: View {
    let onAction: (MessageMenuAction) -> Void

    private let items: [(MessageMenuAction, String, String)] = [
        (.selectAll, "全选", "checkmark.rectangle"),
        (.copy, "复制", "doc.on.doc"),
        (.delete, "删除", "trash"),
        (.quote, "引用", "quote.bubble")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Button {
                    onAction(item.0)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.2)
                            .font(.caption.weight(.bold))
                        Text(item.1)
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 52)
                }
                .buttonStyle(.plain)
                if index < items.count - 1 {
                    Rectangle()
                        .fill(.white.opacity(0.18))
                        .frame(width: 1, height: 28)
                }
            }
        }
        .padding(.horizontal, 4)
        .background(Color(red: 0.18, green: 0.20, blue: 0.24).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }
}

private struct QuoteSnippetView: View {
    let label: String
    let text: String
    var compact: Bool = false
    var onClear: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Capsule()
                .fill(DuckTheme.skyBlue)
                .frame(width: 3, height: compact ? 26 : 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(DuckTheme.skyBlue)
                    .lineLimit(1)
                Text(text)
                    .font(compact ? .caption : .caption)
                    .foregroundStyle(DuckTheme.mutedText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let onClear {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(DuckTheme.mutedText.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, compact ? 0 : 10)
        .padding(.vertical, compact ? 0 : 8)
        .background(compact ? Color.clear : DuckTheme.softBlue)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // 防止被输入栏父布局纵向撑开
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DecisionOptionsView: View {
    let options: [String]
    let recommendation: String
    let selectedOption: String
    var kind: MessageInteractionKind = .decision
    let enabled: Bool
    var isExpired: Bool = false
    let onChoose: (String) -> Void

    private var displayOptions: [String] {
        kind == .chips ? options : options + [DuckSpeech.stillUndecided]
    }

    private let accentEmojis = ["✨", "🔥", "💡", "🎯", "🌟", "💪", "🍀", "🚀"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(headerTitle)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(isExpired ? DuckTheme.mutedText : DuckTheme.inkBlue.opacity(0.72))
                if isExpired {
                    Text("未选择")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(DuckTheme.mutedText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.90, green: 0.91, blue: 0.93))
                        .clipShape(Capsule())
                }
                Spacer(minLength: 0)
            }

            // 过期选项收成一行，避免旧「话题芯片」占满屏幕、看起来像当前选择
            if isExpired {
                Text(kind == .chips ? "你后来另开了话题，这些续聊入口已过期" : "你后来继续聊了，当时未确认决定")
                    .font(.caption)
                    .foregroundStyle(DuckTheme.mutedText.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(displayOptions.enumerated()), id: \.offset) { index, option in
                        optionButton(option, index: index)
                    }
                }
            }
        }
        .padding(isExpired ? 12 : 14)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(cardStroke, lineWidth: 1.2)
        }
    }

    private var cardBackground: some ShapeStyle {
        if isExpired {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.96, green: 0.96, blue: 0.97),
                        Color(red: 0.92, green: 0.93, blue: 0.95)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.96),
                    DuckTheme.warmYellow.opacity(0.12),
                    DuckTheme.softBlue.opacity(0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var cardStroke: some ShapeStyle {
        if isExpired {
            return AnyShapeStyle(DuckTheme.mutedText.opacity(0.22))
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [DuckTheme.warmYellow.opacity(0.55), DuckTheme.skyBlue.opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var headerTitle: String {
        if isExpired {
            return kind == .chips ? "当时未点续聊" : "当时未确认决定"
        }
        if kind == .chips {
            return selectedOption.isEmpty ? "接着往下聊 💬" : "已选，继续聊～"
        }
        if selectedOption.isEmpty {
            return "点一个最终决定 🦆"
        }
        if selectedOption == DuckSpeech.stillUndecided {
            return "先继续聊聊再拍板 💭"
        }
        return "已确认最终决定 ✅"
    }

    @ViewBuilder
    private func optionButton(_ option: String, index: Int) -> some View {
        let isUndecided = option == DuckSpeech.stillUndecided
        let isSelected = selectedOption == option
        let hasSelection = !selectedOption.isEmpty
        let isRecommend = kind == .decision && option == recommendation && !hasSelection && !isExpired
        let canTap = enabled && !isExpired && !hasSelection

        Button {
            guard canTap else { return }
            onChoose(option)
        } label: {
            HStack(spacing: 10) {
                Text(decoratedLabel(option, index: index))
                    .font(.subheadline.weight(.bold))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isSelected {
                    Text("✅")
                        .font(.body)
                } else if isExpired {
                    Text("未选")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(DuckTheme.mutedText.opacity(0.85))
                } else if isRecommend {
                    Text("荐")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(DuckTheme.duckOrange)
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(optionForeground(isSelected: isSelected, isUndecided: isUndecided, isExpired: isExpired))
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(optionBackground(isSelected: isSelected, isUndecided: isUndecided, isExpired: isExpired))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        optionStroke(isSelected: isSelected, isUndecided: isUndecided, isRecommend: isRecommend, isExpired: isExpired),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!canTap && !isSelected)
        .allowsHitTesting(canTap)
        .opacity(hasSelection && !isSelected ? 0.45 : 1)
        .animation(.easeOut(duration: 0.2), value: selectedOption)
    }

    private func decoratedLabel(_ option: String, index: Int) -> String {
        if option == DuckSpeech.stillUndecided {
            return option.containsEmoji ? option : "💭 \(option)"
        }
        if option.containsEmoji { return option }
        return "\(accentEmojis[index % accentEmojis.count]) \(option)"
    }

    private func optionForeground(isSelected: Bool, isUndecided: Bool, isExpired: Bool) -> Color {
        if isSelected { return DuckTheme.successGreen }
        if isExpired { return DuckTheme.mutedText.opacity(0.75) }
        if isUndecided { return DuckTheme.inkBlue }
        return DuckTheme.inkBlue
    }

    private func optionBackground(isSelected: Bool, isUndecided: Bool, isExpired: Bool) -> some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(DuckTheme.successGreen.opacity(0.14))
        }
        if isExpired {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.94, green: 0.94, blue: 0.95),
                        Color(red: 0.89, green: 0.90, blue: 0.92)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        if isUndecided {
            return AnyShapeStyle(DuckTheme.softBlue)
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.97, blue: 0.82),
                    Color(red: 1.0, green: 0.93, blue: 0.62),
                    Color(red: 1.0, green: 0.88, blue: 0.48)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func optionStroke(isSelected: Bool, isUndecided: Bool, isRecommend: Bool, isExpired: Bool) -> Color {
        if isSelected { return DuckTheme.successGreen }
        if isExpired { return DuckTheme.mutedText.opacity(0.22) }
        if isUndecided { return DuckTheme.skyBlue.opacity(0.45) }
        if isRecommend { return DuckTheme.duckOrange.opacity(0.45) }
        return DuckTheme.warmYellow.opacity(0.55)
    }
}

private extension String {
    var containsEmoji: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .otherSymbol, .otherLetter:
                return scalar.value > 0x2600
            default:
                return (0x1F300...0x1FAFF).contains(scalar.value)
                    || (0x2600...0x27BF).contains(scalar.value)
            }
        }
    }
}

private struct DecisionLoadingBubble: View {
    @State private var bounce = false

    var body: some View {
        HStack(spacing: 10) {
            Text("鸭鸭在想呢...")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(DuckTheme.inkBlue)
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(DuckTheme.duckOrange)
                        .frame(width: 7, height: 7)
                        .offset(y: bounce ? -4 : 4)
                        .animation(
                            .easeInOut(duration: 0.45)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.12),
                            value: bounce
                        )
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [DuckTheme.softWhite, DuckTheme.softBlue],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DuckTheme.skyBlue.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.05), radius: 5, y: 3)
        .onAppear { bounce = true }
    }
}

private struct MessageAttachmentStrip: View {
    let paths: [String]
    let kind: AttachmentKind?
    var size: CGSize = CGSize(width: 120, height: 120)

    var body: some View {
        if paths.count <= 1 {
            AttachmentThumbnail(
                relativePath: paths.first,
                kind: kind,
                size: size
            )
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                        AttachmentThumbnail(
                            relativePath: path,
                            kind: .image,
                            size: size
                        )
                    }
                }
            }
        }
    }
}

private struct AttachmentThumbnail: View {
    let relativePath: String?
    let kind: AttachmentKind?
    var size: CGSize = CGSize(width: 88, height: 88)
    var onDelete: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .bottomTrailing) {
                if let image = AttachmentStore.loadImage(relativePath: relativePath) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    ZStack {
                        DuckTheme.softBlue
                        Image(systemName: kind?.systemImage ?? "photo")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(DuckTheme.skyBlue)
                    }
                    .frame(width: size.width, height: size.height)
                }

                if kind == .video {
                    Image(systemName: "video.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.45))
                        .clipShape(Circle())
                        .padding(6)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.8), lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, DuckTheme.duckOrange)
                        .background(Circle().fill(.white).padding(2))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("删除附件")
            }
        }
    }
}

private struct ChatInputBar: View {
    @Binding var draft: String
    var quoteDraft: ChatViewModel.QuoteDraft?
    let pendingAttachments: [PendingAttachment]
    let isRecording: Bool
    var isFocused: FocusState<Bool>.Binding
    let imageAction: () -> Void
    let videoAction: () -> Void
    let removeAttachmentAction: (UUID) -> Void
    let clearAttachmentAction: () -> Void
    var clearQuoteAction: (() -> Void)? = nil
    let sendAction: () -> Void
    let recordAction: () -> Void
    let dismissKeyboard: () -> Void

    private var pendingKind: AttachmentKind? { pendingAttachments.first?.kind }
    private var imageCount: Int { pendingAttachments.filter { $0.kind == .image }.count }

    var body: some View {
        VStack(spacing: 8) {
            if let quoteDraft {
                QuoteSnippetView(
                    label: "引用 \(quoteDraft.fromLabel)",
                    text: quoteDraft.text,
                    onClear: { clearQuoteAction?() }
                )
            }
            if !pendingAttachments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(pendingHeader)
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(DuckTheme.inkBlue)
                        Spacer()
                        Button("全部清除", action: clearAttachmentAction)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(DuckTheme.duckOrange)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(pendingAttachments) { item in
                                AttachmentThumbnail(
                                    relativePath: item.relativePath,
                                    kind: item.kind,
                                    size: CGSize(width: 72, height: 72),
                                    onDelete: { removeAttachmentAction(item.id) }
                                )
                            }
                            if pendingKind == .image, imageCount < ChatViewModel.maxPendingImages {
                                Button(action: imageAction) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "plus")
                                            .font(.title3.weight(.bold))
                                        Text("\(imageCount)/\(ChatViewModel.maxPendingImages)")
                                            .font(.caption2.weight(.bold))
                                    }
                                    .foregroundStyle(DuckTheme.skyBlue)
                                    .frame(width: 72, height: 72)
                                    .background(DuckTheme.softWhite)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(DuckTheme.skyBlue.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [5]))
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("继续添加图片")
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.trailing, 4)
                    }
                }
                .padding(10)
                .background(DuckTheme.softBlue)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            HStack(spacing: 10) {
                Button(action: imageAction) {
                    Image(systemName: "photo.badge.plus")
                        .font(.title3)
                        .foregroundStyle(DuckTheme.skyBlue)
                }
                .accessibilityLabel("添加图片")

                Button(action: videoAction) {
                    Image(systemName: "video.badge.plus")
                        .font(.title3)
                        .foregroundStyle(DuckTheme.skyBlue)
                }
                .accessibilityLabel("添加视频")

                Button(action: recordAction) {
                    Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title3)
                        .foregroundStyle(isRecording ? .red : DuckTheme.skyBlue)
                }
                .accessibilityLabel(isRecording ? "结束语音输入" : "语音转文字")
                TextField(
                    "",
                    text: $draft,
                    prompt: Text(isRecording ? "正在听你说…说完再点一下结束" : "说出你的纠结...")
                        .foregroundStyle(DuckTheme.inkBlue.opacity(0.55)),
                    axis: .vertical
                )
                .lineLimit(1...4)
                .focused(isFocused)
                .disabled(isRecording)
                .submitLabel(.done)
                .onSubmit { dismissKeyboard() }
                .foregroundStyle(DuckTheme.inkBlue)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color.white)
                .clipShape(Capsule())
                .overlay {
                    Capsule().stroke(
                        isRecording ? Color.red.opacity(0.55) : DuckTheme.duckOrange.opacity(0.45),
                        lineWidth: 1.2
                    )
                }
                Button(action: sendAction) {
                    Image("MascotChat")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 42, height: 42)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(DuckTheme.warmYellow, lineWidth: 2))
                }
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(DuckTheme.inputBarChromeGradient)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DuckTheme.inputBarEdge)
                .frame(height: 1.5)
        }
        .shadow(color: DuckTheme.skyBlue.opacity(0.08), radius: 6, y: -2)
    }

    private var pendingHeader: String {
        switch pendingKind {
        case .video: return "已添加视频（仅 1 个）"
        case .image: return "已添加图片 \(imageCount)/\(ChatViewModel.maxPendingImages)"
        case .audio, .none: return "附件"
        }
    }
}
