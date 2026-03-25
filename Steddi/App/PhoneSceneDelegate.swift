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
        window.backgroundColor = .black
        window.rootViewController = UIHostingController(rootView: rootView)
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// Reactive root view that switches between onboarding and home
private struct SteddiRootView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("accentColor") private var accentColor = "lavender"

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                HomeView()
            } else {
                OnboardingView()
            }
        }
        .tint(SteddiTheme.accent)
        .id("root-\(accentColor)")
    }
}
