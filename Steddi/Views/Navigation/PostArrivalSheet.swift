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

    // Road-condition report step (optional, skippable, never nags).
    @State private var reportSectionExpanded = false
    @State private var selectedConditionKind: RoadConditionKind?
    @State private var pinnedConditionCoordinate: CLLocationCoordinate2D?

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
            // Map preview. Becomes tap-to-pin while reporting a condition so the
            // user can drop the exact spot; otherwise it stays read-only.
            RoutePreviewMap(
                coordinates: matched.coordinates,
                pinnedCoordinate: selectedConditionKind == nil ? nil : pinnedConditionCoordinate,
                pinIcon: selectedConditionKind?.icon,
                allowsTapToPin: selectedConditionKind != nil,
                onTap: { coordinate in pinnedConditionCoordinate = coordinate }
            )
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

            conditionReportSection
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

    // MARK: - Condition Report Step

    /// Collapsible "anything to report?" section. Collapsed by default with no
    /// pre-selection, so the primary save flow is untouched unless the user opts
    /// in. Tapping a chip toggles selection; tapping it again clears it.
    private var conditionReportSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    reportSectionExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.bubble")
                        .font(.caption)
                        .foregroundStyle(SteddiTheme.accent)
                    Text("Anything to report about this drive?")
                        .font(SteddiTheme.body(14))
                        .foregroundStyle(SteddiTheme.textSecondary)
                    Spacer()
                    Image(systemName: reportSectionExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(SteddiTheme.textMuted)
                }
            }

            if reportSectionExpanded {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(RoadConditionKind.allCases) { kind in
                        conditionChip(kind)
                    }
                }
                .padding(.top, 12)

                if selectedConditionKind != nil {
                    Text(pinnedConditionCoordinate == nil
                         ? "Tap the map to pin the spot (optional)"
                         : "Pinned — tap again to adjust")
                        .font(SteddiTheme.body(12))
                        .foregroundStyle(SteddiTheme.textMuted)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func conditionChip(_ kind: RoadConditionKind) -> some View {
        let isSelected = selectedConditionKind == kind
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isSelected {
                    selectedConditionKind = nil
                    pinnedConditionCoordinate = nil
                } else {
                    selectedConditionKind = kind
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: kind.icon)
                    .font(.caption)
                Text(kind.displayName)
                    .font(SteddiTheme.body(13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .foregroundStyle(isSelected ? .white : SteddiTheme.textSecondary)
            .background(
                isSelected ? kind.color : SteddiTheme.surfaceSecondary,
                in: RoundedRectangle(cornerRadius: 10)
            )
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
        record.finalizeSummary()
        modelContext.insert(record)

        try? modelContext.save()

        // Opportunistically capture a reported condition, tied to the saved
        // route. Falls back to the route's midpoint when the user didn't pin a
        // spot. Uses the sheet's modelContext directly so it lands in the same
        // store as the route we just saved.
        if let kind = selectedConditionKind {
            let coordinate = pinnedConditionCoordinate
                ?? Self.midpoint(of: matched.coordinates)
                ?? matched.coordinates.first
            if let coordinate {
                let condition = RoadCondition(kind: kind, coordinate: coordinate, route: route)
                modelContext.insert(condition)
                if route.roadConditions == nil { route.roadConditions = [] }
                route.roadConditions?.append(condition)
                try? modelContext.save()
            }
        }

        isSaving = false
        dismiss()
    }

    /// Geometric midpoint of a polyline (the middle vertex) — a reasonable
    /// default pin when the user reports a condition without tapping the map.
    private static func midpoint(of coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard !coordinates.isEmpty else { return nil }
        return coordinates[coordinates.count / 2]
    }
}

// MARK: - Route Preview Map (read-only)

private struct RoutePreviewMap: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]
    /// Pin to render for a reported condition, if any.
    var pinnedCoordinate: CLLocationCoordinate2D? = nil
    /// SF Symbol shown on the pin glyph.
    var pinIcon: String? = nil
    /// When true a tap on the map drops/moves the condition pin.
    var allowsTapToPin: Bool = false
    var onTap: ((CLLocationCoordinate2D) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

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

        // Tap-to-pin recognizer; enabled/disabled in updateUIView per state.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        context.coordinator.mapView = mapView
        context.coordinator.tapRecognizer = tap
        mapView.addGestureRecognizer(tap)

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
        context.coordinator.onTap = onTap
        context.coordinator.tapRecognizer?.isEnabled = allowsTapToPin

        // Draw the route once.
        if !coordinates.isEmpty, !context.coordinator.didAddRoute {
            context.coordinator.didAddRoute = true
            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            mapView.addOverlay(polyline, level: .aboveRoads)
            mapView.setVisibleMapRect(
                polyline.boundingMapRect,
                edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
                animated: false
            )
        }

        // Sync the condition pin annotation with current state.
        syncPin(on: mapView, context: context)
    }

    private func syncPin(on mapView: MKMapView, context: Context) {
        let existing = mapView.annotations.compactMap { $0 as? ConditionPinAnnotation }
        guard let pinnedCoordinate else {
            mapView.removeAnnotations(existing)
            return
        }
        // Reuse the existing annotation, just move it, to avoid a flash.
        if let annotation = existing.first {
            if annotation.coordinate.latitude != pinnedCoordinate.latitude
                || annotation.coordinate.longitude != pinnedCoordinate.longitude {
                annotation.coordinate = pinnedCoordinate
            }
            annotation.iconName = pinIcon
            mapView.removeAnnotations(Array(existing.dropFirst()))
        } else {
            let annotation = ConditionPinAnnotation()
            annotation.coordinate = pinnedCoordinate
            annotation.iconName = pinIcon
            mapView.addAnnotation(annotation)
        }
    }

    final class ConditionPinAnnotation: NSObject, MKAnnotation {
        @objc dynamic var coordinate = CLLocationCoordinate2D()
        var iconName: String?
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var didAddRoute = false
        weak var mapView: MKMapView?
        weak var tapRecognizer: UITapGestureRecognizer?
        var onTap: ((CLLocationCoordinate2D) -> Void)?

        init(onTap: ((CLLocationCoordinate2D) -> Void)?) {
            self.onTap = onTap
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let mapView else { return }
            let point = recognizer.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            onTap?(coordinate)
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
            guard let pin = annotation as? ConditionPinAnnotation else { return nil }
            let id = "conditionPin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: pin, reuseIdentifier: id)
            view.annotation = pin
            view.markerTintColor = UIColor(red: 0.91, green: 0.30, blue: 0.24, alpha: 1.0) // SteddiTheme.warmRed
            view.glyphImage = pin.iconName.flatMap { UIImage(systemName: $0) }
            return view
        }
    }
}
