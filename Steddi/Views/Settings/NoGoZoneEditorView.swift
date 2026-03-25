import SwiftUI
import SwiftData
import MapboxMaps
import CoreLocation

/// Full-screen no-go zone editor — tap the map to place a zone, adjust radius, save.
struct NoGoZoneEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationService.self) private var locationService
    @AppStorage("accentColor") private var accentColor = "lavender"

    @State private var name = ""
    @State private var radiusMeters: Double = 200
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var mapViewRef: MapView?

    // Search
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var searchResults: [GeocodingResult] = []
    @State private var searchTask: Task<Void, Never>?

    private let geocodingService = GeocodingService(accessToken: MapboxTokenProvider.accessToken)

    var body: some View {
        ZStack {
            // Full-screen map
            NoGoZoneMap(
                selectedCoordinate: selectedCoordinate,
                radiusMeters: radiusMeters,
                onTapMap: { coord in
                    selectedCoordinate = coord
                },
                mapViewRef: $mapViewRef
            )
            .ignoresSafeArea()

            VStack {
                // Top bar
                HStack {
                    Button("Cancel") { dismiss() }
                        .font(.body.weight(.medium))
                        .foregroundStyle(SteddiTheme.textPrimary)
                        .padding(10)
                        .background(SteddiTheme.surfacePrimary.opacity(0.88), in: Capsule())

                    Spacer()

                    // Search button
                    Button {
                        showSearch.toggle()
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.body.weight(.medium))
                            .foregroundStyle(SteddiTheme.accent)
                            .padding(10)
                            .background(SteddiTheme.surfacePrimary.opacity(0.88), in: Circle())
                    }

                    Spacer()

                    Button("Save") { save() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(selectedCoordinate != nil ? SteddiTheme.accent : SteddiTheme.textMuted)
                        .padding(10)
                        .background(SteddiTheme.surfacePrimary.opacity(0.88), in: Capsule())
                        .disabled(selectedCoordinate == nil)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // Search overlay
                if showSearch {
                    searchOverlay
                }

                // Tap hint
                if selectedCoordinate == nil && !showSearch {
                    Text("Tap the map to place a no-go zone")
                        .font(SteddiTheme.body(14))
                        .foregroundStyle(SteddiTheme.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(SteddiTheme.surfacePrimary.opacity(0.88), in: Capsule())
                        .padding(.top, 12)
                }

                Spacer()

                // Zoom buttons
                VStack(spacing: 8) {
                    Button {
                        guard let mv = mapViewRef else { return }
                        let zoom = min(mv.mapboxMap.cameraState.zoom + 1, 20)
                        mv.camera.ease(to: CameraOptions(zoom: zoom), duration: 0.3, curve: .easeOut, completion: nil)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(SteddiTheme.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(SteddiTheme.surfacePrimary.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Button {
                        guard let mv = mapViewRef else { return }
                        let zoom = max(mv.mapboxMap.cameraState.zoom - 1, 3)
                        mv.camera.ease(to: CameraOptions(zoom: zoom), duration: 0.3, curve: .easeOut, completion: nil)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(SteddiTheme.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(SteddiTheme.surfacePrimary.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 16)

                Spacer()

                // Bottom card — only shows after placing a zone
                if selectedCoordinate != nil {
                    bottomCard
                }
            }
        }
    }

    // MARK: - Search Overlay

    private var searchOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(SteddiTheme.accent)
                TextField("Search a location", text: $searchQuery)
                    .font(SteddiTheme.body(15))
                    .foregroundStyle(SteddiTheme.textPrimary)
                    .autocorrectionDisabled()
                    .onChange(of: searchQuery) { _, newValue in
                        debounceSearch(newValue)
                    }
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(SteddiTheme.textMuted)
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
                            Button {
                                selectedCoordinate = result.coordinate
                                showSearch = false
                                searchQuery = ""
                                searchResults = []
                                // Center map on selected location
                                mapViewRef?.camera.ease(
                                    to: CameraOptions(center: result.coordinate, zoom: 15),
                                    duration: 0.5, curve: .easeOut, completion: nil
                                )
                            } label: {
                                HStack {
                                    Image(systemName: "mappin")
                                        .foregroundStyle(SteddiTheme.warmRed)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.name)
                                            .font(.body)
                                            .foregroundStyle(SteddiTheme.textPrimary)
                                        if !result.address.isEmpty && result.address != result.name {
                                            Text(result.address)
                                                .font(.caption)
                                                .foregroundStyle(SteddiTheme.textSecondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
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

    // MARK: - Bottom Card

    private var bottomCard: some View {
        VStack(spacing: 14) {
            // Radius slider
            VStack(spacing: 6) {
                HStack {
                    Text("Radius")
                        .font(SteddiTheme.body(15))
                        .foregroundStyle(SteddiTheme.textPrimary)
                    Spacer()
                    Text("\(Int(radiusMeters))m")
                        .font(SteddiTheme.mono(15))
                        .foregroundStyle(SteddiTheme.textSecondary)
                }
                Slider(value: $radiusMeters, in: 100...2000, step: 50)
                    .tint(SteddiTheme.warmRed)
            }

            // Name field
            TextField("Zone name (optional)", text: $name)
                .font(SteddiTheme.body(15))
                .padding(10)
                .background(SteddiTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))

            Text("Routes will avoid this area")
                .font(SteddiTheme.body(12))
                .foregroundStyle(SteddiTheme.textMuted)
        }
        .padding(16)
        .background(
            SteddiTheme.surfacePrimary.opacity(0.95)
                .shadow(color: .black.opacity(0.3), radius: 16, y: -4)
        )
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusLarge, topTrailingRadius: SteddiTheme.radiusLarge))
    }

    // MARK: - Actions

    private func save() {
        guard let coord = selectedCoordinate else { return }
        let zone = NoGoZone(
            latitude: coord.latitude,
            longitude: coord.longitude,
            radiusMeters: radiusMeters,
            name: name.isEmpty ? nil : name,
            isGlobal: true
        )
        modelContext.insert(zone)
        dismiss()
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
}

// MARK: - No-Go Zone Map

struct NoGoZoneMap: UIViewRepresentable {
    let selectedCoordinate: CLLocationCoordinate2D?
    let radiusMeters: Double
    let onTapMap: (CLLocationCoordinate2D) -> Void
    @Binding var mapViewRef: MapView?

    func makeUIView(context: Context) -> MapView {
        let mapView = MapView(frame: .zero, mapInitOptions: MapInitOptions(styleURI: .standard))
        mapView.mapboxMap.mapStyle = .standard(lightPreset: .dusk)
        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.compass.visibility = .hidden
        mapView.location.options.puckType = .puck2D(.init())
        mapView.mapboxMap.setCamera(to: CameraOptions(zoom: 14))

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tap)
        context.coordinator.mapView = mapView

        // Center on user location
        mapView.mapboxMap.onStyleLoaded.observeNext { _ in
            if let coord = mapView.location.latestLocation?.coordinate {
                mapView.mapboxMap.setCamera(to: CameraOptions(center: coord, zoom: 14))
            }
        }.store(in: &context.coordinator.cancellables)

        DispatchQueue.main.async { mapViewRef = mapView }
        return mapView
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        context.coordinator.onTapMap = onTapMap

        // Remove previous zone circle
        try? mapView.mapboxMap.removeLayer(withId: "nogo-fill")
        try? mapView.mapboxMap.removeLayer(withId: "nogo-outline")
        try? mapView.mapboxMap.removeSource(withId: "nogo-source")

        guard let coord = selectedCoordinate else { return }

        // Draw the no-go zone as a circle polygon
        let circleCoords = makeCircle(center: coord, radiusMeters: radiusMeters, points: 64)

        var source = GeoJSONSource(id: "nogo-source")
        source.data = .geometry(.polygon(Polygon([circleCoords])))

        // Red semi-transparent fill
        var fill = FillLayer(id: "nogo-fill", source: "nogo-source")
        fill.slot = .top
        fill.fillColor = .constant(StyleColor(UIColor(red: 0.91, green: 0.30, blue: 0.24, alpha: 0.2)))
        fill.fillEmissiveStrength = .constant(1.0)

        // Red outline
        var outline = LineLayer(id: "nogo-outline", source: "nogo-source")
        outline.slot = .top
        outline.lineColor = .constant(StyleColor(UIColor(red: 0.91, green: 0.30, blue: 0.24, alpha: 0.8)))
        outline.lineWidth = .constant(2)
        outline.lineEmissiveStrength = .constant(1.0)

        try? mapView.mapboxMap.addSource(source)
        try? mapView.mapboxMap.addLayer(fill)
        try? mapView.mapboxMap.addLayer(outline)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Generate circle coordinates around a center point
    private func makeCircle(center: CLLocationCoordinate2D, radiusMeters: Double, points: Int) -> [CLLocationCoordinate2D] {
        let R = 6371000.0
        let d = radiusMeters / R
        let lat = center.latitude * .pi / 180
        let lng = center.longitude * .pi / 180

        var coords: [CLLocationCoordinate2D] = []
        for i in 0...points {
            let angle = Double(i) / Double(points) * 2 * .pi
            let pLat = asin(sin(lat) * cos(d) + cos(lat) * sin(d) * cos(angle))
            let pLng = lng + atan2(sin(angle) * sin(d) * cos(lat), cos(d) - sin(lat) * sin(pLat))
            coords.append(CLLocationCoordinate2D(latitude: pLat * 180 / .pi, longitude: pLng * 180 / .pi))
        }
        return coords
    }

    class Coordinator: NSObject {
        weak var mapView: MapView?
        var onTapMap: ((CLLocationCoordinate2D) -> Void)?
        var cancellables: [AnyCancelable] = []

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView, gesture.state == .ended else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.mapboxMap.coordinate(for: point)
            onTapMap?(coord)
        }
    }
}
