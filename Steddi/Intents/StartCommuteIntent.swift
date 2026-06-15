import AppIntents
import SwiftData

/// "Hey Siri, start my commute" — starts navigation for the user's first active commute.
struct StartCommuteIntent: AppIntent {
    static var title: LocalizedStringResource = "Start My Commute"
    static var description: IntentDescription = "Start navigating your daily commute with Steddi."
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Queue a durable start request rather than posting into the void.
        // `openAppWhenRun` may cold-launch the app, in which case HomeView
        // hasn't attached its observers yet; the store survives the race and is
        // drained when HomeView appears (and reactively while foregrounded).
        PendingCommuteStartStore.shared.request(.firstActive)
        return .result()
    }
}
