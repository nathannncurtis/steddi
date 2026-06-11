import UIKit
import SwiftUI
import SwiftData

class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

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
            .environment(NavigationStateManager.shared)

        let window = UIWindow(windowScene: windowScene)
        switch SteddiTheme.currentThemeModeEx {
        case .dark: window.backgroundColor = .black
        case .light: window.backgroundColor = .white
        case .grey: window.backgroundColor = ThemePalette.grey.surfacePrimary.uiColor
        // Dynamic: match the engine's resolved surface so the launch frame
        // never flashes the wrong polarity mid-transition.
        case .dynamic: window.backgroundColor = ThemeEngine.shared.currentState.surfacePrimary.uiColor
        }
        window.rootViewController = UIHostingController(rootView: rootView)
        window.makeKeyAndVisible()
        self.window = window

        // Handle any URLs passed at launch
        if let url = connectionOptions.urlContexts.first?.url {
            handleURL(url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        handleURL(url)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Scene torn down mid-navigation (user swiped the app away) —
        // applicationWillTerminate is not guaranteed to fire, so end the
        // Live Activity here too or it lingers on the Lock Screen.
        guard NavigationStateManager.shared.isNavigating else { return }
        LiveActivityService.shared.endActivityImmediately()
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
            }
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
    static let steddiTestArrival = Notification.Name("steddiTestArrival")
    static let steddiResetOnboarding = Notification.Name("steddiResetOnboarding")
}

/// Reactive root view that switches between onboarding and home
private struct SteddiRootView: View {
    let storageWarning: String?

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(ThemeModeEx.defaultsKey) private var themeModeEx = ThemeModeEx.dynamic.rawValue

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                HomeView()
            } else {
                OnboardingView()
            }
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
