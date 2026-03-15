import SwiftUI
import SwiftData

@main
struct SteddiApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var locationService = LocationService()
    @State private var offlineCacheService = OfflineCacheService()

    init() {
        // Set up arrival notifications
        ArrivalNotificationService.shared.requestPermissionIfNeeded()
        ArrivalNotificationService.shared.registerCategory()
        ArrivalNotificationService.shared.setupDelegate()

        // Eliminate white safe area gaps — especially visible in landscape
        DispatchQueue.main.async {
            for scene in UIApplication.shared.connectedScenes {
                if let windowScene = scene as? UIWindowScene {
                    for window in windowScene.windows {
                        window.backgroundColor = .black
                        window.rootViewController?.view.backgroundColor = .clear
                    }
                }
            }
        }
    }

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
            CommuteTrip.self,
        ])
        .environment(locationService)
        .environment(offlineCacheService)
    }
}
