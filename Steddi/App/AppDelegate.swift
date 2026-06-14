import UIKit
import CarPlay
import SwiftData
import os

private let appLog = Logger(subsystem: "to.nathancurtis.steddi", category: "App")

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    /// Non-nil when the app had to fall back to an in-memory store.
    private(set) var storageWarning: String?

    lazy var modelContainer: ModelContainer = {
        let result = ModelStoreLocator.makeAppContainer()
        if let warning = result.warning {
            appLog.fault("Running on in-memory store: \(warning)")
            storageWarning = warning
        }
        return result.container
    }()

    let locationService = LocationService()
    let offlineCacheService = OfflineCacheService()

    /// Smart-commute notification orchestrator. Lazily built so it shares the
    /// app's ModelContainer and reads the live location fix.
    lazy var commuteNotificationService: CommuteNotificationService = {
        CommuteNotificationService(
            modelContainer: modelContainer,
            locationProvider: { [weak self] in self?.locationService.currentLocation }
        )
    }()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Catch uncaught exceptions so we can see what's crashing
        NSSetUncaughtExceptionHandler { exception in
            appLog.fault("UNCAUGHT EXCEPTION: \(exception.name.rawValue): \(exception.reason ?? "no reason")\n\(exception.callStackSymbols.joined(separator: "\n"))")
        }

        // ArrivalNotificationService keeps its own permission/category flow; the
        // SAVE_ROUTE prompt fires post-arrival, not at launch.
        ArrivalNotificationService.shared.requestPermissionIfNeeded()
        ArrivalNotificationService.shared.registerCategory()
        ArrivalNotificationService.shared.setupDelegate()

        // Migrate the legacy "themeMode" key before the engine reads settings,
        // then spin the engine up so the first frame paints the right palette.
        ThemeModeEx.migrateLegacyIfNeeded()
        _ = ThemeEngine.shared

        // Register media remote commands (play/pause/skip/seek) so phone nav and
        // CarPlay both route steering-wheel + Control Center input to the active
        // audio app (music-ducking spec).
        MainActor.assumeIsolated { NowPlayingService.shared.registerCommands() }

        // Register the commute-check background task BEFORE launch finishes —
        // BGTaskScheduler requires handlers be registered during launch. We do
        // NOT request notification permission here (spec: never at first launch);
        // that happens from Settings or the first scheduled commute.
        commuteNotificationService.registerBackgroundTask()
        Task {
            // Register the COMMUTE_ALERT category and arm the first refresh if
            // the user already granted permission in a prior session.
            await CommuteNotificationCenter.shared.registerCategory()
            await commuteNotificationService.refreshAuthorizationStatus()
            if commuteNotificationService.authorizationStatus == .authorized {
                commuteNotificationService.scheduleBackgroundRefresh()
            }
        }

        _ = NavigationStateManager.shared

        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Nav is active and the process is dying — end the Live Activity now
        // or it lingers on the Lock Screen as a zombie until iOS reaps it.
        guard NavigationStateManager.shared.isNavigating else { return }
        LiveActivityService.shared.endActivityImmediately()
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
