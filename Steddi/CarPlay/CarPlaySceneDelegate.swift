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

    // MARK: - Route Preview

    /// Show a route preview before starting navigation (Apple's required flow)
    @MainActor
    private func showRoutePreview(name: String, coordinate: CLLocationCoordinate2D) async {
        guard let interfaceController else { return }

        // Calculate the route
        guard let currentLoc = CLLocationManager().location else {
            showError("Unable to determine your location.")
            return
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLoc.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        request.transportType = .automobile

        guard let response = try? await MKDirections(request: request).calculate(),
              let route = response.routes.first else {
            showError("Could not calculate route to \(name).")
            return
        }

        // Build preview template
        let distanceMiles = route.distance / 1609.34
        let distanceText = distanceMiles < 10
            ? String(format: "%.1f mi", distanceMiles)
            : "\(Int(distanceMiles)) mi"
        let etaMinutes = Int(ceil(route.expectedTravelTime / 60))

        let routeInfo = CPListItem(text: "\(etaMinutes) min", detailText: distanceText)
        if let img = UIImage(systemName: "car.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .medium))
            .withTintColor(SteddiTheme.accentUIColor, renderingMode: .alwaysOriginal) {
            routeInfo.setImage(img)
        }

        let arrivalTime = Date().addingTimeInterval(route.expectedTravelTime)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let arrivalItem = CPListItem(text: "Arrive \(formatter.string(from: arrivalTime))", detailText: "via \(route.name ?? "fastest route")")
        if let img = UIImage(systemName: "clock")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)) {
            arrivalItem.setImage(img)
        }

        let section = CPListSection(items: [routeInfo, arrivalItem])
        let previewTemplate = CPListTemplate(title: "Route to \(name)", sections: [section])

        // Add "Start" and "Cancel" buttons via alert after pushing preview
        let startAction = CPAlertAction(title: "Start Navigation", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            self?.interfaceController?.popToRootTemplate(animated: false, completion: nil)
            // Trigger navigation on the phone via notification
            NotificationCenter.default.post(
                name: .steddiNavigateToLocation,
                object: nil,
                userInfo: ["lat": coordinate.latitude, "lng": coordinate.longitude, "name": name]
            )
        }

        let cancelAction = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            self?.interfaceController?.popToRootTemplate(animated: true, completion: nil)
        }

        // Push preview, then show start/cancel alert
        interfaceController.pushTemplate(previewTemplate, animated: true) { _, _ in
            let alert = CPAlertTemplate(
                titleVariants: ["\(etaMinutes) min to \(name) (\(distanceText))"],
                actions: [startAction, cancelAction]
            )
            interfaceController.presentTemplate(alert, animated: true, completion: nil)
        }
    }

    /// Show an error alert on CarPlay
    @MainActor
    private func showError(_ message: String) {
        guard let interfaceController else { return }
        let action = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPAlertTemplate(titleVariants: [message], actions: [action])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
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
                    item.handler = { [weak self] _, completion in
                        // Default to destination — user can pick direction on phone
                        let dest = commute.destination
                        if let dest {
                            Task { @MainActor in
                                await self?.showRoutePreview(
                                    name: dest.name,
                                    coordinate: dest.coordinate
                                )
                            }
                        }
                        completion()
                    }
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
                    item.handler = { [weak self] _, completion in
                        Task { @MainActor in
                            await self?.showRoutePreview(
                                name: location.name,
                                coordinate: location.coordinate
                            )
                        }
                        completion()
                    }
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
