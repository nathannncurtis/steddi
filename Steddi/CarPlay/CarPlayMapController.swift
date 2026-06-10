import UIKit
import MapKit
import CoreLocation

/// Hosts an MKMapView for the CarPlay display.
/// Same route styling and chase-cam as the phone, optimized for CarPlay.
class CarPlayMapController: UIViewController, MKMapViewDelegate {

    private var mapView: MKMapView!
    private var isInNavigation = false
    private var isFreeLook = false
    private var navRouteCoords: [CLLocationCoordinate2D] = []
    private var smoothedBearing: Double = 0
    private var currentZoom: Double = 17.5
    private var routeOverlay: MKPolyline?
    private var hasReceivedLocation = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        mapView = MKMapView(frame: view.bounds)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.overrideUserInterfaceStyle = SteddiTheme.currentThemeMode.mapInterfaceStyle
        mapView.delegate = self

        mapView.preferredConfiguration = SteddiTheme.mapConfiguration(traffic: true, poiFilter: .excludingAll)

        mapView.showsUserLocation = true
        mapView.showsCompass = false
        mapView.showsScale = false

        // Follow user location immediately — don't default to a fixed region
        mapView.setUserTrackingMode(.follow, animated: false)

        view.backgroundColor = .black
        view.addSubview(mapView)

        NotificationCenter.default.addObserver(self, selector: #selector(accentColorChanged), name: .steddiAccentColorChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeModeChanged), name: .steddiThemeModeChanged, object: nil)
    }

    @objc private func themeModeChanged() {
        mapView.overrideUserInterfaceStyle = SteddiTheme.currentThemeMode.mapInterfaceStyle
    }

    @objc private func accentColorChanged() {
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

        // Stop auto-follow — we manage the camera manually during nav
        mapView.setUserTrackingMode(.none, animated: false)

        // Set initial nav camera
        if let userCoord = mapView.userLocation.location?.coordinate,
           CLLocationCoordinate2DIsValid(userCoord) {
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

        // Return to follow mode
        mapView.setUserTrackingMode(.follow, animated: true)
    }

    // MARK: - Free Look & Pan (for CPMapTemplateDelegate)

    func setFreeLook(_ enabled: Bool) {
        isFreeLook = enabled
    }

    func panMap(latDelta: CLLocationDegrees, lngDelta: CLLocationDegrees) {
        let center = mapView.centerCoordinate
        let newCenter = CLLocationCoordinate2D(
            latitude: center.latitude + latDelta,
            longitude: center.longitude + lngDelta
        )
        let camera = MKMapCamera(
            lookingAtCenter: newCenter,
            fromDistance: mapView.camera.centerCoordinateDistance,
            pitch: mapView.camera.pitch,
            heading: mapView.camera.heading
        )
        mapView.setCamera(camera, animated: true)
    }

    /// Chase-cam: follow the engine's snapped pose with its already-smoothed
    /// bearing. Applied without animation — the engine pose is the single clock,
    /// so CarPlay never runs its own animation curve against the phone's.
    func updateNavigationPose(_ pose: NavPose, headingDegrees: Double?) {
        guard isInNavigation, !isFreeLook else { return }

        if let heading = headingDegrees ?? pose.segmentBearingDegrees {
            smoothedBearing = heading
        }
        let lookAhead = RouteGeometry.offsetCoordinate(
            pose.snappedCoordinate, distanceMeters: 80, bearingDegrees: smoothedBearing
        )

        let camera = MKMapCamera(
            lookingAtCenter: lookAhead,
            fromDistance: zoomToDistance(currentZoom),
            pitch: 60,
            heading: smoothedBearing
        )
        mapView.setCamera(camera, animated: false)
    }

    // MARK: - Zoom Controls

    func zoomIn() {
        currentZoom = min(currentZoom + 1, 20)
        applyCameraZoom()
    }

    func zoomOut() {
        currentZoom = max(currentZoom - 1, 12)
        applyCameraZoom()
    }

    func recenter() {
        guard let coord = mapView.userLocation.location?.coordinate else { return }
        isFreeLook = false
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
            mapView.setUserTrackingMode(.follow, animated: true)
        }
    }

    private func applyCameraZoom() {
        let camera = MKMapCamera(
            lookingAtCenter: mapView.centerCoordinate,
            fromDistance: zoomToDistance(currentZoom),
            pitch: mapView.camera.pitch,
            heading: mapView.camera.heading
        )
        mapView.setCamera(camera, animated: true)
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

    func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
        // On first location update, center the map if we haven't navigated yet
        if !hasReceivedLocation && !isInNavigation {
            hasReceivedLocation = true
            if let coord = userLocation.location?.coordinate, CLLocationCoordinate2DIsValid(coord) {
                let region = MKCoordinateRegion(center: coord, latitudinalMeters: 2000, longitudinalMeters: 2000)
                mapView.setRegion(region, animated: true)
            }
        }
    }

    // MARK: - Helpers

    private func zoomToDistance(_ zoom: Double) -> CLLocationDistance {
        let lat = mapView.centerCoordinate.latitude
        return 156543.03 * cos(lat * .pi / 180) / pow(2, zoom) * 256
    }
}
