import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// Multi-mode no-go zone editor. Pick a drawing mode (pin / route / draw /
/// shape / road), build a geometry on the map (or by name), optionally attach a
/// time window, and save. Legacy circle zones remain fully supported via the
/// pin mode.
struct NoGoZoneEditorView: View {
    /// Re-exported so the spec's `NoGoZoneEditorView.EditorMode` spelling and
    /// the shared `ZoneEditorMode` refer to the same type.
    typealias EditorMode = ZoneEditorMode

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationService.self) private var locationService
    @AppStorage("accentColor") private var accentColor = "lavender"
    @AppStorage(ThemeModeEx.defaultsKey) private var themeModeEx: String = ThemeModeEx.dynamic.rawValue

    @State private var selectedMode: ZoneEditorMode = .circlePin
    @State private var name = ""
    @State private var radiusMeters: Double = 200

    // Resolved + preview geometry
    @State private var selectedGeometry: ZoneGeometry?
    @State private var previewGeometry: ZoneGeometry?
    @State private var isSnapping = false
    @State private var drawError: String?

    // Per-mode input state
    @State private var circleCenter: CLLocationCoordinate2D?
    @State private var dotWaypoints: [CLLocationCoordinate2D] = []
    @State private var polygonTaps: [CLLocationCoordinate2D] = []
    @State private var roadName = ""
    @State private var roadStart = ""
    @State private var roadEnd = ""

    // Time window
    @State private var hasTimeWindow = false
    @State private var selectedDays: Set<Int> = [2, 3, 4, 5, 6]  // Mon–Fri
    @State private var startHour = 7
    @State private var endHour = 18

    // Map + search
    @State private var mapViewRef: MKMapView?
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var searchResults: [GeocodingResult] = []
    @State private var searchTask: Task<Void, Never>?

    private let geocodingService = GeocodingService()
    private let drawingService = ZoneDrawingService()

    var body: some View {
        let _ = accentColor // force re-render on accent change
        ZStack {
            NoGoZoneMapV2(
                previewGeometry: previewGeometry ?? selectedGeometry,
                mode: selectedMode,
                inProgressPoints: inProgressGuide,
                onTapMap: handleMapTap,
                onDrawStroke: handleDrawStroke,
                mapViewRef: $mapViewRef
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                modePickerBar
                if showSearch { searchOverlay }
                Spacer()
                if isSnapping { snappingIndicator }
                if let drawError { errorBanner(drawError) }
                bottomControlCard
            }
        }
        .preferredColorScheme(resolvedColorScheme)
    }

    private var resolvedColorScheme: ColorScheme? {
        (ThemeModeEx(rawValue: themeModeEx) ?? .dynamic).colorScheme
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .font(.body.weight(.medium))
                .foregroundStyle(SteddiTheme.textPrimary)
                .padding(10)
                .background(SteddiTheme.surfacePrimary.opacity(0.88), in: Capsule())

            Spacer()

            Button { showSearch.toggle() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(SteddiTheme.accent)
                    .padding(10)
                    .background(SteddiTheme.surfacePrimary.opacity(0.88), in: Circle())
            }

            Spacer()

            Button("Save") { saveZone() }
                .font(.body.weight(.semibold))
                .foregroundStyle(canSave ? SteddiTheme.accent : SteddiTheme.textMuted)
                .padding(10)
                .background(SteddiTheme.surfacePrimary.opacity(0.88), in: Capsule())
                .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Mode picker

    private var modePickerBar: some View {
        HStack(spacing: 8) {
            modeButton(.circlePin, "Pin", "location.circle.fill")
            modeButton(.dotToDot, "Route", "mappin.and.ellipse")
            modeButton(.freehandDraw, "Draw", "pencil")
            modeButton(.polygonDraw, "Shape", "pentagon.fill")
            modeButton(.namedRoad, "Road", "signpost.right.fill")
        }
        .padding(10)
        .background(SteddiTheme.surfacePrimary.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private func modeButton(_ mode: ZoneEditorMode, _ title: String, _ symbol: String) -> some View {
        Button {
            selectMode(mode)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 16))
                Text(title)
            }
        }
        .buttonStyle(ModeButtonStyle(isSelected: selectedMode == mode))
    }

    // MARK: - Bottom card

    private var bottomControlCard: some View {
        VStack(spacing: 14) {
            Text(modeHint)
                .font(SteddiTheme.body(13))
                .foregroundStyle(SteddiTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if selectedMode == .circlePin && circleCenter != nil {
                radiusSlider
            }

            if selectedMode == .namedRoad {
                namedRoadInputs
            } else {
                TextField("Zone name (optional)", text: $name)
                    .font(SteddiTheme.body(15))
                    .padding(10)
                    .background(SteddiTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
            }

            timeWindowControls

            if selectedMode == .dotToDot || selectedMode == .polygonDraw {
                actionButtons
            }
        }
        .padding(16)
        .background(
            SteddiTheme.surfacePrimary.opacity(0.95)
                .shadow(color: .black.opacity(0.3), radius: 16, y: -4)
        )
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusLarge, topTrailingRadius: SteddiTheme.radiusLarge))
    }

    private var radiusSlider: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Radius").font(SteddiTheme.body(15)).foregroundStyle(SteddiTheme.textPrimary)
                Spacer()
                Text("\(Int(radiusMeters))m").font(SteddiTheme.mono(15)).foregroundStyle(SteddiTheme.textSecondary)
            }
            Slider(value: $radiusMeters, in: 100...2000, step: 50)
                .tint(SteddiTheme.warmRed)
                .onChange(of: radiusMeters) { _, _ in updateCirclePreview() }
        }
    }

    private var namedRoadInputs: some View {
        VStack(spacing: 10) {
            TextField("Road name (e.g. 'I-91')", text: $roadName)
                .font(SteddiTheme.body(15))
                .padding(10)
                .background(SteddiTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 10) {
                TextField("From (e.g. 'Main St')", text: $roadStart)
                    .font(SteddiTheme.body(14))
                    .padding(10)
                    .background(SteddiTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                TextField("To (e.g. 'Route 15')", text: $roadEnd)
                    .font(SteddiTheme.body(14))
                    .padding(10)
                    .background(SteddiTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
            }
            Button {
                resolveNamedRoad()
            } label: {
                Text(isSnapping ? "Finding road…" : "Find road")
                    .font(SteddiTheme.body(15).weight(.semibold))
                    .foregroundStyle(SteddiTheme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(SteddiTheme.accent, in: RoundedRectangle(cornerRadius: 10))
            }
            .disabled(roadName.isEmpty || roadStart.isEmpty || roadEnd.isEmpty || isSnapping)
        }
    }

    private var timeWindowControls: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Time window")
                    .font(SteddiTheme.body(15))
                    .foregroundStyle(SteddiTheme.textPrimary)
                Spacer()
                Toggle("", isOn: $hasTimeWindow)
                    .labelsHidden()
                    .tint(SteddiTheme.accent)
            }
            if hasTimeWindow {
                DaysOfWeekPicker(selected: $selectedDays)
                HourRangePicker(start: $startHour, end: $endHour)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                clearDrawing()
            } label: {
                Text("Clear")
                    .font(SteddiTheme.body(15).weight(.medium))
                    .foregroundStyle(SteddiTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(SteddiTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
            }
            if selectedMode == .polygonDraw {
                Button {
                    closePolygon()
                } label: {
                    Text("Close shape")
                        .font(SteddiTheme.body(15).weight(.semibold))
                        .foregroundStyle(SteddiTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(SteddiTheme.accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .disabled(polygonTaps.count < 3)
            }
        }
    }

    private var snappingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().tint(SteddiTheme.accent)
            Text("Snapping to roads…")
                .font(SteddiTheme.body(13))
                .foregroundStyle(SteddiTheme.textPrimary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(SteddiTheme.surfacePrimary.opacity(0.92), in: Capsule())
        .padding(.bottom, 8)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(SteddiTheme.body(13))
            .foregroundStyle(SteddiTheme.warmRed)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(SteddiTheme.surfacePrimary.opacity(0.92), in: Capsule())
            .padding(.bottom, 8)
    }

    // MARK: - Search overlay

    private var searchOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(SteddiTheme.accent)
                TextField("Search a location", text: $searchQuery)
                    .font(SteddiTheme.body(15))
                    .foregroundStyle(SteddiTheme.textPrimary)
                    .autocorrectionDisabled()
                    .onChange(of: searchQuery) { _, newValue in debounceSearch(newValue) }
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""; searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(SteddiTheme.textMuted)
                    }
                }
            }
            .padding(12)
            .background(SteddiTheme.surfacePrimary.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if !searchResults.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(searchResults) { result in
                            Button { selectSearchResult(result) } label: {
                                HStack {
                                    Image(systemName: "mappin").foregroundStyle(SteddiTheme.warmRed).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.name).font(.body).foregroundStyle(SteddiTheme.textPrimary)
                                        if !result.address.isEmpty && result.address != result.name {
                                            Text(result.address).font(.caption).foregroundStyle(SteddiTheme.textSecondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16).padding(.vertical, 10)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
                .background(SteddiTheme.surfacePrimary.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Derived

    private var modeHint: String {
        switch selectedMode {
        case .circlePin: return "Tap the map to place a circular zone."
        case .dotToDot: return "Tap waypoints; we'll route a corridor between them."
        case .freehandDraw: return "Drag on the map to trace a road; we'll snap it."
        case .polygonDraw: return "Tap to add points, then close the shape."
        case .namedRoad: return "Name a road and its bounds to avoid that stretch."
        }
    }

    private var inProgressGuide: [CLLocationCoordinate2D] {
        switch selectedMode {
        case .dotToDot: return dotWaypoints
        case .polygonDraw: return polygonTaps
        default: return []
        }
    }

    private var canSave: Bool {
        selectedGeometry != nil
    }

    // MARK: - Mode switching

    private func selectMode(_ mode: ZoneEditorMode) {
        guard mode != selectedMode else { return }
        selectedMode = mode
        clearDrawing()
    }

    private func clearDrawing() {
        selectedGeometry = nil
        previewGeometry = nil
        circleCenter = nil
        dotWaypoints = []
        polygonTaps = []
        drawError = nil
    }

    // MARK: - Map handlers

    private func handleMapTap(_ coord: CLLocationCoordinate2D) {
        drawError = nil
        switch selectedMode {
        case .circlePin:
            circleCenter = coord
            updateCirclePreview()
        case .dotToDot:
            dotWaypoints.append(coord)
            updateDotToDotPreview()
        case .polygonDraw:
            // Auto-close when tapping near the first point.
            if polygonTaps.count >= 3, let first = polygonTaps.first,
               RouteGeometry.haversineDistance(from: first, to: coord) < 50 {
                closePolygon()
            } else {
                polygonTaps.append(coord)
                updatePolygonPreview()
            }
        case .freehandDraw, .namedRoad:
            break
        }
    }

    private func handleDrawStroke(_ path: [CLLocationCoordinate2D]) {
        guard selectedMode == .freehandDraw, path.count >= 2 else { return }
        drawError = nil
        isSnapping = true
        Task {
            defer { isSnapping = false }
            do {
                let snapped = try await drawingService.snapFreehandStroke(path)
                selectedGeometry = snapped.geometry
                previewGeometry = nil
            } catch {
                drawError = (error as? LocalizedError)?.errorDescription ?? "Couldn't snap the drawing."
            }
        }
    }

    // MARK: - Previews

    private func updateCirclePreview() {
        guard let center = circleCenter else { return }
        selectedGeometry = .circle(center: center, radiusMeters: radiusMeters)
        previewGeometry = nil
    }

    private func updateDotToDotPreview() {
        guard dotWaypoints.count >= 2 else { return }
        isSnapping = true
        Task {
            defer { isSnapping = false }
            do {
                let snapped = try await drawingService.dotToDotCorridor(waypoints: dotWaypoints)
                selectedGeometry = snapped.geometry
                previewGeometry = nil
            } catch {
                drawError = (error as? LocalizedError)?.errorDescription ?? "Couldn't route a corridor."
            }
        }
    }

    private func updatePolygonPreview() {
        guard polygonTaps.count >= 2 else { previewGeometry = nil; return }
        previewGeometry = .polygon(encodedPolyline: PolylineEncoder.encode(polygonTaps, precision: 6))
    }

    private func closePolygon() {
        do {
            selectedGeometry = try drawingService.polygonFromTaps(polygonTaps)
            previewGeometry = nil
        } catch {
            drawError = (error as? LocalizedError)?.errorDescription ?? "Add at least three points."
        }
    }

    private func resolveNamedRoad() {
        drawError = nil
        isSnapping = true
        Task {
            defer { isSnapping = false }
            do {
                let geometry = try await drawingService.namedRoadCorridor(
                    roadName: roadName,
                    startLocation: roadStart,
                    endLocation: roadEnd,
                    proximity: locationService.currentLocation?.coordinate
                )
                selectedGeometry = geometry
                previewGeometry = nil
                if name.isEmpty { name = roadName }
                // Frame the resolved corridor.
                if case .corridor(let polyline, _) = geometry {
                    frameCoordinates(PolylineEncoder.decode(polyline, precision: 6))
                }
            } catch {
                drawError = (error as? LocalizedError)?.errorDescription ?? "Couldn't find that road."
            }
        }
    }

    // MARK: - Save

    private func saveZone() {
        guard let geometry = selectedGeometry else { return }

        let window: TimeWindow? = hasTimeWindow
            ? TimeWindow(daysOfWeek: selectedDays, startHour: startHour, endHour: endHour)
            : nil

        let zone = NoGoZone(
            geometry: geometry,
            name: name.isEmpty ? nil : name,
            isGlobal: true,
            route: nil,
            timeWindow: window
        )
        modelContext.insert(zone)
        try? modelContext.save()
        dismiss()
    }

    // MARK: - Search helpers

    private func selectSearchResult(_ result: GeocodingResult) {
        showSearch = false
        searchQuery = ""
        searchResults = []
        if selectedMode == .circlePin {
            circleCenter = result.coordinate
            updateCirclePreview()
        }
        if let mv = mapViewRef {
            mv.setRegion(MKCoordinateRegion(center: result.coordinate, latitudinalMeters: 2000, longitudinalMeters: 2000), animated: true)
        }
    }

    private func debounceSearch(_ query: String) {
        searchTask?.cancel()
        guard !query.isEmpty else { searchResults = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            do {
                let results = try await geocodingService.search(
                    query: query,
                    proximity: locationService.currentLocation?.coordinate
                )
                if !Task.isCancelled { searchResults = results }
            } catch {}
        }
    }

    private func frameCoordinates(_ coords: [CLLocationCoordinate2D]) {
        guard let mv = mapViewRef, !coords.isEmpty else { return }
        let rect = coords.reduce(MKMapRect.null) { acc, coord in
            let point = MKMapPoint(coord)
            return acc.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        mv.setVisibleMapRect(
            rect,
            edgePadding: UIEdgeInsets(top: 120, left: 60, bottom: 240, right: 60),
            animated: true
        )
    }
}
