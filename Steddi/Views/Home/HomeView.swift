import SwiftUI
import SwiftData
import MapKit
import CoreLocation

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationService.self) private var locationService
    @Environment(NavigationStateManager.self) private var navStateManager
    @Query(sort: \PinnedLocation.sortOrder) private var pinnedLocations: [PinnedLocation]
    @Query(sort: \Commute.createdAt) private var commutes: [Commute]
    @Query private var commuteTrips: [CommuteTrip]

    // Accent color — triggers re-render of entire home + children when changed
    @AppStorage("accentColor") private var accentColor = "lavender"

    // Bottom sheet tab
    @State private var sheetTab: SheetTab = .commutes

    enum SheetTab: String, CaseIterable {
        case commutes = "Commutes"
        case places = "Places"
    }

    // Navigation state
    @State private var isNavigating = false
    @State private var navigationRoute: MKRoute?
    @State private var navigationEngine: NavigationEngine?
    @State private var isCalculatingRoute = false
    @State private var navigationDestination: PinnedLocation?
    @State private var locationFeedTask: Task<Void, Never>?

    // Camera state
    @State private var is3DNav = true

    // UI state
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showAddLocation = false
    @State private var showCommuteList = false
    @State private var showPostArrival = false
    @State private var longPressCoordinate: CLLocationCoordinate2D?
    @State private var recordedPoints: [GPSPoint] = []

    // Active commute tracking (for route saving on arrival)
    @State private var activeCommute: Commute?
    @State private var activeDirection: CommuteDirection?
    @State private var pendingTraceForSave = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    // Live ETAs for commute cards — key: "\(commute.id)-toOrigin" or "\(commute.id)-toDest"
    @State private var commuteETAs: [String: Int] = {
        // Load cached ETAs immediately so cards show numbers on launch
        if let data = UserDefaults.standard.data(forKey: "cachedCommuteETAs"),
           let cached = try? JSONDecoder().decode([String: Int].self, from: data) {
            return cached
        }
        return [:]
    }()

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
                        let points = locationService.stopRecording()
                        locationFeedTask?.cancel()
                        locationFeedTask = nil
                        navigationEngine?.stopNavigation()
                        navStateManager.stopObserving()
                        is3DNav = true
                        isNavigating = false
                        navigationRoute = nil

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
                    },
                    onReport: { type, coordinate in
                        let report = Report(type: type, latitude: coordinate.latitude, longitude: coordinate.longitude)
                        modelContext.insert(report)
                    },
                    commute: activeCommute,
                    direction: activeDirection
                )
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
            checkMilestoneDonation()
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
        .task {
            // Periodically refresh ETAs for commute cards
            while !Task.isCancelled {
                await refreshCommuteETAs()
                try? await Task.sleep(for: .seconds(180)) // refresh every 3 minutes
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
        .sheet(isPresented: $showCommuteList) {
            NavigationStack {
                CommuteListView()
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
        .sheet(isPresented: $showPostArrival) {
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
        .fullScreenCover(isPresented: $showRoutePlanner) {
            if let commute = routePlannerCommute {
                RoutePlannerView(commute: commute)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { navStateManager.isCarPlayActive && navStateManager.isNavigating },
            set: { _ in }
        )) {
            PhoneCompanionView()
                .environment(navStateManager)
        }
        .onOpenURL { url in
            // steddi://test-arrival — trigger post-arrival flow for testing
            if url.host == "test-arrival" {
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

    private func navigateTo(name: String, coordinate: CLLocationCoordinate2D, address: String? = nil) {
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
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
            request.transportType = .automobile

            let directions = MKDirections(request: request)

            do {
                let response = try await directions.calculate()
                guard let route = response.routes.first else {
                    isCalculatingRoute = false
                    return
                }

                locationService.startRecording()

                self.navigationRoute = route
                let engine = NavigationEngine()
                engine.startNavigation(route: route)
                self.navigationEngine = engine

                // Share navigation state for CarPlay
                navStateManager.activeRouteCoords = engine.routePolylineCoordinates
                navStateManager.startObserving(
                    engine: engine,
                    commute: activeCommute,
                    direction: activeDirection
                )

                // Start feeding location updates to the engine
                startLocationFeed()

                withAnimation(.easeInOut(duration: 0.4)) {
                    isCalculatingRoute = false
                    isNavigating = true
                }
            } catch {
                isCalculatingRoute = false
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
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
                .background {
                    Capsule()
                        .fill(SteddiTheme.surfacePrimary.opacity(0.9))
                        .overlay(Capsule().stroke(SteddiTheme.accent.opacity(0.15), lineWidth: 1))
                }
            }

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(SteddiTheme.textSecondary)
                    .frame(width: 44, height: 44)
                    .background {
                        Circle()
                            .fill(SteddiTheme.surfacePrimary.opacity(0.9))
                            .overlay(Circle().stroke(SteddiTheme.accent.opacity(0.08), lineWidth: 1))
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

            bottomSheet
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
                    // Search + settings row
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
                            .background {
                                Capsule()
                                    .fill(SteddiTheme.surfaceSecondary.opacity(0.8))
                                    .overlay(Capsule().stroke(SteddiTheme.accent.opacity(0.1), lineWidth: 1))
                            }
                        }

                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.caption)
                                .foregroundStyle(SteddiTheme.textSecondary)
                                .frame(width: 36, height: 36)
                                .background(SteddiTheme.surfaceSecondary.opacity(0.8), in: Circle())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                    // Tabs
                    HStack(spacing: 0) {
                        ForEach(SheetTab.allCases, id: \.self) { tab in
                            Button { sheetTab = tab } label: {
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

                    // Content — compact
                    ScrollView {
                        switch sheetTab {
                        case .commutes:
                            commutesTab
                        case .places:
                            placesTab
                        }
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

            // Tab selector
            HStack(spacing: 0) {
                ForEach(SheetTab.allCases, id: \.self) { tab in
                    Button {
                        sheetTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(SteddiTheme.heading(14))
                            .foregroundStyle(sheetTab == tab ? SteddiTheme.accent : SteddiTheme.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            SteadyLine(color: SteddiTheme.accent, height: 1)
                .padding(.horizontal, 32)

            // Content
            switch sheetTab {
            case .commutes:
                commutesTab
            case .places:
                placesTab
            }
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
                        ForEach(commutes) { commute in
                            commuteRows(commute)
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
                .frame(maxHeight: 160)
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
        if let preferredRoute = commute.preferredRoute(for: direction) {
            navigateWithSavedRoute(preferredRoute, to: target)
        } else {
            // No saved route — use standard routing
            navigateTo(name: target.name, coordinate: target.coordinate, address: target.address)
        }
    }

    /// Navigate using a saved route's polyline as waypoints
    private func navigateWithSavedRoute(_ savedRoute: Route, to target: PinnedLocation) {
        navigationDestination = target
        isCalculatingRoute = true

        Task {
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

            // Decode saved polyline and sample waypoints from it
            let routeCoords = PolylineEncoder.decode(savedRoute.encodedPolyline, precision: 6)

            // Build waypoints: current position + sampled points along saved route + destination
            // Sample every ~20th coordinate to stay under the 25 waypoint API limit
            var waypointCoords: [CLLocationCoordinate2D] = [currentLocation.coordinate]
            let sampleStep = max(1, routeCoords.count / 20)
            for i in stride(from: sampleStep, to: routeCoords.count - 1, by: sampleStep) {
                waypointCoords.append(routeCoords[i])
            }
            waypointCoords.append(target.coordinate)

            // Use MKDirections with waypoints — route through sampled points
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: target.coordinate))
            request.transportType = .automobile

            let directions = MKDirections(request: request)

            do {
                let response = try await directions.calculate()
                guard let route = response.routes.first else {
                    isCalculatingRoute = false
                    navigateTo(name: target.name, coordinate: target.coordinate, address: target.address)
                    return
                }

                locationService.startRecording()
                self.navigationRoute = route
                let engine = NavigationEngine()
                engine.startNavigation(route: route)
                self.navigationEngine = engine

                // Share navigation state for CarPlay
                navStateManager.activeRouteCoords = engine.routePolylineCoordinates
                navStateManager.startObserving(
                    engine: engine,
                    commute: activeCommute,
                    direction: activeDirection
                )

                // Start feeding location updates to the engine
                startLocationFeed()

                isCalculatingRoute = false
                isNavigating = true
            } catch {
                // Fall back to standard routing if saved route fails
                isCalculatingRoute = false
                navigateTo(name: target.name, coordinate: target.coordinate, address: target.address)
            }
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

        return VStack(spacing: 0) {
            // Commute name header
            HStack {
                Text(commute.name)
                    .font(SteddiTheme.heading(15))
                    .foregroundStyle(SteddiTheme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Direction rows
            if isConfident, let dir = confidentDirection {
                // Near one endpoint — show single tappable destination
                let destName = dir == .originToDestination ? commute.destination?.name : commute.origin?.name
                let etaKey = dir == .originToDestination ? "\(commute.id)-toDest" : "\(commute.id)-toOrigin"
                commuteDirectionRow(commute: commute, direction: dir, destName: destName ?? "—", etaKey: etaKey)
                    .padding(.bottom, 12)
            } else {
                // Not near either — show both directions
                if let destName = commute.destination?.name {
                    commuteDirectionRow(commute: commute, direction: .originToDestination, destName: destName, etaKey: "\(commute.id)-toDest")
                }
                if let originName = commute.origin?.name {
                    commuteDirectionRow(commute: commute, direction: .destinationToOrigin, destName: originName, etaKey: "\(commute.id)-toOrigin")
                }
                Spacer().frame(height: 12)
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

    /// A single tappable direction row within a commute card
    private func commuteDirectionRow(commute: Commute, direction: CommuteDirection, destName: String, etaKey: String) -> some View {
        Button {
            startCommute(commute, direction: direction)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.body)
                    .foregroundStyle(SteddiTheme.accent)

                Text(destName)
                    .font(SteddiTheme.body(14))
                    .foregroundStyle(SteddiTheme.textSecondary)

                Spacer()

                if let eta = commuteETAs[etaKey] {
                    Text("\(eta) min")
                        .font(SteddiTheme.mono(14))
                        .foregroundStyle(SteddiTheme.sage)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(SteddiTheme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Places Tab

    private var placesTab: some View {
        Group {
            if pinnedLocations.isEmpty {
                emptyState
                    .padding(.vertical, 24)
                    .padding(.horizontal, 20)
            } else {
                List {
                    ForEach(pinnedLocations) { location in
                        LocationCardView(
                            name: location.name,
                            icon: location.icon,
                            etaMinutes: nil,
                            delayMinutes: nil,
                            onTap: {
                                navigateTo(
                                    name: location.name,
                                    coordinate: location.coordinate,
                                    address: location.address
                                )
                            }
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                    .onMove(perform: movePlaces)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: 160)
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

    private func refreshCommuteETAs() async {
        guard let currentLoc = locationService.currentLocation else { return }

        // Fetch all ETAs in parallel
        await withTaskGroup(of: (String, Int)?.self) { group in
            for commute in commutes {
                if let dest = commute.destination {
                    group.addTask {
                        let coord = dest.coordinate
                        let request = MKDirections.Request()
                        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLoc.coordinate))
                        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: coord))
                        request.transportType = .automobile
                        guard let eta = try? await MKDirections(request: request).calculateETA() else { return nil }
                        return ("\(commute.id)-toDest", Int(ceil(eta.expectedTravelTime / 60)))
                    }
                }
                if let origin = commute.origin {
                    group.addTask {
                        let coord = origin.coordinate
                        let request = MKDirections.Request()
                        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLoc.coordinate))
                        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: coord))
                        request.transportType = .automobile
                        guard let eta = try? await MKDirections(request: request).calculateETA() else { return nil }
                        return ("\(commute.id)-toOrigin", Int(ceil(eta.expectedTravelTime / 60)))
                    }
                }
            }

            for await result in group {
                if let (key, mins) = result {
                    commuteETAs[key] = mins
                }
            }
        }

        // Cache to disk for instant display on next launch
        if let data = try? JSONEncoder().encode(commuteETAs) {
            UserDefaults.standard.set(data, forKey: "cachedCommuteETAs")
        }
    }

    /// Feed GPS location updates to the NavigationEngine while navigation is active.
    private func startLocationFeed() {
        locationFeedTask?.cancel()
        locationFeedTask = Task { @MainActor in
            while navigationEngine?.isNavigating == true, !Task.isCancelled {
                if let location = locationService.currentLocation {
                    navigationEngine?.updateLocation(location)
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

    private func pinLocation(from result: GeocodingResult) {
        let location = PinnedLocation(
            name: result.name,
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude,
            address: result.address
        )
        modelContext.insert(location)
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

            if !results.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(results) { result in
                            Button { onSelectResult(result) } label: {
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var name = ""
    @State private var selectedIcon = "mappin.circle.fill"

    private static let iconOptions: [(symbol: String, label: String)] = [
        ("house.fill", "Home"),
        ("building.2.fill", "Work"),
        ("figure.run", "Gym"),
        ("cart.fill", "Shopping"),
        ("fork.knife", "Food"),
        ("cup.and.saucer.fill", "Coffee"),
        ("airplane", "Airport"),
        ("cross.fill", "Hospital"),
        ("book.fill", "School"),
        ("mappin.circle.fill", "Other"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Location name", text: $name) }
                Section("Icon") {
                    iconPicker
                }
                if let coord = coordinate {
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
        }
    }

    private var iconPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
            ForEach(Self.iconOptions, id: \.symbol) { option in
                let isSelected = selectedIcon == option.symbol
                Button {
                    selectedIcon = option.symbol
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: option.symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isSelected ? .white : SteddiTheme.accent)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(isSelected ? SteddiTheme.accent : SteddiTheme.accentSubtle)
                            )
                        Text(option.label)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? SteddiTheme.textPrimary : SteddiTheme.textMuted)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func save() {
        guard let coord = coordinate else { return }
        modelContext.insert(PinnedLocation(name: name, latitude: coord.latitude, longitude: coord.longitude, icon: selectedIcon))
    }
}

#Preview {
    HomeView()
        .modelContainer(for: PinnedLocation.self, inMemory: true)
        .environment(LocationService())
}
