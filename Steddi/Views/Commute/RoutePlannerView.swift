import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// Full-screen route planner — map takes priority, details in a bottom card.
struct RoutePlannerView: View {
    let commute: Commute
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("accentColor") private var accentColor = "lavender"

    @State private var direction: CommuteDirection = .originToDestination
    @State private var routeName = ""
    @State private var isCalculating = false
    @State private var calculatedPolyline: String?
    @State private var calculatedDistance: Double?
    @State private var calculatedDuration: Double?
    @State private var calculatedSteps: [DirectionsStep] = []
    @State private var saveAsPreferred = true
    @State private var showDetails = false
    @State private var waypoints: [CLLocationCoordinate2D] = []
    @State private var plannerMapView: MKMapView?

    private var originLocation: PinnedLocation? {
        direction == .originToDestination ? commute.origin : commute.destination
    }

    private var destLocation: PinnedLocation? {
        direction == .originToDestination ? commute.destination : commute.origin
    }

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
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
                    guard let mv = plannerMapView else { return }
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

        let service = DirectionsService()

        // Build waypoints list: origin + user waypoints + destination
        let allPoints = [origin.coordinate] + waypoints + [dest.coordinate]

        do {
            // If we have waypoints, we need to route through them
            // For simplicity, chain origin → wp1 → wp2 → ... → destination
            if waypoints.isEmpty {
                let route = try await service.fetchRoute(from: origin.coordinate, to: dest.coordinate)
                calculatedPolyline = route.encodedPolyline
                calculatedDistance = route.distance
                calculatedDuration = route.duration
                calculatedSteps = route.legs.flatMap { $0.steps }
            } else {
                // Multi-waypoint: chain sequential MKDirections requests and stitch
                var allCoords: [CLLocationCoordinate2D] = []
                var allSteps: [DirectionsStep] = []
                var totalDistance: Double = 0
                var totalDuration: Double = 0

                for i in 0..<(allPoints.count - 1) {
                    let segRoute = try await service.fetchRoute(from: allPoints[i], to: allPoints[i + 1])
                    let segCoords = PolylineEncoder.decode(segRoute.encodedPolyline, precision: 6)
                    if !allCoords.isEmpty && !segCoords.isEmpty {
                        allCoords.append(contentsOf: segCoords.dropFirst())
                    } else {
                        allCoords.append(contentsOf: segCoords)
                    }
                    allSteps.append(contentsOf: segRoute.legs.flatMap { $0.steps })
                    totalDistance += segRoute.distance
                    totalDuration += segRoute.duration
                }

                calculatedPolyline = PolylineEncoder.encode(allCoords, precision: 6)
                calculatedDistance = totalDistance
                calculatedDuration = totalDuration
                calculatedSteps = allSteps
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
        route.encodedSteps = Route.encodeSteps(calculatedSteps)
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
    @Binding var mapViewRef: MKMapView?
    /// Only fit camera on first route load, not on waypoint updates
    private var shouldFitCamera: Bool { waypoints.isEmpty }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.overrideUserInterfaceStyle = SteddiTheme.currentThemeMode.mapInterfaceStyle
        mapView.delegate = context.coordinator

        mapView.preferredConfiguration = SteddiTheme.mapConfiguration(traffic: false)

        mapView.showsCompass = false
        mapView.showsScale = false

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tap)
        context.coordinator.mapView = mapView

        DispatchQueue.main.async { mapViewRef = mapView }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.onTapMap = onTapMap

        // Clean previous overlays and annotations
        mapView.removeOverlays(mapView.overlays)
        let waypointAnnotations = mapView.annotations.filter { $0 is WaypointAnnotation }
        mapView.removeAnnotations(waypointAnnotations)

        // Draw route
        if let polyline {
            let coords = PolylineEncoder.decode(polyline, precision: 6)
            guard !coords.isEmpty else { return }

            let overlay = MKPolyline(coordinates: coords, count: coords.count)
            mapView.addOverlay(overlay, level: .aboveRoads)

            // Only fit camera on initial route, not after adding waypoints
            if shouldFitCamera {
                let padding = UIEdgeInsets(top: 80, left: 40, bottom: 200, right: 40)
                mapView.setVisibleMapRect(overlay.boundingMapRect, edgePadding: padding, animated: false)
            }
        } else if let origin, shouldFitCamera {
            let region = MKCoordinateRegion(center: origin, latitudinalMeters: 5000, longitudinalMeters: 5000)
            mapView.setRegion(region, animated: false)
        }

        // Draw waypoint markers
        for (i, coord) in waypoints.enumerated() {
            let annotation = WaypointAnnotation()
            annotation.coordinate = coord
            annotation.title = "\(i + 1)"
            mapView.addAnnotation(annotation)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class WaypointAnnotation: MKPointAnnotation {}

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
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = SteddiTheme.accentUIColor
                renderer.lineWidth = 6
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let waypoint = annotation as? WaypointAnnotation else { return nil }
            let identifier = "WaypointPin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) ?? MKAnnotationView(annotation: waypoint, reuseIdentifier: identifier)
            view.annotation = waypoint

            // Draw a colored circle
            let size: CGFloat = 20
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
            view.image = renderer.image { ctx in
                let rect = CGRect(x: 0, y: 0, width: size, height: size)
                ctx.cgContext.setFillColor(SteddiTheme.accentUIColor.cgColor)
                ctx.cgContext.fillEllipse(in: rect)
                ctx.cgContext.setStrokeColor(UIColor.white.cgColor)
                ctx.cgContext.setLineWidth(2)
                ctx.cgContext.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
            }
            view.centerOffset = .zero
            return view
        }
    }
}
