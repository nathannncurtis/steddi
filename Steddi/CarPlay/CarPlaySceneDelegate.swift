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
    /// Retained so "Start Navigation" can foreground/cold-launch the phone scene
    /// via `open(_:options:)`. In a CarPlay-only session there is no phone scene
    /// or HomeView, so a bare NotificationCenter post would evaporate; opening
    /// the deep link is what brings the app up to drain the durable nav route.
    private var templateScene: CPTemplateApplicationScene?
    private var mapController: CarPlayMapController?
    private var mapTemplate: CPMapTemplate?
    private var navigationSession: CPNavigationSession?
    /// The active CPTrip backing `navigationSession`. Retained so the whole-trip
    /// remaining distance/ETA can be pushed via `CPMapTemplate.update(_:for:with:)`
    /// — the trip-level surface — separately from the per-maneuver countdown.
    private var navigationTrip: CPTrip?
    private var isShowingNavigation = false
    /// True while the route-preview "Start Navigation / Cancel" CPAlertTemplate is
    /// presented modally. A modal alert is NOT on the navigation stack, so
    /// popToRootTemplate won't remove it — only dismissTemplate does. Tracked so
    /// nav start can tear it down (and so we never call dismissTemplate when no
    /// modal is up, which would log a spurious warning).
    private var isShowingRoutePreviewAlert = false
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
        self.templateScene = templateApplicationScene
        connectCarPlay(interfaceController: interfaceController, window: window)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.templateScene = templateApplicationScene
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
        // Do NOT unregister remote commands here. MPRemoteCommandCenter is a
        // single process-wide singleton; the phone still needs pass-through
        // media controls (steering-wheel/Lock Screen/Control Center) for
        // phone-only navigation after CarPlay leaves. Tearing them down on
        // disconnect would disable media controls for the rest of the app
        // session. Commands were armed at launch and stay armed.
        mapController = nil
        mapTemplate = nil
        self.interfaceController = nil
        self.carWindow = nil
        self.templateScene = nil

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
            var lastGeneration = self.stateManager.sessionGeneration
            while !Task.isCancelled, self.interfaceController != nil {
                try? await Task.sleep(for: .seconds(1))
                let isNav = self.stateManager.isNavigating
                let generation = self.stateManager.sessionGeneration

                if isNav {
                    if !wasNavigating {
                        // Phone started navigating — present CarPlay nav.
                        self.showNavigationUI()
                    } else if generation != lastGeneration {
                        // A new session began (e.g. the next leg of a continuous
                        // trip) without isNavigating observably dipping to false.
                        // Re-target the CPTrip + route overlay to the new leg.
                        self.restartNavigationSession()
                    }
                } else if !isNav && wasNavigating {
                    self.dismissNavigation()
                }

                wasNavigating = isNav
                lastGeneration = generation
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

        // Navigation can start from an independent path (phone-side Start Commute,
        // a deep link, a smart-commute alert) while the driver is still looking at
        // the route-preview alert. That alert is presented modally, so the
        // popToRootTemplate below won't remove it — dismiss it explicitly first so
        // a stale "Start Navigation" can't sit pinned over the live nav map and
        // hijack the active drive to the old destination.
        dismissRoutePreviewAlert(animated: false)

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
        navigationTrip = trip
        navigationSession = mapTemplate.startNavigationSession(for: trip)
        carplayLog.info("CarPlay: navigation session started successfully")

        subscribeLiveUpdates()
    }

    /// Re-target the live CarPlay nav UI to a new session (e.g. the next leg of
    /// a continuous trip) without tearing down the map chase-cam. Keeps the
    /// overlay up, swaps the route overlay + CPTrip destination to the new leg,
    /// and lets the running live-update loop rebuild maneuvers on the next tick.
    @MainActor
    private func restartNavigationSession() {
        // If nav isn't currently shown (e.g. dismissed at final arrival of the
        // prior session and never re-shown), fall back to a full presentation.
        guard isShowingNavigation, let mapTemplate else {
            showNavigationUI()
            return
        }
        carplayLog.info("CarPlay: restartNavigationSession for new leg")

        // A new leg is also a nav-start path — clear any lingering preview modal.
        dismissRoutePreviewAlert(animated: false)

        let routeCoords = stateManager.activeRouteCoords
        if !routeCoords.isEmpty {
            // The chase-cam session is already running (isInNavigation == true),
            // so startNavigation would early-return and never re-target. syncRoute
            // is purpose-built to rebase a live session: it swaps the overlay and
            // rebuilds the arc-length geometry/interpolator for the new leg.
            mapController?.syncRoute(routeCoords)
        }

        // Replace the CPTrip so the destination marker/estimates track the new
        // leg. End the old trip before starting the new one.
        navigationSession?.finishTrip()

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
        navigationTrip = trip
        navigationSession = mapTemplate.startNavigationSession(for: trip)

        // Force the next live tick to rebuild maneuvers for the new leg.
        lastInstruction = ""
        lastFollowOn = ""
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

                // Arrival handling: only tear CarPlay nav down on *final*
                // arrival. For a continuous-mode trip, an intermediate leg
                // latches hasArrived while isNavigating stays true (the next leg
                // restarts the session in the same main-actor turn). Dismissing
                // here would leave CarPlay on the idle map for every subsequent
                // leg, since the 1 Hz phone-nav watcher never sees the transient
                // isNavigating false. Keep the overlay live across legs; the
                // watcher re-targets the CPTrip on the new sessionGeneration.
                // The final leg ends the session (isNavigating -> false), and the
                // watcher dismisses then.
                if self.stateManager.hasArrived && !self.stateManager.isNavigating {
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
        guard let session = navigationSession else { return }

        // Maneuver estimate = countdown to the NEXT turn (current step distance/time).
        // CPNavigationSession.updateEstimates(_:for:) scopes the estimate to that one
        // CPManeuver, so this must be the per-step value — NOT the whole-trip remaining,
        // or the maneuver banner shows the full trip distance as the distance-to-turn.
        if let firstManeuver = session.upcomingManeuvers.first {
            let stepMeters = stateManager.stepDistanceRaw
            let stepTime = Self.timeToNextManeuver(
                distanceMeters: stepMeters,
                speedMph: stateManager.currentSpeedMph
            )
            let maneuverEstimates = CPTravelEstimates(
                distanceRemaining: Measurement(value: stepMeters, unit: UnitLength.meters),
                timeRemaining: stepTime
            )
            session.updateEstimates(maneuverEstimates, for: firstManeuver)
        }

        // Trip estimate = whole-trip remaining distance/ETA to the destination.
        // This is the trip-level surface (CPMapTemplate), distinct from the per-turn banner.
        if let mapTemplate, let navigationTrip {
            let tripEstimates = CPTravelEstimates(
                distanceRemaining: Measurement(value: stateManager.distanceRemainingMeters, unit: UnitLength.meters),
                timeRemaining: stateManager.etaSeconds
            )
            mapTemplate.update(tripEstimates, for: navigationTrip, with: .green)
        }
    }

    /// Estimated seconds to reach the next maneuver, derived from the remaining
    /// step distance and current speed. The engine exposes per-step distance
    /// (`stepDistanceRaw`) but no per-step time, so we derive it here.
    /// Falls back to 0 when stopped/near the turn so CarPlay just shows the
    /// distance countdown rather than a nonsensically large time.
    nonisolated static func timeToNextManeuver(distanceMeters: Double, speedMph: Double) -> TimeInterval {
        guard distanceMeters > 0 else { return 0 }
        let speedMPS = speedMph * 0.44704
        // Below a walking-pace floor the divide explodes; treat as 0 (unknown).
        guard speedMPS > 0.5 else { return 0 }
        return distanceMeters / speedMPS
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

        // Locale-aware "jmm" (resolves to 12h or 24h per the locale) instead of a
        // hardcoded "h:mm a", which breaks 24-hour-clock locales. Shares the same
        // implementation used by the phone nav surfaces.
        let arrivalString = NavigationEngine.formatArrivalTime(route.expectedTravelTime)
        let arrivalItem = CPListItem(text: "Arrive \(arrivalString)", detailText: "via \(route.name)")
        if let img = UIImage(systemName: "clock")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)) {
            arrivalItem.setImage(img)
        }

        let section = CPListSection(items: [routeInfo, arrivalItem])
        let previewTemplate = CPListTemplate(title: "Route to \(name)", sections: [section])

        let startAction = CPAlertAction(title: "Start Navigation", style: .default) { [weak self] _ in
            self?.isShowingRoutePreviewAlert = false
            self?.interfaceController?.dismissTemplate(animated: true) { _, _ in }
            self?.interfaceController?.popToRootTemplate(animated: false) { _, _ in }
            self?.startNavigation(to: name, coordinate: coordinate)
        }

        let cancelAction = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.isShowingRoutePreviewAlert = false
            self?.interfaceController?.dismissTemplate(animated: true) { _, _ in }
            self?.interfaceController?.popToRootTemplate(animated: true) { _, _ in }
        }

        interfaceController.pushTemplate(previewTemplate, animated: true) { [weak self] _, _ in
            let alert = CPAlertTemplate(
                titleVariants: ["\(etaMinutes) min to \(name) (\(distanceText))"],
                actions: [startAction, cancelAction]
            )
            interfaceController.presentTemplate(alert, animated: true) { [weak self] success, _ in
                if success { self?.isShowingRoutePreviewAlert = true }
            }
        }
    }

    /// Dismiss the modally-presented route-preview alert if one is up. A no-op
    /// when no preview alert is showing, so it never logs a dismiss-with-no-modal
    /// warning. Called when navigation starts so the stale alert can't linger over
    /// the live nav UI.
    @MainActor
    private func dismissRoutePreviewAlert(animated: Bool) {
        guard isShowingRoutePreviewAlert else { return }
        isShowingRoutePreviewAlert = false
        interfaceController?.dismissTemplate(animated: animated) { _, _ in }
    }

    /// Start navigation to a coordinate from the CarPlay route preview.
    ///
    /// In a CarPlay-only session (driver got in with the phone locked / Steddi
    /// not running) there is no phone scene and no HomeView, so the old
    /// `NotificationCenter.post(.steddiNavigateToLocation)` had no subscriber and
    /// did nothing — the headline browse-and-go flow was a dead control. Mirror
    /// the proven dashboard "Start Commute" pattern instead:
    ///  1. Queue a durable nav route so the request survives until HomeView
    ///     attaches (covers the cold-launch race a bare post loses).
    ///  2. `open()` the `steddi://navigate` deep link, which foregrounds — or
    ///     cold-launches — the phone scene. Tapping the CarPlay alert alone never
    ///     brings the phone app up, so the open() call is what actually starts
    ///     navigation (the phone scene's CarWindow drives the CarPlay nav UI
    ///     via NavigationStateManager once HomeView calls startObserving).
    @MainActor
    private func startNavigation(to name: String, coordinate: CLLocationCoordinate2D) {
        PendingUIRouteStore.shared.request(.navigate(name: name, coordinate: coordinate))

        var components = URLComponents()
        components.scheme = "steddi"
        components.host = "navigate"
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "lng", value: String(coordinate.longitude)),
            URLQueryItem(name: "name", value: name)
        ]
        guard let url = components.url else { return }
        templateScene?.open(url, options: nil) { success in
            if !success {
                carplayLog.error("CarPlay: failed to open phone scene for Start Navigation")
            }
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
        navigationTrip = nil

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
