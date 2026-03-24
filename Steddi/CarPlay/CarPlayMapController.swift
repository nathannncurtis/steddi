import UIKit
import MapboxMaps
import CoreLocation
import Combine

/// Hosts a MapboxMaps MapView sized to the CarPlay display.
/// Same lavender route styling and chase-cam as the phone, optimized for CarPlay screen.
class CarPlayMapController: UIViewController {

    private var mapView: MapView!
    private var isInNavigation = false
    private var navRouteCoords: [CLLocationCoordinate2D] = []
    private var smoothedBearing: Double = 0
    private var cancellables: [AnyCancellable] = []
    private var currentZoom: Double = 17.5

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        let initOptions = MapInitOptions(styleURI: .standard)
        mapView = MapView(frame: view.bounds, mapInitOptions: initOptions)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Lavender puck — same as phone
        var puckConfig = Puck2DConfiguration()
        puckConfig.topImage = SteddiMapContainer.makePuckImage()
        puckConfig.pulsing = nil
        puckConfig.scale = .constant(0.8)
        mapView.location.options.puckType = .puck2D(puckConfig)
        mapView.location.options.puckBearing = .heading

        // Hide ornaments — CarPlay template provides its own chrome
        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.compass.visibility = .hidden

        mapView.mapboxMap.setCamera(to: CameraOptions(zoom: 14))

        view.backgroundColor = .black
        view.addSubview(mapView)

        updateMapStyle()

        mapView.mapboxMap.onStyleLoaded.observeNext { [weak self] _ in
            guard let self,
                  let coord = self.mapView.location.latestLocation?.coordinate else { return }
            self.mapView.mapboxMap.setCamera(to: CameraOptions(center: coord, zoom: 14))
        }.store(in: &cancellables)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        mapView?.frame = view.bounds
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle {
            updateMapStyle()
        }
    }

    // MARK: - Map Style

    private func updateMapStyle() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        if isDark {
            mapView.mapboxMap.mapStyle = .standard(lightPreset: .dusk)
        } else {
            let hour = Calendar.current.component(.hour, from: Date())
            if hour >= 19 || hour < 6 {
                mapView.mapboxMap.mapStyle = .standard(lightPreset: .dusk)
            } else if hour >= 17 {
                mapView.mapboxMap.mapStyle = .standard(lightPreset: .dawn)
            } else {
                mapView.mapboxMap.mapStyle = .standard(lightPreset: .day)
            }
        }
    }

    // MARK: - Navigation

    func startNavigation(routeCoords: [CLLocationCoordinate2D]) {
        guard !isInNavigation else { return }
        isInNavigation = true
        navRouteCoords = routeCoords
        smoothedBearing = 0
        currentZoom = 17.5

        showRouteLine(routeCoords)

        if let coord = mapView.location.latestLocation?.coordinate {
            mapView.mapboxMap.setCamera(to: CameraOptions(
                center: coord, zoom: currentZoom, bearing: 0, pitch: 55
            ))
        }
    }

    func stopNavigation() {
        guard isInNavigation else { return }
        isInNavigation = false
        navRouteCoords = []

        removeRouteLine()

        mapView.mapboxMap.setCamera(to: CameraOptions(
            center: mapView.location.latestLocation?.coordinate,
            zoom: 14, bearing: 0, pitch: 0
        ))
    }

    /// Chase-cam: follow user with route-based bearing, smoothed rotation, look-ahead offset
    func updateCamera(coordinate: CLLocationCoordinate2D, bearing: Double) {
        guard isInNavigation else { return }

        let routeBearing = SteddiMapContainer.bearingAlongRoute(
            from: coordinate, routeCoords: navRouteCoords
        )
        smoothedBearing = SteddiMapContainer.smoothBearing(
            current: smoothedBearing, target: routeBearing, factor: 0.15
        )
        let lookAhead = SteddiMapContainer.offsetCoordinate(
            coordinate, distanceMeters: 80, bearingDegrees: smoothedBearing
        )

        mapView.camera.ease(
            to: CameraOptions(
                center: lookAhead, zoom: currentZoom,
                bearing: smoothedBearing, pitch: 60
            ),
            duration: 1.0, curve: .linear, completion: nil
        )
    }

    // MARK: - Zoom Controls

    func zoomIn() {
        currentZoom = min(currentZoom + 1, 20)
        if let center = mapView.mapboxMap.cameraState.center as? CLLocationCoordinate2D {
            mapView.camera.ease(to: CameraOptions(center: center, zoom: currentZoom), duration: 0.3, curve: .easeInOut, completion: nil)
        }
    }

    func zoomOut() {
        currentZoom = max(currentZoom - 1, 12)
        if let center = mapView.mapboxMap.cameraState.center as? CLLocationCoordinate2D {
            mapView.camera.ease(to: CameraOptions(center: center, zoom: currentZoom), duration: 0.3, curve: .easeInOut, completion: nil)
        }
    }

    func recenter() {
        guard let coord = mapView.location.latestLocation?.coordinate else { return }
        currentZoom = 17.5
        if isInNavigation {
            mapView.camera.ease(
                to: CameraOptions(center: coord, zoom: currentZoom, bearing: smoothedBearing, pitch: 60),
                duration: 0.5, curve: .easeInOut, completion: nil
            )
        } else {
            mapView.camera.ease(
                to: CameraOptions(center: coord, zoom: 14, bearing: 0, pitch: 0),
                duration: 0.5, curve: .easeInOut, completion: nil
            )
        }
    }

    // MARK: - Route Line

    private func showRouteLine(_ coordinates: [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty else { return }

        var source = GeoJSONSource(id: "steddi-route-source")
        source.data = .geometry(.lineString(LineString(coordinates)))

        var lineLayer = LineLayer(id: "steddi-route-line", source: "steddi-route-source")
        lineLayer.slot = .top
        lineLayer.lineColor = .constant(StyleColor(SteddiTheme.accentUIColor))
        lineLayer.lineWidth = .constant(8)
        lineLayer.lineOpacity = .constant(1.0)
        lineLayer.lineCap = .constant(.round)
        lineLayer.lineJoin = .constant(.round)
        lineLayer.lineEmissiveStrength = .constant(1.0)

        try? mapView.mapboxMap.addSource(source)
        try? mapView.mapboxMap.addLayer(lineLayer)
    }

    private func removeRouteLine() {
        try? mapView.mapboxMap.removeLayer(withId: "steddi-route-line")
        try? mapView.mapboxMap.removeSource(withId: "steddi-route-source")
    }
}
