import UIKit
import CarPlay

/// CarPlay Dashboard widget — shows shortcut buttons when Steddi isn't the active app.
/// Displays "Start Commute" and navigation status in the CarPlay dashboard.
class CarPlayDashboardDelegate: UIResponder, CPTemplateApplicationDashboardSceneDelegate {

    private var dashboardController: CPDashboardController?
    private var dashboardWindow: UIWindow?
    /// Retained so button handlers can call `open(_:options:completionHandler:)`
    /// to bring Steddi to the foreground — a dashboard scene cannot present
    /// templates, and a button's closure alone never launches/foregrounds the
    /// app, so without this every shortcut button is a dead control while the
    /// phone app is suspended.
    private var dashboardScene: CPTemplateApplicationDashboardScene?

    private var stateManager: NavigationStateManager { NavigationStateManager.shared }

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didConnect dashboardController: CPDashboardController,
        to window: UIWindow
    ) {
        self.dashboardController = dashboardController
        self.dashboardWindow = window
        self.dashboardScene = templateApplicationDashboardScene

        updateDashboardButtons()

        // Poll for navigation state changes to update buttons
        Task { @MainActor [weak self] in
            while let self, self.dashboardController != nil {
                try? await Task.sleep(for: .seconds(2))
                self.updateDashboardButtons()
            }
        }
    }

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didDisconnect dashboardController: CPDashboardController,
        from window: UIWindow
    ) {
        self.dashboardController = nil
        self.dashboardWindow = nil
        self.dashboardScene = nil
    }

    /// Bring Steddi to the foreground from the dashboard, carrying intent in the
    /// deep link. `open` is the only mechanism that launches/foregrounds the app
    /// from a dashboard scene — a button closure on its own cannot. Falls back
    /// to `UIApplication.open` if the scene reference is somehow gone.
    @MainActor
    private func openApp(_ url: URL) {
        if let dashboardScene {
            dashboardScene.open(url, options: nil) { _ in }
        } else {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    @MainActor
    private func updateDashboardButtons() {
        guard let dashboardController else { return }

        var buttons: [CPDashboardButton] = []

        if stateManager.isNavigating {
            // Show navigation status
            let etaText = "\(stateManager.etaMinutes) min"
            if let img = UIImage(systemName: "location.fill")?
                .withTintColor(SteddiTheme.accentUIColor, renderingMode: .alwaysOriginal) {
                let navButton = CPDashboardButton(
                    titleVariants: [stateManager.instruction, "Navigating"],
                    subtitleVariants: [etaText, stateManager.distanceRemaining],
                    image: img
                ) { [weak self] _ in
                    // Foreground Steddi to show the live turn-by-turn UI. The
                    // app already presents the nav overlay while navigating, so
                    // no extra intent is needed beyond bringing it forward.
                    Task { @MainActor in
                        self?.openApp(DashboardLink.showNavigation)
                    }
                }
                buttons.append(navButton)
            }
        } else {
            // Show "Start Commute" shortcut
            if let img = UIImage(systemName: "car.fill")?
                .withTintColor(SteddiTheme.accentUIColor, renderingMode: .alwaysOriginal) {
                let commuteButton = CPDashboardButton(
                    titleVariants: ["Start Commute", "Commute"],
                    subtitleVariants: ["Tap to navigate", "Go"],
                    image: img
                ) { [weak self] _ in
                    Task { @MainActor in
                        // Queue a durable start request (covers a warm app that
                        // is already foregrounded) and open the deep link, which
                        // both foregrounds/launches the suspended app and — via
                        // its host handler — re-queues the same request so a cold
                        // launch starts the commute too. Tapping the button alone
                        // never foregrounds the app, so the open() call is what
                        // actually makes "Start Commute" do anything.
                        PendingCommuteStartStore.shared.request(.firstActive)
                        self?.openApp(DashboardLink.startCommute)
                    }
                }
                buttons.append(commuteButton)
            }

            // Show "Recent" shortcut
            if let img = UIImage(systemName: "clock.fill")?
                .withTintColor(SteddiTheme.accentUIColor, renderingMode: .alwaysOriginal) {
                let recentButton = CPDashboardButton(
                    titleVariants: ["Recent Places", "Recents"],
                    subtitleVariants: ["Navigate somewhere", "Places"],
                    image: img
                ) { [weak self] _ in
                    // Foreground the app on its Places tab so the driver can pick
                    // a destination. Tapping the button alone never foregrounds
                    // the app, so the open() call is the real action.
                    Task { @MainActor in
                        self?.openApp(DashboardLink.showPlaces)
                    }
                }
                buttons.append(recentButton)
            }
        }

        dashboardController.shortcutButtons = buttons
    }
}

/// Deep links the dashboard buttons open to foreground Steddi. Each reuses the
/// existing `steddi://` scheme routed in `PhoneSceneDelegate.handleURL`.
private enum DashboardLink {
    static let startCommute = URL(string: "steddi://start-commute")!
    static let showPlaces = URL(string: "steddi://places")!
    /// No params — its only job is to foreground the app, which already shows
    /// the live nav UI while navigating.
    static let showNavigation = URL(string: "steddi://navigate")!
}
