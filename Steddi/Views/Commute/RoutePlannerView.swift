import SwiftUI
import SwiftData
import MapboxMaps
import MapboxNavigationCore
import MapboxDirections
import CoreLocation

/// Plan a route between two endpoints of a commute.
/// Shows a map with the calculated route, lets user pick direction and save.
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
    @State private var errorMessage: String?
    @State private var saveAsPreferred = false

    private var originLocation: PinnedLocation? {
        direction == .originToDestination ? commute.origin : commute.destination
    }

    private var destLocation: PinnedLocation? {
        direction == .originToDestination ? commute.destination : commute.origin
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Direction picker
                Picker("Direction", selection: $direction) {
                    Text("\(commute.origin?.name ?? "Origin") → \(commute.destination?.name ?? "Dest")")
                        .tag(CommuteDirection.originToDestination)
                    Text("\(commute.destination?.name ?? "Dest") → \(commute.origin?.name ?? "Origin")")
                        .tag(CommuteDirection.destinationToOrigin)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .onChange(of: direction) { _, _ in
                    Task { await calculateRoute() }
                }

                // Map preview
                RoutePlannerMap(
                    origin: originLocation?.coordinate,
                    destination: destLocation?.coordinate,
                    polyline: calculatedPolyline
                )
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium))
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // Route info
                if isCalculating {
                    ProgressView("Calculating route...")
                        .padding(.top, 20)
                } else if let error = errorMessage {
                    Text(error)
                        .font(SteddiTheme.body(14))
                        .foregroundStyle(SteddiTheme.warmRed)
                        .padding(.top, 20)
                } else if calculatedPolyline != nil {
                    routeInfoSection
                }

                Spacer()
            }
            .navigationTitle("Plan Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { saveRoute() }
                        .fontWeight(.semibold)
                        .disabled(calculatedPolyline == nil)
                }
            }
            .task { await calculateRoute() }
        }
    }

    // MARK: - Route Info

    private var routeInfoSection: some View {
        VStack(spacing: 12) {
            // Stats
            HStack(spacing: 24) {
                if let dist = calculatedDistance {
                    VStack(spacing: 2) {
                        Text(String(format: "%.1f mi", dist / 1609.34))
                            .font(SteddiTheme.mono(18))
                            .foregroundStyle(SteddiTheme.textPrimary)
                        Text("Distance")
                            .font(SteddiTheme.body(12))
                            .foregroundStyle(SteddiTheme.textMuted)
                    }
                }
                if let dur = calculatedDuration {
                    VStack(spacing: 2) {
                        Text("\(Int(ceil(dur / 60))) min")
                            .font(SteddiTheme.mono(18))
                            .foregroundStyle(SteddiTheme.textPrimary)
                        Text("Typical")
                            .font(SteddiTheme.body(12))
                            .foregroundStyle(SteddiTheme.textMuted)
                    }
                }
            }
            .padding(.top, 16)

            // Name + options
            Form {
                Section {
                    TextField("Route name (optional)", text: $routeName)
                }
                Section {
                    Toggle("Set as preferred", isOn: $saveAsPreferred)
                        .tint(SteddiTheme.accent)
                } footer: {
                    Text(saveAsPreferred
                         ? "This will be the default route for this direction."
                         : "This will be added as a fallback route.")
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Calculate Route

    private func calculateRoute() async {
        guard let origin = originLocation, let dest = destLocation else {
            errorMessage = "Origin or destination not set."
            return
        }

        isCalculating = true
        errorMessage = nil

        let service = DirectionsService(accessToken: MapboxTokenProvider.accessToken)

        do {
            let route = try await service.fetchRoute(
                from: origin.coordinate,
                to: dest.coordinate
            )
            calculatedPolyline = route.encodedPolyline
            calculatedDistance = route.distanceMeters
            calculatedDuration = route.durationSeconds
        } catch {
            errorMessage = "Could not calculate route."
        }

        isCalculating = false
    }

    // MARK: - Save

    private func saveRoute() {
        guard let polyline = calculatedPolyline else { return }

        let existingRoutes = commute.orderedRoutes(for: direction)
        let rank: Int

        if saveAsPreferred {
            // Bump existing routes for this direction
            for route in existingRoutes {
                route.rank += 1
            }
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
    let polyline: String?

    func makeUIView(context: Context) -> MapView {
        let mapView = MapView(frame: .zero, mapInitOptions: MapInitOptions(styleURI: .standard))
        mapView.mapboxMap.mapStyle = .standard(lightPreset: .dusk)
        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.compass.visibility = .hidden
        // Logo and attribution are required by Mapbox TOS — keep them
        return mapView
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        // Clean up previous layers
        try? mapView.mapboxMap.removeLayer(withId: "planner-route")
        try? mapView.mapboxMap.removeSource(withId: "planner-source")

        // Draw route if available
        if let polyline, let origin, let destination {
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

            // Fit camera to route
            let camera = mapView.mapboxMap.camera(
                for: .lineString(LineString(coords)),
                padding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
                bearing: nil,
                pitch: nil
            )
            mapView.mapboxMap.setCamera(to: camera)
        } else if let origin {
            mapView.mapboxMap.setCamera(to: CameraOptions(center: origin, zoom: 12))
        }
    }
}
