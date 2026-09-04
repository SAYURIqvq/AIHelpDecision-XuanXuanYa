import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]
    @StateObject private var chrome = AppChrome()
    @State private var showSplash = true

    var body: some View {
        ZStack {
            MainTabView()
                .environmentObject(chrome)
                .opacity(showSplash ? 0 : 1)

            if showSplash {
                SplashView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .environmentObject(chrome)
        .sheet(isPresented: $chrome.showGrainExhaustSheet) {
            GrainExhaustSheet()
                .environmentObject(chrome)
        }
        .alert(chrome.purchaseSuccessMessage, isPresented: $chrome.showPurchaseSuccess) {
            Button("好鸭", role: .cancel) {}
        }
        .onAppear {
            ensureProfile()
            _ = GrainWalletService.ensureWallet(in: modelContext)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.spring(response: 0.65, dampingFraction: 0.82)) {
                    showSplash = false
                }
            }
        }
    }

    private func ensureProfile() {
        guard profiles.isEmpty else { return }
        modelContext.insert(UserProfile(
            preferences: "喜欢简单直接、预算敏感、重视健康和长期体验。",
            commonScenarios: "吃什么、买哪个、要不要换工作、周末去哪。"
        ))
        try? modelContext.save()
    }
}

struct MainTabView: View {
    @EnvironmentObject private var chrome: AppChrome

    var body: some View {
        TabView(selection: Binding(
            get: { chrome.selectedTab },
            set: { chrome.selectedTab = $0 }
        )) {
            ChatView()
                .tabItem {
                    Label("聊天", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(AppChrome.Tab.chat)
            CallView()
                .tabItem {
                    Label("通话", systemImage: "phone.connection")
                }
                .tag(AppChrome.Tab.call)
            RechargeCenterView()
                .tabItem {
                    Label("囤粮", systemImage: "leaf.circle.fill")
                }
                .tag(AppChrome.Tab.grain)
            ProfileView()
                .tabItem {
                    Label("我的", systemImage: "person.crop.circle")
                }
                .tag(AppChrome.Tab.profile)
        }
        .tint(DuckTheme.duckOrange)
        .onAppear {
            DuckTheme.applyChromeAppearance()
        }
    }
}

struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        ZStack {
            DuckTheme.pageGradient.ignoresSafeArea()
            VStack(spacing: 22) {
                Image("MascotSplash")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 170, height: 170)
                    .shadow(color: DuckTheme.skyBlue.opacity(0.28), radius: 16, y: 8)
                    .scaleEffect(animate ? 1 : 0.86)
                    .offset(y: reduceMotion ? 0 : (animate ? -6 : 8))

                VStack(spacing: 8) {
                    Text("选选鸭")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(DuckTheme.duckOrange)
                    Text("纠结的事，交给鸭鸭帮你拍板")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(DuckTheme.inkBlue)
                }

                Image("DecisionDoors")
                    .resizable()
                    .scaledToFill()
                    .frame(height: 174)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(.white, lineWidth: 3)
                    }
                    .padding(.horizontal, 24)
                    .shadow(color: DuckTheme.warmYellow.opacity(0.25), radius: 14, y: 8)

                HStack {
                    Chip("中午吃什么")
                    Chip("买哪个手机")
                    Chip("要不要换工作")
                }
            }
            .padding(.vertical, 24)
        }
        .onAppear {
            withAnimation(reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}

