import AppIntents

/// Provides Steddi shortcuts to the Shortcuts app and Siri suggestions.
struct SteddiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartCommuteIntent(),
            phrases: [
                "Start my commute with \(.applicationName)",
                "Start my commute in \(.applicationName)",
                "Navigate to work with \(.applicationName)",
                "Start \(.applicationName)",
                "Let's go with \(.applicationName)"
            ],
            shortTitle: "Start Commute",
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: CheckCommuteETAIntent(),
            phrases: [
                "How's my drive with \(.applicationName)",
                "Check my commute with \(.applicationName)",
                "How long is my commute with \(.applicationName)",
                "Check traffic with \(.applicationName)"
            ],
            shortTitle: "Check ETA",
            systemImageName: "clock.fill"
        )
    }
}
