import SwiftData
import SwiftUI

@main
struct XuanXuanYaApp: App {
    init() {
        DuckTheme.applyChromeAppearance()
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            UserProfile.self,
            ChatMessage.self,
            DecisionRecord.self,
            GrainWallet.self,
            MonthCardRecord.self,
            GrainLedgerEntry.self,
            QuizResult.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create model container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(sharedModelContainer)
    }
}

