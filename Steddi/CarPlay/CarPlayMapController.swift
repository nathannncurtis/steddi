import UIKit
import MapKit
import CoreLocation

/// Hosts an MKMapView for the CarPlay display.
/// Same route styling and chase-cam as the phone, optimized for CarPlay.
class CarPlayMapController: UIViewController, MKMapViewDelegate {

    // Optional, not implicitly-unwrapped: CarPlay can connect into an
    // ALREADY-ACTIVE drive, which sets this controller as the CPWindow root and
    // can drive startNavigation/recenter/zoom before UIKit lazily runs
    // viewDidLoad on the first layout pass. Every access guards `mapView` so a
    // pre-viewDidLoad call no-ops instead of trapping on a force-unwrap.
    private var mapView: MKMapView?
    private var isInNavigation = false
    private var isFreeLook = false
    private var navRouteCoords: [CLLocationCoordinate2D] = []
    private var routeCumulative: [Double] = []
    private var smoothedBearing: Double = 0
    private var currentZoom: Double = 17.5
    private var routeOverlay: MKPolyline?
    private var hasReceivedLocation = false

    // Display-link interpolation — same single-clock pattern as the phone map,
    // so the camera glides between 1Hz poses instead of teleporting per second.
    private var interpolator = NavPoseInterpolator()
    private var displayLink: CADisplayLink?
    private var lastPoseTimestamp: Date?

    deinit {
        displayLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        let map = MKMapView(frame: view.bounds)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.overrideUserInterfaceStyle = SteddiTheme.currentThemeMode.mapInterfaceStyle
        map.delegate = self

        map.preferredConfiguration = SteddiTheme.mapConfiguration(traffic: true, poiFilter: .excludingAll)

        map.showsUserLocation = true
        map.showsCompass = false
        map.showsScale = false

        view.backgroundColor = .black
        view.addSubview(map)
        mapView = map

        // If a drive was already active when CarPlay connected, the controller
        // may have been asked to start navigation before this view loaded —
        // those calls no-op'd on the nil mapView. Re-apply the live nav state now
        // that the map exists so the active route renders instead of staying on
        // the idle follow camera.
        if isInNavigation {
            applyActiveNavigationState()
        } else {
            // Follow user location immediately — don't default to a fixed region
            map.setUserTrackingMode(.follow, animated: false)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(accentColorChanged), name: .steddiAccentColorChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeModeChanged), name: .steddiThemeModeChanged, object: nil)
    }

    @objc private func themeModeChanged() {
        mapView?.overrideUserInterfaceStyle = SteddiTheme.currentThemeMode.mapInterfaceStyle
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
        routeCumulative = RouteGeometry.cumulativeDistances(routeCoords)
        smoothedBearing = 0
        currentZoom = 17.5
        interpolator = NavPoseInterpolator()
        lastPoseTimestamp = nil
        startDisplayLink()

        // The map may not exist yet — CarPlay can connect into an already-active
        // drive and call this before viewDidLoad runs. The nav STATE above is set
        // unconditionally so viewDidLoad can render it once the view loads (it
        // calls applyActiveNavigationState when isInNavigation is already true).
        applyActiveNavigationState()
    }

    /// Render the active-navigation map state (route overlay + initial nav
    /// camera). Safe to call before the view loads — no-ops on a nil mapView and
    /// is re-invoked from viewDidLoad once the map exists, so an active drive
    /// adopted at CarPlay connect-time still renders without a force-unwrap trap.
    private func applyActiveNavigationState() {
        guard let mapView else { return }

        showRouteLine(navRouteCoords)

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
        routeCumulative = []
        stopDisplayLink()

        removeRouteLine()

        // Return to follow mode
        mapView?.setUserTrackingMode(.follow, animated: true)
    }

    // MARK: - Free Look & Pan (for CPMapTemplateDelegate)

    func setFreeLook(_ enabled: Bool) {
        isFreeLook = enabled
    }

    func panMap(latDelta: CLLocationDegrees, lngDelta: CLLocationDegrees) {
        guard let mapView else { return }
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

    /// Feed a fresh engine pose into the interpolator. The display link — not
    /// this call — drives the camera, so motion glides between the ~1Hz poses
    /// instead of teleporting once per second.
    func updateNavigationPose(_ pose: NavPose, headingDegrees: Double?) {
        guard isInNavigation else { return }
        if let heading = headingDegrees ?? pose.segmentBearingDegrees {
            smoothedBearing = heading
        }
        guard pose.fixTimestamp != lastPoseTimestamp else { return }
        lastPoseTimestamp = pose.fixTimestamp
        interpolator.push(pose, at: CACurrentMediaTime())
    }

    /// Adopt the engine's polyline when an auto-reroute swapped it — redraw the
    /// overlay and rebase arc lengths so the camera doesn't chase a stale route.
    func syncRoute(_ coords: [CLLocationCoordinate2D]) {
        guard isInNavigation, coords.count >= 2 else { return }
        if coords.count == navRouteCoords.count,
           let newFirst = coords.first, let oldFirst = navRouteCoords.first,
           let newLast = coords.last, let oldLast = navRouteCoords.last,
           newFirst.latitude == oldFirst.latitude, newFirst.longitude == oldFirst.longitude,
           newLast.latitude == oldLast.latitude, newLast.longitude == oldLast.longitude {
            return // same route
        }
        navRouteCoords = coords
        routeCumulative = RouteGeometry.cumulativeDistances(coords)
        interpolator = NavPoseInterpolator()
        lastPoseTimestamp = nil
        removeRouteLine()
        showRouteLine(coords)
    }

    /// The user's current coordinate from the CarPlay map's authorized location
    /// tracking (nil until the first fix or if invalid). Used by route preview
    /// instead of a fresh CLLocationManager, which is always nil.
    var currentUserCoordinate: CLLocationCoordinate2D? {
        guard let c = mapView?.userLocation.location?.coordinate, CLLocationCoordinate2DIsValid(c) else { return nil }
        return c
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: CarPlayDisplayLinkProxy(self), selector: #selector(CarPlayDisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func displayLinkFired(_ link: CADisplayLink) {
        guard isInNavigation, !isFreeLook, let mapView else { return }
        let now = link.timestamp

        var maxDistance = Double.greatestFiniteMagnitude
        if let total = routeCumulative.last { maxDistance = total }
        guard let distance = interpolator.distanceAlongRoute(at: now, maxDistance: maxDistance),
              let center = RouteGeometry.coordinate(
                  atDistance: distance, polyline: navRouteCoords, cumulative: routeCumulative
              )
        else { return }

        let lookAhead = RouteGeometry.offsetCoordinate(
            center, distanceMeters: 80, bearingDegrees: smoothedBearing
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
        guard let mapView, let coord = mapView.userLocation.location?.coordinate else { return }
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
        guard let mapView else { return }
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
        guard !coordinates.isEmpty, let mapView else { return }
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        routeOverlay = polyline
        mapView.addOverlay(polyline, level: .aboveRoads)
    }

    private func removeRouteLine() {
        if let overlay = routeOverlay {
            mapView?.removeOverlay(overlay)
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
        // Latitude only scales the meters-per-pixel term; 0 (equator) is a safe
        // fallback if the map isn't loaded yet (callers all guard mapView first).
        let lat = mapView?.centerCoordinate.latitude ?? 0
        return 156543.03 * cos(lat * .pi / 180) / pow(2, zoom) * 256
    }
}

/// Breaks the CADisplayLink -> target retain cycle for the CarPlay map.
private final class CarPlayDisplayLinkProxy {
    private weak var controller: CarPlayMapController?
    init(_ controller: CarPlayMapController) { self.controller = controller }
    @objc func tick(_ link: CADisplayLink) {
        guard let controller else { link.invalidate(); return }
        controller.displayLinkFired(link)
    }
}
