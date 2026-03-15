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

        let pitch: CGFloat = is3D ? 70 : 0
        let zoom: CGFloat = is3D ? 18.5 : 16.5
        mapView.camera.ease(
            to: CameraOptions(
                center: mapView.location.latestLocation?.coordinate,
                zoom: zoom,
                pitch: pitch
            ),
            duration: 0.5,
            curve: .easeInOut,
            completion: nil
        )
    }

    func startNavigation(routes: NavigationRoutes, provider: MapboxNavigationProvider) {
        guard !isInNavigation else { return }
        isInNavigation = true
        self.navProvider = provider

        // Start active guidance on the navigation core
        provider.tripSession().startActiveGuidance(with: routes, startLegIndex: 0)

        // Show route line on map
        let coords = routes.mainRoute.route.shape?.coordinates ?? []
        showRouteLine(coords)

        let pitch: CGFloat = currentIs3D ? 60 : 0
        let zoom: CGFloat = currentIs3D ? 17.5 : 16

        // Camera follows route
        mapView.mapboxMap.setCamera(to: CameraOptions(
            center: mapView.location.latestLocation?.coordinate,
            zoom: zoom,
            bearing: 0,
            pitch: pitch
        ))

        // Follow location during nav — smooth camera tracking
        provider.navigation().locationMatching
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let coord = state.enhancedLocation.coordinate
                let bearing = state.enhancedLocation.course >= 0 ? state.enhancedLocation.course : 0
                let navPitch: CGFloat = self.currentIs3D ? 70 : 0
                let navZoom: CGFloat = self.currentIs3D ? 18.5 : 16.5
                self.mapView.camera.ease(
                    to: CameraOptions(
                        center: coord,
                        zoom: navZoom,
                        bearing: self.currentIs3D ? bearing : 0,
                        pitch: navPitch
                    ),
                    duration: 1.0,
                    curve: .linear,
                    completion: nil
                )
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

        // Bottom layer: lavender glow/casing
        var glowLayer = LineLayer(id: "steddi-route-glow", source: "steddi-route-source")
        glowLayer.slot = .top
        glowLayer.lineColor = .constant(StyleColor(UIColor(red: 0.61, green: 0.56, blue: 0.77, alpha: 1.0)))
        glowLayer.lineWidth = .constant(14)
        glowLayer.lineOpacity = .constant(0.7)
        glowLayer.lineCap = .constant(.round)
        glowLayer.lineJoin = .constant(.round)

        // Top layer: bright white so it's visible on ANY map background
        var lineLayer = LineLayer(id: "steddi-route-line", source: "steddi-route-source")
        lineLayer.slot = .top
        lineLayer.lineColor = .constant(StyleColor(.white))
        lineLayer.lineWidth = .constant(6)
        lineLayer.lineOpacity = .constant(1.0)
        lineLayer.lineCap = .constant(.round)
        lineLayer.lineJoin = .constant(.round)

        try? mapView.mapboxMap.addSource(source)
        try? mapView.mapboxMap.addLayer(glowLayer)
        try? mapView.mapboxMap.addLayer(lineLayer)
    }

    private func removeRouteLine() {
        try? mapView.mapboxMap.removeLayer(withId: "steddi-route-line")
        try? mapView.mapboxMap.removeLayer(withId: "steddi-route-glow")
        try? mapView.mapboxMap.removeSource(withId: "steddi-route-source")
    }
}
