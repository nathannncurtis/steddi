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

    override func viewDidLoad() {
        super.viewDidLoad()

        let initOptions = MapInitOptions(styleURI: .standard)
        mapView = MapView(frame: view.bounds, mapInitOptions: initOptions)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

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

        view.addSubview(mapView)

        // Apply Standard style with dusk light preset for colored but dark-toned map
        mapView.mapboxMap.mapStyle = .standard(lightPreset: .dusk)

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

        // Show route line as UIKit overlay (immune to 3D lighting)
        let coords = routes.mainRoute.route.shape?.coordinates ?? []
        showRouteLine(coords)

        // Initial camera
        mapView.mapboxMap.setCamera(to: CameraOptions(
            center: mapView.location.latestLocation?.coordinate,
            zoom: currentIs3D ? 17.0 : 16.0,
            bearing: 0,
            pitch: currentIs3D ? 55 : 0
        ))

        // Follow location during nav — "chase cam" style
        // Offset the center ahead of the user so they sit in the lower third
        provider.navigation().locationMatching
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let coord = state.enhancedLocation.coordinate
                let bearing = state.enhancedLocation.course >= 0 ? state.enhancedLocation.course : 0

                if self.currentIs3D {
                    // Push the camera center forward along the bearing
                    // so the user's position appears in the lower third
                    let offsetMeters: Double = 150 // look ~150m ahead
                    let lookAhead = Self.offsetCoordinate(coord, distanceMeters: offsetMeters, bearingDegrees: bearing)

                    self.mapView.camera.ease(
                        to: CameraOptions(
                            center: lookAhead,
                            zoom: 17.0,
                            bearing: bearing,
                            pitch: 55
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
