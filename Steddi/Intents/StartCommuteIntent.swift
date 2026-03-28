import AppIntents
import SwiftData

/// "Hey Siri, start my commute" — starts navigation for the user's first active commute.
struct StartCommuteIntent: AppIntent {
    static var title: LocalizedStringResource = "Start My Commute"
    static var description: IntentDescription = "Start navigating your daily commute with Steddi."
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Post notification that HomeView listens for to trigger commute start
        NotificationCenter.default.post(name: .steddiStartCommuteFromSiri, object: nil)
        return .result()
    }
}

extension Notification.Name {
    static let steddiStartCommuteFromSiri = Notification.Name("steddiStartCommuteFromSiri")
}
