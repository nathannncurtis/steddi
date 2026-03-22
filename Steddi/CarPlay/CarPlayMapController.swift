import UIKit
import MapboxMaps
import CoreLocation
import Combine

/// Hosts a MapboxMaps MapView sized to the CarPlay display.
/// Simpler than SteddiMapView — optimized for the smaller CarPlay screen
/// with chase-cam navigation and the same lavender route styling.
class CarPlayMapController: UIViewController {

    private var mapView: MapView!
    private var isInNavigation = false
    private var navRouteCoords: [CLLocationCoordinate2D] = []
    private var smoothedBearing: Double = 0
    private var cancellables: [AnyCancelable] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        let initOptions = MapInitOptions(styleURI: .standard)
        mapView = MapView(frame: view.bounds, mapInitOptions: initOptions)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Lavender puck — same as SteddiMapView
        var puckConfig = Puck2DConfiguration()
        puckConfig.topImage = SteddiMapContainer.makePuckImage()
        puckConfig.pulsing = nil
        puckConfig.scale = .constant(0.8)
        mapView.location.options.puckType = .puck2D(puckConfig)
        mapView.location.options.puckBearing = .heading

        // Hide ornaments — CarPlay has its own chrome
        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.compass.visibility = .hidden

        // Initial camera
        mapView.mapboxMap.setCamera(to: CameraOptions(zoom: 14))

        view.backgroundColor = .black
        view.addSubview(mapView)

        // Set map style
        updateMapStyle()

        // Center on user once style loads
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

    /// Same logic as SteddiMapView: dusk for dark mode, time-based for light mode.
    /// Kept simpler for CarPlay — no extra detail layers.
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

    /// Begin showing the route line and switch to chase-cam mode.
    func startNavigation(routeCoords: [CLLocationCoordinate2D]) {
        guard !isInNavigation else { return }
        isInNavigation = true
        navRouteCoords = routeCoords
        smoothedBearing = 0

        showRouteLine(routeCoords)

        // Initial navigation camera
        if let coord = mapView.location.latestLocation?.coordinate {
            mapView.mapboxMap.setCamera(to: CameraOptions(
                center: coord,
                zoom: 17.0,
                bearing: 0,
                pitch: 55
            ))
        }
    }

    /// Stop navigation mode, remove route line, reset camera.
    func stopNavigation() {
        guard isInNavigation else { return }
        isInNavigation = false
        navRouteCoords = []

        removeRouteLine()

        // Reset to overview
        mapView.mapboxMap.setCamera(to: CameraOptions(
            center: mapView.location.latestLocation?.coordinate,
            zoom: 14,
            bearing: 0,
            pitch: 0
        ))
    }

    /// Update the chase-cam to follow the user's position and bearing.
    /// Uses the same bearing-along-route and smoothing logic as SteddiMapContainer.
    func updateCamera(coordinate: CLLocationCoordinate2D, bearing: Double) {
        guard isInNavigation else { return }

        // Get stable bearing from route geometry
        let routeBearing = SteddiMapContainer.bearingAlongRoute(
            from: coordinate,
            routeCoords: navRouteCoords
        )

        // Smooth the bearing to prevent jerky rotation
        smoothedBearing = SteddiMapContainer.smoothBearing(
            current: smoothedBearing,
            target: routeBearing,
            factor: 0.15
        )

        // Offset camera center ahead so the user sits in the lower third
        let lookAhead = SteddiMapContainer.offsetCoordinate(
            coordinate,
            distanceMeters: 80,
            bearingDegrees: smoothedBearing
        )

        mapView.camera.ease(
            to: CameraOptions(
                center: lookAhead,
                zoom: 17.5,
                bearing: smoothedBearing,
                pitch: 60
            ),
            duration: 1.0,
            curve: .linear,
            completion: nil
        )
    }

    // MARK: - Route Line

    /// Same lavender route line as SteddiMapContainer.
    private func showRouteLine(_ coordinates: [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty else { return }

        var source = GeoJSONSource(id: "steddi-route-source")
        source.data = .geometry(.lineString(LineString(coordinates)))

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
