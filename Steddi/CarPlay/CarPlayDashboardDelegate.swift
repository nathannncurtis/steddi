import UIKit
import CarPlay

/// CarPlay Dashboard widget — shows shortcut buttons when Steddi isn't the active app.
/// Displays "Start Commute" and navigation status in the CarPlay dashboard.
class CarPlayDashboardDelegate: UIResponder, CPTemplateApplicationDashboardSceneDelegate {

    private var dashboardController: CPDashboardController?
    private var dashboardWindow: UIWindow?

    private var stateManager: NavigationStateManager { NavigationStateManager.shared }

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didConnect dashboardController: CPDashboardController,
        to window: UIWindow
    ) {
        self.dashboardController = dashboardController
        self.dashboardWindow = window

        updateDashboardButtons()

        // Poll for navigation state changes to update buttons
        Task { @MainActor in
            while self.dashboardController != nil {
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
    }

    @MainActor
    private func updateDashboardButtons() {
        guard let dashboardController else { return }

        var buttons: [CPDashboardButton] = []

        if stateManager.isNavigating {
            // Show navigation status
            let etaText = "\(stateManager.etaMinutes) min"
            let navButton = CPDashboardButton(
                titleVariants: [stateManager.instruction, "Navigating"],
                subtitleVariants: [etaText, stateManager.distanceRemaining],
                image: UIImage(systemName: "location.fill")!
                    .withTintColor(SteddiTheme.accentUIColor, renderingMode: .alwaysOriginal)
            ) { _ in
                // Tapping opens the full Steddi CarPlay app
            }
            buttons.append(navButton)
        } else {
            // Show "Start Commute" shortcut
            let commuteButton = CPDashboardButton(
                titleVariants: ["Start Commute", "Commute"],
                subtitleVariants: ["Tap to navigate", "Go"],
                image: UIImage(systemName: "car.fill")!
                    .withTintColor(SteddiTheme.accentUIColor, renderingMode: .alwaysOriginal)
            ) { _ in
                // Trigger commute start on the phone
                NotificationCenter.default.post(name: .steddiStartCommuteFromSiri, object: nil)
            }
            buttons.append(commuteButton)

            // Show "Recent" shortcut
            let recentButton = CPDashboardButton(
                titleVariants: ["Recent Places", "Recents"],
                subtitleVariants: ["Navigate somewhere", "Places"],
                image: UIImage(systemName: "clock.fill")!
                    .withTintColor(SteddiTheme.accentUIColor, renderingMode: .alwaysOriginal)
            ) { _ in
                // Opens the full app
            }
            buttons.append(recentButton)
        }

        dashboardController.shortcutButtons = buttons
    }
}
