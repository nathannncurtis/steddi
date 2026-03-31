import UIKit
import CarPlay
import SwiftData
import os

private let appLog = Logger(subsystem: "to.nathancurtis.steddi", category: "App")

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    lazy var modelContainer: ModelContainer = {
        try! ModelContainer(for:
            PinnedLocation.self,
            Commute.self,
            Route.self,
            DriveRecord.self,
            NoGoZone.self,
            CommuteTrip.self,
            Report.self
        )
    }()

    let locationService = LocationService()
    let offlineCacheService = OfflineCacheService()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Catch uncaught exceptions so we can see what's crashing
        NSSetUncaughtExceptionHandler { exception in
            appLog.fault("UNCAUGHT EXCEPTION: \(exception.name.rawValue): \(exception.reason ?? "no reason")\n\(exception.callStackSymbols.joined(separator: "\n"))")
        }

        ArrivalNotificationService.shared.requestPermissionIfNeeded()
        ArrivalNotificationService.shared.registerCategory()
        ArrivalNotificationService.shared.setupDelegate()

        _ = NavigationStateManager.shared

        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }

        if connectingSceneSession.role.rawValue == "CPTemplateApplicationDashboardSceneSessionRoleApplication" {
            let config = UISceneConfiguration(name: "CarPlay Dashboard", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlayDashboardDelegate.self
            return config
        }

        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = PhoneSceneDelegate.self
        return config
    }
}
