import SwiftData
import SwiftUI

@main
struct XuanXuanYaApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            UserProfile.self,
            ChatMessage.self,
            DecisionRecord.self
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

