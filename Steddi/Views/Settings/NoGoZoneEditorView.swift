import SwiftUI
import SwiftData
import MapKit
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
    @State private var mapViewRef: MKMapView?

    // Search
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var searchResults: [GeocodingResult] = []
    @State private var searchTask: Task<Void, Never>?

    private let geocodingService = GeocodingService()

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
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
                        var region = mv.region
                        region.span.latitudeDelta /= 2
                        region.span.longitudeDelta /= 2
                        mv.setRegion(region, animated: true)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(SteddiTheme.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(SteddiTheme.surfacePrimary.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Button {
                        guard let mv = mapViewRef else { return }
                        var region = mv.region
                        region.span.latitudeDelta = min(region.span.latitudeDelta * 2, 180)
                        region.span.longitudeDelta = min(region.span.longitudeDelta * 2, 360)
                        mv.setRegion(region, animated: true)
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
                                if let mv = mapViewRef {
                                    let region = MKCoordinateRegion(center: result.coordinate, latitudinalMeters: 2000, longitudinalMeters: 2000)
                                    mv.setRegion(region, animated: true)
                                }
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
    @Binding var mapViewRef: MKMapView?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.overrideUserInterfaceStyle = SteddiTheme.currentThemeMode.mapInterfaceStyle
        mapView.delegate = context.coordinator

        let config = MKStandardMapConfiguration(emphasisStyle: .muted)
        mapView.preferredConfiguration = config

        mapView.showsUserLocation = true
        mapView.showsCompass = false
        mapView.showsScale = false

        let region = MKCoordinateRegion(
            center: mapView.userLocation.coordinate.latitude != 0
                ? mapView.userLocation.coordinate
                : CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            latitudinalMeters: 5000,
            longitudinalMeters: 5000
        )
        mapView.setRegion(region, animated: false)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tap)
        context.coordinator.mapView = mapView

        DispatchQueue.main.async { mapViewRef = mapView }
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.onTapMap = onTapMap

        // Remove previous zone circle overlay
        mapView.removeOverlays(mapView.overlays)

        guard let coord = selectedCoordinate else { return }

        // Draw the no-go zone as an MKCircle
        let circle = MKCircle(center: coord, radius: radiusMeters)
        mapView.addOverlay(circle, level: .aboveRoads)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MKMapViewDelegate {
        weak var mapView: MKMapView?
        var onTapMap: ((CLLocationCoordinate2D) -> Void)?

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView, gesture.state == .ended else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            onTapMap?(coord)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = UIColor(red: 0.91, green: 0.30, blue: 0.24, alpha: 0.2)
                renderer.strokeColor = UIColor(red: 0.91, green: 0.30, blue: 0.24, alpha: 0.8)
                renderer.lineWidth = 2
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
