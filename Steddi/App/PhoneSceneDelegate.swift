import UIKit
import SwiftUI
import SwiftData

class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    /// Hosting controller for the SwiftUI tree. Kept so dynamic theme updates
    /// can bump its theme-revision trait override (see `applyThemeRevision`).
    private weak var hostingController: UIViewController?
    private var dynamicThemeObserver: NSObjectProtocol?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }

        let container = appDelegate.modelContainer
        let rootView = SteddiRootView(storageWarning: appDelegate.storageWarning)
            .modelContainer(container)
            .environment(appDelegate.locationService)
            .environment(appDelegate.offlineCacheService)
            .environment(appDelegate.commuteNotificationService)
            .environment(NavigationStateManager.shared)
            .environment(PendingCommuteStartStore.shared)

        let window = UIWindow(windowScene: windowScene)
        switch SteddiTheme.currentThemeModeEx {
        case .dark: window.backgroundColor = .black
        case .light: window.backgroundColor = .white
        case .grey: window.backgroundColor = ThemePalette.grey.surfacePrimary.uiColor
        // Dynamic: match the engine's resolved surface so the launch frame
        // never flashes the wrong polarity mid-transition.
        case .dynamic: window.backgroundColor = ThemeEngine.shared.currentState.surfacePrimary.uiColor
        }
        let hosting = UIHostingController(rootView: rootView)
        window.rootViewController = hosting
        self.hostingController = hosting
        applyThemeRevision()
        window.makeKeyAndVisible()
        self.window = window

        // Single injection point for dynamic theme propagation: every engine
        // step posts `.steddiDynamicThemeUpdated`; bumping the hosting
        // controller's theme-revision trait re-resolves every dynamic
        // `SteddiTheme` color in the SwiftUI tree (HomeView, the nav overlay,
        // every card) against the latest snapshot, without rebuilding state.
        dynamicThemeObserver = NotificationCenter.default.addObserver(
            forName: .steddiDynamicThemeUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyThemeRevision()
        }

        // Handle any URLs passed at launch
        if let url = connectionOptions.urlContexts.first?.url {
            handleURL(url)
        }
    }

    deinit {
        if let dynamicThemeObserver {
            NotificationCenter.default.removeObserver(dynamicThemeObserver)
        }
    }

    /// Mirror the engine's published revision into the hosting controller's
    /// trait overrides. `ThemeRevisionTrait.affectsColorAppearance` makes UIKit
    /// re-invoke every dynamic color provider in the subtree when this changes.
    private func applyThemeRevision() {
        hostingController?.traitOverrides[ThemeRevisionTrait.self] = ThemeEngine.revision
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        handleURL(url)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // sceneDidDisconnect is NOT termination: UIKit also calls it when the
        // system reclaims a scene to free resources while the app keeps running
        // (Apple: "UIKit may disconnect a scene… this does not indicate the app
        // is quitting"). With multiple-scene support + background location, iOS
        // can reap this window scene mid-drive while navigation continues in
        // NavigationStateManager.shared. So we must NOT kill an active nav Live
        // Activity here — it is meant to outlive the app/scene during a drive.
        //
        // Only reap when there is NO active navigation (e.g. a paused/arrived
        // activity still under its dismissal policy, or a swipe-kill while idle):
        // applicationWillTerminate handles true process death regardless of
        // isNavigating, and the next launch's cleanupOrphanedActivities() sweeps
        // up anything missed.
        //
        // Use the NON-blocking end here: this is a routine scene reclaim, not
        // termination — the process keeps running, so the 2s blocking wait of
        // endActivityImmediately() would needlessly stall the main thread (and
        // any live CarPlay scene). endActivityAsync() self-guards on empty.
        guard !NavigationStateManager.shared.isNavigating else { return }
        LiveActivityService.shared.endActivityAsync()
    }

    private func handleURL(_ url: URL) {
        // steddi://navigate?lat=X&lng=Y&name=Z
        // steddi://search?q=X
        // steddi://arrive
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let host = url.host ?? ""
        let params = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        switch host {
        case "navigate":
            if let latStr = params["lat"], let lngStr = params["lng"],
               let lat = Double(latStr), let lng = Double(lngStr) {
                let name = params["name"] ?? "Destination"
                NotificationCenter.default.post(
                    name: .steddiNavigateToLocation,
                    object: nil,
                    userInfo: ["lat": lat, "lng": lng, "name": name]
                )
            } else if let commuteIdStr = params["commuteId"], let commuteId = UUID(uuidString: commuteIdStr) {
                // Smart-commute notification "Start Commute" deep link:
                // steddi://navigate?commuteId=<id>&direction=<dir>
                //
                // Queue a durable start request rather than posting into the
                // void: this URL can arrive during cold-launch scene
                // connection, before HomeView attaches its observers. The store
                // survives that race and HomeView drains it on appear.
                let direction = params["direction"].flatMap(CommuteDirection.init(rawValue:))
                MainActor.assumeIsolated {
                    PendingCommuteStartStore.shared.request(
                        .specific(commuteId: commuteId, direction: direction)
                    )
                }
            }
        case "start-commute":
            // CarPlay dashboard "Start Commute" button. Queue a durable
            // first-active start request: this URL both foregrounds/launches the
            // app and (on a cold launch) lands before HomeView attaches, so the
            // store carries the intent until HomeView drains it on appear.
            MainActor.assumeIsolated {
                PendingCommuteStartStore.shared.request(.firstActive)
            }
        case "places":
            // CarPlay dashboard "Recent Places" button — foreground the app on
            // its Places tab so the driver can pick a destination.
            NotificationCenter.default.post(name: .steddiShowPlaces, object: nil)
        case "search":
            if let query = params["q"] {
                NotificationCenter.default.post(
                    name: .steddiSearchQuery,
                    object: nil,
                    userInfo: ["query": query]
                )
            }
        case "arrive":
            NotificationCenter.default.post(name: .steddiTestArrival, object: nil)
        case "reset-onboarding":
            UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
            // Force restart by posting notification
            NotificationCenter.default.post(name: .steddiResetOnboarding, object: nil)
        default:
            break
        }
    }
}

// MARK: - URL Scheme Notifications

extension Notification.Name {
    static let steddiNavigateToLocation = Notification.Name("steddiNavigateToLocation")
    static let steddiSearchQuery = Notification.Name("steddiSearchQuery")
    static let steddiShowPlaces = Notification.Name("steddiShowPlaces")
    static let steddiTestArrival = Notification.Name("steddiTestArrival")
    static let steddiResetOnboarding = Notification.Name("steddiResetOnboarding")
}

/// Reactive root view that switches between onboarding and home
private struct SteddiRootView: View {
    let storageWarning: String?

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(ThemeModeEx.defaultsKey) private var themeModeEx = ThemeModeEx.dynamic.rawValue

    /// Bumped when Reduce Transparency toggles so `SteddiGlass`-backed chrome
    /// re-resolves between live glass and the solid `SteddiTheme` fallback.
    @State private var glassRevision = 0

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                HomeView()
            } else {
                OnboardingView()
            }
        }
        .id(glassRevision)
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIAccessibility.reduceTransparencyStatusDidChangeNotification
            )
        ) { _ in
            glassRevision &+= 1
        }
        .preferredColorScheme(resolvedColorScheme)
        .safeAreaInset(edge: .top) {
            if let storageWarning {
                Label(storageWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.92), in: Capsule())
                    .padding(.top, 4)
            }
        }
    }

    private var resolvedColorScheme: ColorScheme? {
        let mode = ThemeModeEx(rawValue: themeModeEx) ?? .dynamic
        guard mode == .dynamic else { return mode.colorScheme }
        // Observation-tracked read: the body re-evaluates whenever the engine
        // publishes a new state, so chrome follows the continuous solar curve.
        return ThemeEngine.shared.currentState.prefersDarkChrome ? .dark : .light
    }
}
