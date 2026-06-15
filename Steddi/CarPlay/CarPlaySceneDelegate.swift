import UIKit
import CarPlay
import MapKit
import SwiftData
import CoreLocation
import os

private let carplayLog = Logger(subsystem: "to.nathancurtis.steddi", category: "CarPlay")

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var carWindow: CPWindow?
    private var mapController: CarPlayMapController?
    private var mapTemplate: CPMapTemplate?
    private var navigationSession: CPNavigationSession?
    private var isShowingNavigation = false
    private var modelContainer: ModelContainer?
    private var liveUpdateTask: Task<Void, Never>?
    private var phoneNavWatchTask: Task<Void, Never>?
    /// Single auto-recenter timer armed after a free-look pan. Held so each new
    /// pan resets the window (rather than stacking timers) and so it can be
    /// cancelled when navigation ends or CarPlay disconnects.
    private var recenterTask: Task<Void, Never>?

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
        carplayLog.info("CarPlay: connectCarPlay called, window=\(window != nil)")
        self.interfaceController = interfaceController

        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            modelContainer = appDelegate.modelContainer
        }

        // Map view controller draws in the CPWindow behind all templates
        let mapVC = CarPlayMapController()
        self.mapController = mapVC
        if let window {
            self.carWindow = window
            window.rootViewController = mapVC
        }

        // CPMapTemplate is transparent — the map shows through.
        // Set it as root and NEVER replace it (replacing triggers an iOS 26 simulator crash
        // in Apple's CPSMapTemplateViewController._updateShareButtonVisibility).
        let template = CPMapTemplate()
        template.automaticallyHidesNavigationBar = true
        template.hidesButtonsWithNavigationBar = false
        template.mapDelegate = self
        self.mapTemplate = template

        // Idle state: map buttons + nav bar for browsing
        configureIdleUI()

        carplayLog.info("CarPlay: setting CPMapTemplate as root")
        interfaceController.setRootTemplate(template, animated: false) { success, error in
            carplayLog.info("CarPlay: setRootTemplate result: success=\(success), error=\(error?.localizedDescription ?? "none")")
        }

        NowPlayingService.shared.registerCommands()

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
        phoneNavWatchTask?.cancel()
        phoneNavWatchTask = nil
        liveUpdateTask?.cancel()
        liveUpdateTask = nil
        recenterTask?.cancel()
        recenterTask = nil
        dismissNavigation()
        NowPlayingService.shared.unregisterCommands()
        mapController = nil
        mapTemplate = nil
        self.interfaceController = nil
        self.carWindow = nil

        Task { @MainActor in
            stateManager.isCarPlayActive = false
        }
    }

    // MARK: - Idle / Nav UI Configuration

    private func configureIdleUI() {
        guard let mapTemplate else { return }

        let zoomIn = CPMapButton { [weak self] _ in self?.mapController?.zoomIn() }
        zoomIn.image = UIImage(systemName: "plus.magnifyingglass")

        let zoomOut = CPMapButton { [weak self] _ in self?.mapController?.zoomOut() }
        zoomOut.image = UIImage(systemName: "minus.magnifyingglass")

        let recenter = CPMapButton { [weak self] _ in self?.mapController?.recenter() }
        recenter.image = UIImage(systemName: "location.fill")

        mapTemplate.mapButtons = [recenter, zoomIn, zoomOut]

        let browseButton = CPBarButton(title: "Commutes") { [weak self] _ in
            self?.showCommutesList()
        }
        let placesButton = CPBarButton(title: "Places") { [weak self] _ in
            self?.showPlacesList()
        }
        mapTemplate.leadingNavigationBarButtons = [browseButton]
        mapTemplate.trailingNavigationBarButtons = [placesButton]
    }

    private func configureNavUI() {
        guard let mapTemplate else { return }

        let zoomIn = CPMapButton { [weak self] _ in self?.mapController?.zoomIn() }
        zoomIn.image = UIImage(systemName: "plus.magnifyingglass")

        let zoomOut = CPMapButton { [weak self] _ in self?.mapController?.zoomOut() }
        zoomOut.image = UIImage(systemName: "minus.magnifyingglass")

        let recenter = CPMapButton { [weak self] _ in self?.mapController?.recenter() }
        recenter.image = UIImage(systemName: "location.fill")

        let nowPlaying = CPMapButton { [weak self] _ in
            guard let self, let ic = self.interfaceController else { return }
            ic.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { _, _ in }
        }
        nowPlaying.image = UIImage(systemName: "music.note")

        mapTemplate.mapButtons = [recenter, zoomIn, zoomOut, nowPlaying]

        // Clear nav bar during navigation
        mapTemplate.leadingNavigationBarButtons = []
        mapTemplate.trailingNavigationBarButtons = []
    }

    // MARK: - Browse Lists

    @MainActor
    private func showCommutesList() {
        guard let interfaceController else { return }

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
                    if let img = UIImage(systemName: "arrow.triangle.swap")?
                        .withConfiguration(UIImage.SymbolConfiguration(pointSize: 24, weight: .medium))
                        .withTintColor(SteddiTheme.accentUIColor, renderingMode: .alwaysOriginal) {
                        item.setImage(img)
                    }
                    // Capture plain value copies, not the @Model. The list can
                    // sit on screen for minutes; touching the SwiftData object
                    // (or its lazily-faulted coordinate) on tap could fault on a
                    // row deleted from the main context in the meantime.
                    if let dest = commute.destination {
                        let destName = dest.name
                        let destCoord = dest.coordinate
                        item.handler = { [weak self] _, completion in
                            Task { @MainActor in
                                await self?.showRoutePreview(name: destName, coordinate: destCoord)
                            }
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

        let template = CPListTemplate(title: "Commutes", sections: [CPListSection(items: items)])
        interfaceController.pushTemplate(template, animated: true) { _, _ in }
    }

    @MainActor
    private func showPlacesList() {
        guard let interfaceController else { return }

        var items: [CPListItem] = []

        if let container = modelContainer {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<PinnedLocation>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )

            if let locations = try? context.fetch(descriptor) {
                for location in locations.prefix(12) {
                    let item = CPListItem(text: location.name, detailText: location.address ?? "")
                    if let img = UIImage(systemName: "mappin.circle.fill")?
                        .withConfiguration(UIImage.SymbolConfiguration(pointSize: 24, weight: .medium))
                        .withTintColor(SteddiTheme.accentUIColor, renderingMode: .alwaysOriginal) {
                        item.setImage(img)
                    }
                    // Capture plain value copies, not the @Model — see
                    // showCommutesList. The coordinate is a lazily-faulted
                    // property, so reading it now (not on tap) avoids faulting a
                    // row the user may delete on the phone while this list shows.
                    let placeName = location.name
                    let placeCoord = location.coordinate
                    item.handler = { [weak self] _, completion in
                        Task { @MainActor in
                            await self?.showRoutePreview(name: placeName, coordinate: placeCoord)
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

        let template = CPListTemplate(title: "Places", sections: [CPListSection(items: items)])
        interfaceController.pushTemplate(template, animated: true) { _, _ in }
    }

    // MARK: - Watch Phone Navigation

    private func watchPhoneNavigation() {
        phoneNavWatchTask?.cancel()
        phoneNavWatchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var wasNavigating = self.stateManager.isNavigating
            while !Task.isCancelled, self.interfaceController != nil {
                try? await Task.sleep(for: .seconds(1))
                let isNav = self.stateManager.isNavigating

                if isNav && !wasNavigating {
                    self.showNavigationUI()
                } else if !isNav && wasNavigating {
                    self.dismissNavigation()
                }

                wasNavigating = isNav
            }
        }
    }

    // MARK: - Show Navigation

    @MainActor
    private func showNavigationUI() {
        guard let mapTemplate, !isShowingNavigation else {
            carplayLog.info("CarPlay: showNavigationUI skipped (mapTemplate=\(self.mapTemplate != nil), isShowing=\(self.isShowingNavigation))")
            return
        }
        carplayLog.info("CarPlay: showNavigationUI starting")
        isShowingNavigation = true

        // Pop any pushed templates (commutes list, etc.) back to map root
        // Must provide completion handler — CarPlay throws if there's nothing to pop and no handler is set
        interfaceController?.popToRootTemplate(animated: false) { _, _ in }

        // Start the map chase-cam with route overlay
        let routeCoords = stateManager.activeRouteCoords
        carplayLog.info("CarPlay: route has \(routeCoords.count) coords")
        if !routeCoords.isEmpty {
            mapController?.startNavigation(routeCoords: routeCoords)
        }

        // Switch to navigation buttons
        configureNavUI()

        // Create navigation session for maneuver display
        carplayLog.info("CarPlay: creating CPTrip and navigation session")
        let origin = MKMapItem.forCurrentLocation()
        let destination: MKMapItem
        if let destCoord = routeCoords.last {
            destination = MKMapItem(location: CLLocation(latitude: destCoord.latitude, longitude: destCoord.longitude), address: nil)
        } else {
            destination = MKMapItem.forCurrentLocation()
        }

        let routeChoice = CPRouteChoice(
            summaryVariants: ["Steddi Route"],
            additionalInformationVariants: [],
            selectionSummaryVariants: ["Steddi Route"]
        )
        let trip = CPTrip(origin: origin, destination: destination, routeChoices: [routeChoice])
        navigationSession = mapTemplate.startNavigationSession(for: trip)
        carplayLog.info("CarPlay: navigation session started successfully")

        subscribeLiveUpdates()
    }

    // MARK: - Live Updates

    private var lastInstruction: String = ""
    private var lastFollowOn: String = ""

    @MainActor
    private func subscribeLiveUpdates() {
        liveUpdateTask?.cancel()
        lastInstruction = ""
        lastFollowOn = ""

        liveUpdateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isShowingNavigation else { break }

                // Auto-reroute swaps the active route — keep the overlay current
                self.mapController?.syncRoute(self.stateManager.activeRouteCoords)

                // Update map camera from the same snapped pose the phone renders
                if let pose = self.stateManager.currentPose {
                    self.mapController?.updateNavigationPose(
                        pose,
                        headingDegrees: self.stateManager.headingDegrees
                    )
                }

                // Only rebuild maneuvers when the instruction actually changes
                let currentInstr = self.stateManager.instruction
                let currentFollowOn = self.stateManager.followOnInstruction
                if currentInstr != self.lastInstruction || currentFollowOn != self.lastFollowOn {
                    self.lastInstruction = currentInstr
                    self.lastFollowOn = currentFollowOn
                    self.rebuildManeuvers()
                }

                // Update travel estimates
                self.updateTravelEstimates()

                // Check for arrival
                if self.stateManager.hasArrived {
                    self.dismissNavigation()
                    break
                }
            }
        }
    }

    private func rebuildManeuvers() {
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

    private func updateTravelEstimates() {
        guard let session = navigationSession,
              let firstManeuver = session.upcomingManeuvers.first else { return }

        let estimates = CPTravelEstimates(
            distanceRemaining: Measurement(value: stateManager.distanceRemainingMeters, unit: UnitLength.meters),
            timeRemaining: stateManager.etaSeconds
        )
        session.updateEstimates(estimates, for: firstManeuver)
    }

    // MARK: - Route Preview

    @MainActor
    private func showRoutePreview(name: String, coordinate: CLLocationCoordinate2D) async {
        guard let interfaceController else { return }

        guard let origin = mapController?.currentUserCoordinate else {
            showError("Unable to determine your location.")
            return
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
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
            self?.interfaceController?.dismissTemplate(animated: true) { _, _ in }
            self?.interfaceController?.popToRootTemplate(animated: false) { _, _ in }
            NotificationCenter.default.post(
                name: .steddiNavigateToLocation,
                object: nil,
                userInfo: ["lat": coordinate.latitude, "lng": coordinate.longitude, "name": name]
            )
        }

        let cancelAction = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true) { _, _ in }
            self?.interfaceController?.popToRootTemplate(animated: true) { _, _ in }
        }

        interfaceController.pushTemplate(previewTemplate, animated: true) { _, _ in
            let alert = CPAlertTemplate(
                titleVariants: ["\(etaMinutes) min to \(name) (\(distanceText))"],
                actions: [startAction, cancelAction]
            )
            interfaceController.presentTemplate(alert, animated: true) { _, _ in }
        }
    }

    @MainActor
    private func showError(_ message: String) {
        guard let interfaceController else { return }
        let action = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true) { _, _ in }
        }
        let alert = CPAlertTemplate(titleVariants: [message], actions: [action])
        interfaceController.presentTemplate(alert, animated: true) { _, _ in }
    }

    // MARK: - Dismiss Navigation

    @MainActor
    private func dismissNavigation() {
        liveUpdateTask?.cancel()
        liveUpdateTask = nil
        // A free-look timer queued during navigation must not fire after it
        // ends, snapping the now-idle browsing camera back to follow mode.
        recenterTask?.cancel()
        recenterTask = nil
        isShowingNavigation = false
        navigationSession?.finishTrip()
        navigationSession = nil

        mapController?.stopNavigation()

        // Restore idle UI on the same map template (never swap root)
        configureIdleUI()
    }
}

// MARK: - CPMapTemplateDelegate

extension CarPlaySceneDelegate: CPMapTemplateDelegate {

    func mapTemplate(_ mapTemplate: CPMapTemplate, panBeganWith direction: CPMapTemplate.PanDirection) {
        // A new pan restarts the free-look window — cancel any pending
        // auto-recenter so it can't fire mid-inspection.
        recenterTask?.cancel()
        recenterTask = nil
        mapController?.setFreeLook(true)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
        let scrollAmount: CLLocationDegrees = 0.002
        var lat: CLLocationDegrees = 0
        var lng: CLLocationDegrees = 0

        if direction.contains(.up) { lat += scrollAmount }
        if direction.contains(.down) { lat -= scrollAmount }
        if direction.contains(.left) { lng -= scrollAmount }
        if direction.contains(.right) { lng += scrollAmount }

        mapController?.panMap(latDelta: lat, lngDelta: lng)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, panEndedWith direction: CPMapTemplate.PanDirection) {
        // Replace any in-flight timer so only the most recent pan's 5s window is
        // live — repeated pans reset the window instead of stacking timers that
        // would yank the camera back mid-inspection.
        recenterTask?.cancel()
        recenterTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            self.recenterTask = nil
            self.mapController?.setFreeLook(false)
            self.mapController?.recenter()
        }
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, shouldShowNotificationFor maneuver: CPManeuver) -> Bool {
        true
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, shouldUpdateNotificationFor maneuver: CPManeuver, with travelEstimates: CPTravelEstimates) -> Bool {
        true
    }
}
