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
            // The notification/idle-ETA pass runs off the main actor on the
            // cooperative pool, so it must NOT synchronously read
            // `@MainActor LocationService.currentLocation` (a data race against
            // the CoreLocation main-actor write). Read the process-wide,
            // lock-guarded `LastKnownLocation` instead — it is Sendable, safe
            // from any actor, and `LocationService` publishes every fix to it.
            locationProvider: { LastKnownLocation.current }
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

        // Register BOTH notification categories (SAVE_ROUTE + COMMUTE_ALERT) in a
        // single setNotificationCategories call and become the notification
        // delegate at launch (neither prompts the user). One combined call owns
        // the full set, so the two registrants can never clobber each other via
        // interleaved read-modify-writes against the shared global set. We
        // deliberately do NOT request notification permission here — per the
        // onboarding spec it is never asked at first launch; the
        // arrival/SAVE_ROUTE prompt is deferred to the first arrival (HomeView),
        // mirroring the in-context location/commute flows.
        CommuteNotificationCenter.registerAllCategories()
        ArrivalNotificationService.shared.setupDelegate()

        // Finish any out-of-band tip (consumable) transactions so they don't sit
        // in the StoreKit queue and re-deliver on every launch.
        TipTransactionObserver.start()

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
            // Categories are already registered synchronously above via
            // CommuteNotificationCenter.registerAllCategories(); here we only arm
            // the first refresh if the user granted permission in a prior session.
            await commuteNotificationService.refreshAuthorizationStatus()
            if commuteNotificationService.authorizationStatus == .authorized {
                commuteNotificationService.scheduleBackgroundRefresh()
            }
        }

        _ = NavigationStateManager.shared

        // Wire the road-condition memory service to the shared store and run the
        // 90-day decay sweep on launch so aged-out conditions never accumulate.
        MainActor.assumeIsolated {
            RoadConditionService.shared.configure(container: modelContainer)
            RoadConditionService.shared.sweepExpiredConditions()
            // Wire the speed-camera service to the shared store and sweep aged-out
            // reports (mobile traps after 6h, fixed cameras after a year).
            SpeedCameraService.shared.configure(container: modelContainer)
            SpeedCameraService.shared.sweepExpiredReports()

            // Reap any Live Activity left over from a prior session at launch,
            // regardless of which scene type brings the process up. HomeView.onAppear
            // also calls this, but a CarPlay-first cold launch never creates HomeView,
            // so the launch-time sweep is what makes the documented guarantee true on
            // that path. Self-guards on an empty activity set; a true cold launch has
            // no in-memory active nav, so it can't end a legitimately-live activity.
            LiveActivityService.shared.cleanupOrphanedActivities()

            // Same backstop for the home-screen widget: an OOM/watchdog kill
            // mid-drive leaves the App Group's kIsNavigating stuck true, so the
            // widget shows a phantom live nav. At launch we're not in a live
            // session, so clear a crash-orphaned "navigating" flag + its stale
            // ETA. No-op when actually navigating.
            NavigationStateManager.shared.reconcileWidgetSessionAtLaunch()
        }

        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Pre-drive ETA widget: every time the app becomes active (launch and
        // each foreground), refresh the idle home-screen ETA for the next
        // upcoming commute so opening/closing Steddi keeps the widget fresh
        // before the first drive. Lightweight — reuses the existing commute-ETA
        // computation and is gated to no-op while navigating, so it never
        // clobbers a live ETA.
        Task {
            await commuteNotificationService.refreshIdleCommuteETA()
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // The process is dying — end any Live Activity now or it lingers on the
        // Lock Screen as a zombie until iOS reaps it. We do NOT gate on
        // isNavigating: after a normal arrival/stop nav is no longer "navigating"
        // but the activity is still presented under its 30s dismissal policy, so
        // gating would skip reaping that pending-dismissal activity.
        // endActivityImmediately() self-guards (no-op when nothing is live).
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
