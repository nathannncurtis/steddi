import SwiftUI
import SwiftData
import MapKit
import CoreLocation

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationService.self) private var locationService
    @Environment(NavigationStateManager.self) private var navStateManager
    @Environment(PendingCommuteStartStore.self) private var pendingCommuteStart
    @Query(sort: \PinnedLocation.sortOrder) private var pinnedLocations: [PinnedLocation]
    @Query(sort: \Commute.createdAt) private var commutes: [Commute]
    @Query private var commuteTrips: [CommuteTrip]
    @Query(sort: \Trip.createdAt) private var trips: [Trip]

    // Accent color — triggers re-render of entire home + children when changed
    @AppStorage("accentColor") private var accentColor = "lavender"

    // Bottom sheet tab
    @State private var sheetTab: SheetTab = .commutes
    /// Flips true on first commutes-tab appearance to stagger the cards in.
    @State private var commuteCardsAppeared = false
    /// Namespace for the moving accent-glass pill behind the active sheet tab.
    @Namespace private var sheetTabNamespace

    enum SheetTab: String, CaseIterable {
        case commutes = "Commutes"
        case places = "Places"
        case trips = "Trips"
    }

    // Navigation state
    @State private var isNavigating = false
    @State private var navigationRoute: MKRoute?
    @State private var navigationEngine: NavigationEngine?
    @State private var isCalculatingRoute = false
    @State private var navigationDestination: PinnedLocation?
    @State private var locationFeedTask: Task<Void, Never>?

    // Saved route polyline for map rendering
    @State private var activeSavedPolyline: [CLLocationCoordinate2D]?
    /// Active road conditions for the route being navigated, shown as map badges.
    @State private var activeRoadConditions: [RoadCondition] = []
    /// Saved route currently (or just) navigated, so the post-arrival flow can
    /// check it for conditions due for reconfirmation.
    @State private var navigatedSavedRoute: Route?
    /// Stale conditions queued for the post-arrival "still there?" prompt.
    @State private var reconfirmConditions: [RoadCondition] = []
    @State private var showRoadConditionReconfirm = false

    // Route preview state
    @State private var showRoutePreview = false
    @State private var previewRoute: MKRoute?
    @State private var previewAlternates: [MKRoute] = []
    @State private var previewDestinationName: String = ""
    @State private var previewIsCommute = false
    /// The toll/highway preferences that shaped the previewed route, surfaced
    /// as an "Avoiding…" indicator in the preview card.
    @State private var previewPreferences = RoutePreferences(avoidsTolls: false, avoidsHighways: false)

    // Camera state
    @State private var is3DNav = true

    // UI state
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showAddLocation = false
    // Add Place save flow — seeds AddLocationSheet from a search result or
    // the current location (reverse-geocoded).
    @State private var addPlaceCoordinate: CLLocationCoordinate2D?
    @State private var addPlaceName: String?
    @State private var addPlaceAddress: String?
    @State private var addPlaceCategory: PlaceCategory = .other
    @State private var showAddPlaceFlow = false
    @State private var isResolvingCurrentLocation = false
    @State private var showCommuteList = false
    @State private var showTripList = false
    @State private var showPostArrival = false
    @State private var longPressCoordinate: CLLocationCoordinate2D?
    @State private var recordedPoints: [GPSPoint] = []

    // Active commute tracking (for route saving on arrival)
    @State private var activeCommute: Commute?
    @State private var activeDirection: CommuteDirection?
    @State private var pendingTraceForSave = false

    // Active trip tracking (leg-by-leg navigation orchestration)
    @State private var activeTrip: Trip?
    @State private var tripArrivalStop: TripStop?       // stop just arrived at
    @State private var showTripArrivalPrompt = false    // manual mode next-leg prompt
    @State private var tripAutoAdvanceTask: Task<Void, Never>?
    @State private var dismissedResumeBanners: Set<UUID> = []

    // Off-route recovery — single-flight, cooldown, per-trip improvisation count
    @State private var isRecoveryInFlight = false
    @State private var lastRecoveryAt: Date?
    @State private var recoveriesThisTrip = 0

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    // Live ETAs for commute cards — key: "\(commute.id)-toOrigin" or "\(commute.id)-toDest"
    @State private var commuteETAs: [String: Int] = [:]

    /// Distance in miles from current location to a coordinate
    private func distanceMiles(to coord: CLLocationCoordinate2D) -> Double? {
        guard let loc = locationService.currentLocation else { return nil }
        let dist = loc.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
        return dist / 1609.34
    }

    private func formattedDistance(to coord: CLLocationCoordinate2D) -> String? {
        guard let miles = distanceMiles(to: coord) else { return nil }
        if miles < 10 {
            return String(format: "%.1f mi", miles)
        }
        return "\(Int(miles)) mi"
    }

    // Direction picker for ambiguous commutes
    @State private var showDirectionPicker = false
    @State private var directionPickerCommute: Commute?

    // Post-arrival → route planner handoff
    @State private var showRoutePlanner = false
    @State private var routePlannerCommute: Commute?

    // Donation milestone prompts
    @AppStorage("appInstalledAt") private var appInstalledAt: Double = 0
    @AppStorage("lastMilestoneShown") private var lastMilestoneShown: Double = 0
    @AppStorage("milestoneDonationDismissCount") private var milestoneDonationDismissCount: Int = 0
    @State private var showMilestoneDonation = false

    // Stashed commute/direction for post-arrival (persists after nav ends)
    @State private var arrivalCommute: Commute?
    @State private var arrivalDirection: CommuteDirection?
    @State private var testPolyline: String? = nil

    // Surfaced when a review link-out (Yelp / Google / Apple Maps) fails to open
    // — e.g. the target app isn't installed or the URL can't be handled.
    @State private var placeLinkErrorMessage: String?
    private let mockPolyline = "gipx_Appax~Exr@GzBu@p@iBGqKAgI?uBjCAz{@?dNFzPPfAClKA`VGnS?vA?dGBtLKrAQ|DmArCwA|FnOjCvHhAvGTnE?jEe@xEkBfJsDbMuHdT{GvPeC`IeAnGoA~Vy@xXU~^LvM`@hFzAvI`F|NnChHnBvG~ArHlAvL`@dHInLqBxYoBl[cAhL{AnJoCpLoClJkGfPqEhIoFxH}GpHkCfC}FpEuFfDeIfDqKrCkIlA{]nC{Db@sFhAoEjBkEzCuD~CyCdDkDzF}ClHcBnH_AdIWjJJjJr@tI|ArHnCnJ|BdGjDxGbGnIlDtD"

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
        ZStack(alignment: .bottom) {
            // Background behind safe area — dark so no white gaps in landscape
            Color.black.ignoresSafeArea()

            // Unified map — same instance for home + navigation
            SteddiMapView(
                isNavigating: $isNavigating,
                is3DView: $is3DNav,
                navigationRoute: navigationRoute,
                savedRoutePolyline: activeSavedPolyline,
                engine: navigationEngine,
                roadConditions: activeRoadConditions,
                onLongPress: { coord in
                    longPressCoordinate = coord
                    showAddLocation = true
                },
                onArrival: {},
                onCancelled: {}
            )
            .ignoresSafeArea() // map fills everything, UI floats on top

            // Navigation overlay
            if let engine = navigationEngine, isNavigating {
                SteddiNavOverlay(
                    engine: engine,
                    onEndNavigation: {
                        // Trip navigation ends through its own path — position
                        // persists so the trip can resume later, and none of
                        // the commute route-save machinery fires.
                        if activeTrip != nil {
                            endTripNavigation(completed: false)
                            return
                        }
                        let points = locationService.stopRecording()
                        locationService.disableNavigationMode()
                        locationFeedTask?.cancel()
                        locationFeedTask = nil
                        navigationEngine?.stopNavigation()
                        navStateManager.stopObserving()
                        LiveActivityService.shared.endActivity()
                        is3DNav = true
                        withAnimation(TransitionKit.standardEntrance) {
                            isNavigating = false
                        }
                        navigationRoute = nil
                        activeSavedPolyline = nil
                        activeRoadConditions = []

                        // Save the raw drive record
                        if points.count >= 2 {
                            let record = DriveRecord()
                            record.rawGPSPoints = points
                            record.associatedCommute = activeCommute
                            record.endedAt = Date()
                            modelContext.insert(record)
                            recordedPoints = points
                        }

                        // Stash commute/direction for post-arrival flow
                        arrivalCommute = activeCommute
                        arrivalDirection = activeDirection

                        // Check if we should prompt to save this route
                        if let commute = activeCommute,
                           let direction = activeDirection,
                           points.count >= 2,
                           commute.preferredRoute(for: direction) == nil {
                            // No preferred route for this direction — schedule notification
                            let destName = (direction == .originToDestination ? commute.destination?.name : commute.origin?.name) ?? "destination"
                            ArrivalNotificationService.shared.scheduleRoutePrompt(
                                commuteName: commute.name,
                                destinationName: destName
                            )
                            pendingTraceForSave = true
                        }

                        // Clear active tracking
                        activeCommute = nil
                        activeDirection = nil
                    },
                    onToggleView: { is3D in
                        is3DNav = is3D
                    },
                    onSwitchRoute: { route in
                        switchToRoute(route)
                    },
                    onReport: { type, coordinate in
                        let report = Report(type: type, latitude: coordinate.latitude, longitude: coordinate.longitude)
                        modelContext.insert(report)
                    },
                    onReportCamera: { kind, coordinate in
                        // Persist as a CameraReport and rebuild the proximity
                        // index so the new sighting alerts on the rest of the drive.
                        SpeedCameraService.shared.reportCamera(kind: kind, coordinate: coordinate)
                    },
                    commute: activeCommute,
                    direction: activeDirection,
                    tripContext: tripNavContext(engine: engine)
                )
                .transition(TransitionKit.steddiSheet)
            }

            // Trip arrival moment — floats above the nav overlay during the
            // continuous-mode pause and as the trip-complete card
            if let arrivedStop = tripArrivalStop, !showTripArrivalPrompt {
                TripArrivalCard(
                    stopName: arrivedStop.name,
                    nextStopName: activeTrip?.currentStop?.name,
                    onTap: { tripArrivalCardTapped() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, isLandscape ? 16 : 130)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Home UI — hides during navigation
            if !isNavigating && !isCalculatingRoute {
                if isLandscape {
                    landscapeLayout
                } else {
                    portraitLayout
                }
            }

            // Loading overlay
            if isCalculatingRoute {
                routeLoadingOverlay
            }
        }
        .ignoresSafeArea()
        .onAppear {
            locationService.requestPermission()
            locationService.startUpdating()
            migrateExistingPinsToCategories()
            checkMilestoneDonation()
            LiveActivityService.shared.cleanupOrphanedActivities()
            // Drain any start request that landed before this view attached
            // (cold launch from Siri / CarPlay / a notification deep link).
            consumePendingCommuteStart()
        }
        .task {
            // TEST FLAG: set to true to jump straight into turn-by-turn on launch
            let testTBT = false
            if testTBT {
                try? await Task.sleep(for: .seconds(3))
                navigateTo(name: "Test Dest", coordinate: CLLocationCoordinate2D(latitude: 33.980, longitude: -117.375))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .steddiSaveRouteFromNotification)) { _ in
            if pendingTraceForSave && !recordedPoints.isEmpty {
                showPostArrival = true
            }
        }
        // Drain start requests raised from outside the SwiftUI tree (Siri,
        // CarPlay dashboard, notification "Start Commute" / deep link). The
        // store is the single shared mailbox: producers stash a request that
        // can race a cold launch, and we consume it both here (reactively while
        // foregrounded) and on `.onAppear` below (covering the cold-launch case
        // where the request landed before this view existed).
        .onChange(of: pendingCommuteStart.version) { _, _ in
            consumePendingCommuteStart()
        }
        // Distance is calculated locally — ETAs fetched async in background
        .fullScreenCover(isPresented: $showRoutePreview) {
            if let route = previewRoute {
                RoutePreviewView(
                    route: route,
                    destinationName: previewDestinationName,
                    alternateRoutes: previewAlternates,
                    preferences: previewPreferences,
                    onStart: { selectedRoute in
                        showRoutePreview = false
                        beginNavigation(with: selectedRoute)
                    },
                    onCancel: {
                        showRoutePreview = false
                        previewRoute = nil
                        previewAlternates = []
                    }
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showMilestoneDonation, onDismiss: {
            milestoneDonationDismissCount += 1
            lastMilestoneShown = Date().timeIntervalSince1970
        }) {
            DonationView()
        }
        .sheet(isPresented: $showAddLocation) {
            AddLocationSheet(coordinate: longPressCoordinate)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showAddPlaceFlow) {
            AddLocationSheet(
                coordinate: addPlaceCoordinate,
                prefilledAddress: addPlaceAddress,
                prefilledName: addPlaceName,
                initialCategory: addPlaceCategory
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showCommuteList) {
            NavigationStack {
                CommuteListView()
            }
        }
        .sheet(isPresented: $showTripList) {
            NavigationStack {
                TripListView()
            }
        }
        .sheet(isPresented: $showTripArrivalPrompt, onDismiss: handleTripPromptDismiss) {
            if let trip = activeTrip, let nextStop = trip.currentStop {
                TripArrivalPromptSheet(
                    arrivedStopName: tripArrivalStop?.name,
                    nextStop: nextStop,
                    legIndex: trip.currentStopIndex + 1,
                    totalLegs: trip.orderedStops.count,
                    onNextLeg: {
                        advanceTripLeg(to: nextStop, trip: trip)
                    },
                    onSwitchToContinuous: {
                        trip.flowMode = .continuous
                        advanceTripLeg(to: nextStop, trip: trip)
                    },
                    onEndTrip: {
                        endTripNavigation(completed: false)
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
        .confirmationDialog(
            "Where are you headed?",
            isPresented: $showDirectionPicker,
            titleVisibility: .visible
        ) {
            if let commute = directionPickerCommute {
                Button(commute.origin?.name ?? "Origin") {
                    startCommute(commute, direction: .destinationToOrigin)
                }
                Button(commute.destination?.name ?? "Destination") {
                    startCommute(commute, direction: .originToDestination)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .sheet(isPresented: $showPostArrival, onDismiss: presentRoadConditionReconfirmIfNeeded) {
            PostArrivalSheet(
                recordedPoints: recordedPoints,
                commute: arrivalCommute,
                direction: arrivalDirection,
                onEditRoute: {
                    testPolyline = nil
                    // Open route planner for this commute (or first available)
                    if let commute = arrivalCommute ?? commutes.first {
                        routePlannerCommute = commute
                        showRoutePlanner = true
                    }
                },
                preMatchedPolyline: recordedPoints.count < 20 ? mockPolyline : nil
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showRoadConditionReconfirm) {
            RoadConditionReconfirmSheet(conditions: reconfirmConditions)
                .presentationDetents([.medium])
        }
        .fullScreenCover(isPresented: $showRoutePlanner) {
            if let commute = routePlannerCommute {
                RoutePlannerView(commute: commute)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { navStateManager.isCarPlayActive && navStateManager.isNavigating },
            set: { _ in }
        )) {
            PhoneCompanionView(onSwitchRoute: { route in
                switchToRoute(route)
            })
            .environment(navStateManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .steddiTestArrival)) { _ in
            // steddi://arrive — trigger post-arrival flow for testing
            let polyline = "gipx_Appax~Exr@GzBu@p@iBGqKAgI?uBjCAz{@?dNFzPPfAClKA`VGnS?vA?dGBtLKrAQ|DmArCwA|FnOjCvHhAvGTnE?jEe@xEkBfJsDbMuHdT{GvPeC`IeAnGoA~Vy@xXU~^LvM`@hFzAvI`F|NnChHnBvG~ArHlAvL`@dHInLqBxYoBl[cAhL{AnJoCpLoClJkGfPqEhIoFxH}GpHkCfC}FpEuFfDeIfDqKrCkIlA{]nC{Db@sFhAoEjBkEzCuD~CyCdDkDzF}ClHcBnH_AdIWjJJjJr@tI|ArHnCnJ|BdGjDxGbGnIlDtD"
            arrivalCommute = commutes.first
            arrivalDirection = .originToDestination
            testPolyline = polyline

            // Create minimal GPS points (won't be used for matching since preMatchedPolyline is set)
            let coords = PolylineEncoder.decode(polyline, precision: 6)
            recordedPoints = coords.prefix(10).map { coord in
                GPSPoint(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            }
            showPostArrival = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .steddiShowPlaces)) { _ in
            // CarPlay dashboard "Recent Places" deep link foregrounded the app —
            // surface the Places tab so the driver lands where they expect.
            withAnimation(TransitionKit.quickFade) { sheetTab = .places }
        }
        .onReceive(NotificationCenter.default.publisher(for: .steddiNavigateToLocation)) { notification in
            // steddi://navigate and CarPlay Start Navigation both post this
            guard let lat = notification.userInfo?["lat"] as? Double,
                  let lng = notification.userInfo?["lng"] as? Double else { return }
            let name = notification.userInfo?["name"] as? String ?? "Destination"
            navigateTo(
                name: name,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                skipPreview: true
            )
        }
        .alert(
            "Couldn’t Open Link",
            isPresented: Binding(
                get: { placeLinkErrorMessage != nil },
                set: { if !$0 { placeLinkErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { placeLinkErrorMessage = nil }
        } message: {
            Text(placeLinkErrorMessage ?? "")
        }
    }

    // MARK: - Donation Milestone

    private func checkMilestoneDonation() {
        let now = Date().timeIntervalSince1970

        // Set install date on first launch
        if appInstalledAt == 0 {
            appInstalledAt = now
            return
        }

        // Stop prompting after 3 dismissals
        if milestoneDonationDismissCount >= 3 { return }

        // Suppress re-prompt within 30 days
        let thirtyDays: Double = 30 * 24 * 60 * 60
        if now - lastMilestoneShown < thirtyDays { return }

        // Trigger if 30+ days since install or 50+ trips
        let daysSinceInstall = now - appInstalledAt
        if daysSinceInstall >= thirtyDays || commuteTrips.count >= 50 {
            showMilestoneDonation = true
        }
    }

    // MARK: - Navigation

    private func navigateTo(name: String, coordinate: CLLocationCoordinate2D, address: String? = nil, skipPreview: Bool = false, preferences: RoutePreferences? = nil) {
        let dest = PinnedLocation(
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            address: address
        )
        navigationDestination = dest

        isCalculatingRoute = true

        Task {
            // Wait for location
            locationService.startUpdating()
            var currentLocation = locationService.currentLocation
            for _ in 0..<20 {
                if currentLocation != nil { break }
                try? await Task.sleep(for: .milliseconds(500))
                currentLocation = locationService.currentLocation
            }

            guard let currentLocation else {
                isCalculatingRoute = false
                return
            }

            let request = MKDirections.Request()
            request.source = MKMapItem(location: CLLocation(latitude: currentLocation.coordinate.latitude, longitude: currentLocation.coordinate.longitude), address: nil)
            request.destination = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
            request.transportType = .automobile
            let resolvedPreferences = preferences ?? RoutePreferences.resolve(commute: activeCommute)
            resolvedPreferences.apply(to: request)

            let directions = MKDirections(request: request)

            do {
                let response = try await directions.calculate()
                guard let route = response.routes.first else {
                    isCalculatingRoute = false
                    return
                }

                request.requestsAlternateRoutes = true
                let altResponse = try? await MKDirections(request: request).calculate()
                let alternates = (altResponse?.routes ?? []).filter { $0 !== route }

                isCalculatingRoute = false
                if skipPreview {
                    beginNavigation(with: route)
                } else {
                    previewRoute = route
                    previewAlternates = Array(alternates.prefix(2))
                    previewDestinationName = name
                    previewIsCommute = false
                    previewPreferences = resolvedPreferences
                    showRoutePreview = true
                }
            } catch {
                isCalculatingRoute = false
            }
        }
    }

    /// Start navigation with a route (called from preview or directly for commutes).
    /// Hook the OSM speed limit service into a fresh engine: position-based
    /// lookups every fix, corridor prefetch warmed in the background.
    private func wireSpeedLimits(for engine: NavigationEngine) {
        engine.speedLimitProvider = { coordinate, heading in
            OSMSpeedLimitService.shared.speedLimit(at: coordinate, heading: heading)
        }
        let corridor = engine.routePolylineCoordinates
        guard corridor.count >= 2 else { return }
        let key = "\(corridor.count)-" +
            String(format: "%.5f,%.5f-%.5f,%.5f",
                   corridor[0].latitude, corridor[0].longitude,
                   corridor[corridor.count - 1].latitude, corridor[corridor.count - 1].longitude)
        Task {
            await OSMSpeedLimitService.shared.prefetch(for: corridor, routeKey: key)
        }
    }

    /// Hook the speed-camera service into the engine: per-fix grid-indexed
    /// proximity lookup (OSM cameras + user reports, heading-gated to cameras
    /// ahead) plus a subtle ducking tone + haptic + voice on first approach.
    /// Cameras are global (not route-scoped like conditions), so this is wired
    /// for both ad-hoc and saved-route navigation. OSM cameras prefetch in the
    /// background off the route corridor.
    private func wireSpeedCameras(for engine: NavigationEngine) {
        engine.speedCameraProvider = { coordinate, heading in
            SpeedCameraService.shared.checkProximity(currentCoord: coordinate, heading: heading)
        }
        engine.onSpeedCameraApproaching = { alert in
            SpeedCameraAlertTone.shared.play()
            HapticService.shared.fire(.speedCameraAlert)
            VoiceGuidanceService.shared.speak("\(alert.kind.spokenName) ahead")
        }

        let corridor = engine.routePolylineCoordinates
        guard corridor.count >= 2 else { return }
        let key = "\(corridor.count)-" +
            String(format: "%.5f,%.5f-%.5f,%.5f",
                   corridor[0].latitude, corridor[0].longitude,
                   corridor[corridor.count - 1].latitude, corridor[corridor.count - 1].longitude)
        Task {
            await SpeedCameraService.shared.prefetchOSMCameras(for: corridor, routeKey: key)
        }
    }

    /// Hook road-condition memory into the engine: a grid-indexed proximity
    /// lookup per fix plus a subtle haptic + voice heads-up on first approach.
    /// Only wired for saved routes, since conditions are route-scoped — ad-hoc
    /// MKRoute navigation has no Route model to anchor remembered conditions.
    private func wireRoadConditions(for engine: NavigationEngine, route: Route?) {
        navigatedSavedRoute = route
        guard let route else {
            activeRoadConditions = []
            return
        }
        let conditions = RoadConditionService.shared.fetchConditionsOnRoute(route)
        activeRoadConditions = conditions
        guard !conditions.isEmpty else { return }

        engine.roadConditionProvider = { coordinate in
            RoadConditionService.checkProximityToConditions(
                currentCoord: coordinate,
                routeConditions: conditions,
                proximityThresholdMeters: 100
            )
        }
        engine.onRoadConditionApproaching = { condition in
            HapticService.shared.fire(.roadConditionAlert)
            let road = condition.route?.name.map { " on \($0)" } ?? ""
            VoiceGuidanceService.shared.speak("\(condition.kind.spokenName) ahead\(road)")
        }
    }

    /// After the post-arrival sheet closes, offer to reconfirm any condition on
    /// the just-driven route that's past the 14-day window. One-time per
    /// arrival; skippable and never blocking. A small delay lets the
    /// post-arrival sheet finish dismissing before this sheet presents.
    private func presentRoadConditionReconfirmIfNeeded() {
        guard let route = navigatedSavedRoute else { return }
        let stale = RoadConditionService.shared.staleConditionsOnRoute(route)
        guard !stale.isEmpty else { return }
        reconfirmConditions = stale
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            showRoadConditionReconfirm = true
        }
    }

    private func beginNavigation(with route: MKRoute) {
        locationService.enableNavigationMode()
        locationService.startRecording()

        self.activeSavedPolyline = nil
        self.activeRoadConditions = []
        self.navigationRoute = route
        // New trip: the off-route recovery cap is PER-TRIP, so reset it here.
        // Without this it accumulates across every drive and permanently
        // disables recovery after a few lifetime deviations.
        recoveriesThisTrip = 0
        let engine = NavigationEngine()
        engine.startNavigation(route: route)
        self.navigationEngine = engine
        wireSpeedLimits(for: engine)
        wireSpeedCameras(for: engine)

        engine.onOffRoute = { event in
            Task { @MainActor [self] in
                await self.handleOffRoute(event)
            }
        }

        let destName = navigationDestination?.name ?? "Destination"
        navStateManager.activeRouteCoords = engine.routePolylineCoordinates
        navStateManager.startObserving(
            engine: engine,
            commute: activeCommute,
            direction: activeDirection,
            trip: activeTrip,
            destinationName: destName
        )

        startLocationFeed()

        // Start Live Activity
        LiveActivityService.shared.startActivity(destinationName: destName, tripContext: liveActivityTripContext)

        withAnimation(TransitionKit.standardEntrance) {
            isNavigating = true
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        // Search pill + gear grouped as one floating glass cluster over the map.
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    showSearch = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.body.weight(.medium))
                            .foregroundStyle(SteddiTheme.accent)
                        Text("Where to?")
                            .font(SteddiTheme.heading(17))
                            .foregroundStyle(SteddiTheme.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    // Neutral glass — the accent lives in the leading icon.
                    .steddiGlass(tint: nil, interactive: true, in: Capsule())
                }

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(SteddiTheme.textSecondary)
                        .frame(width: 44, height: 44)
                        .steddiGlass(tint: nil, interactive: true, in: .circle)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Bottom Sheet

    // MARK: - Portrait Layout

    private var portraitLayout: some View {
        Group {
            VStack {
                if showSearch {
                    ExpandedSearchView(
                        currentLocation: locationService.currentLocation?.coordinate,
                        onSelectResult: { result in
                            showSearch = false
                            navigateTo(name: result.name, coordinate: result.coordinate, address: result.address)
                        },
                        onPinResult: { result in
                            showSearch = false
                            pinLocation(from: result)
                        },
                        onDismiss: { showSearch = false }
                    )
                } else {
                    topBar
                }
                Spacer()
            }
            .padding(.top, isLandscape ? 0 : 54) // keep UI below status bar in portrait only

            VStack(spacing: 10) {
                if let trip = resumableTrip {
                    resumeTripBanner(trip)
                }
                bottomSheet
            }
            .padding(.bottom, isLandscape ? 0 : 34) // keep sheet above home indicator in portrait only
        }
    }

    // MARK: - Landscape Layout

    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            // Side panel on the left
            VStack(spacing: 0) {
                // Search bar compact
                if showSearch {
                    ExpandedSearchView(
                        currentLocation: locationService.currentLocation?.coordinate,
                        onSelectResult: { result in
                            showSearch = false
                            navigateTo(name: result.name, coordinate: result.coordinate, address: result.address)
                        },
                        onPinResult: { result in
                            showSearch = false
                            pinLocation(from: result)
                        },
                        onDismiss: { showSearch = false }
                    )
                } else {
                    // Search + settings row — grouped glass cluster.
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            Button { showSearch = true } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(SteddiTheme.accent)
                                    Text("Where to?")
                                        .font(SteddiTheme.heading(15))
                                        .foregroundStyle(SteddiTheme.textPrimary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .steddiGlass(
                                    tint: nil,
                                    interactive: true,
                                    in: Capsule(),
                                    fallbackFill: SteddiTheme.surfaceSecondary
                                )
                            }

                            Button { showSettings = true } label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.caption)
                                    .foregroundStyle(SteddiTheme.textSecondary)
                                    .frame(width: 36, height: 36)
                                    .steddiGlass(
                                        tint: nil,
                                        interactive: true,
                                        in: .circle,
                                        fallbackFill: SteddiTheme.surfaceSecondary
                                    )
                                    // Keep the 36pt glass visual but expand the
                                    // hit area to the 44pt minimum tap target.
                                    .frame(width: 44, height: 44)
                                    .contentShape(Circle())
                            }
                            .accessibilityLabel("Settings")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                    // Tabs
                    HStack(spacing: 0) {
                        ForEach(SheetTab.allCases, id: \.self) { tab in
                            Button { withAnimation(TransitionKit.quickFade) { sheetTab = tab } } label: {
                                Text(tab.rawValue)
                                    .font(SteddiTheme.heading(12))
                                    .foregroundStyle(sheetTab == tab ? SteddiTheme.accent : SteddiTheme.textMuted)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)

                    SteadyLine(color: SteddiTheme.accent, height: 1)
                        .padding(.horizontal, 20)

                    // Content — compact, crossfades between tabs.
                    ScrollView {
                        Group {
                            switch sheetTab {
                            case .commutes:
                                commutesTab
                            case .places:
                                placesTab
                            case .trips:
                                tripsTab
                            }
                        }
                        .id(sheetTab)
                        .transition(.opacity)
                    }
                }
            }
            .frame(width: 280)
            .padding(.leading, 44) // shift content right to clear notch
            .background(
                SteddiTheme.surfacePrimary
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: SteddiTheme.radiusLarge, topTrailingRadius: SteddiTheme.radiusLarge))
                    .shadow(color: .black.opacity(0.3), radius: 12, x: 4)
            )

            // Map fills the rest
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Bottom Sheet (portrait only)

    private var bottomSheet: some View {
        VStack(spacing: 0) {
            // Drag indicator
            Capsule()
                .fill(SteddiTheme.textMuted.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 10)

            // Tab selector — the bar itself is a floating Liquid Glass capsule,
            // with a moving accent-glass pill sliding under the active tab
            // (matchedGeometry morph). Bar + pill share one GlassEffectContainer
            // so they compose into a single glass cluster rather than stacking
            // two separate glass layers. The list content below stays on the
            // solid sheet surface for legibility (no glass-on-glass).
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(SheetTab.allCases, id: \.self) { tab in
                        Button {
                            withAnimation(TransitionKit.quickFade) { sheetTab = tab }
                        } label: {
                            Text(tab.rawValue)
                                .font(SteddiTheme.heading(14))
                                // Active label rides on the accent-glass pill, so it
                                // needs an on-accent foreground (not the accent itself,
                                // which washes out against the tinted pill). Inactive
                                // labels stay muted on the neutral glass bar.
                                .foregroundStyle(sheetTab == tab ? SteddiTheme.textPrimary : SteddiTheme.textMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background {
                                    if sheetTab == tab {
                                        Capsule()
                                            .fill(.clear)
                                            .steddiGlass(tint: SteddiTheme.accent, interactive: false, in: Capsule())
                                            .glassEffectID("sheet.tab.active", in: sheetTabNamespace)
                                            .glassEffectTransition(.matchedGeometry)
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                // The bar surface — a single subtle neutral glass layer behind
                // the whole tab row so the nav menu reads as floating glass.
                .steddiGlass(
                    tint: nil,
                    interactive: false,
                    in: Capsule(),
                    fallbackFill: SteddiTheme.surfaceSecondary
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            SteadyLine(color: SteddiTheme.accent, height: 1)
                .padding(.horizontal, 32)
                .padding(.top, 4)

            // Content — crossfades between tabs.
            Group {
                switch sheetTab {
                case .commutes:
                    commutesTab
                case .places:
                    placesTab
                case .trips:
                    tripsTab
                }
            }
            .id(sheetTab)
            .transition(.opacity)
        }
        .background(SteddiTheme.surfacePrimary)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusLarge, topTrailingRadius: SteddiTheme.radiusLarge))
        .shadow(color: .black.opacity(0.3), radius: 20, y: -5)
        .overlay(alignment: .bottom) {
            // Solid color strip below the clipped sheet to fill the safe area gap
            SteddiTheme.surfacePrimary
                .frame(height: 60)
                .offset(y: 60)
        }
    }

    // MARK: - Commutes Tab

    private var commutesTab: some View {
        Group {
            if commutes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.title2)
                        .foregroundStyle(SteddiTheme.accent)
                    Text("No commutes yet")
                        .font(SteddiTheme.heading(16))
                        .foregroundStyle(SteddiTheme.textPrimary)
                    Text("Create a commute to get started")
                        .font(SteddiTheme.body(14))
                        .foregroundStyle(SteddiTheme.textSecondary)
                    Button {
                        showCommuteList = true
                    } label: {
                        Label("New Commute", systemImage: "plus")
                            .font(SteddiTheme.heading(14))
                            .foregroundStyle(SteddiTheme.accent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(SteddiTheme.accentSubtle, in: Capsule())
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 20)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(commutes.enumerated()), id: \.element.id) { index, commute in
                            commuteRows(commute)
                                .opacity(commuteCardsAppeared ? 1 : 0)
                                .offset(x: commuteCardsAppeared ? 0 : -24)
                                .animation(TransitionKit.cardStagger(index: index), value: commuteCardsAppeared)
                        }
                        Button {
                            showCommuteList = true
                        } label: {
                            Label("New Commute", systemImage: "plus")
                                .font(SteddiTheme.heading(13))
                                .foregroundStyle(SteddiTheme.accent)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: isLandscape ? .infinity : 160)
                .onAppear {
                    guard !commuteCardsAppeared else { return }
                    if SteddiMotion.shouldAnimate {
                        commuteCardsAppeared = true
                    } else {
                        // Reduce Motion: show cards instantly, no stagger.
                        var txn = Transaction()
                        txn.disablesAnimations = true
                        withTransaction(txn) { commuteCardsAppeared = true }
                    }
                }
            }
        }
    }

    /// Resolve the raw direction result for a commute
    private func resolveCardResult(_ commute: Commute) -> CommuteDirectionResolver.Result {
        guard let currentLoc = locationService.currentLocation else {
            return .confident(.originToDestination, destinationName: commute.destination?.name ?? "—")
        }
        return CommuteDirectionResolver.resolve(
            commute: commute,
            currentLocation: currentLoc,
            trips: commuteTrips
        )
    }

    /// Legacy helper used by ETA refresh
    private func resolveCardDirection(_ commute: Commute) -> (destination: String, direction: CommuteDirection) {
        let result = resolveCardResult(commute)
        switch result {
        case .confident(let dir, let name):
            return (name, dir)
        case .ambiguous(let originName, let destName):
            return ("\(originName) ↔ \(destName)", .originToDestination)
        }
    }

    /// Consume a queued start request (Siri / CarPlay / notification deep
    /// link). Resolves the commute + direction and routes through the same
    /// `startCommute` path the in-app cards use, so every entry point behaves
    /// identically. No-op while already navigating.
    private func consumePendingCommuteStart() {
        guard let action = pendingCommuteStart.consume() else { return }
        guard !isNavigating else { return }

        switch action {
        case .specific(let commuteId, let direction):
            guard let commute = commutes.first(where: { $0.id == commuteId }) else { return }
            startCommute(commute, direction: direction ?? resolvedStartDirection(commute))
        case .firstActive:
            guard let commute = commutes.first(where: { $0.isActive }) else { return }
            startCommute(commute, direction: resolvedStartDirection(commute))
        }
    }

    /// Best-guess direction when a request doesn't carry one — proximity/schedule
    /// via the resolver, falling back to heading out. Can't surface the
    /// direction picker for an out-of-band start, so ambiguity defaults out.
    private func resolvedStartDirection(_ commute: Commute) -> CommuteDirection {
        switch resolveCardResult(commute) {
        case .confident(let direction, _):
            return direction
        case .ambiguous:
            return .originToDestination
        }
    }

    private func startCommute(_ commute: Commute, direction: CommuteDirection) {
        let target: PinnedLocation? = direction == .originToDestination ? commute.destination : commute.origin
        guard let target else { return }

        // Track active commute for arrival logic
        activeCommute = commute
        activeDirection = direction

        // Log the trip for future learning
        let trip = CommuteTrip(commute: commute, direction: direction)
        modelContext.insert(trip)

        // Check for a saved preferred route in this direction
        let allRoutes = commute.routes ?? []
        print("[STEDDI-NAV] startCommute: \(commute.name), direction: \(direction.rawValue)")
        print("[STEDDI-NAV] Total routes on commute: \(allRoutes.count)")
        for r in allRoutes {
            print("[STEDDI-NAV]   Route: rank=\(r.rank), direction=\(r.direction.rawValue), polyline length=\(r.encodedPolyline.count) chars, source=\(r.source.rawValue)")
        }

        if let preferredRoute = commute.preferredRoute(for: direction) {
            print("[STEDDI-NAV] Found preferred route for direction \(direction.rawValue): polyline \(preferredRoute.encodedPolyline.count) chars")
            navigateWithSavedRoute(preferredRoute, to: target)
        } else if commute.skipRoutePreview == true {
            print("[STEDDI-NAV] No saved route, skipPreview=true — routing directly")
            navigateTo(name: target.name, coordinate: target.coordinate, address: target.address, skipPreview: true)
        } else {
            print("[STEDDI-NAV] NO preferred route found for direction \(direction.rawValue) — showing preview")
            navigateTo(name: target.name, coordinate: target.coordinate, address: target.address)
        }
    }

    /// Switch the active commute onto a suggested faster/fallback route. Shared
    /// by the on-phone nav overlay's reroute card and the CarPlay phone-companion
    /// reroute card so both surfaces perform the identical route swap.
    private func switchToRoute(_ route: Route) {
        // Reroute to the fallback
        let target: PinnedLocation? = activeDirection == .originToDestination ? activeCommute?.destination : activeCommute?.origin
        guard let target else { return }
        locationFeedTask?.cancel()
        locationFeedTask = nil
        navigationEngine?.stopNavigation()
        navStateManager.stopObserving()
        isNavigating = false
        navigationRoute = nil
        navigateWithSavedRoute(route, to: target)
    }

    /// Navigate using a saved route's polyline with custom turn-by-turn logic.
    /// Bypasses Apple Maps routing entirely — generates steps from the polyline geometry.
    private func navigateWithSavedRoute(_ savedRoute: Route, to target: PinnedLocation) {
        navigationDestination = target
        isCalculatingRoute = true

        Task {
            // Decode the saved polyline
            let savedCoords = PolylineEncoder.decode(savedRoute.encodedPolyline, precision: 6)
            print("[STEDDI-NAV] navigateWithSavedRoute: decoded \(savedCoords.count) coordinates from polyline")

            guard savedCoords.count >= 2 else {
                print("[STEDDI-NAV] ERROR: polyline has < 2 coords, falling back to Apple Maps")
                isCalculatingRoute = false
                navigateTo(name: target.name, coordinate: target.coordinate, address: target.address)
                return
            }

            // Use saved steps if available (from planning time), otherwise generate from polyline
            let navSteps: [NavStep]
            if let saved = savedRoute.savedNavSteps {
                print("[STEDDI-NAV] Using \(saved.count) saved steps from planning time")
                navSteps = saved
            } else {
                print("[STEDDI-NAV] No saved steps, generating from polyline geometry")
                navSteps = CustomRouteBuilder.buildSteps(from: savedCoords)
            }

            for (i, step) in navSteps.enumerated() {
                print("[STEDDI-NAV]   Step \(i): \(step.instruction) (\(Int(step.distance))m)")
            }

            isCalculatingRoute = false
            beginCustomNavigation(polyline: savedCoords, steps: navSteps, expectedTravelTime: savedRoute.typicalDurationSeconds, route: savedRoute)
            migrateInflatedPlannedDuration(savedRoute, coords: savedCoords)
        }
    }

    /// Lazy migration: legacy planned routes carry durations inflated by the
    /// old chained per-leg planner (every plot point modeled as a trip
    /// destination). When a planned route's saved duration blows past the
    /// sanity bound against a direct estimate, recompute it as one OSRM
    /// via-route pinned to the saved geometry and persist the result.
    /// Runs in the background after navigation starts. Idempotent — a
    /// migrated duration passes the bound and is never re-fetched — and
    /// guarded: a failed fetch leaves the route untouched.
    private func migrateInflatedPlannedDuration(_ savedRoute: Route, coords: [CLLocationCoordinate2D]) {
        guard savedRoute.source == .planned,
              let saved = savedRoute.typicalDurationSeconds, saved > 0,
              let origin = coords.first, let destination = coords.last else { return }

        Task {
            let service = DirectionsService()
            guard let direct = try? await service.fetchDirectETA(from: origin, to: destination),
                  NavigationEngine.exceedsSanityBound(saved: saved, directEstimate: direct) else { return }

            // Follow the saved polyline: spike-cleaned, evenly sampled vias
            let vias = DirectionsService.sampledViaPoints(from: RouteGeometry.removeSpikes(coords))
            guard let recomputed = try? await service.fetchViaRoute(points: vias),
                  recomputed.duration > 0, recomputed.duration < saved else { return }

            print("[STEDDI-NAV] migrated inflated planned duration \(Int(saved))s -> \(Int(recomputed.duration))s")
            savedRoute.typicalDurationSeconds = recomputed.duration
            savedRoute.distanceMeters = recomputed.distance
            try? modelContext.save()
        }
    }

    /// Start navigation with custom polyline and steps (no MKRoute).
    private func beginCustomNavigation(polyline: [CLLocationCoordinate2D], steps: [NavStep], expectedTravelTime: TimeInterval? = nil, route: Route? = nil) {
        print("[STEDDI-NAV] beginCustomNavigation: polyline=\(polyline.count) coords, steps=\(steps.count), eta=\(expectedTravelTime ?? 0)s")
        locationService.enableNavigationMode()
        locationService.startRecording()

        self.activeSavedPolyline = polyline
        self.navigationRoute = nil
        // New trip: reset the per-trip off-route recovery cap (see beginNavigation).
        recoveriesThisTrip = 0

        let engine = NavigationEngine()
        engine.startNavigation(polyline: polyline, steps: steps, expectedTravelTime: expectedTravelTime)
        self.navigationEngine = engine
        wireSpeedLimits(for: engine)
        wireSpeedCameras(for: engine)
        wireRoadConditions(for: engine, route: route)

        engine.onOffRoute = { event in
            Task { @MainActor [self] in
                await self.handleOffRoute(event)
            }
        }

        let destName = navigationDestination?.name ?? "Destination"
        navStateManager.activeRouteCoords = engine.routePolylineCoordinates
        navStateManager.startObserving(
            engine: engine,
            commute: activeCommute,
            direction: activeDirection,
            trip: activeTrip,
            destinationName: destName
        )

        startLocationFeed()

        // Start Live Activity
        LiveActivityService.shared.startActivity(destinationName: destName, tripContext: liveActivityTripContext)

        withAnimation(TransitionKit.standardEntrance) {
            isNavigating = true
        }
    }

    /// Produces one or two rows for a commute depending on direction resolution.
    /// When ambiguous (not near either endpoint), shows two rows — one per direction.
    @ViewBuilder
    private func commuteRows(_ commute: Commute) -> some View {
        commuteCard(commute)
    }

    private func commuteCard(_ commute: Commute) -> some View {
        let result = resolveCardResult(commute)
        let isConfident: Bool
        let confidentDirection: CommuteDirection?

        switch result {
        case .confident(let dir, _):
            isConfident = true
            confidentDirection = dir
        case .ambiguous:
            isConfident = false
            confidentDirection = nil
        }

        return Button {
            HapticService.shared.fire(.uiToggle)
            // Tapping the card body — if confident, go directly; if ambiguous, show picker
            if isConfident, let dir = confidentDirection {
                startCommute(commute, direction: dir)
            } else {
                directionPickerCommute = commute
                showDirectionPicker = true
            }
        } label: {
            VStack(spacing: 0) {
                // Commute name header + ETA summary
                HStack {
                    Text(commute.name)
                        .font(SteddiTheme.heading(15))
                        .foregroundStyle(SteddiTheme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SteddiTheme.textMuted)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

                // Direction rows with ETAs
                if isConfident, let dir = confidentDirection {
                    let dest = dir == .originToDestination ? commute.destination : commute.origin
                    commuteDistanceRow(destName: dest?.name ?? "—", coord: dest?.coordinate)
                        .padding(.bottom, 10)
                } else {
                    if let dest = commute.destination {
                        commuteDistanceRow(destName: dest.name, coord: dest.coordinate)
                    }
                    if let origin = commute.origin {
                        commuteDistanceRow(destName: origin.name, coord: origin.coordinate)
                    }
                    Spacer().frame(height: 10)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                    .fill(SteddiTheme.surfaceSecondary.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                            .stroke(SteddiTheme.accent.opacity(0.06), lineWidth: 1)
                    )
            }
        }
        .buttonStyle(.steddiPress)
    }

    /// Distance display row within a commute card
    private func commuteDistanceRow(destName: String, coord: CLLocationCoordinate2D?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(SteddiTheme.accent)

            Text(destName)
                .font(SteddiTheme.body(13))
                .foregroundStyle(SteddiTheme.textSecondary)
                .lineLimit(1)

            Spacer()

            if let coord, let dist = formattedDistance(to: coord) {
                Text(dist)
                    .font(SteddiTheme.mono(13))
                    .foregroundStyle(SteddiTheme.sage)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }

    // MARK: - Places Tab

    private var placesTab: some View {
        Group {
            if pinnedLocations.isEmpty {
                VStack(spacing: 14) {
                    emptyState
                    addPlaceMenu(compact: false)
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 20)
            } else {
                VStack(spacing: 8) {
                    List {
                        ForEach(pinnedLocations) { location in
                            LocationCardView(
                                name: location.name,
                                icon: location.icon,
                                etaMinutes: nil,
                                delayMinutes: nil,
                                category: location.resolvedCategory,
                                onTap: {
                                    navigateTo(
                                        name: location.name,
                                        coordinate: location.coordinate,
                                        address: location.address
                                    )
                                },
                                trailingMenu: { placeCardMenu(location) }
                            )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }
                        .onMove(perform: movePlaces)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(maxHeight: isLandscape ? .infinity : 160)

                    addPlaceMenu(compact: true)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    /// "Add Place" entry point on the Places tab. Mirrors the Commutes tab's
    /// New Commute affordance but offers a menu: Search opens the search flow,
    /// Use Current Location reverse-geocodes and opens the category picker.
    @ViewBuilder
    private func addPlaceMenu(compact: Bool) -> some View {
        Menu {
            Button {
                showSearch = true
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            Button {
                startCurrentLocationAddFlow()
            } label: {
                Label("Use Current Location", systemImage: "location.fill")
            }
        } label: {
            if compact {
                Label("Add Place", systemImage: "plus")
                    .font(SteddiTheme.heading(13))
                    .foregroundStyle(SteddiTheme.accent)
            } else {
                Label("Add Place", systemImage: "plus")
                    .font(SteddiTheme.heading(14))
                    .foregroundStyle(SteddiTheme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(SteddiTheme.accentSubtle, in: Capsule())
            }
        }
    }

    /// Overflow menu for a pinned place card: review link-outs (Yelp, Google,
    /// Apple Maps) plus delete. All review actions open URLs in the browser /
    /// Maps app — no embed, no API.
    @ViewBuilder
    private func placeCardMenu(_ location: PinnedLocation) -> some View {
        if let url = ReviewURLs.yelpSearchURL(name: location.name, coordinate: location.coordinate) {
            Button {
                openReviewURL(url, target: "Yelp")
            } label: {
                Label("View Reviews (Yelp)", systemImage: "star.fill")
            }
        }
        if let url = ReviewURLs.googleMapsURL(name: location.name, coordinate: location.coordinate) {
            Button {
                openReviewURL(url, target: "Google Maps")
            } label: {
                Label("View on Google Maps", systemImage: "map.fill")
            }
        }
        if let url = ReviewURLs.appleMapsURL(name: location.name, coordinate: location.coordinate) {
            Button {
                openReviewURL(url, target: "Apple Maps")
            } label: {
                Label("View in Apple Maps", systemImage: "map")
            }
        }
        Divider()
        Button(role: .destructive) {
            modelContext.delete(location)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Opens a review link-out and surfaces an alert if the system can't handle
    /// the URL (e.g. the target app isn't installed). `target` names the
    /// destination for the failure message.
    private func openReviewURL(_ url: URL, target: String) {
        UIApplication.shared.open(url) { success in
            if !success {
                placeLinkErrorMessage =
                    "Couldn’t open \(target). Make sure the app is installed and try again."
            }
        }
    }

    private func movePlaces(from source: IndexSet, to destination: Int) {
        var items = pinnedLocations
        items.move(fromOffsets: source, toOffset: destination)
        for (index, item) in items.enumerated() {
            item.sortOrder = index
        }
    }

    // MARK: - Trips Tab

    private var activeTrips: [Trip] {
        trips.filter { !$0.isArchived }
    }

    private var tripsTab: some View {
        Group {
            if activeTrips.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "map")
                        .font(.title2)
                        .foregroundStyle(SteddiTheme.accent)
                    Text("No trips yet")
                        .font(SteddiTheme.heading(16))
                        .foregroundStyle(SteddiTheme.textPrimary)
                    Text("Plan a multi-stop journey")
                        .font(SteddiTheme.body(14))
                        .foregroundStyle(SteddiTheme.textSecondary)
                    Button {
                        showTripList = true
                    } label: {
                        Label("New Trip", systemImage: "plus")
                            .font(SteddiTheme.heading(14))
                            .foregroundStyle(SteddiTheme.accent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(SteddiTheme.accentSubtle, in: Capsule())
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 20)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(activeTrips) { trip in
                            tripCard(trip)
                        }
                        Button {
                            showTripList = true
                        } label: {
                            Label("New Trip", systemImage: "plus")
                                .font(SteddiTheme.heading(13))
                                .foregroundStyle(SteddiTheme.accent)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: isLandscape ? .infinity : 160)
            }
        }
    }

    private func tripCard(_ trip: Trip) -> some View {
        TripCardView(
            trip: trip,
            distanceToNextStop: trip.currentStop.flatMap { formattedDistance(to: $0.coordinate) },
            onTap: { startTrip(trip) },
            onEdit: { showTripList = true },
            onArchive: { trip.isArchived = true },
            onDelete: { modelContext.delete(trip) }
        )
    }

    // MARK: - Trip Navigation Orchestration

    /// Begin or resume trip navigation. A fresh trip starts at stop 0; an
    /// in-progress trip resumes its current stop (UUID-based position, so
    /// reorders and deletes since the last session can't orphan it).
    private func startTrip(_ trip: Trip) {
        guard !isNavigating, !isCalculatingRoute else { return }
        if trip.currentStopId == nil {
            trip.start()
        } else {
            trip.lastNavigatedAt = Date()
        }
        guard let stop = trip.currentStop else { return }
        activeTrip = trip
        tripArrivalStop = nil
        try? modelContext.save()
        beginTripLeg(to: stop, trip: trip)
    }

    /// Navigate one leg: saved per-leg route when the stop has one, otherwise
    /// live routing with trip/stop preferences. Both paths flow through the
    /// existing engine.startNavigation machinery.
    private func beginTripLeg(to stop: TripStop, trip: Trip) {
        if let savedRoute = stop.savedRoute {
            let dest = PinnedLocation(
                name: stop.name,
                latitude: stop.latitude,
                longitude: stop.longitude,
                address: stop.address
            )
            navigateWithSavedRoute(savedRoute, to: dest)
        } else {
            navigateTo(
                name: stop.name,
                coordinate: stop.coordinate,
                address: stop.address,
                skipPreview: true,
                preferences: trip.routePreferences(for: stop)
            )
        }
    }

    /// Strict trip-arrival routing — intermediate stops NEVER show the
    /// commute PostArrivalSheet. Continuous mode: brief arrival card, then
    /// auto-advance. Manual mode: pause and prompt for the next leg. The
    /// final stop completes and archives the trip.
    private func handleTripArrival() {
        guard let trip = activeTrip, let arrivedStop = trip.currentStop else { return }

        arrivedStop.arrivalTime = Date()
        tripArrivalStop = arrivedStop

        // Persist position on every arrival fire — app death during the
        // between-legs pause resumes on the correct leg.
        let result = trip.advanceAfterArrival()
        try? modelContext.save()

        switch result {
        case .completed:
            endTripNavigation(completed: true)
        case .nextLeg:
            guard let nextStop = trip.currentStop else {
                endTripNavigation(completed: true)
                return
            }
            if trip.flowMode == .continuous {
                scheduleAutoAdvance(to: nextStop, trip: trip)
            } else {
                pauseNavigationBetweenLegs()
                showTripArrivalPrompt = true
            }
        }
    }

    /// Continuous mode: brief arrival moment (3s), then the next leg starts
    /// on its own. Cancelled if the user taps the card to take manual control.
    private func scheduleAutoAdvance(to stop: TripStop, trip: Trip) {
        tripAutoAdvanceTask?.cancel()
        tripAutoAdvanceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            advanceTripLeg(to: stop, trip: trip)
        }
    }

    /// Start navigation to the next stop — restarts the Live Activity so the
    /// session shows the new leg destination.
    private func advanceTripLeg(to stop: TripStop, trip: Trip) {
        tripAutoAdvanceTask?.cancel()
        tripAutoAdvanceTask = nil
        tripArrivalStop = nil
        showTripArrivalPrompt = false
        LiveActivityService.shared.endActivity()
        beginTripLeg(to: stop, trip: trip)
    }

    /// Manual mode pause between legs: engine and overlay stand down, the
    /// trip stays active so the next-leg prompt can continue it.
    private func pauseNavigationBetweenLegs() {
        _ = locationService.stopRecording()
        locationService.disableNavigationMode()
        locationFeedTask?.cancel()
        locationFeedTask = nil
        navigationEngine?.stopNavigation()
        navStateManager.stopObserving()
        LiveActivityService.shared.endActivity()
        is3DNav = true
        withAnimation(TransitionKit.standardEntrance) {
            isNavigating = false
        }
        navigationRoute = nil
        activeSavedPolyline = nil
        activeRoadConditions = []
    }

    /// Tear down trip navigation. Completed trips were already archived by
    /// advanceAfterArrival; an early End keeps the position for resume.
    private func endTripNavigation(completed: Bool) {
        tripAutoAdvanceTask?.cancel()
        tripAutoAdvanceTask = nil
        _ = locationService.stopRecording()
        locationService.disableNavigationMode()
        locationFeedTask?.cancel()
        locationFeedTask = nil
        navigationEngine?.stopNavigation()
        navStateManager.stopObserving()
        LiveActivityService.shared.endActivity()
        is3DNav = true
        isNavigating = false
        navigationRoute = nil
        activeSavedPolyline = nil
        activeRoadConditions = []

        if !completed {
            activeTrip?.lastNavigatedAt = Date()
            tripArrivalStop = nil
        } else {
            // Let the trip-complete card linger briefly, then clear it
            tripAutoAdvanceTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3.5))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { tripArrivalStop = nil }
            }
        }
        showTripArrivalPrompt = false
        try? modelContext.save()
        activeTrip = nil
    }

    /// Continuous-mode arrival card tapped: cancel the auto-advance and take
    /// manual control for a quick stop (next-leg prompt). The trip-complete
    /// card just dismisses.
    private func tripArrivalCardTapped() {
        tripAutoAdvanceTask?.cancel()
        tripAutoAdvanceTask = nil

        guard let trip = activeTrip, trip.currentStop != nil else {
            withAnimation(.easeOut(duration: 0.25)) { tripArrivalStop = nil }
            return
        }
        pauseNavigationBetweenLegs()
        showTripArrivalPrompt = true
    }

    /// Next-leg prompt swiped away without a choice: leave the trip paused —
    /// position persists, so the resume banner picks it back up.
    private func handleTripPromptDismiss() {
        guard !isNavigating, !isCalculatingRoute, let trip = activeTrip else { return }
        tripArrivalStop = nil
        trip.lastNavigatedAt = Date()
        try? modelContext.save()
        activeTrip = nil
    }

    // MARK: - Trip Context (Overlay + Live Activity)

    /// Leg counter + trip-aware remaining summary for the nav overlay.
    private func tripNavContext(engine: NavigationEngine) -> TripNavContext? {
        guard let trip = activeTrip, let stop = trip.currentStop else { return nil }
        return TripNavContext(
            tripName: trip.name,
            legIndex: trip.currentStopIndex + 1,
            totalLegs: trip.orderedStops.count,
            nextStopName: stop.name,
            remainingSummary: tripRemainingSummary(trip: trip, currentStop: stop, engine: engine)
        )
    }

    /// Trip context for the Live Activity session of the current leg.
    private var liveActivityTripContext: TripActivityContext? {
        guard let trip = activeTrip, trip.currentStop != nil else { return nil }
        return TripActivityContext(
            tripName: trip.name,
            legIndex: trip.currentStopIndex + 1,
            totalLegs: trip.orderedStops.count
        )
    }

    /// Trip-aware ETA: the engine's live ETA for the current leg plus
    /// estimates for the legs after it — saved route durations when present,
    /// straight-line estimates otherwise. No extra direction requests fire.
    private func tripRemainingSummary(trip: Trip, currentStop: TripStop, engine: NavigationEngine) -> String? {
        let remaining = trip.remainingStops
        guard !remaining.isEmpty else { return nil }

        var legs: [TripProgression.LegEstimate] = []
        var previous = currentStop
        for stop in remaining {
            let meters = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: stop.latitude, longitude: stop.longitude))
            legs.append(TripProgression.LegEstimate(
                savedDurationSeconds: stop.savedRoute?.typicalDurationSeconds,
                straightLineMeters: meters
            ))
            previous = stop
        }

        let total = TripProgression.remainingTripSeconds(
            currentLegSeconds: engine.etaSeconds,
            remainingLegs: legs
        )
        let minutes = Int(ceil(total / 60))
        let stopsText = "\(remaining.count) more"
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m · \(stopsText)"
        }
        return "\(minutes) min · \(stopsText)"
    }

    // MARK: - Resume Trip Banner

    /// First in-progress trip not currently navigating — offered for resume
    /// after an app death or an early End.
    private var resumableTrip: Trip? {
        guard !isNavigating, activeTrip == nil else { return nil }
        return trips.first { $0.isInProgress && !$0.isArchived && !dismissedResumeBanners.contains($0.id) }
    }

    private func resumeTripBanner(_ trip: Trip) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(SteddiTheme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Resume \(trip.name)")
                    .font(SteddiTheme.heading(14))
                    .foregroundStyle(SteddiTheme.textPrimary)
                HStack(spacing: 4) {
                    Text("Leg \(trip.currentStopIndex + 1) of \(trip.orderedStops.count)")
                    if let last = trip.lastNavigatedAt {
                        Text("·")
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(SteddiTheme.body(12))
                .foregroundStyle(SteddiTheme.textSecondary)
            }

            Spacer()

            Button {
                startTrip(trip)
            } label: {
                Text("Resume")
                    .font(SteddiTheme.heading(13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(SteddiTheme.accent, in: Capsule())
            }

            Button {
                dismissedResumeBanners.insert(trip.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SteddiTheme.textMuted)
                    .frame(width: 28, height: 28)
                    .background(SteddiTheme.surfaceSecondary, in: Circle())
                    // 28pt glyph, 44pt tap target.
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Dismiss resume banner")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                .fill(SteddiTheme.surfacePrimary.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                        .stroke(SteddiTheme.accent.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Loading Overlay

    private var routeLoadingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(SteddiTheme.accent)
            Text("Finding your route...")
                .font(SteddiTheme.heading(16))
                .foregroundStyle(SteddiTheme.textPrimary)
        }
        .padding(32)
        .background {
            RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                .fill(SteddiTheme.surfacePrimary.opacity(0.95))
                .shadow(color: .black.opacity(0.3), radius: 16)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .font(.title2)
                .foregroundStyle(SteddiTheme.accent)
            Text("No pinned locations yet")
                .font(SteddiTheme.heading(16))
                .foregroundStyle(SteddiTheme.textPrimary)
            Text("Long press the map or search to save a place")
                .font(SteddiTheme.body(14))
                .foregroundStyle(SteddiTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // Distance is calculated locally via formattedDistance() — ETAs fetched async in background

    /// Fetch ETAs for all commute destinations in parallel
    private func refreshCommuteETAs() async {
        guard let userLocation = locationService.currentLocation else { return }

        await withTaskGroup(of: (String, Int?).self) { group in
            for commute in commutes {
                if let dest = commute.destination {
                    let key = "\(commute.id)-toDest"
                    let coord = dest.coordinate
                    group.addTask {
                        let eta = await Self.fetchETA(from: userLocation.coordinate, to: coord)
                        return (key, eta)
                    }
                }
                if let origin = commute.origin {
                    let key = "\(commute.id)-toOrigin"
                    let coord = origin.coordinate
                    group.addTask {
                        let eta = await Self.fetchETA(from: userLocation.coordinate, to: coord)
                        return (key, eta)
                    }
                }
            }

            for await (key, eta) in group {
                if let eta {
                    commuteETAs[key] = eta
                }
            }
        }
    }

    /// Reroute when user deviates from the predefined route.
    /// For custom routes: find nearest point AHEAD on saved polyline, route to rejoin it.
    /// For Apple routes: request fresh directions avoiding U-turns.
    private func handleOffRoute(_ event: OffRouteEvent) async {
        guard let engine = navigationEngine else { return }

        // Single-flight + cooldown: while a recovery request is pending (or
        // just resolved), further off-route fires are ignored — no stacked
        // MKDirections requests, no repeated voice nagging.
        guard !isRecoveryInFlight else { return }
        if let last = lastRecoveryAt, Date().timeIntervalSince(last) < 30 { return }
        isRecoveryInFlight = true
        lastRecoveryAt = Date()
        defer { isRecoveryInFlight = false }

        HapticService.shared.fire(.rerouteSuggestion)

        if let savedPolyline = activeSavedPolyline {
            await recoverOntoSavedRoute(event: event, engine: engine, savedPolyline: savedPolyline)
        } else if let destination = engine.routePolylineCoordinates.last {
            await handleOffRoute(from: event.coordinate, to: destination)
        }
    }

    /// Forward-momentum recovery onto a predefined route: weight macro legs
    /// (the freeway, the right direction) over micro waypoints, take the most
    /// direct path from the divergence to that target, then fall back onto
    /// the saved route. U-turns are never the default — every candidate is
    /// ahead of the driver — and none of this is gated by the opportunistic
    /// reroute threshold.
    private func recoverOntoSavedRoute(
        event: OffRouteEvent,
        engine: NavigationEngine,
        savedPolyline: [CLLocationCoordinate2D]
    ) async {
        let steps = engine.steps
        let cumulative = RouteGeometry.cumulativeDistances(savedPolyline)
        let total = cumulative.last ?? 0
        let alongs = steps.map {
            RouteGeometry.alongDistance(of: $0.coordinate, polyline: savedPolyline, cumulative: cumulative)
        }
        let legs = RouteRecoveryEngine.classifyLegs(steps: steps, alongDistances: alongs, totalDistance: total)
        let candidates = RouteRecoveryEngine.rejoinCandidates(
            event: event, legs: legs, steps: steps, alongDistances: alongs,
            polyline: savedPolyline, totalDistance: total
        )
        guard !candidates.isEmpty else { return }

        VoiceGuidanceService.shared.speak("Rerouting ahead to rejoin your route.")

        // Fetch a recovery route to each candidate concurrently.
        let service = DirectionsService()
        let origin = event.coordinate
        let options = await withTaskGroup(of: RecoveryOption?.self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask { @MainActor in
                    guard let route = try? await service.fetchRoute(from: origin, to: candidate.coordinate) else { return nil }
                    let coords = PolylineEncoder.decode(route.encodedPolyline, precision: 6)
                    let firstInstructions = route.legs.flatMap(\.steps).prefix(2)
                        .map(\.instructions).joined(separator: " ").lowercased()
                    return RecoveryOption(
                        candidateIndex: index,
                        etaSeconds: route.duration,
                        initialBearingDegrees: RouteGeometry.bearing(
                            atDistance: 0,
                            polyline: coords,
                            cumulative: RouteGeometry.cumulativeDistances(coords),
                            lookAheadMeters: 75
                        ),
                        beginsWithUTurn: firstInstructions.contains("u-turn")
                    )
                }
            }
            var collected: [RecoveryOption] = []
            for await option in group { if let option { collected.append(option) } }
            return collected
        }

        let decision = RouteRecoveryEngine.choose(
            candidates: candidates, options: options, event: event,
            totalDistance: total, expectedTravelTime: engine.originalExpectedTravelTime,
            recoveriesThisTrip: recoveriesThisTrip
        )
        recoveriesThisTrip += 1

        switch decision {
        case .rejoin(let index):
            guard index < candidates.count,
                  let option = options.first(where: { $0.candidateIndex == index }),
                  let route = try? await service.fetchRoute(from: origin, to: candidates[index].coordinate)
            else {
                if let destination = savedPolyline.last {
                    await handleOffRoute(from: event.coordinate, to: destination)
                }
                return
            }
            _ = option
            splice(recovery: route, onto: savedPolyline, cumulative: cumulative,
                   at: candidates[index], steps: steps, alongs: alongs, engine: engine)
        case .abandonToDestination:
            if let destination = savedPolyline.last {
                await handleOffRoute(from: event.coordinate, to: destination)
            }
        }
    }

    /// Stitch the recovery route onto the saved route at the rejoin point and
    /// restart the engine on the combined geometry — normal guidance then
    /// falls back onto the predefined route automatically.
    private func splice(
        recovery: DirectionsRoute,
        onto savedPolyline: [CLLocationCoordinate2D],
        cumulative: [Double],
        at candidate: RejoinCandidate,
        steps: [NavStep],
        alongs: [Double],
        engine: NavigationEngine
    ) {
        let recoveryCoords = PolylineEncoder.decode(recovery.encodedPolyline, precision: 6)
        guard recoveryCoords.count >= 2 else { return }
        // Without saved geometry there's nothing to stitch onto — bail safely
        // rather than indexing an empty polyline.
        guard !savedPolyline.isEmpty else { return }

        // Saved geometry from the rejoin point forward. The fallback (no
        // cumulative match) is the last vertex; clamp into bounds so a
        // short/mismatched `cumulative` (or an empty one) can never produce an
        // out-of-range index into `savedPolyline`.
        let rawRejoinIndex = cumulative.firstIndex(where: { $0 >= candidate.alongDistance }) ?? (savedPolyline.count - 1)
        let rejoinIndex = min(max(0, rawRejoinIndex), savedPolyline.count - 1)
        let savedTail = Array(savedPolyline[rejoinIndex...])

        // Recovery steps (drop its arrival step) + saved steps from the rejoin
        let recoverySteps = recovery.legs.flatMap(\.steps)
            .filter { !DirectionsService.isArrivalStep($0) }
            .map { SavedStep(from: $0).toNavStep }
        let savedTailSteps = zip(steps, alongs)
            .filter { $0.1 >= candidate.alongDistance }
            .map(\.0)

        let combined = recoveryCoords + savedTail
        let combinedSteps = recoverySteps + savedTailSteps
        guard combined.count >= 2, !combinedSteps.isEmpty else { return }

        let remaining = RouteRecoveryEngine.proratedRemainingETA(
            fromAlong: candidate.alongDistance,
            totalDistance: cumulative.last ?? 0,
            expectedTravelTime: engine.originalExpectedTravelTime
        )

        engine.startNavigation(
            polyline: combined,
            steps: combinedSteps,
            expectedTravelTime: recovery.duration + remaining
        )
        activeSavedPolyline = combined
        navStateManager.activeRouteCoords = combined
    }

    private func handleOffRoute(from currentPos: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async {
        // If we're on a custom saved route, just reset the off-route counter
        // and let the engine keep tracking. The user will naturally rejoin
        // the saved polyline or the step will advance when they get close.
        // Don't fight them — the saved polyline is the guide, not a prison.
        if activeSavedPolyline != nil {
            // Simply announce and let them continue — they know their route
            HapticService.shared.fire(.rerouteSuggestion)
            VoiceGuidanceService.shared.speak("Off route. Continue to rejoin your route.")
            return
        }

        // Apple Maps routing (dumb nav) — request fresh directions
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: currentPos.latitude, longitude: currentPos.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        let resolvedPreferences = RoutePreferences.resolve(commute: activeCommute, in: .standard)
        resolvedPreferences.apply(to: request)

        do {
            let response = try await MKDirections(request: request).calculate()
            guard !response.routes.isEmpty else { return }

            let bestRoute = response.routes
                .sorted { a, b in
                    let aHasUTurn = a.steps.prefix(2).contains { $0.instructions.lowercased().contains("u-turn") }
                    let bHasUTurn = b.steps.prefix(2).contains { $0.instructions.lowercased().contains("u-turn") }
                    if aHasUTurn != bHasUTurn { return !aHasUTurn }
                    return a.expectedTravelTime < b.expectedTravelTime
                }
                .first ?? response.routes[0]

            navigationEngine?.stopNavigation()
            navigationEngine?.startNavigation(route: bestRoute)
            navigationRoute = bestRoute

            navigationEngine?.onOffRoute = { event in
                Task { @MainActor [self] in
                    await self.handleOffRoute(event)
                }
            }

            if let engine = navigationEngine {
                navStateManager.activeRouteCoords = engine.routePolylineCoordinates
            }

            HapticService.shared.fire(.rerouteSuggestion)
            VoiceGuidanceService.shared.speak("Rerouting")
        } catch {
            // Silently fail — user is still driving, next off-route check will retry
        }
    }

    /// Calculate ETA in minutes using MKDirections
    private static func fetchETA(from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async -> Int? {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: source.latitude, longitude: source.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = .automobile
        do {
            let response = try await MKDirections(request: request).calculateETA()
            return Int(response.expectedTravelTime / 60)
        } catch {
            return nil
        }
    }

    /// Feed GPS location updates to the NavigationEngine while navigation is active.
    private func startLocationFeed() {
        locationFeedTask?.cancel()
        var updateCount = 0
        var lastFedTimestamp: Date?
        locationFeedTask = Task { @MainActor in
            while navigationEngine?.isNavigating == true, !Task.isCancelled {
                // Trip leg arrival — the engine latches hasArrived but keeps
                // navigating; trips advance legs here. Commutes keep their
                // manual End flow, so this only routes when a trip is active.
                if activeTrip != nil, navigationEngine?.hasArrived == true {
                    handleTripArrival()
                    break
                }

                // Only feed fresh fixes — refeeding the same stale CLLocation
                // every 500ms churns the engine's published pose for no reason
                if let location = locationService.currentLocation,
                   location.timestamp != lastFedTimestamp {
                    lastFedTimestamp = location.timestamp
                    navigationEngine?.updateLocation(location)
                }

                // Update Live Activity every 3 seconds (every 6th tick)
                updateCount += 1
                if updateCount % 6 == 0, let engine = navigationEngine {
                    LiveActivityService.shared.updateActivity(engine: engine)
                }

                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Generate mock GPS trace from a hardcoded real route polyline for testing.
    /// Uses a known-good Riverside route to guarantee Map Matching success.
    private func generateMockTrace() async -> [GPSPoint] {
        // Hardcoded polyline from a real Directions API response (UCR → Riverside Plaza, ~8 mi)
        // This is a precision-6 encoded polyline that follows actual roads
        let knownPolyline = "gipx_Appax~Exr@GzBu@p@iBGqKAgI?uBjCAz{@?dNFzPPfAClKA`VGnS?vA?dGBtLKrAQ|DmArCwA|FnOjCvHhAvGTnE?jEe@xEkBfJsDbMuHdT{GvPeC`IeAnGoA~Vy@xXU~^LvM`@hFzAvI`F|NnChHnBvG~ArHlAvL`@dHInLqBxYoBl[cAhL{AnJoCpLoClJkGfPqEhIoFxH}GpHkCfC}FpEuFfDeIfDqKrCkIlA{]nC{Db@sFhAoEjBkEzCuD~CyCdDkDzF}ClHcBnH_AdIWjJJjJr@tI|ArHnCnJ|BdGjDxGbGnIlDtD"

        let coords = PolylineEncoder.decode(knownPolyline, precision: 6)
        guard coords.count >= 2 else { return [] }

        // Sample to ~40 points with realistic timestamps (3 sec apart)
        let step = max(1, coords.count / 40)
        let baseTime = Date().addingTimeInterval(-Double(coords.count / step) * 3)
        var points: [GPSPoint] = []
        for i in stride(from: 0, to: coords.count, by: step) {
            let loc = CLLocation(
                coordinate: coords[i],
                altitude: 250,
                horizontalAccuracy: 8,
                verticalAccuracy: 10,
                course: 0,
                speed: 13.4,
                timestamp: baseTime.addingTimeInterval(Double(points.count) * 3)
            )
            points.append(GPSPoint(from: loc))
        }
        return points
    }

    /// Save a searched place: open the category + icon picker seeded from the
    /// result rather than inserting blindly, so every saved place gets a
    /// category.
    private func pinLocation(from result: GeocodingResult) {
        addPlaceCoordinate = result.coordinate
        addPlaceName = result.name
        addPlaceAddress = result.address.isEmpty ? nil : result.address
        addPlaceCategory = .other
        showAddPlaceFlow = true
    }

    /// "Use Current Location" flow: reverse-geocode the user's position, then
    /// open the category + icon picker seeded with the resolved address. Falls
    /// back to raw coordinates if geocoding fails.
    private func startCurrentLocationAddFlow() {
        guard !isResolvingCurrentLocation else { return }
        isResolvingCurrentLocation = true
        Task {
            // Wait briefly for a fix if we don't have one yet.
            locationService.startUpdating()
            var location = locationService.currentLocation
            for _ in 0..<10 where location == nil {
                try? await Task.sleep(for: .milliseconds(300))
                location = locationService.currentLocation
            }
            defer { isResolvingCurrentLocation = false }
            guard let location else { return }

            let coord = location.coordinate
            var resolvedAddress: String?
            var resolvedName = "Current Location"
            if let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first {
                let parts = [
                    placemark.subThoroughfare, placemark.thoroughfare,
                    placemark.locality, placemark.administrativeArea
                ].compactMap { $0 }
                if !parts.isEmpty { resolvedAddress = parts.joined(separator: " ") }
                if let name = placemark.name, !name.isEmpty { resolvedName = name }
            }

            addPlaceCoordinate = coord
            addPlaceName = resolvedName
            addPlaceAddress = resolvedAddress
            addPlaceCategory = .other
            showAddPlaceFlow = true
        }
    }

    // MARK: - Category Migration

    /// One-time backfill: pins created before the `category` field existed
    /// arrive with an empty category. Infer one from the pin's icon, defaulting
    /// to "other". Idempotent — only empty categories are touched, so it's a
    /// no-op on subsequent launches.
    private func migrateExistingPinsToCategories() {
        var changed = false
        for pin in pinnedLocations where pin.category.isEmpty {
            pin.category = PinnedLocationCategoryMigration.inferredKey(forIcon: pin.icon)
            changed = true
        }
        if changed { try? modelContext.save() }
    }
}

// MARK: - Category Migration (testable)

/// Pure mapping from a legacy pin's SF Symbol to a category key. Lives outside
/// the view so it can be unit-tested without a SwiftData context.
enum PinnedLocationCategoryMigration {
    /// Category key inferred from an icon, defaulting to "other" for unmapped
    /// symbols.
    static func inferredKey(forIcon icon: String) -> String {
        (PlaceCategory.inferred(fromIcon: icon) ?? .other).key
    }
}

// MARK: - Expanded Search

private struct ExpandedSearchView: View {
    let currentLocation: CLLocationCoordinate2D?
    let onSelectResult: (GeocodingResult) -> Void
    let onPinResult: (GeocodingResult) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var results: [GeocodingResult] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedResult: GeocodingResult?
    @FocusState private var isSearchFocused: Bool

    private let geocodingService = GeocodingService()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onDismiss) {
                    Image(systemName: "arrow.left")
                        .font(.body.weight(.medium))
                        .foregroundStyle(SteddiTheme.accent)
                }

                TextField("Search an address", text: $query)
                    .font(SteddiTheme.body(17))
                    .foregroundStyle(SteddiTheme.textPrimary)
                    .focused($isSearchFocused)
                    .autocorrectionDisabled()
                    .onChange(of: query) { _, newValue in
                        debounceSearch(newValue)
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(SteddiTheme.textMuted)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background {
                Capsule()
                    .fill(SteddiTheme.surfacePrimary)
                    .overlay(Capsule().stroke(SteddiTheme.accent.opacity(0.25), lineWidth: 1))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if let selected = selectedResult {
                SearchResultActionCard(
                    name: selected.name,
                    address: selected.address,
                    distanceText: formattedDistance(to: selected),
                    onNavigate: { onSelectResult(selected) },
                    onSave: { onPinResult(selected) },
                    onCancel: {
                        withAnimation(.easeOut(duration: 0.2)) { selectedResult = nil }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if !results.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(results) { result in
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) { selectedResult = result }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin")
                                        .font(.body)
                                        .foregroundStyle(SteddiTheme.accent)
                                        .frame(width: 32)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(result.name)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(SteddiTheme.textPrimary)
                                        if !result.address.isEmpty && result.address != result.name {
                                            Text(result.address)
                                                .font(.caption)
                                                .foregroundStyle(SteddiTheme.textSecondary)
                                                .lineLimit(1)
                                        }
                                    }

                                    Spacer()

                                    if let distanceText = formattedDistance(to: result) {
                                        Text(distanceText)
                                            .font(SteddiTheme.mono(12))
                                            .foregroundStyle(SteddiTheme.textMuted)
                                    }

                                    Button { onPinResult(result) } label: {
                                        Image(systemName: "mappin.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(SteddiTheme.accent)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)

                            if result.id != results.last?.id {
                                Divider()
                                    .background(SteddiTheme.surfaceElevated)
                                    .padding(.leading, 60)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .background {
                    RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                        .fill(SteddiTheme.surfacePrimary.opacity(0.95))
                        .overlay(RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium).stroke(SteddiTheme.accent.opacity(0.08), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .frame(maxHeight: 360)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            } else if !query.isEmpty {
                Text("No results")
                    .font(SteddiTheme.body(14))
                    .foregroundStyle(SteddiTheme.textMuted)
                    .padding(.top, 24)
            }
        }
        .onAppear {
            DispatchQueue.main.async { isSearchFocused = true }
        }
    }

    private func debounceSearch(_ query: String) {
        searchTask?.cancel()
        guard !query.isEmpty else { results = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            do {
                let r = try await geocodingService.search(query: query, proximity: currentLocation)
                if !Task.isCancelled {
                    withAnimation(.easeOut(duration: 0.2)) { results = r }
                }
            } catch {}
        }
    }

    private func formattedDistance(to result: GeocodingResult) -> String? {
        guard let currentLocation else { return nil }
        let from = CLLocation(latitude: currentLocation.latitude, longitude: currentLocation.longitude)
        let to = CLLocation(latitude: result.coordinate.latitude, longitude: result.coordinate.longitude)
        let meters = from.distance(from: to)
        let miles = meters / 1609.344
        if miles < 0.1 {
            let feet = Int(meters * 3.28084)
            return "\(feet) ft"
        } else {
            return String(format: "%.1f mi", miles)
        }
    }
}

// MARK: - Add Location Sheet

private struct AddLocationSheet: View {
    let coordinate: CLLocationCoordinate2D?
    /// Reverse-geocoded address shown as context (e.g. from current-location flow).
    var prefilledAddress: String? = nil
    /// Suggested name to seed the field (e.g. a search result's name).
    var prefilledName: String? = nil
    /// Pre-selected category (e.g. inferred from a search result or save flow).
    var initialCategory: PlaceCategory = .other

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var name = ""
    @State private var selectedIcon = "mappin.circle.fill"
    @State private var selectedCategory: PlaceCategory = .other
    @State private var didSeed = false

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Location name", text: $name) }
                Section("Category") {
                    categoryPicker
                }
                Section("Icon") {
                    PlaceIconPickerView(selectedIcon: $selectedIcon, category: selectedCategory)
                }
                if let address = prefilledAddress, !address.isEmpty {
                    Section("Address") {
                        Text(address).foregroundStyle(.secondary)
                    }
                } else if let coord = coordinate {
                    Section {
                        HStack { Text("Latitude"); Spacer(); Text(String(format: "%.4f", coord.latitude)).foregroundStyle(.secondary) }
                        HStack { Text("Longitude"); Spacer(); Text(String(format: "%.4f", coord.longitude)).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Pin Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save(); dismiss() }
                        .fontWeight(.semibold)
                        .disabled(name.isEmpty || coordinate == nil)
                }
            }
            .onAppear {
                guard !didSeed else { return }
                didSeed = true
                if let prefilledName, name.isEmpty { name = prefilledName }
                selectedCategory = initialCategory
                selectedIcon = initialCategory.symbol
            }
        }
    }

    private var categoryPicker: some View {
        Picker("Category", selection: $selectedCategory) {
            ForEach(PlaceCategory.allCategories) { category in
                Label(category.displayName, systemImage: category.symbol)
                    .tag(category)
            }
        }
        .onChange(of: selectedCategory) { _, newValue in
            // Default the icon to the category's symbol when the user hasn't
            // deliberately picked one outside the new category's set.
            selectedIcon = newValue.symbol
        }
    }

    private func save() {
        guard let coord = coordinate else { return }
        modelContext.insert(PinnedLocation(
            name: name,
            latitude: coord.latitude,
            longitude: coord.longitude,
            address: prefilledAddress,
            icon: selectedIcon,
            category: selectedCategory.key
        ))
    }
}

#Preview {
    HomeView()
        .modelContainer(for: PinnedLocation.self, inMemory: true)
        .environment(LocationService())
        .environment(PendingCommuteStartStore())
}
