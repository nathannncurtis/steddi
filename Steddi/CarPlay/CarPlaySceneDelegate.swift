import UIKit
import CarPlay
import MapKit
import SwiftData
import CoreLocation

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var carWindow: CPWindow?
    private var mapController: CarPlayMapController?
    private var navigationSession: CPNavigationSession?
    private var isShowingNavigation = false
    private var rootTabBar: CPTabBarTemplate?
    private var modelContainer: ModelContainer?
    private var liveUpdateTask: Task<Void, Never>?

    private var stateManager: NavigationStateManager { NavigationStateManager.shared }

    // MARK: - Scene Connection

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        connectCarPlay(interfaceController: interfaceController, window: window)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let window = templateApplicationScene.carWindow
        connectCarPlay(interfaceController: interfaceController, window: window)
    }

    private func connectCarPlay(interfaceController: CPInterfaceController, window: CPWindow?) {
        self.interfaceController = interfaceController
        self.carWindow = window

        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            modelContainer = appDelegate.modelContainer
        }

        // Step 1: Create the map view controller and set it as the window's root.
        // Per Apple's docs: "Your app should create its view controller and assign it
        // to the rootViewController property of this window."
        // The map is ALWAYS the content. Templates overlay on top.
        let mapVC = CarPlayMapController()
        self.mapController = mapVC
        if let window {
            window.rootViewController = mapVC
        }

        // Step 2: Set the initial template (commutes/recents tabs)
        let commutesTab = buildCommutesTab()
        let recentsTab = buildRecentsTab()
        let tabBar = CPTabBarTemplate(templates: [commutesTab, recentsTab])
        self.rootTabBar = tabBar
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)

        Task { @MainActor in
            stateManager.isCarPlayActive = true

            if stateManager.isNavigating {
                self.showNavigationUI()
            }

            self.watchPhoneNavigation()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        dismissNavigation()
        mapController = nil
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

        // Start the map navigation with route coordinates
        let routeCoords = stateManager.activeRouteCoords
        if !routeCoords.isEmpty {
            mapController?.startNavigation(routeCoords: routeCoords)
        }

        // Build CPMapTemplate — this overlays navigation chrome on top of the map
        let mapTemplate = CPMapTemplate()
        mapTemplate.automaticallyHidesNavigationBar = true
        mapTemplate.hidesButtonsWithNavigationBar = false

        let zoomInButton = CPMapButton { [weak self] _ in
            self?.mapController?.zoomIn()
        }
        zoomInButton.image = UIImage(systemName: "plus.magnifyingglass")

        let zoomOutButton = CPMapButton { [weak self] _ in
            self?.mapController?.zoomOut()
        }
        zoomOutButton.image = UIImage(systemName: "minus.magnifyingglass")

        let recenterButton = CPMapButton { [weak self] _ in
            self?.mapController?.recenter()
        }
        recenterButton.image = UIImage(systemName: "location.fill")

        mapTemplate.mapButtons = [recenterButton, zoomInButton, zoomOutButton]

        // Replace root template with the map template
        interfaceController.setRootTemplate(mapTemplate, animated: true, completion: nil)

        // Start a navigation session for maneuver display
        let trip = CPTrip(
            origin: MKMapItem.forCurrentLocation(),
            destination: MKMapItem.forCurrentLocation(),
            routeChoices: []
        )
        navigationSession = mapTemplate.startNavigationSession(for: trip)

        subscribeLiveUpdates()
    }

    // MARK: - Live Updates

    @MainActor
    private func subscribeLiveUpdates() {
        liveUpdateTask?.cancel()

        liveUpdateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isShowingNavigation else { break }

                if let coord = self.stateManager.currentCoordinate {
                    self.mapController?.updateCamera(
                        coordinate: coord,
                        bearing: self.stateManager.headingDegrees
                    )
                }

                self.updateManeuvers()

                let distanceMeters = self.parseDistanceMeters()
                let estimates = CPTravelEstimates(
                    distanceRemaining: Measurement(value: distanceMeters, unit: UnitLength.meters),
                    timeRemaining: TimeInterval(self.stateManager.etaMinutes * 60)
                )
                if let firstManeuver = self.navigationSession?.upcomingManeuvers.first {
                    self.navigationSession?.updateEstimates(estimates, for: firstManeuver)
                }

                if self.stateManager.hasArrived {
                    self.dismissNavigation()
                    break
                }
            }
        }
    }

    private func updateManeuvers() {
        guard let session = navigationSession else { return }

        let currentManeuver = CPManeuver()
        currentManeuver.instructionVariants = [stateManager.instruction]
        if let img = UIImage(systemName: stateManager.maneuverType)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 28, weight: .bold))
            .withTintColor(SteddiTheme.accentUIColor, renderingMode: .alwaysOriginal) {
            currentManeuver.symbolImage = img
        }

        var maneuvers = [currentManeuver]

        if !stateManager.followOnInstruction.isEmpty {
            let followOn = CPManeuver()
            followOn.instructionVariants = [stateManager.followOnInstruction]
            if let img = UIImage(systemName: stateManager.followOnManeuverSymbol)?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .medium))
                .withTintColor(SteddiTheme.accentUIColor, renderingMode: .alwaysOriginal) {
                followOn.symbolImage = img
            }
            maneuvers.append(followOn)
        }

        session.upcomingManeuvers = maneuvers
    }

    private func parseDistanceMeters() -> Double {
        let remaining = stateManager.distanceRemaining
        if remaining.hasSuffix("ft") {
            let num = Double(remaining.replacingOccurrences(of: " ft", with: "").replacingOccurrences(of: ",", with: "")) ?? 0
            return num / 3.281
        } else if remaining.hasSuffix("mi") {
            let num = Double(remaining.replacingOccurrences(of: " mi", with: "").replacingOccurrences(of: ",", with: "")) ?? 0
            return num * 1609.34
        }
        return 0
    }

    // MARK: - Route Preview

    @MainActor
    private func showRoutePreview(name: String, coordinate: CLLocationCoordinate2D) async {
        guard let interfaceController else { return }

        guard let currentLoc = CLLocationManager().location else {
            showError("Unable to determine your location.")
            return
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: currentLoc.coordinate.latitude, longitude: currentLoc.coordinate.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        request.transportType = .automobile

        guard let response = try? await MKDirections(request: request).calculate(),
              let route = response.routes.first else {
            showError("Could not calculate route to \(name).")
            return
        }

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
        let arrivalItem = CPListItem(text: "Arrive \(formatter.string(from: arrivalTime))", detailText: "via \(route.name)")
        if let img = UIImage(systemName: "clock")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)) {
            arrivalItem.setImage(img)
        }

        let section = CPListSection(items: [routeInfo, arrivalItem])
        let previewTemplate = CPListTemplate(title: "Route to \(name)", sections: [section])

        let startAction = CPAlertAction(title: "Start Navigation", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            self?.interfaceController?.popToRootTemplate(animated: false, completion: nil)
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

        interfaceController.pushTemplate(previewTemplate, animated: true) { _, _ in
            let alert = CPAlertTemplate(
                titleVariants: ["\(etaMinutes) min to \(name) (\(distanceText))"],
                actions: [startAction, cancelAction]
            )
            interfaceController.presentTemplate(alert, animated: true, completion: nil)
        }
    }

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
        navigationSession = nil

        mapController?.stopNavigation()

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
