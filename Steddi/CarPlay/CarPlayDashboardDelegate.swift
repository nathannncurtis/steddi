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

    /// The 2s button-refresh loop. Stored so a rapid disconnect/reconnect can't
    /// leave a stale loop running alongside a new one — cancelled on disconnect
    /// and before each (re)connect. Mirrors the task discipline in
    /// `CarPlaySceneDelegate` (phoneNavWatchTask / liveUpdateTask).
    private var pollTask: Task<Void, Never>?

    private var stateManager: NavigationStateManager { NavigationStateManager.shared }

    /// Snapshot of every input that determines the dashboard button set, cached
    /// from the last assignment. The 2s poll rebuilds and reassigns
    /// `shortcutButtons` on every tick; CarPlay treats each assignment as an
    /// update signal and re-renders the dashboard widget, so reassigning
    /// byte-identical buttons every 2s churns the widget (and burns main-actor
    /// work + image construction) the whole time CarPlay is connected. We diff
    /// this snapshot and skip the reassign when nothing relevant changed, only
    /// rebuilding on an actual transition. `accent` is included because the
    /// button glyphs are tinted with `SteddiTheme.accentUIColor`, which the user
    /// can change mid-session — so an accent change must still re-tint the
    /// buttons. nil until the first build.
    private struct DashboardButtonState: Equatable {
        let isNavigating: Bool
        let instruction: String
        let etaText: String
        let distanceRemaining: String
        let accent: String
    }
    private var lastButtonState: DashboardButtonState?

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didConnect dashboardController: CPDashboardController,
        to window: UIWindow
    ) {
        self.dashboardController = dashboardController
        self.dashboardWindow = window
        self.dashboardScene = templateApplicationDashboardScene

        updateDashboardButtons()

        // Poll for navigation state changes to update buttons. Cancel any prior
        // loop first so a reconnect within the 2s tick window can't leave the
        // old loop spinning alongside this one.
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while let self, self.dashboardController != nil, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self.updateDashboardButtons()
            }
        }
    }

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didDisconnect dashboardController: CPDashboardController,
        from window: UIWindow
    ) {
        pollTask?.cancel()
        pollTask = nil
        self.dashboardController = nil
        self.dashboardWindow = nil
        self.dashboardScene = nil
        // Drop the diff cache so a reconnect rebuilds from scratch — the new
        // controller starts with no buttons assigned, so the first
        // updateDashboardButtons after reconnect must not be skipped as "unchanged".
        self.lastButtonState = nil
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

        // Diff the inputs that determine the button set. The 2s poll calls this
        // every tick; when nothing relevant changed (the common idle case),
        // skip the rebuild + reassign so CarPlay doesn't re-render identical
        // buttons every 2s. Rebuild only on an actual transition.
        let etaText = "\(stateManager.etaMinutes) min"
        let newState = DashboardButtonState(
            isNavigating: stateManager.isNavigating,
            instruction: stateManager.instruction,
            etaText: etaText,
            distanceRemaining: stateManager.distanceRemaining,
            accent: SteddiTheme.currentAccentOption.rawValue
        )
        guard newState != lastButtonState else { return }
        lastButtonState = newState

        var buttons: [CPDashboardButton] = []

        if stateManager.isNavigating {
            // Show navigation status
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
