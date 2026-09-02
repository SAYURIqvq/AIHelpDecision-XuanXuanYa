import PhotosUI
import SwiftData
import SwiftUI

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatMessage.createdAt) private var messages: [ChatMessage]
    @Query private var profiles: [UserProfile]
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var recorder = AudioRecorder()
    @State private var selectedImage: PhotosPickerItem?
    @State private var selectedVideo: PhotosPickerItem?

    private let quickPrompts = ["中午吃啥", "买A还是买B", "要不要换工作"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HeaderBar()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            if messages.isEmpty {
                                EmptyChatHeader { prompt in
                                    viewModel.draft = prompt
                                }
                            }
                            ForEach(messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                            if viewModel.isThinking {
                                ThinkingBubble()
                            }
                        }
                        .padding(20)
                    }
                    .background(DuckTheme.pageGradient)
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                ChatInputBar(
                    draft: $viewModel.draft,
                    pendingAttachmentKind: viewModel.pendingAttachmentKind,
                    isRecording: recorder.isRecording,
                    selectedImage: $selectedImage,
                    selectedVideo: $selectedVideo,
                    sendAction: {
                        Task {
                            await viewModel.send(modelContext: modelContext, profile: profiles.first, recentMessages: messages)
                        }
                    },
                    recordAction: {
                        Task {
                            await recorder.toggleRecording()
                            if !recorder.isRecording, let url = recorder.lastRecordingURL {
                                viewModel.attach(kind: .audio, fileName: url.lastPathComponent)
                                await viewModel.transcribeRecording(url)
                            }
                        }
                    }
                )
            }
            .navigationBarHidden(true)
            .alert("鸭鸭提示", isPresented: Binding(
                get: { viewModel.errorMessage != nil || recorder.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil; recorder.errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? recorder.errorMessage ?? "")
            }
            .onChange(of: selectedImage) { _, item in
                Task { await handlePicker(item, kind: .image) }
            }
            .onChange(of: selectedVideo) { _, item in
                Task { await handlePicker(item, kind: .video) }
            }
        }
    }

    private func handlePicker(_ item: PhotosPickerItem?, kind: AttachmentKind) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        let ext = kind == .image ? "jpg" : "mov"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("duck-\(UUID().uuidString).\(ext)")
        try? data.write(to: url)
        await MainActor.run {
            viewModel.attach(kind: kind, fileName: url.lastPathComponent)
            if viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                viewModel.draft = kind == .image ? "我发了图片，帮我判断选哪个。" : "我发了视频，帮我分析后给我一个明确建议。"
            }
        }
    }
}

private struct EmptyChatHeader: View {
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

            HStack(spacing: 8) {
                Chip("中午吃啥") { choosePrompt("中午吃什么？我想快点决定。") }
                Chip("买A还是买B") { choosePrompt("我在 A 和 B 之间纠结，帮我拍板。") }
                Chip("要不要换工作") { choosePrompt("我在纠结要不要换工作，帮我分析。") }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if message.role == .assistant {
                avatar
            } else {
                Spacer(minLength: 40)
            }

            VStack(alignment: message.role == .assistant ? .leading : .trailing, spacing: 8) {
                if let kind = message.attachmentKind {
                    Label(kind.label, systemImage: kind.systemImage)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(DuckTheme.skyBlue)
                        .background(DuckTheme.softBlue)
                        .clipShape(Capsule())
                }
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(message.role == .assistant ? DuckTheme.inkBlue : .white)
                    .padding(14)
                    .background(message.role == .assistant ? DuckTheme.softWhite : DuckTheme.skyBlue)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.05), radius: 5, y: 3)
            }
            .frame(maxWidth: 292, alignment: message.role == .assistant ? .leading : .trailing)

            if message.role == .user {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(DuckTheme.warmYellow)
            } else {
                Spacer(minLength: 40)
            }
        }
    }

    private var avatar: some View {
        Image("MascotChat")
            .resizable()
            .scaledToFill()
            .frame(width: 34, height: 34)
            .clipShape(Circle())
    }
}

private struct ThinkingBubble: View {
    var body: some View {
        HStack(spacing: 10) {
            Image("MascotChat")
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(Circle())
            Text("鸭鸭正在拍板...")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DuckTheme.mutedText)
                .padding(12)
                .background(DuckTheme.softWhite)
                .clipShape(Capsule())
            Spacer()
        }
    }
}

private struct ChatInputBar: View {
    @Binding var draft: String
    let pendingAttachmentKind: AttachmentKind?
    let isRecording: Bool
    @Binding var selectedImage: PhotosPickerItem?
    @Binding var selectedVideo: PhotosPickerItem?
    let sendAction: () -> Void
    let recordAction: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let pendingAttachmentKind {
                Label("已添加\(pendingAttachmentKind.label)", systemImage: pendingAttachmentKind.systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DuckTheme.skyBlue)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                PhotosPicker(selection: $selectedImage, matching: .images) {
                    Image(systemName: "photo.badge.plus")
                        .font(.title3)
                }
                PhotosPicker(selection: $selectedVideo, matching: .videos) {
                    Image(systemName: "video.badge.plus")
                        .font(.title3)
                }
                Button(action: recordAction) {
                    Image(systemName: isRecording ? "stop.circle.fill" : "waveform.circle")
                        .font(.title3)
                        .foregroundStyle(isRecording ? .red : DuckTheme.skyBlue)
                }
                TextField("说出你的纠结...", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(DuckTheme.softWhite)
                    .clipShape(Capsule())
                    .overlay { Capsule().stroke(DuckTheme.warmYellow.opacity(0.55), lineWidth: 1) }
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
            .foregroundStyle(DuckTheme.skyBlue)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(DuckTheme.warmYellow.opacity(0.28)).frame(height: 1)
        }
    }
}

