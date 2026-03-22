import UIKit
import CarPlay
import MapboxMaps
import MapboxNavigationCore
import MapboxDirections
import SwiftData
import CoreLocation
import Combine

// MARK: - CarPlaySceneDelegate
// Uses NavigationStateManager from Services/NavigationStateManager.swift

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPTemplateApplicationDashboardSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var carWindow: CPWindow?
    private var mapTemplate: CPMapTemplate?
    private var navigationSession: CPNavigationSession?
    private var mapController: CarPlayMapController?

    private var modelContainer: ModelContainer?
    private var navProvider: MapboxNavigationProvider?
    private var cancellables: Set<AnyCancellable> = []

    private var stateManager: NavigationStateManager { NavigationStateManager.shared }

    // MARK: - Template Application Scene

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController
        self.carWindow = window

        // Build a model container matching SteddiApp's config
        do {
            modelContainer = try ModelContainer(for:
                PinnedLocation.self,
                Commute.self,
                Route.self,
                DriveRecord.self,
                NoGoZone.self,
                CommuteTrip.self,
                Report.self
            )
        } catch {
            print("[CarPlay] Failed to create ModelContainer: \(error)")
        }

        Task { @MainActor in
            stateManager.isCarPlayActive = true
            await buildRootTemplate()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        stopCarPlayNavigation()
        cancellables.removeAll()
        self.interfaceController = nil
        self.carWindow = nil
        self.mapController = nil
        self.navProvider = nil

        Task { @MainActor in
            stateManager.isCarPlayActive = false
        }
    }

    // MARK: - Dashboard Scene

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didConnect dashboardController: CPDashboardController,
        to window: UIWindow
    ) {
        // Dashboard shows compact navigation widgets
        // Updated via observation of NavigationStateManager
        Task { @MainActor in
            updateDashboard(dashboardController)
        }
    }

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didDisconnect dashboardController: CPDashboardController,
        from window: UIWindow
    ) {
        // No cleanup needed — dashboard is read-only
    }

    // MARK: - Build Root Template

    @MainActor
    private func buildRootTemplate() async {
        guard let interfaceController else { return }

        let commutesTab = await buildCommutesTab()
        let recentsTab = buildRecentsTab()

        let tabBar = CPTabBarTemplate(templates: [commutesTab, recentsTab])
        interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)
    }

    // MARK: - Commutes Tab

    @MainActor
    private func buildCommutesTab() async -> CPListTemplate {
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
                    let subtitle = "\(originName) → \(destName)"

                    var detail = subtitle
                    if let duration = commute.preferredRoute?.typicalDurationSeconds {
                        let mins = Int(ceil(duration / 60))
                        detail = "\(subtitle) — ~\(mins) min"
                    }

                    let item = CPListItem(text: commute.name, detailText: detail)
                    item.handler = { [weak self] _, completion in
                        Task { @MainActor in
                            await self?.handleCommuteTap(commute)
                            completion()
                        }
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

    @MainActor
    private func buildRecentsTab() -> CPListTemplate {
        var items: [CPListItem] = []

        if let container = modelContainer {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<PinnedLocation>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )

            if let locations = try? context.fetch(descriptor) {
                for location in locations.prefix(12) {
                    let item = CPListItem(
                        text: location.name,
                        detailText: location.address ?? ""
                    )
                    item.handler = { [weak self] _, completion in
                        Task { @MainActor in
                            await self?.navigateToLocation(location)
                            completion()
                        }
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

    // MARK: - Handle Commute Tap

    @MainActor
    private func handleCommuteTap(_ commute: Commute) async {
        // Resolve direction
        guard let currentLocation = CLLocationManager().location else {
            showError("Unable to determine your location.")
            return
        }

        // Fetch trips for pattern learning
        var trips: [CommuteTrip] = []
        if let container = modelContainer {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<CommuteTrip>()
            trips = (try? context.fetch(descriptor)) ?? []
        }

        let resolution = CommuteDirectionResolver.resolve(
            commute: commute,
            currentLocation: currentLocation,
            trips: trips
        )

        switch resolution {
        case .confident(let direction, _):
            await startCommuteNavigation(commute: commute, direction: direction)

        case .ambiguous(let originName, let destinationName):
            // Show a direction picker alert on CarPlay
            showDirectionPicker(
                commute: commute,
                originName: originName,
                destinationName: destinationName
            )
        }
    }

    @MainActor
    private func showDirectionPicker(commute: Commute, originName: String, destinationName: String) {
        guard let interfaceController else { return }

        let toDestAction = CPAlertAction(title: "→ \(destinationName)", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            Task { @MainActor in
                await self?.startCommuteNavigation(commute: commute, direction: .originToDestination)
            }
        }

        let toOriginAction = CPAlertAction(title: "→ \(originName)", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            Task { @MainActor in
                await self?.startCommuteNavigation(commute: commute, direction: .destinationToOrigin)
            }
        }

        let cancelAction = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
        }

        let alert = CPAlertTemplate(titleVariants: ["Which way?"], actions: [toDestAction, toOriginAction, cancelAction])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: - Start Commute Navigation

    @MainActor
    private func startCommuteNavigation(commute: Commute, direction: CommuteDirection) async {
        // Check for preferred route
        if let preferredRoute = commute.preferredRoute(for: direction) {
            // Decode the stored polyline to get waypoints for Mapbox Navigation
            let coords = PolylineEncoder.decode(preferredRoute.encodedPolyline, precision: 6)
            guard coords.count >= 2 else {
                await calculateAndStartNavigation(commute: commute, direction: direction)
                return
            }

            await calculateAndStartNavigation(
                commute: commute,
                direction: direction,
                waypoints: [
                    Waypoint(coordinate: coords.first!, name: "Start"),
                    Waypoint(coordinate: coords.last!, name: commute.destination?.name ?? "Destination")
                ]
            )
        } else {
            await calculateAndStartNavigation(commute: commute, direction: direction)
        }
    }

    @MainActor
    private func calculateAndStartNavigation(
        commute: Commute,
        direction: CommuteDirection,
        waypoints: [Waypoint]? = nil
    ) async {
        let provider = MapboxNavigationProvider(coreConfig: .init())
        self.navProvider = provider

        let resolvedWaypoints: [Waypoint]
        if let waypoints {
            resolvedWaypoints = waypoints
        } else {
            guard let currentLocation = CLLocationManager().location else {
                showError("Unable to determine your location.")
                return
            }

            let destination: PinnedLocation?
            switch direction {
            case .originToDestination: destination = commute.destination
            case .destinationToOrigin: destination = commute.origin
            }

            guard let dest = destination else {
                showError("Commute is missing a destination.")
                return
            }

            resolvedWaypoints = [
                Waypoint(coordinate: currentLocation.coordinate, name: "Current Location"),
                Waypoint(coordinate: dest.coordinate, name: dest.name)
            ]
        }

        let routeOptions = NavigationRouteOptions(waypoints: resolvedWaypoints)

        do {
            let routes = try await provider.routingProvider().calculateRoutes(options: routeOptions).value
            startCarPlayNavigation(routes: routes, commute: commute, direction: direction)
        } catch {
            showError("Could not calculate route.")
        }
    }

    // MARK: - Navigate to Location (non-commute)

    @MainActor
    private func navigateToLocation(_ location: PinnedLocation) async {
        guard let currentLocation = CLLocationManager().location else {
            showError("Unable to determine your location.")
            return
        }

        let provider = MapboxNavigationProvider(coreConfig: .init())
        self.navProvider = provider

        let waypoints = [
            Waypoint(coordinate: currentLocation.coordinate, name: "Current Location"),
            Waypoint(coordinate: location.coordinate, name: location.name)
        ]

        let routeOptions = NavigationRouteOptions(waypoints: waypoints)

        do {
            let routes = try await provider.routingProvider().calculateRoutes(options: routeOptions).value
            startCarPlayNavigation(routes: routes, commute: nil, direction: nil)
        } catch {
            showError("Could not calculate route to \(location.name).")
        }
    }

    // MARK: - Start CarPlay Navigation

    @MainActor
    private func startCarPlayNavigation(routes: NavigationRoutes, commute: Commute?, direction: CommuteDirection?) {
        guard let interfaceController, let carWindow, let navProvider else { return }

        // Create map template
        let mapTemplate = CPMapTemplate()
        mapTemplate.guidanceBackgroundColor = .black
        self.mapTemplate = mapTemplate

        // Set up the map view controller
        let mapController = CarPlayMapController()
        mapController.view.frame = carWindow.bounds
        carWindow.rootViewController = mapController
        self.mapController = mapController

        // Start active guidance
        navProvider.tripSession().startActiveGuidance(with: routes, startLegIndex: 0)

        // Show route line
        let coords = routes.mainRoute.route.shape?.coordinates ?? []
        mapController.startNavigation(routeCoords: coords)

        // Create navigation session
        let trip = CPTrip(
            origin: MKMapItem(placemark: MKPlacemark(coordinate: coords.first ?? CLLocationCoordinate2D())),
            destination: MKMapItem(placemark: MKPlacemark(coordinate: coords.last ?? CLLocationCoordinate2D())),
            routeChoices: [CPRouteChoice(summaryVariants: ["Steddi Route"], additionalInformationVariants: [], selectionSummaryVariants: [])]
        )
        let session = mapTemplate.startNavigationSession(for: trip)
        self.navigationSession = session

        // Build initial maneuvers from route steps
        updateManeuversFromRoute(routes)

        // Push the map template
        interfaceController.pushTemplate(mapTemplate, animated: true, completion: nil)

        // Update state
        stateManager.isNavigating = true
        stateManager.isCarPlayActive = true

        // Subscribe to navigation updates
        observeNavigation(provider: navProvider, commute: commute, direction: direction)
    }

    // MARK: - Navigation Observation

    @MainActor
    private func observeNavigation(provider: MapboxNavigationProvider, commute: Commute?, direction: CommuteDirection?) {
        let nav = provider.navigation()

        // Route progress
        nav.routeProgress
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] state in
                guard let self else { return }
                let progress = state.routeProgress

                let etaMins = max(1, Int(ceil(progress.durationRemaining / 60)))
                let distRemaining = progress.distanceRemaining

                // Update state manager
                self.stateManager.etaMinutes = etaMins
                self.stateManager.distanceRemaining = NavigationStateManager.formatDistance(distRemaining)
                self.stateManager.arrivalTime = NavigationStateManager.formatArrivalTime(progress.durationRemaining)

                // Current step
                let step = progress.currentLegProgress.currentStep
                let stepDist = progress.currentLegProgress.currentStepProgress.distanceRemaining
                self.stateManager.instruction = step.instructions
                self.stateManager.stepDistanceRaw = stepDist
                self.stateManager.stepDistance = NavigationStateManager.formatDistance(stepDist)
                self.stateManager.maneuverType = self.sfSymbol(
                    for: step.maneuverType,
                    direction: step.maneuverDirection
                )

                // Follow-on
                if let followOn = progress.currentLegProgress.followOnStep {
                    self.stateManager.followOnInstruction = followOn.instructions
                    self.stateManager.followOnManeuverSymbol = self.sfSymbol(
                        for: followOn.maneuverType,
                        direction: followOn.maneuverDirection
                    )
                } else {
                    self.stateManager.followOnInstruction = ""
                    self.stateManager.followOnManeuverSymbol = ""
                }

                // Update CarPlay maneuvers
                self.updateCurrentManeuver(
                    instruction: step.instructions,
                    symbolName: self.stateManager.maneuverType,
                    distanceRemaining: distRemaining,
                    durationRemaining: progress.durationRemaining,
                    stepDistanceRemaining: stepDist
                )
            }
            .store(in: &cancellables)

        // Location matching
        nav.locationMatching
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let coord = state.enhancedLocation.coordinate
                let bearing = state.location.course

                self.stateManager.currentCoordinate = coord
                self.stateManager.headingDegrees = bearing
                self.stateManager.roadName = state.roadName?.text ?? ""

                let speedMS = state.currentSpeed.converted(to: .metersPerSecond).value
                self.stateManager.currentSpeedMph = max(0, speedMS * 2.23694)

                if let limitValue = state.speedLimit.value {
                    self.stateManager.speedLimitMph = limitValue.converted(to: .milesPerHour).value
                } else {
                    self.stateManager.speedLimitMph = nil
                }

                // Update map camera
                self.mapController?.updateCamera(coordinate: coord, bearing: bearing)
            }
            .store(in: &cancellables)

        // Arrival
        nav.waypointsArrival
            .receive(on: DispatchQueue.main)
            .sink { [weak self] arrival in
                guard arrival.event != nil else { return }
                self?.handleArrival()
            }
            .store(in: &cancellables)

        // Reroute checking (for commutes with fallback routes)
        if let commute, let direction {
            startRerouteChecking(commute: commute, direction: direction, provider: provider)
        }
    }

    // MARK: - Update CarPlay Maneuvers

    @MainActor
    private func updateManeuversFromRoute(_ routes: NavigationRoutes) {
        guard let session = navigationSession else { return }

        let steps = routes.mainRoute.route.legs.flatMap(\.steps)
        var maneuvers: [CPManeuver] = []

        for step in steps {
            let maneuver = CPManeuver()
            maneuver.instructionVariants = [step.instructions]

            let symbolName = sfSymbol(for: step.maneuverType, direction: step.maneuverDirection)
            maneuver.symbolImage = UIImage(systemName: symbolName)?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)
            )

            let estimates = CPTravelEstimates(
                distanceRemaining: Measurement(value: step.distance, unit: .meters),
                timeRemaining: step.expectedTravelTime
            )
            maneuver.initialTravelEstimates = estimates

            maneuvers.append(maneuver)
        }

        session.upcomingManeuvers = maneuvers
    }

    @MainActor
    private func updateCurrentManeuver(
        instruction: String,
        symbolName: String,
        distanceRemaining: Double,
        durationRemaining: TimeInterval,
        stepDistanceRemaining: Double
    ) {
        guard let session = navigationSession else { return }

        // Update the first (current) maneuver
        if var currentManeuver = session.upcomingManeuvers.first {
            currentManeuver.instructionVariants = [instruction]
            currentManeuver.symbolImage = UIImage(systemName: symbolName)?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)
            )

            let stepEstimates = CPTravelEstimates(
                distanceRemaining: Measurement(value: stepDistanceRemaining, unit: .meters),
                timeRemaining: 0 // Step-level time not always available
            )
            session.updateEstimates(stepEstimates, for: currentManeuver)
        }

        // Update trip-level estimates
        let tripEstimates = CPTravelEstimates(
            distanceRemaining: Measurement(value: distanceRemaining, unit: .meters),
            timeRemaining: durationRemaining
        )
        session.updateEstimates(tripEstimates, for: session.upcomingManeuvers.first ?? CPManeuver())
    }

    // MARK: - Reroute Checking

    @MainActor
    private func startRerouteChecking(commute: Commute, direction: CommuteDirection, provider: MapboxNavigationProvider) {
        Task { @MainActor in
            let directionsService = DirectionsService(accessToken: MapboxTokenProvider.accessToken)
            let nav = provider.navigation()

            while !Task.isCancelled && stateManager.isNavigating {
                try? await Task.sleep(for: .seconds(300)) // 5-minute interval
                guard !Task.isCancelled, stateManager.isNavigating else { break }
                guard stateManager.rerouteSuggestion == nil else { continue }

                guard let currentLocation = nav.currentLocationMatching?.enhancedLocation,
                      let currentProgress = nav.currentRouteProgress else { continue }

                let remainingETA = currentProgress.routeProgress.durationRemaining
                let fallbacks = commute.orderedRoutes(for: direction).filter { $0.rank > 0 }
                guard !fallbacks.isEmpty else { continue }

                var bestSuggestion: (route: Route, savingsMinutes: Double, savingsPercentage: Double)?
                var bestSavings: TimeInterval = 0

                for fallback in fallbacks {
                    do {
                        let fallbackETA = try await directionsService.fetchETA(
                            from: currentLocation.coordinate,
                            along: fallback.encodedPolyline
                        )

                        let decision = RerouteEngine.evaluate(
                            remainingETASeconds: remainingETA,
                            fallbackETASeconds: fallbackETA,
                            basePercentage: commute.thresholdPercentage,
                            hardMinuteFloor: commute.hardMinuteFloor
                        )

                        if decision.shouldReroute, decision.savingsSeconds > bestSavings {
                            bestSavings = decision.savingsSeconds
                            bestSuggestion = (
                                route: fallback,
                                savingsMinutes: decision.savingsMinutes,
                                savingsPercentage: decision.savingsSeconds / remainingETA
                            )
                        }
                    } catch {
                        continue
                    }
                }

                if let suggestion = bestSuggestion {
                    stateManager.rerouteSuggestion = suggestion
                    showRerouteAlert(suggestion: suggestion, commute: commute, direction: direction)
                }
            }
        }
    }

    @MainActor
    private func showRerouteAlert(
        suggestion: (route: Route, savingsMinutes: Double, savingsPercentage: Double),
        commute: Commute,
        direction: CommuteDirection
    ) {
        guard let interfaceController else { return }

        let savingsText = "Save ~\(Int(suggestion.savingsMinutes)) min"
        let routeName = suggestion.route.name ?? "Faster route"

        let switchAction = CPAlertAction(title: "Switch", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            Task { @MainActor in
                await self?.switchToRoute(suggestion.route, commute: commute, direction: direction)
            }
        }

        let stayAction = CPAlertAction(title: "Stay", style: .cancel) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            Task { @MainActor in
                self?.stateManager.rerouteSuggestion = nil
            }
        }

        let alert = CPAlertTemplate(
            titleVariants: ["\(routeName): \(savingsText)"],
            actions: [switchAction, stayAction]
        )
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    @MainActor
    private func switchToRoute(_ route: Route, commute: Commute, direction: CommuteDirection) async {
        stateManager.rerouteSuggestion = nil

        // Stop current navigation and restart with the new route's polyline
        stopCarPlayNavigation()

        let coords = PolylineEncoder.decode(route.encodedPolyline, precision: 6)
        guard coords.count >= 2 else { return }

        let provider = MapboxNavigationProvider(coreConfig: .init())
        self.navProvider = provider

        let waypoints = [
            Waypoint(coordinate: coords.first!, name: "Start"),
            Waypoint(coordinate: coords.last!, name: route.name ?? "Destination")
        ]

        let routeOptions = NavigationRouteOptions(waypoints: waypoints)

        do {
            let routes = try await provider.routingProvider().calculateRoutes(options: routeOptions).value
            startCarPlayNavigation(routes: routes, commute: commute, direction: direction)
        } catch {
            showError("Could not switch routes.")
        }
    }

    // MARK: - Handle Arrival

    @MainActor
    private func handleArrival() {
        navigationSession?.finishTrip()
        stopCarPlayNavigation()

        // Pop back to root
        interfaceController?.popToRootTemplate(animated: true, completion: nil)
    }

    // MARK: - Stop Navigation

    @MainActor
    private func stopCarPlayNavigation() {
        cancellables.removeAll()
        navigationSession = nil
        mapTemplate = nil
        mapController?.stopNavigation()

        stateManager.isNavigating = false
        stateManager.rerouteSuggestion = nil
    }

    // MARK: - Dashboard Updates

    @MainActor
    private func updateDashboard(_ dashboard: CPDashboardController) {
        // Dashboard buttons show compact nav info
        // CarPlay dashboard is very limited — just shortcut buttons
        // The system shows our navigation template automatically when navigating
        let navButton = CPDashboardButton(
            titleVariants: ["Steddi"],
            subtitleVariants: ["Navigate"],
            image: UIImage(systemName: "location.fill")!
        ) { _ in
            // Tapping brings up the full CarPlay app
        }

        dashboard.shortcutButtons = [navButton]
    }

    // MARK: - Error Handling

    @MainActor
    private func showError(_ message: String) {
        guard let interfaceController else { return }

        let action = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
        }

        let alert = CPAlertTemplate(titleVariants: [message], actions: [action])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: - SF Symbol Mapping

    private func sfSymbol(for maneuverType: ManeuverType, direction: ManeuverDirection?) -> String {
        switch maneuverType {
        case .turn:
            switch direction {
            case .left, .sharpLeft, .slightLeft: return "arrow.turn.up.left"
            case .right, .sharpRight, .slightRight: return "arrow.turn.up.right"
            case .uTurn: return "arrow.uturn.down"
            default: return "arrow.up"
            }
        case .merge: return "arrow.merge"
        case .takeOnRamp, .takeOffRamp:
            switch direction {
            case .left, .sharpLeft, .slightLeft: return "arrow.up.left"
            case .right, .sharpRight, .slightRight: return "arrow.up.right"
            default: return "arrow.up.right"
            }
        case .reachFork:
            switch direction {
            case .left, .slightLeft: return "arrow.up.left"
            default: return "arrow.up.right"
            }
        case .reachEnd: return "arrow.turn.up.right"
        case .useLane: return "arrow.up"
        case .takeRotary, .takeRoundabout: return "arrow.triangle.2.circlepath"
        case .arrive: return "flag.fill"
        case .depart: return "location.fill"
        default: return "arrow.up"
        }
    }
}
