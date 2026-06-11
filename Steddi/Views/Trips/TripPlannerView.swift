import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// Full-screen map-based trip creation — mirrors RoutePlannerView. Tap the
/// map to add stops in order (numbered pins); the bottom card lists the stops
/// with drag reorder, a flow-mode toggle, and route preferences.
struct TripPlannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationService.self) private var locationService
    @AppStorage("accentColor") private var accentColor = "lavender"

    /// Draft stop being assembled before save.
    struct DraftStop: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var coordinate: CLLocationCoordinate2D

        static func == (lhs: DraftStop, rhs: DraftStop) -> Bool {
            lhs.id == rhs.id
                && lhs.name == rhs.name
                && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
        }
    }

    @State private var tripName = ""
    @State private var draftStops: [DraftStop] = []
    @State private var flowMode: TripFlowMode = .continuous
    @State private var useCustomPreferences = false
    @State private var avoidsTolls = false
    @State private var avoidsHighways = false
    @State private var plannerMapView: MKMapView?

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
        ZStack {
            TripPlannerMap(
                initialCenter: locationService.currentLocation?.coordinate,
                stops: draftStops.map(\.coordinate),
                onTapMap: { coord in
                    draftStops.append(DraftStop(name: "Stop \(draftStops.count + 1)", coordinate: coord))
                },
                mapViewRef: $plannerMapView
            )
            .ignoresSafeArea()

            // Zoom buttons — right side
            VStack(spacing: 8) {
                zoomButton("plus") { zoom(factor: 0.5) }
                zoomButton("minus") { zoom(factor: 2) }
            }
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 16)
            .padding(.top, 180)

            VStack {
                // Top bar
                HStack {
                    Button("Cancel") { dismiss() }
                        .font(.body.weight(.medium))
                        .foregroundStyle(SteddiTheme.textPrimary)
                        .padding(10)
                        .background(SteddiTheme.surfacePrimary.opacity(0.85), in: Capsule())

                    Spacer()

                    Text("New Trip")
                        .font(SteddiTheme.heading(15))
                        .foregroundStyle(SteddiTheme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(SteddiTheme.surfacePrimary.opacity(0.85), in: Capsule())

                    Spacer()

                    Button("Save") { saveTrip() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(canSave ? SteddiTheme.accent : SteddiTheme.textMuted)
                        .padding(10)
                        .background(SteddiTheme.surfacePrimary.opacity(0.85), in: Capsule())
                        .disabled(!canSave)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                bottomCard
            }
        }
    }

    private var canSave: Bool {
        !tripName.trimmingCharacters(in: .whitespaces).isEmpty && !draftStops.isEmpty
    }

    private func zoomButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SteddiTheme.textPrimary)
                .frame(width: 44, height: 44)
                .background(SteddiTheme.surfacePrimary.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func zoom(factor: Double) {
        guard let mv = plannerMapView else { return }
        var region = mv.region
        region.span.latitudeDelta = min(region.span.latitudeDelta * factor, 180)
        region.span.longitudeDelta = min(region.span.longitudeDelta * factor, 360)
        mv.setRegion(region, animated: true)
    }

    // MARK: - Bottom Card

    private var bottomCard: some View {
        VStack(spacing: 12) {
            TextField("Trip name", text: $tripName)
                .font(SteddiTheme.body(15))
                .padding(10)
                .background(SteddiTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))

            if draftStops.isEmpty {
                Text("Tap the map to add stops in order")
                    .font(SteddiTheme.body(13))
                    .foregroundStyle(SteddiTheme.textMuted)
            } else {
                stopList
            }

            // Flow mode toggle
            HStack {
                Text("Between stops")
                    .font(SteddiTheme.body(14))
                    .foregroundStyle(SteddiTheme.textPrimary)
                Spacer()
                Picker("Flow mode", selection: $flowMode) {
                    Text("Continuous").tag(TripFlowMode.continuous)
                    Text("Manual").tag(TripFlowMode.manual)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            // Route preferences
            HStack {
                Text("Custom route preferences")
                    .font(SteddiTheme.body(14))
                    .foregroundStyle(SteddiTheme.textPrimary)
                Spacer()
                Toggle("", isOn: $useCustomPreferences)
                    .tint(SteddiTheme.accent)
                    .labelsHidden()
            }

            if useCustomPreferences {
                HStack(spacing: 16) {
                    Toggle(isOn: $avoidsTolls) {
                        Text("Avoid tolls").font(SteddiTheme.body(13))
                    }
                    .tint(SteddiTheme.accent)
                    Toggle(isOn: $avoidsHighways) {
                        Text("Avoid highways").font(SteddiTheme.body(13))
                    }
                    .tint(SteddiTheme.accent)
                }
                .foregroundStyle(SteddiTheme.textSecondary)
            }
        }
        .padding(16)
        .background(
            SteddiTheme.surfacePrimary.opacity(0.95)
                .shadow(color: .black.opacity(0.3), radius: 16, y: -4)
        )
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusLarge, topTrailingRadius: SteddiTheme.radiusLarge))
    }

    /// Draggable, editable stop list — order here is trip order.
    private var stopList: some View {
        List {
            ForEach($draftStops) { $stop in
                HStack(spacing: 10) {
                    Text("\((draftStops.firstIndex(of: stop) ?? 0) + 1)")
                        .font(SteddiTheme.mono(12))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(SteddiTheme.accent, in: Circle())

                    TextField("Stop name", text: $stop.name)
                        .font(SteddiTheme.body(14))
                        .foregroundStyle(SteddiTheme.textPrimary)

                    Button {
                        draftStops.removeAll { $0.id == stop.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(SteddiTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            }
            .onMove { source, destination in
                draftStops.move(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active)) // always show drag handles
        .frame(height: min(CGFloat(draftStops.count) * 44 + 8, 176))
    }

    // MARK: - Save

    private func saveTrip() {
        let trip = Trip(name: tripName.trimmingCharacters(in: .whitespaces), flowMode: flowMode)
        if useCustomPreferences {
            trip.avoidsTolls = avoidsTolls
            trip.avoidsHighways = avoidsHighways
        }

        modelContext.insert(trip)
        if trip.stops == nil { trip.stops = [] }
        for (index, draft) in draftStops.enumerated() {
            let stop = TripStop(
                order: index,
                name: draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Stop \(index + 1)" : draft.name,
                latitude: draft.coordinate.latitude,
                longitude: draft.coordinate.longitude
            )
            modelContext.insert(stop)
            trip.stops?.append(stop)
        }

        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Trip Planner Map

/// Map for trip planning: tap to add stops, numbered pins mark the order.
struct TripPlannerMap: UIViewRepresentable {
    let initialCenter: CLLocationCoordinate2D?
    let stops: [CLLocationCoordinate2D]
    let onTapMap: (CLLocationCoordinate2D) -> Void
    @Binding var mapViewRef: MKMapView?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.overrideUserInterfaceStyle = SteddiTheme.currentThemeMode.mapInterfaceStyle
        mapView.delegate = context.coordinator
        mapView.preferredConfiguration = SteddiTheme.mapConfiguration(traffic: false)
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsUserLocation = true

        if let center = initialCenter {
            mapView.setRegion(
                MKCoordinateRegion(center: center, latitudinalMeters: 8000, longitudinalMeters: 8000),
                animated: false
            )
        }

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tap)
        context.coordinator.mapView = mapView

        DispatchQueue.main.async { mapViewRef = mapView }
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.onTapMap = onTapMap

        let stopAnnotations = mapView.annotations.compactMap { $0 as? StopAnnotation }
        mapView.removeAnnotations(stopAnnotations)

        for (index, coord) in stops.enumerated() {
            let annotation = StopAnnotation()
            annotation.coordinate = coord
            annotation.number = index + 1
            mapView.addAnnotation(annotation)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class StopAnnotation: MKPointAnnotation {
        var number: Int = 0
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        weak var mapView: MKMapView?
        var onTapMap: ((CLLocationCoordinate2D) -> Void)?

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView, gesture.state == .ended else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            onTapMap?(coord)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let stop = annotation as? StopAnnotation else { return nil }
            let identifier = "TripStopPin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: stop, reuseIdentifier: identifier)
            view.annotation = stop

            // Numbered circle pin in the accent color
            let size: CGFloat = 26
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
            view.image = renderer.image { ctx in
                let rect = CGRect(x: 0, y: 0, width: size, height: size)
                ctx.cgContext.setFillColor(SteddiTheme.accentUIColor.cgColor)
                ctx.cgContext.fillEllipse(in: rect)
                ctx.cgContext.setStrokeColor(UIColor.white.cgColor)
                ctx.cgContext.setLineWidth(2)
                ctx.cgContext.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))

                let text = "\(stop.number)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                let textSize = text.size(withAttributes: attributes)
                text.draw(
                    at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2),
                    withAttributes: attributes
                )
            }
            view.centerOffset = .zero
            return view
        }
    }
}
