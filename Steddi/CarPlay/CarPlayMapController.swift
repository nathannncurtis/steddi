import UIKit
import MapKit
import CoreLocation
import Combine

/// Hosts an MKMapView sized to the CarPlay display.
/// Same route styling and chase-cam as the phone, optimized for CarPlay screen.
class CarPlayMapController: UIViewController, MKMapViewDelegate {

    private var mapView: MKMapView!
    private var isInNavigation = false
    private var navRouteCoords: [CLLocationCoordinate2D] = []
    private var smoothedBearing: Double = 0
    private var cancellables: [AnyCancellable] = []
    private var currentZoom: Double = 17.5
    private var routeOverlay: MKPolyline?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        mapView = MKMapView(frame: view.bounds)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.overrideUserInterfaceStyle = .dark
        mapView.delegate = self

        let config = MKStandardMapConfiguration(emphasisStyle: .muted)
        mapView.preferredConfiguration = config

        mapView.showsUserLocation = true

        // Hide ornaments — CarPlay template provides its own chrome
        mapView.showsCompass = false
        mapView.showsScale = false

        let region = MKCoordinateRegion(
            center: mapView.userLocation.coordinate.latitude != 0
                ? mapView.userLocation.coordinate
                : CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            latitudinalMeters: 5000,
            longitudinalMeters: 5000
        )
        mapView.setRegion(region, animated: false)

        view.backgroundColor = .black
        view.addSubview(mapView)

        // Observe accent color changes
        NotificationCenter.default.addObserver(self, selector: #selector(accentColorChanged), name: .steddiAccentColorChanged, object: nil)
    }

    @objc private func accentColorChanged() {
        // Refresh route line if showing
        if isInNavigation {
            removeRouteLine()
            showRouteLine(navRouteCoords)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        mapView?.frame = view.bounds
    }

    // MARK: - Navigation

    func startNavigation(routeCoords: [CLLocationCoordinate2D]) {
        guard !isInNavigation else { return }
        isInNavigation = true
        navRouteCoords = routeCoords
        smoothedBearing = 0
        currentZoom = 17.5

        showRouteLine(routeCoords)

        if let userCoord = mapView.userLocation.location?.coordinate {
            let camera = MKMapCamera(
                lookingAtCenter: userCoord,
                fromDistance: zoomToDistance(currentZoom),
                pitch: 55,
                heading: 0
            )
            mapView.setCamera(camera, animated: true)
        }
    }

    func stopNavigation() {
        guard isInNavigation else { return }
        isInNavigation = false
        navRouteCoords = []

        removeRouteLine()

        if let userCoord = mapView.userLocation.location?.coordinate {
            let camera = MKMapCamera(
                lookingAtCenter: userCoord,
                fromDistance: 5000,
                pitch: 0,
                heading: 0
            )
            mapView.setCamera(camera, animated: true)
        }
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

        let camera = MKMapCamera(
            lookingAtCenter: lookAhead,
            fromDistance: zoomToDistance(currentZoom),
            pitch: 60,
            heading: smoothedBearing
        )
        UIView.animate(withDuration: 1.0, delay: 0, options: [.curveLinear]) {
            self.mapView.setCamera(camera, animated: false)
        }
    }

    // MARK: - Zoom Controls

    func zoomIn() {
        currentZoom = min(currentZoom + 1, 20)
        let camera = MKMapCamera(
            lookingAtCenter: mapView.centerCoordinate,
            fromDistance: zoomToDistance(currentZoom),
            pitch: mapView.camera.pitch,
            heading: mapView.camera.heading
        )
        mapView.setCamera(camera, animated: true)
    }

    func zoomOut() {
        currentZoom = max(currentZoom - 1, 12)
        let camera = MKMapCamera(
            lookingAtCenter: mapView.centerCoordinate,
            fromDistance: zoomToDistance(currentZoom),
            pitch: mapView.camera.pitch,
            heading: mapView.camera.heading
        )
        mapView.setCamera(camera, animated: true)
    }

    func recenter() {
        guard let coord = mapView.userLocation.location?.coordinate else { return }
        currentZoom = 17.5
        if isInNavigation {
            let camera = MKMapCamera(
                lookingAtCenter: coord,
                fromDistance: zoomToDistance(currentZoom),
                pitch: 60,
                heading: smoothedBearing
            )
            mapView.setCamera(camera, animated: true)
        } else {
            let camera = MKMapCamera(
                lookingAtCenter: coord,
                fromDistance: 5000,
                pitch: 0,
                heading: 0
            )
            mapView.setCamera(camera, animated: true)
        }
    }

    // MARK: - Route Line

    private func showRouteLine(_ coordinates: [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty else { return }
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        routeOverlay = polyline
        mapView.addOverlay(polyline, level: .aboveRoads)
    }

    private func removeRouteLine() {
        if let overlay = routeOverlay {
            mapView.removeOverlay(overlay)
            routeOverlay = nil
        }
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let polyline = overlay as? MKPolyline {
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = SteddiTheme.accentUIColor
            renderer.lineWidth = 8
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    // MARK: - Helpers

    /// Convert a zoom level to MKMapCamera distance (approximate)
    private func zoomToDistance(_ zoom: Double) -> CLLocationDistance {
        let lat = mapView.centerCoordinate.latitude
        return 156543.03 * cos(lat * .pi / 180) / pow(2, zoom) * 256
    }
}
