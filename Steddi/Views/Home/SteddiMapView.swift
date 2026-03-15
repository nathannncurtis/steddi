import SwiftUI
import MapboxMaps
import MapboxNavigationCore
import MapboxDirections
import CoreLocation
import Combine

/// Manages the map in a single UIKit view controller.
/// Navigation uses the same map — Steddi's custom SwiftUI overlay replaces Mapbox's stock UI.
struct SteddiMapView: UIViewControllerRepresentable {
    @Binding var isNavigating: Bool
    @Binding var is3DView: Bool
    let navigationRoutes: NavigationRoutes?
    let provider: MapboxNavigationProvider?
    let onLongPress: (CLLocationCoordinate2D) -> Void
    let onArrival: () -> Void
    let onCancelled: () -> Void

    func makeUIViewController(context: Context) -> SteddiMapContainer {
        let vc = SteddiMapContainer()
        vc.onLongPress = onLongPress
        vc.view.insetsLayoutMarginsFromSafeArea = false
        return vc
    }

    func updateUIViewController(_ vc: SteddiMapContainer, context: Context) {
        if isNavigating, let routes = navigationRoutes, let provider = provider {
            if !vc.isInNavigation {
                vc.startNavigation(routes: routes, provider: provider)
            }
            vc.set3DView(is3DView)
        } else if !isNavigating && vc.isInNavigation {
            vc.stopNavigation()
        }
    }
}

class SteddiMapContainer: UIViewController {
    private var mapView: MapView!
    var isInNavigation = false
    private var currentIs3D = true
    private var navProvider: MapboxNavigationProvider?
    private var navRouteCoords: [CLLocationCoordinate2D] = []
    private var smoothedBearing: Double = 0

    var onLongPress: ((CLLocationCoordinate2D) -> Void)?

    /// Creates a soft-cornered triangle pointing up in lavender.
    static func makePuckImage() -> UIImage {
        let size = CGSize(width: 44, height: 44)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let lavender = UIColor(red: 0.61, green: 0.56, blue: 0.77, alpha: 1.0)

            // Rounded triangle pointing up
            let path = UIBezierPath()
            let inset: CGFloat = 4
            let w = size.width - inset * 2
            let h = size.height - inset * 2
            let cornerRadius: CGFloat = 6

            // Three points: top center, bottom left, bottom right
            let top = CGPoint(x: size.width / 2, y: inset)
            let bottomLeft = CGPoint(x: inset, y: inset + h)
            let bottomRight = CGPoint(x: inset + w, y: inset + h)

            // Draw with rounded corners
            path.move(to: CGPoint(
                x: (top.x + bottomLeft.x) / 2 + cornerRadius * 0.5,
                y: (top.y + bottomLeft.y) / 2 - cornerRadius * 0.3
            ))
            path.addQuadCurve(to: CGPoint(
                x: (top.x + bottomRight.x) / 2 - cornerRadius * 0.5,
                y: (top.y + bottomRight.y) / 2 - cornerRadius * 0.3
            ), controlPoint: top)
            path.addQuadCurve(to: CGPoint(
                x: (bottomRight.x + bottomLeft.x) / 2 + cornerRadius * 0.3,
                y: bottomRight.y - cornerRadius * 0.2
            ), controlPoint: bottomRight)
            path.addQuadCurve(to: CGPoint(
                x: (top.x + bottomLeft.x) / 2 + cornerRadius * 0.5,
                y: (top.y + bottomLeft.y) / 2 - cornerRadius * 0.3
            ), controlPoint: bottomLeft)
            path.close()

            // Fill with lavender
            lavender.setFill()
            path.fill()

            // White border
            UIColor.white.setStroke()
            path.lineWidth = 2.5
            path.stroke()
        }
    }

    override var prefersHomeIndicatorAutoHidden: Bool { false }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        mapView?.frame = view.bounds
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let initOptions = MapInitOptions(styleURI: .standard)
        mapView = MapView(frame: view.bounds, mapInitOptions: initOptions)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.insetsLayoutMarginsFromSafeArea = false

        // Lavender soft triangle puck
        var puckConfig = Puck2DConfiguration()
        puckConfig.topImage = Self.makePuckImage()
        puckConfig.pulsing = nil
        puckConfig.scale = .constant(0.8)
        mapView.location.options.puckType = .puck2D(puckConfig)
        mapView.location.options.puckBearing = .heading

        // Hide ornaments that clash with Steddi UI
        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.compass.visibility = .hidden

        // Initial camera
        mapView.mapboxMap.setCamera(to: CameraOptions(zoom: 14))

        // Match the bottom sheet color so there's no visible gap
        view.backgroundColor = UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1)
        mapView.backgroundColor = UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1)

        view.addSubview(mapView)

        // Set map style based on current system appearance
        updateMapStyle()

        // Follow user location on style load
        mapView.mapboxMap.onStyleLoaded.observeNext { [weak self] _ in
            guard let self,
                  let coord = self.mapView.location.latestLocation?.coordinate else { return }
            self.mapView.mapboxMap.setCamera(to: CameraOptions(center: coord, zoom: 14))
        }.store(in: &cancellables)

        // Long press gesture
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        mapView.addGestureRecognizer(lp)
    }

    private var cancellables: [AnyCancelable] = []

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle {
            updateMapStyle()
        }
    }

    private func updateMapStyle() {
        let isDark = traitCollection.userInterfaceStyle == .dark

        if isDark {
            mapView.mapboxMap.mapStyle = .standard(lightPreset: .dusk)
        } else {
            // Light mode — use day, but switch to dusk near sunset
            let hour = Calendar.current.component(.hour, from: Date())
            if hour >= 19 || hour < 6 {
                // Evening/night — use dusk even in light mode
                mapView.mapboxMap.mapStyle = .standard(lightPreset: .dusk)
            } else if hour >= 17 {
                // Golden hour — use dawn (warm sunset look)
                mapView.mapboxMap.mapStyle = .standard(lightPreset: .dawn)
            } else {
                mapView.mapboxMap.mapStyle = .standard(lightPreset: .day)
            }
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: mapView)
        let coordinate = mapView.mapboxMap.coordinate(for: point)
        onLongPress?(coordinate)
    }

    func set3DView(_ is3D: Bool) {
        guard currentIs3D != is3D else { return }
        currentIs3D = is3D

        mapView.camera.ease(
            to: CameraOptions(
                center: mapView.location.latestLocation?.coordinate,
                zoom: is3D ? 17.0 : 16.5,
                pitch: is3D ? 55 : 0
            ),
            duration: 0.5,
            curve: .easeInOut,
            completion: nil
        )
    }

    /// Get the bearing along the route at the closest point to the user's position.
    /// This gives a stable, route-following bearing instead of noisy GPS course.
    static func bearingAlongRoute(from position: CLLocationCoordinate2D, routeCoords: [CLLocationCoordinate2D]) -> Double {
        guard routeCoords.count >= 2 else { return 0 }

        // Find the closest route segment
        var bestIndex = 0
        var bestDist = Double.greatestFiniteMagnitude
        let posLoc = CLLocation(latitude: position.latitude, longitude: position.longitude)

        for i in 0..<routeCoords.count {
            let d = posLoc.distance(from: CLLocation(latitude: routeCoords[i].latitude, longitude: routeCoords[i].longitude))
            if d < bestDist {
                bestDist = d
                bestIndex = i
            }
        }

        // Use the next point on the route to determine forward bearing
        let lookAheadIndex = min(bestIndex + 3, routeCoords.count - 1) // look a few points ahead for stability
        guard lookAheadIndex > bestIndex else { return 0 }

        let from = routeCoords[bestIndex]
        let to = routeCoords[lookAheadIndex]

        let dLon = (to.longitude - from.longitude) * .pi / 180
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var bearing = atan2(y, x) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return bearing
    }

    /// Smooth bearing transitions to prevent jerky camera rotation.
    static func smoothBearing(current: Double, target: Double, factor: Double) -> Double {
        // Handle the 360/0 wraparound
        var diff = target - current
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        var result = current + diff * factor
        if result < 0 { result += 360 }
        if result >= 360 { result -= 360 }
        return result
    }

    /// Offset a coordinate by a distance along a bearing (for chase-cam look-ahead)
    static func offsetCoordinate(_ coord: CLLocationCoordinate2D, distanceMeters: Double, bearingDegrees: Double) -> CLLocationCoordinate2D {
        let R = 6371000.0 // earth radius in meters
        let d = distanceMeters / R
        let brng = bearingDegrees * .pi / 180
        let lat1 = coord.latitude * .pi / 180
        let lon1 = coord.longitude * .pi / 180

        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(brng))
        let lon2 = lon1 + atan2(sin(brng) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))

        return CLLocationCoordinate2D(
            latitude: lat2 * 180 / .pi,
            longitude: lon2 * 180 / .pi
        )
    }

    func startNavigation(routes: NavigationRoutes, provider: MapboxNavigationProvider) {
        guard !isInNavigation else { return }
        isInNavigation = true
        self.navProvider = provider

        // Start active guidance on the navigation core
        provider.tripSession().startActiveGuidance(with: routes, startLegIndex: 0)

        // Store route coordinates for bearing calculation
        let coords = routes.mainRoute.route.shape?.coordinates ?? []
        navRouteCoords = coords
        showRouteLine(coords)

        // Initial camera
        mapView.mapboxMap.setCamera(to: CameraOptions(
            center: mapView.location.latestLocation?.coordinate,
            zoom: currentIs3D ? 17.0 : 16.0,
            bearing: 0,
            pitch: currentIs3D ? 55 : 0
        ))

        // Follow location during nav — "chase cam" style
        provider.navigation().locationMatching
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let coord = state.enhancedLocation.coordinate

                if self.currentIs3D {
                    // Get bearing from route geometry (stable, not jumpy GPS course)
                    let routeBearing = Self.bearingAlongRoute(
                        from: coord,
                        routeCoords: self.navRouteCoords
                    )

                    // Smooth the bearing to prevent jerky rotation
                    self.smoothedBearing = Self.smoothBearing(
                        current: self.smoothedBearing,
                        target: routeBearing,
                        factor: 0.15
                    )

                    // Offset camera center ahead so user sits in lower third
                    let lookAhead = Self.offsetCoordinate(
                        coord,
                        distanceMeters: 80,
                        bearingDegrees: self.smoothedBearing
                    )

                    self.mapView.camera.ease(
                        to: CameraOptions(
                            center: lookAhead,
                            zoom: 18.0,
                            bearing: self.smoothedBearing,
                            pitch: 65
                        ),
                        duration: 1.0,
                        curve: .linear,
                        completion: nil
                    )
                } else {
                    self.mapView.camera.ease(
                        to: CameraOptions(
                            center: coord,
                            zoom: 16.5,
                            bearing: 0,
                            pitch: 0
                        ),
                        duration: 1.0,
                        curve: .linear,
                        completion: nil
                    )
                }
            }
            .store(in: &cancellables)
    }

    func stopNavigation() {
        guard isInNavigation else { return }
        isInNavigation = false

        // Cancel location following subscriptions
        cancellables.removeAll()

        // Remove route line
        removeRouteLine()

        // Reset camera
        mapView.mapboxMap.setCamera(to: CameraOptions(
            center: mapView.location.latestLocation?.coordinate,
            zoom: 14,
            bearing: 0,
            pitch: 0
        ))

        // Re-subscribe to style loaded for home mode
        mapView.mapboxMap.onStyleLoaded.observeNext { [weak self] _ in
            guard let self,
                  let coord = self.mapView.location.latestLocation?.coordinate else { return }
            self.mapView.mapboxMap.setCamera(to: CameraOptions(center: coord, zoom: 14))
        }.store(in: &cancellables)
    }

    // MARK: - Route Line

    private func showRouteLine(_ coordinates: [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty else { return }

        var source = GeoJSONSource(id: "steddi-route-source")
        source.data = .geometry(.lineString(LineString(coordinates)))

        // Lavender route line — fullbright, no border
        var lineLayer = LineLayer(id: "steddi-route-line", source: "steddi-route-source")
        lineLayer.slot = .top
        lineLayer.lineColor = .constant(StyleColor(UIColor(red: 0.61, green: 0.56, blue: 0.77, alpha: 1.0)))
        lineLayer.lineWidth = .constant(8)
        lineLayer.lineOpacity = .constant(1.0)
        lineLayer.lineCap = .constant(.round)
        lineLayer.lineJoin = .constant(.round)
        lineLayer.lineEmissiveStrength = .constant(1.0) // fullbright — ignores 3D lighting

        try? mapView.mapboxMap.addSource(source)
        try? mapView.mapboxMap.addLayer(lineLayer)
    }

    private func removeRouteLine() {
        try? mapView.mapboxMap.removeLayer(withId: "steddi-route-line")
        try? mapView.mapboxMap.removeSource(withId: "steddi-route-source")
    }
}
