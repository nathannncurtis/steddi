import SwiftUI
import SwiftData

@main
struct SteddiApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var locationService = LocationService()
    @State private var offlineCacheService = OfflineCacheService()

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                HomeView()
            } else {
                OnboardingView()
            }
        }
        .modelContainer(for: [
            PinnedLocation.self,
            Commute.self,
            Route.self,
            DriveRecord.self,
            NoGoZone.self,
        ])
        .environment(locationService)
        .environment(offlineCacheService)
    }
}
