import AVFoundation
import LiveKit
import SwiftUI

struct CallView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var chrome: AppChrome
    @StateObject private var viewModel = LiveKitCallViewModel()

    private var isInCall: Bool {
        viewModel.state == .connected || viewModel.state == .connecting
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DuckTheme.pageGradient.ignoresSafeArea()

                if isInCall {
                    ActiveCallScreen(
                        viewModel: viewModel,
                        onHangUp: hangUp
                    )
                    .transition(.opacity)
                } else {
                    CallLobbyView(
                        onVoice: { start(.voice) },
                        onVideo: { start(.video) },
                        errorText: errorText
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: isInCall)
            .navigationBarHidden(true)
            .toolbar(isInCall ? .hidden : .automatic, for: .tabBar)
            .task {
                await viewModel.prepareIfNeeded()
            }
        }
    }

    private var errorText: String? {
        if case .failed(let message) = viewModel.state { return message }
        if viewModel.state == .permissionDenied {
            return viewModel.mode == .voice
                ? "需要麦克风权限才能和鸭鸭打电话鸭～"
                : "需要相机和麦克风权限才能和鸭鸭打视频鸭～"
        }
        return nil
    }

    private func start(_ mode: DuckCallMode) {
        Task { @MainActor in
            let wallet = GrainWalletService.ensureWallet(in: modelContext)
            guard GrainWalletService.canStartCall(wallet: wallet, mode: mode) else {
                chrome.presentExhausted()
                return
            }
            await viewModel.startCall(mode: mode)
        }
    }

    private func hangUp() {
        let seconds = viewModel.billableSeconds
        let mode = viewModel.mode
        // 立刻回到大厅，避免冷启动后 stopRunning 卡住黑屏
        viewModel.leaveCallUI()
        Task { @MainActor in
            await viewModel.teardownMedia()
            let wallet = GrainWalletService.ensureWallet(in: modelContext)
            if case .exhausted = GrainWalletService.consumeCall(
                seconds: max(seconds, 1),
                mode: mode,
                wallet: wallet,
                context: modelContext
            ) {
                chrome.presentExhausted()
            }
        }
    }
}

// MARK: - Lobby

private struct CallLobbyView: View {
    let onVoice: () -> Void
    let onVideo: () -> Void
    var errorText: String?

    @State private var float = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(DuckTheme.warmYellow.opacity(0.22))
                                .frame(width: 118, height: 118)
                                .scaleEffect(float ? 1.08 : 0.94)
                            Image("MascotSplash")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 96, height: 96)
                                .offset(y: float ? -6 : 4)
                        }
                        Text("实时商量决策")
                            .font(.title2.weight(.heavy))
                            .foregroundStyle(DuckTheme.inkBlue)
                        Text("选一种方式和鸭鸭当面把选择敲定")
                            .font(.subheadline)
                            .foregroundStyle(DuckTheme.mutedText)
                            .multilineTextAlignment(.center)
                        Text("电话 \(GrainCosts.voiceCallPerMinute)谷粒/分钟 · 视频 \(GrainCosts.videoCallPerMinute)谷粒/分钟")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(DuckTheme.duckOrange)
                    }
                    .padding(.top, 12)

                    CallModeCard(
                        title: "和鸭鸭打电话商量",
                        subtitle: "和鸭鸭打电话商量 · \(GrainCosts.voiceCallPerMinute)谷粒/分钟",
                        badge: "语音",
                        systemImage: "phone.fill",
                        gradient: [
                            Color(red: 0.35, green: 0.78, blue: 0.98),
                            Color(red: 0.18, green: 0.62, blue: 0.92)
                        ],
                        action: onVoice
                    )

                    CallModeCard(
                        title: "和鸭鸭打视频商量",
                        subtitle: "实时视频 · 鸭鸭看得见选项 · \(GrainCosts.videoCallPerMinute)谷粒/分钟",
                        badge: "视频",
                        systemImage: "video.fill",
                        gradient: [
                            Color(red: 1.0, green: 0.78, blue: 0.28),
                            Color(red: 1.0, green: 0.58, blue: 0.16)
                        ],
                        action: onVideo
                    )

                    if let errorText {
                        Text(errorText)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                float = true
            }
        }
    }
}

private struct CallModeCard: View {
    let title: String
    let subtitle: String
    let badge: String
    let systemImage: String
    let gradient: [Color]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.22))
                        .frame(width: 58, height: 58)
                    Image(systemName: systemImage)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                        Text(badge)
                            .font(.caption2.weight(.black))
                            .foregroundStyle(gradient[1])
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.white)
                            .clipShape(Capsule())
                    }
                    Text(subtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(18)
            .background(
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: gradient.last?.opacity(0.35) ?? .clear, radius: 14, y: 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Active fullscreen call

private struct ActiveCallScreen: View {
    @ObservedObject var viewModel: LiveKitCallViewModel
    let onHangUp: () -> Void

    private var isConnecting: Bool { viewModel.state == .connecting }

    var body: some View {
        ZStack {
            callBackground.ignoresSafeArea()

            if viewModel.mode == .video {
                videoCameraLayer
            }

            VStack(spacing: 12) {
                callTopBar

                if viewModel.mode == .voice {
                    Spacer(minLength: 0)
                    voiceCallContent
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    videoCoachRow
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }

                callControls
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
    }

    private var callBackground: some View {
        Group {
            if viewModel.mode == .voice {
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.22, blue: 0.42),
                        Color(red: 0.16, green: 0.42, blue: 0.68),
                        Color(red: 0.22, green: 0.55, blue: 0.72)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                Color.black
            }
        }
    }

    private var callTopBar: some View {
        VStack(spacing: 6) {
            Text(viewModel.mode.title)
                .font(.headline.weight(.heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            HStack(spacing: 8) {
                Text(isConnecting ? "正在接通鸭鸭…" : viewModel.formattedElapsed)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("·")
                    .foregroundStyle(.white.opacity(0.45))
                Text("\(viewModel.mode.grainsPerMinute)谷粒/分钟")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DuckTheme.warmYellow)
                    .lineLimit(1)
                if viewModel.usesOmniRealtime {
                    Text("·")
                        .foregroundStyle(.white.opacity(0.45))
                    Text("鸭鸭在线")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(red: 0.55, green: 0.95, blue: 0.72))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var voiceCallContent: some View {
        VStack(spacing: 22) {
            PulsingDuckOrb(
                title: voiceOrbTitle,
                subtitle: voiceOrbSubtitle
            )
            VoiceWaveBars(active: (!viewModel.isMuted && !isConnecting) || viewModel.isDuckSpeaking)
            if !viewModel.assistantTranscript.isEmpty || !viewModel.userTranscript.isEmpty {
                CallTranscriptPanel(
                    userText: viewModel.userTranscript,
                    duckText: viewModel.assistantTranscript,
                    compact: false
                )
            }
        }
        .padding(.horizontal, 4)
    }

    private var voiceOrbTitle: String {
        if isConnecting { return "鸭鸭来电中…" }
        if viewModel.isDuckSpeaking { return "鸭鸭正在说…" }
        if viewModel.isUserSpeaking { return "鸭鸭在听你说" }
        return viewModel.usesOmniRealtime ? "和鸭鸭实时商量中" : "鸭鸭在听你说"
    }

    private var voiceOrbSubtitle: String {
        if isConnecting { return "叮咚叮咚，马上接听" }
        if !viewModel.turnHint.isEmpty { return viewModel.turnHint }
        if viewModel.isDuckSpeaking { return "点「打断」或清楚说话，就能插话" }
        if viewModel.isUserSpeaking { return "说完稍停一下，鸭鸭就接上" }
        return viewModel.usesOmniRealtime ? "把纠结说出来，鸭鸭用声音帮你拍板" : "把纠结说出来，一起商量拍板"
    }

    /// 全屏本机摄像头底层
    private var videoCameraLayer: some View {
        ZStack {
            FullscreenLocalCamera(
                track: viewModel.localVideoTrack,
                useLocalPreview: viewModel.useLocalPreview && viewModel.cameraEnabled,
                localSession: viewModel.localCamera.session,
                mirror: viewModel.usingFrontCamera,
                cameraEnabled: viewModel.cameraEnabled
            )
            .ignoresSafeArea()

            VStack {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 260)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private var videoCoachRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                FloatingDuckCoach(
                    isConnecting: isConnecting,
                    cameraOn: viewModel.cameraEnabled,
                    isSpeaking: viewModel.isDuckSpeaking,
                    subtitle: videoCoachSubtitle
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(viewModel.usingFrontCamera ? "前置" : "后置 · 对准选项")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(viewModel.usingFrontCamera ? .white : DuckTheme.inkBlue)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 92)
                    .background(viewModel.usingFrontCamera ? Color.black.opacity(0.35) : DuckTheme.warmYellow)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if !viewModel.assistantTranscript.isEmpty || !viewModel.userTranscript.isEmpty {
                CallTranscriptPanel(
                    userText: viewModel.userTranscript,
                    duckText: viewModel.assistantTranscript,
                    compact: true
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var videoCoachSubtitle: String {
        if isConnecting { return "正在接通…" }
        if !viewModel.turnHint.isEmpty { return viewModel.turnHint }
        if viewModel.isDuckSpeaking { return "点「打断」可插话" }
        if viewModel.isUserSpeaking { return "在听你说" }
        return viewModel.usesOmniRealtime ? "对准选项，鸭鸭看得见" : "把纠结对准镜头"
    }

    private var callControls: some View {
        HStack(spacing: 12) {
            CallControlButton(
                systemImage: viewModel.isMuted ? "mic.slash.fill" : "mic.fill",
                label: viewModel.isMuted ? "已静音" : "静音",
                tint: viewModel.isMuted ? DuckTheme.duckOrange : .white.opacity(0.18)
            ) {
                Task { await viewModel.setMuted(!viewModel.isMuted) }
            }

            if viewModel.showsTurnControl {
                CallControlButton(
                    systemImage: viewModel.turnControlSymbol,
                    label: viewModel.turnControlLabel,
                    tint: turnControlTint,
                    emphasized: viewModel.canInterruptNow
                ) {
                    viewModel.interruptDuckSpeaking()
                }
            }

            if viewModel.mode == .video {
                CallControlButton(
                    systemImage: viewModel.cameraEnabled ? "video.fill" : "video.slash.fill",
                    label: viewModel.cameraEnabled ? "摄像头" : "已关闭",
                    tint: viewModel.cameraEnabled ? .white.opacity(0.18) : DuckTheme.duckOrange
                ) {
                    Task { await viewModel.setCameraEnabled(!viewModel.cameraEnabled) }
                }

                CallControlButton(
                    systemImage: "arrow.triangle.2.circlepath.camera.fill",
                    label: "翻转",
                    tint: .white.opacity(0.18)
                ) {
                    Task { await viewModel.switchCamera() }
                }
            }

            CallControlButton(
                systemImage: "phone.down.fill",
                label: "挂断",
                tint: Color(red: 0.92, green: 0.28, blue: 0.28),
                large: true
            ) {
                onHangUp()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 14)
        .background(.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .animation(.easeInOut(duration: 0.18), value: viewModel.canInterruptNow)
        .animation(.easeInOut(duration: 0.18), value: viewModel.isUserSpeaking)
    }

    private var turnControlTint: Color {
        if viewModel.canInterruptNow {
            return DuckTheme.warmYellow.opacity(0.95)
        }
        if viewModel.isUserSpeaking {
            return Color(red: 0.28, green: 0.78, blue: 0.58).opacity(0.95)
        }
        return .white.opacity(0.18)
    }
}

private struct CallTranscriptPanel: View {
    let userText: String
    let duckText: String
    var compact: Bool = false

    private var maxHeight: CGFloat { compact ? 180 : 220 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if !userText.isEmpty {
                    Text("你：\(userText)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(compact ? 0.85 : 0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !duckText.isEmpty {
                    Text("鸭鸭：\(duckText)")
                        .font(compact ? .caption.weight(.bold) : .subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 12 : 14)
        .background(compact ? Color.black.opacity(0.42) : Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 14 : 16, style: .continuous))
    }
}

private struct FullscreenLocalCamera: View {
    let track: VideoTrack?
    let useLocalPreview: Bool
    let localSession: AVCaptureSession
    var mirror: Bool
    var cameraEnabled: Bool

    var body: some View {
        ZStack {
            Color.black
            if useLocalPreview {
                LocalCameraPreview(session: localSession, mirror: mirror)
            } else if let track, cameraEnabled {
                SwiftUIVideoView(track, mirrorMode: mirror ? .mirror : .off)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                    Text("摄像头已关闭")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }
}

private struct FloatingDuckCoach: View {
    var isConnecting: Bool
    var cameraOn: Bool
    var isSpeaking: Bool = false
    var subtitle: String? = nil

    @State private var bob = false
    @State private var glow = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .stroke(DuckTheme.warmYellow.opacity(glow ? 0.2 : 0.75), lineWidth: 2)
                    .frame(width: 64, height: 64)
                    .scaleEffect(glow ? 1.18 : 1.0)
                Image("MascotChat")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .offset(y: bob ? -3 : 2)
            }
            // 给呼吸光圈和上下浮动留足空间，避免被父级裁切
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 4) {
                Text(coachTitle)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(coachSubtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.black.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                bob = true
                glow = true
            }
        }
    }

    private var coachTitle: String {
        if isConnecting { return "鸭鸭接通中…" }
        if isSpeaking { return "鸭鸭正在说" }
        return "鸭鸭陪你看"
    }

    private var coachSubtitle: String {
        if let subtitle, !subtitle.isEmpty { return subtitle }
        return cameraOn ? "把选项对准镜头，说说你的纠结" : "打开摄像头，鸭鸭才能帮你看鸭"
    }
}

private struct CallControlButton: View {
    let systemImage: String
    let label: String
    let tint: Color
    var large: Bool = false
    var emphasized: Bool = false
    let action: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if emphasized {
                        Circle()
                            .stroke(DuckTheme.warmYellow.opacity(pulse ? 0.15 : 0.65), lineWidth: 2)
                            .frame(width: pulse ? 64 : 56, height: pulse ? 64 : 56)
                    }
                    Image(systemName: systemImage)
                        .font(large ? .title2.weight(.bold) : .body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: large ? 68 : 52, height: large ? 68 : 52)
                        .background(tint)
                        .clipShape(Circle())
                }
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .onAppear { pulse = emphasized }
        .onChange(of: emphasized) { _, on in
            pulse = on
        }
        .animation(
            emphasized
                ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                : .default,
            value: pulse
        )
    }
}

private struct PulsingDuckOrb: View {
    let title: String
    let subtitle: String

    @State private var pulse = false
    @State private var spin = false
    @State private var bob = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [
                                    DuckTheme.warmYellow.opacity(0.0),
                                    DuckTheme.warmYellow.opacity(0.55 - Double(i) * 0.12),
                                    DuckTheme.skyBlue.opacity(0.45),
                                    DuckTheme.warmYellow.opacity(0.0)
                                ],
                                center: .center
                            ),
                            lineWidth: 2.5
                        )
                        .frame(width: 150 + CGFloat(i) * 36, height: 150 + CGFloat(i) * 36)
                        .scaleEffect(pulse ? 1.08 : 0.92)
                        .opacity(pulse ? 0.35 : 0.85)
                        .rotationEffect(.degrees(spin ? Double(i % 2 == 0 ? 360 : -360) : 0))
                        .animation(
                            .easeInOut(duration: 1.3 + Double(i) * 0.25)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.12),
                            value: pulse
                        )
                }

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [DuckTheme.warmYellow.opacity(0.55), .clear],
                            center: .center,
                            startRadius: 10,
                            endRadius: 80
                        )
                    )
                    .frame(width: 160, height: 160)
                    .scaleEffect(pulse ? 1.1 : 0.9)

                Image("MascotSplash")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .shadow(color: DuckTheme.warmYellow.opacity(0.45), radius: 16, y: 6)
                    .offset(y: bob ? -8 : 6)
                    .scaleEffect(bob ? 1.04 : 0.97)
            }
            .frame(height: 240)

            Text(title)
                .font(.title3.weight(.heavy))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
        }
        .onAppear {
            pulse = true
            bob = true
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                spin = true
            }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                bob = true
            }
        }
    }
}

private struct VoiceWaveBars: View {
    var active: Bool
    @State private var wave = false

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<7, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [DuckTheme.warmYellow, DuckTheme.skyBlue],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 7, height: barHeight(index))
                    .animation(
                        active
                            ? .easeInOut(duration: 0.38)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.07)
                            : .default,
                        value: wave
                    )
            }
        }
        .frame(height: 42)
        .opacity(active ? 1 : 0.35)
        .onAppear {
            wave = true
        }
        .onChange(of: active) { _, _ in
            wave = false
            DispatchQueue.main.async { wave = true }
        }
    }

    private func barHeight(_ index: Int) -> CGFloat {
        guard active else { return 10 }
        let base: [CGFloat] = [14, 26, 36, 42, 34, 24, 16]
        return wave ? base[index] : max(8, base[index] * 0.4)
    }
}
