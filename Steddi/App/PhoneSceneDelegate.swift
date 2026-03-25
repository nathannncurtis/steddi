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

        let rootView = SteddiRootView()
            .modelContainer(appDelegate.modelContainer)
            .environment(appDelegate.locationService)
            .environment(appDelegate.offlineCacheService)
            .environment(NavigationStateManager.shared)

        let window = UIWindow(windowScene: windowScene)
        let mode = SteddiTheme.currentThemeMode
        switch mode {
        case .dark: window.backgroundColor = .black
        case .light: window.backgroundColor = .white
        case .dynamic: window.backgroundColor = .systemBackground
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
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("themeMode") private var themeMode = "dynamic"

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                HomeView()
            } else {
                OnboardingView()
            }
        }
        .preferredColorScheme(resolvedColorScheme)
    }

    private var resolvedColorScheme: ColorScheme? {
        switch themeMode {
        case "dark": return .dark
        case "light": return .light
        default: return ThemeMode.isDaytime ? .light : .dark
        }
    }
}
