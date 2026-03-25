import UIKit
import CarPlay
import MapKit
import SwiftData
import CoreLocation

// MARK: - CarPlaySceneDelegate

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var carWindow: CPWindow?

    // Navigation state
    private var isShowingNavigation = false

    // Root template (commutes/recents)
    private var rootTabBar: CPTabBarTemplate?

    private var modelContainer: ModelContainer?

    private var stateManager: NavigationStateManager { NavigationStateManager.shared }

    // Live update polling task
    private var liveUpdateTask: Task<Void, Never>?

    // MARK: - Scene Connection

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        NSLog("[CarPlay] didConnect (3-param)")
        connectCarPlay(interfaceController: interfaceController, window: window)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        NSLog("[CarPlay] didConnect (2-param), trying to get carWindow from scene")
        let window = templateApplicationScene.carWindow
        NSLog("[CarPlay] carWindow: %@", window.debugDescription)
        connectCarPlay(interfaceController: interfaceController, window: window)
    }

    private func connectCarPlay(interfaceController: CPInterfaceController, window: CPWindow?) {
        self.interfaceController = interfaceController
        self.carWindow = window

        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            modelContainer = appDelegate.modelContainer
        }

        // Build commutes/recents tabs as default root
        let commutesTab = buildCommutesTab()
        let recentsTab = buildRecentsTab()
        let tabBar = CPTabBarTemplate(templates: [commutesTab, recentsTab])
        self.rootTabBar = tabBar
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)

        Task { @MainActor in
            stateManager.isCarPlayActive = true

            // If phone is already navigating, show map immediately
            if stateManager.isNavigating {
                self.showNavigationUI()
            }

            // Watch for navigation state changes
            self.watchPhoneNavigation()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        dismissNavigation()
        self.interfaceController = nil
        self.carWindow = nil
        self.rootTabBar = nil

        Task { @MainActor in
            stateManager.isCarPlayActive = false
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        dismissNavigation()
        self.interfaceController = nil
        self.carWindow = nil
        self.rootTabBar = nil

        Task { @MainActor in
            stateManager.isCarPlayActive = false
        }
    }

    // MARK: - Watch Phone Navigation

    private func watchPhoneNavigation() {
        Task { @MainActor in
            var wasNavigating = stateManager.isNavigating
            while interfaceController != nil {
                try? await Task.sleep(for: .seconds(1))
                let isNav = stateManager.isNavigating

                if isNav && !wasNavigating {
                    showNavigationUI()
                } else if !isNav && wasNavigating {
                    dismissNavigation()
                }

                wasNavigating = isNav
            }
        }
    }

    // MARK: - Show Navigation

    @MainActor
    private func showNavigationUI() {
        guard let interfaceController, !isShowingNavigation else { return }
        isShowingNavigation = true

        NSLog("[CarPlay] Showing navigation UI")

        // Build the live TBT list
        let navTemplate = buildNavTemplate()

        // Replace root with navigation template
        interfaceController.setRootTemplate(navTemplate, animated: true, completion: nil)
        NSLog("[CarPlay] Navigation template set as root")

        // Start polling for live updates
        subscribeLiveUpdates()
    }

    /// Build a CPListTemplate with live TBT information
    private func buildNavTemplate() -> CPListTemplate {
        let instruction = stateManager.instruction.isEmpty ? "Navigating..." : stateManager.instruction
        let distance = stateManager.stepDistance.isEmpty ? "Calculating..." : stateManager.stepDistance

        // Current maneuver — primary item
        let currentItem = CPListItem(text: distance, detailText: instruction)
        if let img = UIImage(systemName: stateManager.maneuverType)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 28, weight: .bold))
            .withTintColor(SteddiTheme.accentUIColor, renderingMode: .alwaysOriginal) {
            currentItem.setImage(img)
        }

        var nextItems: [CPListItem] = []

        // Follow-on maneuver
        if !stateManager.followOnInstruction.isEmpty {
            let followItem = CPListItem(text: "Then", detailText: stateManager.followOnInstruction)
            if let img = UIImage(systemName: stateManager.followOnManeuverSymbol)?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .medium))
                .withTintColor(SteddiTheme.accentUIColor, renderingMode: .alwaysOriginal) {
                followItem.setImage(img)
            }
            nextItems.append(followItem)
        }

        // Upcoming steps
        for step in stateManager.upcomingSteps.prefix(3) {
            let item = CPListItem(text: step.distance, detailText: step.instruction)
            if let img = UIImage(systemName: step.maneuverSymbol)?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)) {
                item.setImage(img)
            }
            nextItems.append(item)
        }

        var infoItems: [CPListItem] = []

        // ETA
        let etaText = "\(stateManager.etaMinutes) min \u{00B7} \(stateManager.distanceRemaining)"
        let etaItem = CPListItem(text: etaText, detailText: "Arrive \(stateManager.arrivalTime)")
        if let img = UIImage(systemName: "clock.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .medium))
            .withTintColor(.systemGreen, renderingMode: .alwaysOriginal) {
            etaItem.setImage(img)
        }
        infoItems.append(etaItem)

        // Speed
        let speedText = "\(Int(stateManager.currentSpeedMph)) mph"
        var speedDetail = stateManager.roadName
        if let limit = stateManager.speedLimitMph {
            speedDetail = "Limit \(Int(limit)) mph" + (speedDetail.isEmpty ? "" : " \u{00B7} \(speedDetail)")
        }
        let speedItem = CPListItem(text: speedText, detailText: speedDetail)
        let isOverLimit = stateManager.speedLimitMph != nil && stateManager.currentSpeedMph > (stateManager.speedLimitMph! + 5)
        let speedColor: UIColor = isOverLimit ? .systemRed : .white
        if let img = UIImage(systemName: "speedometer")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .medium))
            .withTintColor(speedColor, renderingMode: .alwaysOriginal) {
            speedItem.setImage(img)
        }
        infoItems.append(speedItem)

        var sections: [CPListSection] = []
        sections.append(CPListSection(items: [currentItem], header: "Next Turn", sectionIndexTitle: nil))
        if !nextItems.isEmpty {
            sections.append(CPListSection(items: nextItems, header: "Upcoming", sectionIndexTitle: nil))
        }
        sections.append(CPListSection(items: infoItems, header: "Trip", sectionIndexTitle: nil))

        let template = CPListTemplate(title: "Steddi", sections: sections)
        return template
    }

    // MARK: - Live Updates

    @MainActor
    private func subscribeLiveUpdates() {
        liveUpdateTask?.cancel()

        liveUpdateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let interfaceController = self.interfaceController else { break }
                guard self.isShowingNavigation else { break }

                // Rebuild the nav template with fresh data from NavigationStateManager
                let updatedTemplate = self.buildNavTemplate()

                // Update the current template's sections
                if let topTemplate = interfaceController.rootTemplate as? CPListTemplate {
                    topTemplate.updateSections(updatedTemplate.sections)
                }

                // Check for arrival
                if self.stateManager.hasArrived {
                    self.dismissNavigation()
                    break
                }
            }
        }
    }

    // MARK: - Dismiss Navigation

    @MainActor
    private func dismissNavigation() {
        liveUpdateTask?.cancel()
        liveUpdateTask = nil
        isShowingNavigation = false

        // Restore commutes/recents root
        if let interfaceController, let rootTabBar {
            interfaceController.setRootTemplate(rootTabBar, animated: true, completion: nil)
        }
    }

    // MARK: - Commutes Tab

    private func buildCommutesTab() -> CPListTemplate {
        var items: [CPListItem] = []

        if let container = modelContainer {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Commute>(
                predicate: #Predicate { $0.isActive },
                sortBy: [SortDescriptor(\.createdAt)]
            )

            if let commutes = try? context.fetch(descriptor) {
                for commute in commutes {
                    let originName = commute.origin?.name ?? "?"
                    let destName = commute.destination?.name ?? "?"
                    var detail = "\(originName) \u{2192} \(destName)"

                    if let duration = commute.preferredRoute?.typicalDurationSeconds {
                        let mins = Int(ceil(duration / 60))
                        detail += " \u{2014} ~\(mins) min"
                    }

                    let item = CPListItem(text: commute.name, detailText: detail)
                    items.append(item)
                }
            }
        }

        if items.isEmpty {
            items.append(CPListItem(text: "No commutes", detailText: "Add commutes in the Steddi app"))
        }

        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Commutes", sections: [section])
        template.tabTitle = "Commutes"
        template.tabImage = UIImage(systemName: "arrow.triangle.swap")
        return template
    }

    // MARK: - Recents Tab

    private func buildRecentsTab() -> CPListTemplate {
        var items: [CPListItem] = []

        if let container = modelContainer {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<PinnedLocation>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )

            if let locations = try? context.fetch(descriptor) {
                for location in locations.prefix(12) {
                    let item = CPListItem(text: location.name, detailText: location.address ?? "")
                    items.append(item)
                }
            }
        }

        if items.isEmpty {
            items.append(CPListItem(text: "No places", detailText: "Add places in the Steddi app"))
        }

        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Recents", sections: [section])
        template.tabTitle = "Recents"
        template.tabImage = UIImage(systemName: "clock")
        return template
    }
}
