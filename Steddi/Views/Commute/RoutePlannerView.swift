import SwiftUI
import SwiftData
import MapboxMaps
import MapboxNavigationCore
import MapboxDirections
import CoreLocation

/// Full-screen route planner — map takes priority, details in a bottom card.
struct RoutePlannerView: View {
    let commute: Commute
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var direction: CommuteDirection = .originToDestination
    @State private var routeName = ""
    @State private var isCalculating = false
    @State private var calculatedPolyline: String?
    @State private var calculatedDistance: Double?
    @State private var calculatedDuration: Double?
    @State private var saveAsPreferred = true
    @State private var showDetails = false
    @State private var waypoints: [CLLocationCoordinate2D] = []
    @State private var plannerMapView: MapView?

    private var originLocation: PinnedLocation? {
        direction == .originToDestination ? commute.origin : commute.destination
    }

    private var destLocation: PinnedLocation? {
        direction == .originToDestination ? commute.destination : commute.origin
    }

    var body: some View {
        ZStack {
            // Full-screen map
            RoutePlannerMap(
                origin: originLocation?.coordinate,
                destination: destLocation?.coordinate,
                waypoints: waypoints,
                polyline: calculatedPolyline,
                onTapMap: { coord in
                    waypoints.append(coord)
                    Task { await calculateRoute() }
                },
                mapViewRef: $plannerMapView
            )
            .ignoresSafeArea()

            // Zoom buttons — right side
            VStack(spacing: 8) {
                Button {
                    guard let mv = plannerMapView else { return }
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
                    guard let mv = plannerMapView else { return }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 16)
            .padding(.top, 180)

            // Top bar
            VStack {
                HStack {
                    Button("Cancel") { dismiss() }
                        .font(.body.weight(.medium))
                        .foregroundStyle(SteddiTheme.textPrimary)
                        .padding(10)
                        .background(SteddiTheme.surfacePrimary.opacity(0.85), in: Capsule())

                    Spacer()

                    // Direction toggle
                    Button {
                        direction = direction == .originToDestination ? .destinationToOrigin : .originToDestination
                        waypoints = []
                        Task { await calculateRoute() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.caption)
                            Text(direction == .originToDestination
                                 ? "\(commute.origin?.name ?? "A") → \(commute.destination?.name ?? "B")"
                                 : "\(commute.destination?.name ?? "B") → \(commute.origin?.name ?? "A")")
                                .font(SteddiTheme.body(13))
                                .lineLimit(1)
                        }
                        .foregroundStyle(SteddiTheme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(SteddiTheme.surfacePrimary.opacity(0.85), in: Capsule())
                    }

                    Spacer()

                    Button("Save") { saveRoute() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(calculatedPolyline != nil ? SteddiTheme.accent : SteddiTheme.textMuted)
                        .padding(10)
                        .background(SteddiTheme.surfacePrimary.opacity(0.85), in: Capsule())
                        .disabled(calculatedPolyline == nil)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                // Bottom card
                bottomCard
            }

            // Loading overlay
            if isCalculating {
                ProgressView()
                    .tint(SteddiTheme.accent)
                    .scaleEffect(x: 1.2, y: 1.2)
                    .frame(width: 56, height: 56)
                    .background(SteddiTheme.surfacePrimary.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .task { await calculateRoute() }
    }

    // MARK: - Bottom Card

    private var bottomCard: some View {
        VStack(spacing: 12) {
            // Stats row
            if let dist = calculatedDistance, let dur = calculatedDuration {
                HStack(spacing: 24) {
                    HStack(spacing: 6) {
                        Image(systemName: "road.lanes")
                            .font(.caption)
                            .foregroundStyle(SteddiTheme.accent)
                        Text(String(format: "%.1f mi", dist / 1609.34))
                            .font(SteddiTheme.mono(16))
                            .foregroundStyle(SteddiTheme.textPrimary)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.caption)
                            .foregroundStyle(SteddiTheme.accent)
                        Text("\(Int(ceil(dur / 60))) min")
                            .font(SteddiTheme.mono(16))
                            .foregroundStyle(SteddiTheme.textPrimary)
                    }

                    Spacer()

                    // Waypoint count
                    if !waypoints.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.caption2)
                            Text("\(waypoints.count) waypoint\(waypoints.count == 1 ? "" : "s")")
                                .font(SteddiTheme.body(12))
                        }
                        .foregroundStyle(SteddiTheme.textMuted)
                    }
                }
            }

            // Tap hint
            if waypoints.isEmpty && calculatedPolyline != nil {
                Text("Tap the map to add waypoints and shape your route")
                    .font(SteddiTheme.body(13))
                    .foregroundStyle(SteddiTheme.textMuted)
            }

            // Expandable details
            if showDetails {
                VStack(spacing: 10) {
                    TextField("Route name (optional)", text: $routeName)
                        .font(SteddiTheme.body(15))
                        .padding(10)
                        .background(SteddiTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))

                    HStack {
                        Text("Set as preferred")
                            .font(SteddiTheme.body(15))
                            .foregroundStyle(SteddiTheme.textPrimary)
                        Spacer()
                        Toggle("", isOn: $saveAsPreferred)
                            .tint(SteddiTheme.accent)
                            .labelsHidden()
                    }
                }
            }

            // Toggle details / undo waypoints
            HStack {
                if !waypoints.isEmpty {
                    Button {
                        waypoints.removeLast()
                        Task { await calculateRoute() }
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(SteddiTheme.body(13))
                            .foregroundStyle(SteddiTheme.textSecondary)
                    }
                }

                Spacer()

                Button {
                    showDetails.toggle()
                } label: {
                    Text(showDetails ? "Less" : "More options")
                        .font(SteddiTheme.body(13))
                        .foregroundStyle(SteddiTheme.accent)
                }
            }
        }
        .padding(16)
        .background(
            SteddiTheme.surfacePrimary.opacity(0.95)
                .shadow(color: .black.opacity(0.3), radius: 16, y: -4)
        )
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusLarge, topTrailingRadius: SteddiTheme.radiusLarge))
    }

    // MARK: - Calculate Route

    private func calculateRoute() async {
        guard let origin = originLocation, let dest = destLocation else { return }

        isCalculating = true

        let service = DirectionsService(accessToken: MapboxTokenProvider.accessToken)

        // Build waypoints list: origin + user waypoints + destination
        var allPoints = [origin.coordinate] + waypoints + [dest.coordinate]

        do {
            // If we have waypoints, we need to route through them
            // For simplicity, chain origin → wp1 → wp2 → ... → destination
            if waypoints.isEmpty {
                let route = try await service.fetchRoute(from: origin.coordinate, to: dest.coordinate)
                calculatedPolyline = route.encodedPolyline
                calculatedDistance = route.distanceMeters
                calculatedDuration = route.durationSeconds
            } else {
                // Multi-waypoint: build coordinate string and hit API directly
                let coords = allPoints.map { "\($0.longitude),\($0.latitude)" }.joined(separator: ";")

                var components = URLComponents(string: "https://api.mapbox.com/directions/v5/mapbox/driving-traffic/\(coords)")!
                components.queryItems = [
                    URLQueryItem(name: "access_token", value: MapboxTokenProvider.accessToken),
                    URLQueryItem(name: "geometries", value: "polyline6"),
                    URLQueryItem(name: "overview", value: "full"),
                ]

                let (data, response) = try await URLSession.shared.data(from: components.url!)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    isCalculating = false
                    return
                }

                struct DirResponse: Decodable {
                    let routes: [DirRoute]
                    struct DirRoute: Decodable {
                        let geometry: String
                        let distance: Double
                        let duration: Double
                    }
                }

                let result = try JSONDecoder().decode(DirResponse.self, from: data)
                if let route = result.routes.first {
                    calculatedPolyline = route.geometry
                    calculatedDistance = route.distance
                    calculatedDuration = route.duration
                }
            }
        } catch {}

        isCalculating = false
    }

    // MARK: - Save

    private func saveRoute() {
        guard let polyline = calculatedPolyline else { return }

        let existingRoutes = commute.orderedRoutes(for: direction)
        let rank: Int

        if saveAsPreferred {
            for route in existingRoutes { route.rank += 1 }
            rank = 0
        } else {
            rank = existingRoutes.count
        }

        let route = Route(
            rank: rank,
            encodedPolyline: polyline,
            name: routeName.isEmpty ? nil : routeName,
            distanceMeters: calculatedDistance,
            typicalDurationSeconds: calculatedDuration,
            source: .planned,
            direction: direction
        )
        route.commute = commute
        if commute.routes == nil { commute.routes = [] }
        commute.routes?.append(route)
        modelContext.insert(route)
        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Route Planner Map

struct RoutePlannerMap: UIViewRepresentable {
    let origin: CLLocationCoordinate2D?
    let destination: CLLocationCoordinate2D?
    let waypoints: [CLLocationCoordinate2D]
    let polyline: String?
    let onTapMap: (CLLocationCoordinate2D) -> Void
    @Binding var mapViewRef: MapView?
    /// Only fit camera on first route load, not on waypoint updates
    private var shouldFitCamera: Bool { waypoints.isEmpty }

    func makeUIView(context: Context) -> MapView {
        let mapView = MapView(frame: .zero, mapInitOptions: MapInitOptions(styleURI: .standard))
        mapView.mapboxMap.mapStyle = .standard(lightPreset: .dusk)
        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.compass.visibility = .hidden

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tap)
        context.coordinator.mapView = mapView

        DispatchQueue.main.async { mapViewRef = mapView }

        return mapView
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        context.coordinator.onTapMap = onTapMap

        // Clean previous
        try? mapView.mapboxMap.removeLayer(withId: "planner-route")
        try? mapView.mapboxMap.removeSource(withId: "planner-source")
        try? mapView.mapboxMap.removeLayer(withId: "planner-points")
        try? mapView.mapboxMap.removeSource(withId: "planner-points-source")

        // Draw route
        if let polyline {
            let coords = PolylineEncoder.decode(polyline, precision: 6)
            guard !coords.isEmpty else { return }

            var source = GeoJSONSource(id: "planner-source")
            source.data = .geometry(.lineString(LineString(coords)))

            var layer = LineLayer(id: "planner-route", source: "planner-source")
            layer.slot = .top
            layer.lineColor = .constant(StyleColor(UIColor(red: 0.61, green: 0.56, blue: 0.77, alpha: 1.0)))
            layer.lineWidth = .constant(6)
            layer.lineOpacity = .constant(1.0)
            layer.lineEmissiveStrength = .constant(1.0)
            layer.lineCap = .constant(.round)
            layer.lineJoin = .constant(.round)

            try? mapView.mapboxMap.addSource(source)
            try? mapView.mapboxMap.addLayer(layer)

            // Only fit camera on initial route, not after adding waypoints
            if shouldFitCamera {
                let camera = mapView.mapboxMap.camera(
                    for: .lineString(LineString(coords)),
                    padding: UIEdgeInsets(top: 80, left: 40, bottom: 200, right: 40),
                    bearing: nil,
                    pitch: nil
                )
                mapView.mapboxMap.setCamera(to: camera)
            }
        } else if let origin, shouldFitCamera {
            mapView.mapboxMap.setCamera(to: CameraOptions(center: origin, zoom: 12))
        }

        // Draw waypoint markers
        if !waypoints.isEmpty {
            let points = waypoints.map { Point($0) }
            let features = points.enumerated().map { (i, pt) -> Feature in
                var f = Feature(geometry: .point(pt))
                f.properties = ["index": .number(Double(i + 1))]
                return f
            }

            var source = GeoJSONSource(id: "planner-points-source")
            source.data = .featureCollection(FeatureCollection(features: features))

            var layer = CircleLayer(id: "planner-points", source: "planner-points-source")
            layer.slot = .top
            layer.circleColor = .constant(StyleColor(UIColor(red: 0.61, green: 0.56, blue: 0.77, alpha: 1.0)))
            layer.circleRadius = .constant(8)
            layer.circleStrokeColor = .constant(StyleColor(.white))
            layer.circleStrokeWidth = .constant(2)
            layer.circleEmissiveStrength = .constant(1.0)

            try? mapView.mapboxMap.addSource(source)
            try? mapView.mapboxMap.addLayer(layer)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject {
        weak var mapView: MapView?
        var onTapMap: ((CLLocationCoordinate2D) -> Void)?

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView, gesture.state == .ended else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.mapboxMap.coordinate(for: point)
            onTapMap?(coord)
        }
    }
}
