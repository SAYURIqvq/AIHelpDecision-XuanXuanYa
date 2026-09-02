import LiveKit
import SwiftUI

struct CallView: View {
    @StateObject private var viewModel = LiveKitCallViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HeaderBar()
                ScrollView {
                    VStack(spacing: 22) {
                        VStack(spacing: 8) {
                            Image(systemName: "video.bubble.left.fill")
                                .font(.system(size: 44, weight: .bold))
                                .foregroundStyle(DuckTheme.skyBlue)
                            Text("视频商量决策")
                                .font(.title2.weight(.heavy))
                                .foregroundStyle(DuckTheme.inkBlue)
                            Text("和好友 1v1 当面把选择敲定")
                                .font(.subheadline)
                                .foregroundStyle(DuckTheme.mutedText)
                        }
                        .padding(.top, 18)

                        CallStage(
                            state: viewModel.state,
                            localTrack: viewModel.localVideoTrack,
                            remoteTrack: viewModel.remoteVideoTrack
                        )

                        PrimaryDuckButton(title: callButtonTitle, systemImage: callButtonIcon) {
                            Task {
                                if viewModel.state == .connected || viewModel.state == .connecting {
                                    await viewModel.endCall()
                                } else {
                                    await viewModel.startCall()
                                }
                            }
                        }

                        DuckCard {
                            Label("通话状态", systemImage: "info.circle")
                                .font(.headline.weight(.heavy))
                                .foregroundStyle(DuckTheme.inkBlue)
                            Text(viewModel.statusText)
                                .font(.subheadline)
                                .foregroundStyle(DuckTheme.mutedText)
                        }

                        if viewModel.state == .connected {
                            HStack(spacing: 12) {
                                ToggleButton(
                                    title: viewModel.isMuted ? "打开麦克风" : "静音",
                                    systemImage: viewModel.isMuted ? "mic.slash.fill" : "mic.fill",
                                    isActive: viewModel.isMuted
                                ) {
                                    Task { await viewModel.setMuted(!viewModel.isMuted) }
                                }
                                ToggleButton(
                                    title: viewModel.cameraEnabled ? "关闭摄像头" : "打开摄像头",
                                    systemImage: viewModel.cameraEnabled ? "video.fill" : "video.slash.fill",
                                    isActive: !viewModel.cameraEnabled
                                ) {
                                    Task { await viewModel.setCameraEnabled(!viewModel.cameraEnabled) }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
                .background(DuckTheme.pageGradient)
            }
            .navigationBarHidden(true)
        }
    }

    private var callButtonTitle: String {
        switch viewModel.state {
        case .connected, .connecting:
            return "挂断通话"
        default:
            return "发起通话"
        }
    }

    private var callButtonIcon: String {
        switch viewModel.state {
        case .connected, .connecting:
            return "phone.down.fill"
        default:
            return "video.fill"
        }
    }
}

private struct CallStage: View {
    let state: LiveKitCallViewModel.CallState
    let localTrack: VideoTrack?
    let remoteTrack: VideoTrack?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(DuckTheme.inkBlue)
                .frame(height: 330)

            VStack(spacing: 12) {
                if state == .connected || state == .connecting {
                    HStack(spacing: 10) {
                        VideoTile(title: "好友", color: DuckTheme.skyBlue, systemImage: "person.fill", track: remoteTrack)
                        VideoTile(title: "我", color: DuckTheme.warmYellow, systemImage: "person.crop.circle.fill", track: localTrack)
                    }
                } else {
                    Image("MascotSplash")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 142, height: 142)
                    Text("点一下就能开始")
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(.white)
                    Text("没有房间号，没有复杂步骤")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .padding(18)
        }
        .shadow(color: DuckTheme.inkBlue.opacity(0.18), radius: 16, y: 8)
    }
}

private struct VideoTile: View {
    let title: String
    let color: Color
    let systemImage: String
    let track: VideoTrack?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let track {
                SwiftUIVideoView(track, mirrorMode: title == "我" ? .mirror : .off)
            } else {
                VStack {
                    Spacer()
                    Image(systemName: systemImage)
                        .font(.system(size: 42))
                        .foregroundStyle(.white)
                    Text(title == "我" ? "等待本地画面" : "等待好友加入")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.76))
                    Spacer()
                }
            }
            Text(title)
                .font(.headline.weight(.heavy))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.18))
                .clipShape(Capsule())
                .padding(10)
        }
        .frame(maxWidth: .infinity, minHeight: 284)
        .background(color.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ToggleButton: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundStyle(isActive ? .white : DuckTheme.inkBlue)
                .background(isActive ? DuckTheme.inkBlue : DuckTheme.softWhite)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
