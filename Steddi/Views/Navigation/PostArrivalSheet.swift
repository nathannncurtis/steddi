import SwiftUI
import SwiftData
import MapboxMaps
import CoreLocation

struct PostArrivalSheet: View {
    let recordedPoints: [GPSPoint]
    let commute: Commute?
    let direction: CommuteDirection?
    let onEditRoute: () -> Void
    /// Pre-matched polyline for testing — skips Map Matching API call
    var preMatchedPolyline: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("accentColor") private var accentColor = "lavender"

    @State private var isMatching = true
    @State private var matchedRoute: MatchedRoute?
    @State private var matchError = false
    @State private var routeName = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isMatching {
                    matchingState
                } else if let matched = matchedRoute {
                    reviewState(matched)
                } else {
                    errorState
                }
            }
            .background(SteddiTheme.surfacePrimary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") { dismiss() }
                        .foregroundStyle(SteddiTheme.textMuted)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await matchTrace() }
    }

    // MARK: - Loading State

    private var matchingState: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .tint(SteddiTheme.accent)
                .scaleEffect(x: 1.5, y: 1.5)
            Text("Cleaning up your route...")
                .font(SteddiTheme.heading(16))
                .foregroundStyle(SteddiTheme.textPrimary)
            Text("Snapping GPS trace to roads")
                .font(SteddiTheme.body(14))
                .foregroundStyle(SteddiTheme.textMuted)
            Spacer()
        }
    }

    // MARK: - Review State (matched route)

    private func reviewState(_ matched: MatchedRoute) -> some View {
        VStack(spacing: 0) {
            // Map preview
            RoutePreviewMap(coordinates: matched.coordinates)
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium))
                .padding(.horizontal, 16)
                .padding(.top, 12)

            // Stats
            HStack(spacing: 24) {
                HStack(spacing: 6) {
                    Image(systemName: "road.lanes")
                        .font(.caption)
                        .foregroundStyle(SteddiTheme.accent)
                    Text(String(format: "%.1f mi", matched.distanceMeters / 1609.34))
                        .font(SteddiTheme.mono(16))
                        .foregroundStyle(SteddiTheme.textPrimary)
                }

                if let commuteName = commute?.name {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.caption)
                            .foregroundStyle(SteddiTheme.accent)
                        Text(commuteName)
                            .font(SteddiTheme.body(14))
                            .foregroundStyle(SteddiTheme.textSecondary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // Route name field
            TextField("Route name (optional)", text: $routeName)
                .font(SteddiTheme.body(15))
                .padding(12)
                .background(SteddiTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.top, 12)

            Spacer()

            // Action buttons
            VStack(spacing: 10) {
                Button {
                    Task { await saveRoute(matched) }
                } label: {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    } else {
                        Text("Looks good — save it")
                            .font(SteddiTheme.heading(16))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                }
                .background(SteddiTheme.accent, in: RoundedRectangle(cornerRadius: 14))
                .disabled(isSaving)

                Button {
                    dismiss()
                    // Small delay so sheet dismisses before presenting planner
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        onEditRoute()
                    }
                } label: {
                    Text("Not quite — let me plan it")
                        .font(SteddiTheme.body(15))
                        .foregroundStyle(SteddiTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Error State

    private var errorState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(SteddiTheme.warmRed)
            Text("Couldn't match your route")
                .font(SteddiTheme.heading(16))
                .foregroundStyle(SteddiTheme.textPrimary)
            Text("The GPS trace couldn't be snapped to roads. Try planning the route manually instead.")
                .font(SteddiTheme.body(14))
                .foregroundStyle(SteddiTheme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()

            VStack(spacing: 10) {
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        onEditRoute()
                    }
                } label: {
                    Text("Plan it manually")
                        .font(SteddiTheme.heading(16))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .background(SteddiTheme.accent, in: RoundedRectangle(cornerRadius: 14))

                Button("Discard") { dismiss() }
                    .font(SteddiTheme.body(15))
                    .foregroundStyle(SteddiTheme.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Map Matching

    private func matchTrace() async {
        // If pre-matched polyline provided (testing), skip API call
        if let polyline = preMatchedPolyline {
            let coords = PolylineEncoder.decode(polyline, precision: 6)
            let distance = zip(coords, coords.dropFirst()).reduce(0.0) { sum, pair in
                sum + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                    .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
            }
            self.matchedRoute = MatchedRoute(encodedPolyline: polyline, coordinates: coords, distanceMeters: distance)
            isMatching = false
            return
        }

        let service = MapMatchingService(accessToken: MapboxTokenProvider.accessToken)

        do {
            let matched = try await service.matchTrace(recordedPoints)
            self.matchedRoute = matched
        } catch {
            self.matchError = true
        }

        isMatching = false
    }

    // MARK: - Save Route

    private func saveRoute(_ matched: MatchedRoute) async {
        isSaving = true

        let rank: Int
        if let commute, let direction {
            // Set as preferred — bump existing routes
            let existingRoutes = commute.orderedRoutes(for: direction)
            for route in existingRoutes { route.rank += 1 }
            rank = 0
        } else {
            rank = 0
        }

        let route = Route(
            rank: rank,
            encodedPolyline: matched.encodedPolyline,
            name: routeName.isEmpty ? nil : routeName,
            distanceMeters: matched.distanceMeters,
            source: .recorded,
            direction: direction ?? .originToDestination
        )

        if let commute {
            route.commute = commute
            if commute.routes == nil { commute.routes = [] }
            commute.routes?.append(route)
        }

        modelContext.insert(route)

        // Save drive record with matched polyline
        let record = DriveRecord()
        record.rawGPSPoints = recordedPoints
        record.matchedPolyline = matched.encodedPolyline
        record.associatedCommute = commute
        record.wasConverted = true
        record.endedAt = Date()
        modelContext.insert(record)

        try? modelContext.save()
        isSaving = false
        dismiss()
    }
}

// MARK: - Route Preview Map (read-only)

private struct RoutePreviewMap: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MapView {
        let mapView = MapView(frame: .zero, mapInitOptions: MapInitOptions(styleURI: .standard))
        mapView.mapboxMap.mapStyle = .standard(lightPreset: .dusk)
        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.compass.visibility = .hidden
        mapView.gestures.options.panEnabled = false
        mapView.gestures.options.pinchEnabled = false
        mapView.gestures.options.rotateEnabled = false
        mapView.gestures.options.pitchEnabled = false
        mapView.gestures.options.doubleTapToZoomInEnabled = false
        mapView.gestures.options.doubleTouchToZoomOutEnabled = false

        context.coordinator.mapView = mapView

        // Wait for style to load before adding route
        mapView.mapboxMap.onStyleLoaded.observeNext { [weak mapView] _ in
            guard let mapView else { return }
            context.coordinator.addRoute(to: mapView, coordinates: coordinates)
        }.store(in: &context.coordinator.cancellables)

        return mapView
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        context.coordinator.pendingCoordinates = coordinates
    }

    class Coordinator {
        weak var mapView: MapView?
        var cancellables: [AnyCancelable] = []
        var pendingCoordinates: [CLLocationCoordinate2D] = []
        var didAddRoute = false

        func addRoute(to mapView: MapView, coordinates: [CLLocationCoordinate2D]) {
            guard !coordinates.isEmpty, !didAddRoute else { return }
            didAddRoute = true

            var source = GeoJSONSource(id: "preview-source")
            source.data = .geometry(.lineString(LineString(coordinates)))

            var layer = LineLayer(id: "preview-route", source: "preview-source")
            layer.slot = .top
            layer.lineColor = .constant(StyleColor(SteddiTheme.accentUIColor))
            layer.lineWidth = .constant(6)
            layer.lineOpacity = .constant(1.0)
            layer.lineEmissiveStrength = .constant(1.0)
            layer.lineCap = .constant(.round)
            layer.lineJoin = .constant(.round)

            try? mapView.mapboxMap.addSource(source)
            try? mapView.mapboxMap.addLayer(layer)

            let camera = mapView.mapboxMap.camera(
                for: .lineString(LineString(coordinates)),
                padding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
                bearing: nil,
                pitch: nil
            )
            mapView.mapboxMap.setCamera(to: camera)
        }
    }
}
