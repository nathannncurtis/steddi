import SwiftUI
import SwiftData
import MapKit
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
        let _ = accentColor // force SwiftUI re-render on accent change
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

        let service = MapMatchingService()

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

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.overrideUserInterfaceStyle = SteddiTheme.currentThemeMode.mapInterfaceStyle
        mapView.delegate = context.coordinator

        mapView.preferredConfiguration = SteddiTheme.mapConfiguration(traffic: false)

        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false

        // Add route immediately if we have coordinates
        if !coordinates.isEmpty {
            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            mapView.addOverlay(polyline, level: .aboveRoads)
            // Fit to route after layout
            DispatchQueue.main.async {
                mapView.setVisibleMapRect(
                    polyline.boundingMapRect,
                    edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
                    animated: false
                )
            }
        }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Only update if coordinates changed and we haven't drawn yet
        guard !coordinates.isEmpty, !context.coordinator.didAddRoute else { return }
        context.coordinator.didAddRoute = true

        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        mapView.addOverlay(polyline, level: .aboveRoads)
        mapView.setVisibleMapRect(
            polyline.boundingMapRect,
            edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
            animated: false
        )
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var didAddRoute = false

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
    }
}
