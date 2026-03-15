import SwiftUI
import SwiftData
import MapboxNavigationCore
import MapboxDirections
import CoreLocation

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationService.self) private var locationService
    @Query(sort: \PinnedLocation.sortOrder) private var pinnedLocations: [PinnedLocation]
    @Query(sort: \Commute.createdAt) private var commutes: [Commute]

    // Bottom sheet tab
    @State private var sheetTab: SheetTab = .commutes

    enum SheetTab: String, CaseIterable {
        case commutes = "Commutes"
        case places = "Places"
    }

    // Navigation state
    @State private var isNavigating = false
    @State private var navigationRoutes: NavigationRoutes?
    @State private var navProvider: MapboxNavigationProvider?
    @State private var isCalculatingRoute = false
    @State private var navigationDestination: PinnedLocation?

    // Camera state
    @State private var is3DNav = true

    // UI state
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showAddLocation = false
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

    // Direction picker for ambiguous commutes
    @State private var showDirectionPicker = false
    @State private var directionPickerCommute: Commute?
    // Set to true to auto-start nav for testing, false for normal use
    private let debugAutoNav = false
    @State private var debugDidAutoNav = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background behind safe area — dark so no white gaps in landscape
            Color.black.ignoresSafeArea()

            // Unified map — same instance for home + navigation
            SteddiMapView(
                isNavigating: $isNavigating,
                is3DView: $is3DNav,
                navigationRoutes: navigationRoutes,
                provider: navProvider,
                onLongPress: { coord in
                    longPressCoordinate = coord
                    showAddLocation = true
                },
                onArrival: {},
                onCancelled: {}
            )
            .ignoresSafeArea() // map fills everything, UI floats on top

            // Navigation overlay
            if let provider = navProvider, isNavigating {
                SteddiNavOverlay(
                    provider: provider,
                    onEndNavigation: {
                        let points = locationService.stopRecording()
                        provider.tripSession().setToIdle()
                        is3DNav = true
                        isNavigating = false
                        navigationRoutes = nil

                        // Save the raw drive record
                        if points.count >= 2 {
                            let record = DriveRecord()
                            record.rawGPSPoints = points
                            record.associatedCommute = activeCommute
                            record.endedAt = Date()
                            modelContext.insert(record)
                            recordedPoints = points
                        }

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
                    }
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
        .onAppear {
            locationService.requestPermission()
            locationService.startUpdating()
        }
        .onReceive(NotificationCenter.default.publisher(for: .steddiSaveRouteFromNotification)) { _ in
            if pendingTraceForSave && !recordedPoints.isEmpty {
                showPostArrival = true
            }
        }
        .task {
            if debugAutoNav && !debugDidAutoNav {
                debugDidAutoNav = true
                try? await Task.sleep(for: .seconds(3))
                navigateTo(name: "Debug Target", coordinate: CLLocationCoordinate2D(latitude: 33.980, longitude: -117.375))
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showAddLocation) {
            AddLocationSheet(coordinate: longPressCoordinate)
                .presentationDetents([.medium])
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
                destinationName: navigationDestination?.name ?? "Destination",
                recordedPoints: recordedPoints
            )
            .presentationDetents([.medium, .large])
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

            let provider = MapboxNavigationProvider(coreConfig: .init())

            let origin = Waypoint(coordinate: currentLocation.coordinate, name: "Current Location")
            let destination = Waypoint(coordinate: coordinate, name: name)
            let routeOptions = NavigationRouteOptions(waypoints: [origin, destination])

            do {
                let routes = try await provider.routingProvider().calculateRoutes(options: routeOptions).value

                locationService.startRecording()

                self.navProvider = provider
                self.navigationRoutes = routes

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
            bottomSheet
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
            .background(SteddiTheme.surfacePrimary)

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
        .background(SteddiTheme.surfacePrimary.shadow(color: .black.opacity(0.3), radius: 20, y: -5))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusLarge, topTrailingRadius: SteddiTheme.radiusLarge))
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
                    Text("Set up a commute in Settings")
                        .font(SteddiTheme.body(14))
                        .foregroundStyle(SteddiTheme.textSecondary)
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 20)
            } else {
                VStack(spacing: 8) {
                    ForEach(commutes.prefix(isLandscape ? 2 : 4)) { commute in
                        commuteCard(commute)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    /// Resolve direction for display on the commute card — shows where you'd go
    private func resolveCardDirection(_ commute: Commute) -> (destination: String, direction: CommuteDirection) {
        guard let currentLoc = locationService.currentLocation else {
            return (commute.destination?.name ?? "—", .originToDestination)
        }

        let result = CommuteDirectionResolver.resolve(
            commute: commute,
            currentLocation: currentLoc
        )

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

            let provider = MapboxNavigationProvider(coreConfig: .init())

            // Decode saved polyline and sample waypoints from it
            let routeCoords = PolylineEncoder.decode(savedRoute.encodedPolyline, precision: 6)

            // Build waypoints: current position + sampled points along saved route + destination
            // Sample every ~20th coordinate to stay under the 25 waypoint API limit
            var waypointCoords: [CLLocationCoordinate2D] = [currentLocation.coordinate]
            let step = max(1, routeCoords.count / 20)
            for i in stride(from: step, to: routeCoords.count - 1, by: step) {
                waypointCoords.append(routeCoords[i])
            }
            waypointCoords.append(target.coordinate)

            var waypoints = waypointCoords.map { Waypoint(coordinate: $0) }
            waypoints[0].name = "Current Location"
            waypoints[waypoints.count - 1].name = target.name

            let routeOptions = NavigationRouteOptions(waypoints: waypoints)

            do {
                let routes = try await provider.routingProvider().calculateRoutes(options: routeOptions).value
                locationService.startRecording()
                self.navProvider = provider
                self.navigationRoutes = routes
                isCalculatingRoute = false
                isNavigating = true
            } catch {
                // Fall back to standard routing if saved route fails
                isCalculatingRoute = false
                navigateTo(name: target.name, coordinate: target.coordinate, address: target.address)
            }
        }
    }

    private func commuteCard(_ commute: Commute) -> some View {
        Button {
            guard let currentLoc = locationService.currentLocation else {
                // No location — just go to destination
                startCommute(commute, direction: .originToDestination)
                return
            }

            let result = CommuteDirectionResolver.resolve(
                commute: commute,
                currentLocation: currentLoc
            )

            switch result {
            case .confident(let direction, _):
                startCommute(commute, direction: direction)
            case .ambiguous:
                directionPickerCommute = commute
                showDirectionPicker = true
            }
        } label: {
            HStack(spacing: 12) {
                // Route indicator
                VStack(spacing: 2) {
                    Circle()
                        .fill(SteddiTheme.accent)
                        .frame(width: 8, height: 8)
                    Rectangle()
                        .fill(SteddiTheme.accent.opacity(0.3))
                        .frame(width: 2, height: 16)
                    Circle()
                        .fill(SteddiTheme.sage)
                        .frame(width: 8, height: 8)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(commute.name)
                        .font(SteddiTheme.heading(15))
                        .foregroundStyle(SteddiTheme.textPrimary)

                    HStack(spacing: 4) {
                        let resolved = resolveCardDirection(commute)
                        Image(systemName: "location.fill")
                            .font(.caption2)
                            .foregroundStyle(SteddiTheme.accent)
                        Text(resolved.destination)
                            .foregroundStyle(SteddiTheme.textSecondary)
                    }
                    .font(SteddiTheme.body(13))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SteddiTheme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                    .fill(SteddiTheme.surfaceSecondary.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                            .stroke(SteddiTheme.accent.opacity(0.06), lineWidth: 1)
                    )
            }
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
                VStack(spacing: 8) {
                    ForEach(pinnedLocations.prefix(isLandscape ? 2 : 6)) { location in
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
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
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

    private let geocodingService = GeocodingService(accessToken: MapboxTokenProvider.accessToken)

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
}

// MARK: - Add Location Sheet

private struct AddLocationSheet: View {
    let coordinate: CLLocationCoordinate2D?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Location name", text: $name) }
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

    private func save() {
        guard let coord = coordinate else { return }
        modelContext.insert(PinnedLocation(name: name, latitude: coord.latitude, longitude: coord.longitude))
    }
}

#Preview {
    HomeView()
        .modelContainer(for: PinnedLocation.self, inMemory: true)
        .environment(LocationService())
}
