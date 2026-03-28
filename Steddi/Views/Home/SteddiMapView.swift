import SwiftUI
import MapKit
import UIKit
import CoreLocation
import Combine

/// Manages the map in a single UIKit view controller.
/// Navigation uses the same map — Steddi's custom SwiftUI overlay replaces Apple's stock UI.
struct SteddiMapView: UIViewControllerRepresentable {
    @Binding var isNavigating: Bool
    @Binding var is3DView: Bool
    let navigationRoute: MKRoute?
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
        if isNavigating, let route = navigationRoute {
            if !vc.isInNavigation {
                vc.startNavigation(route: route)
            }
            vc.set3DView(is3DView)
        } else if !isNavigating && vc.isInNavigation {
            vc.stopNavigation()
        }
    }
}

class SteddiMapContainer: UIViewController {
    private var mapView: MKMapView!
    var isInNavigation = false
    private var currentIs3D = true
    private var navRouteCoords: [CLLocationCoordinate2D] = []
    private var smoothedBearing: Double = 0
    private var routeOverlay: MKPolyline?
    private var puckAnnotation: MKPointAnnotation?

    var onLongPress: ((CLLocationCoordinate2D) -> Void)?

    /// Creates a soft-cornered triangle pointing up in lavender.
    static func makePuckImage() -> UIImage {
        let size = CGSize(width: 44, height: 44)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let lavender = SteddiTheme.accentUIColor

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
        // Extend map into top/left/right safe areas but NOT bottom (sheet covers bottom)
        let insets = view.safeAreaInsets
        mapView?.frame = CGRect(
            x: -insets.left,
            y: -insets.top,
            width: view.bounds.width + insets.left + insets.right,
            height: view.bounds.height + insets.top // no bottom extension
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        mapView = MKMapView(frame: view.bounds)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.insetsLayoutMarginsFromSafeArea = false
        mapView.delegate = self

        // Clean muted dark map style
        let config = MKStandardMapConfiguration(emphasisStyle: .muted)
        config.showsTraffic = true
        mapView.preferredConfiguration = config
        applyThemeStyle()

        // Show user location with custom puck (handled in delegate)
        mapView.showsUserLocation = true

        // Hide ornaments that clash with Steddi UI
        mapView.showsCompass = false
        mapView.showsScale = false

        // Show 3D buildings
        mapView.showsBuildings = true

        // Clean map — hide POIs
        mapView.pointOfInterestFilter = .excludingAll

        // Match the bottom sheet color so there's no visible gap below the sheet
        let sheetColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1)
                : UIColor(red: 0.98, green: 0.97, blue: 0.96, alpha: 1)
        }
        view.backgroundColor = sheetColor

        view.addSubview(mapView)

        // Long press gesture
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        mapView.addGestureRecognizer(lp)

        // Observe accent color changes
        NotificationCenter.default.addObserver(self, selector: #selector(accentColorChanged), name: .steddiAccentColorChanged, object: nil)

        // Observe theme mode changes
        NotificationCenter.default.addObserver(self, selector: #selector(themeModeChanged), name: .steddiThemeModeChanged, object: nil)

        // Center on user location once available
        mapView.setUserTrackingMode(.follow, animated: false)
    }

    private func applyThemeStyle() {
        mapView.overrideUserInterfaceStyle = SteddiTheme.currentThemeMode.mapInterfaceStyle
    }

    @objc private func themeModeChanged() {
        applyThemeStyle()
    }

    @objc private func accentColorChanged() {
        // Update the puck image directly on the existing annotation view
        if let userLocation = mapView.userLocation as MKAnnotation?,
           let annotationView = mapView.view(for: userLocation) {
            annotationView.image = Self.makePuckImage()
        }

        // Refresh route line if showing
        if isInNavigation, let overlay = routeOverlay {
            if let renderer = mapView.renderer(for: overlay) as? MKPolylineRenderer {
                renderer.strokeColor = SteddiTheme.accentUIColor
                renderer.setNeedsDisplay()
            }
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: mapView)
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        onLongPress?(coordinate)
    }

    func set3DView(_ is3D: Bool) {
        guard currentIs3D != is3D else { return }
        currentIs3D = is3D
        // Update camera immediately with current location
        let coord = mapView.userLocation.coordinate
        guard CLLocationCoordinate2DIsValid(coord) else { return }
        applyCameraForNav(at: coord, course: smoothedBearing, animated: true)
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

    func startNavigation(route: MKRoute) {
        guard !isInNavigation else { return }
        isInNavigation = true

        // Store route coordinates for bearing calculation
        let polyline = route.polyline
        let pointCount = polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        navRouteCoords = coords

        // Add route overlay
        routeOverlay = polyline
        mapView.addOverlay(polyline, level: .aboveRoads)

        // Don't use userTrackingMode — we manage the camera manually like Apple Maps does
        mapView.setUserTrackingMode(.none, animated: false)

        // Add snapped puck annotation
        let puck = MKPointAnnotation()
        puck.coordinate = mapView.userLocation.coordinate
        puckAnnotation = puck
        mapView.addAnnotation(puck)

        // Set initial nav camera immediately so it doesn't stay zoomed out
        let userCoord = mapView.userLocation.coordinate
        if CLLocationCoordinate2DIsValid(userCoord) {
            applyCameraForNav(at: userCoord, course: mapView.userLocation.location?.course ?? 0, animated: true)
        }
    }

    func stopNavigation() {
        guard isInNavigation else { return }
        isInNavigation = false

        // Remove route overlay
        if let overlay = routeOverlay {
            mapView.removeOverlay(overlay)
            routeOverlay = nil
        }

        // Remove snapped puck
        if let puck = puckAnnotation {
            mapView.removeAnnotation(puck)
            puckAnnotation = nil
        }

        navRouteCoords = []

        // Reset to follow mode (no heading) for home screen
        mapView.setUserTrackingMode(.follow, animated: true)
    }
}

// MARK: - MKMapViewDelegate

extension SteddiMapContainer: MKMapViewDelegate {

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation is MKUserLocation {
            // During navigation, hide default user location (we use snapped puck instead)
            if isInNavigation {
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "HiddenUser")
                view.isHidden = true
                return view
            }
            // Non-nav: show custom puck at raw GPS position
            let identifier = "SteddiPuck"
            let annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            annotationView.image = Self.makePuckImage()
            annotationView.canShowCallout = false
            annotationView.centerOffset = .zero
            annotationView.isHidden = false
            return annotationView
        }

        // Snapped navigation puck
        if annotation is MKPointAnnotation {
            let identifier = "NavPuck"
            let annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            annotationView.image = Self.makePuckImage()
            annotationView.canShowCallout = false
            annotationView.centerOffset = .zero
            return annotationView
        }

        return nil
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

    func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
        guard isInNavigation else { return }
        guard let location = userLocation.location else { return }

        // Snap position to route polyline
        let displayCoord: CLLocationCoordinate2D
        if !navRouteCoords.isEmpty {
            displayCoord = NavigationEngine.snapToPolyline(point: location.coordinate, polyline: navRouteCoords)
        } else {
            displayCoord = location.coordinate
        }

        // Move snapped puck
        puckAnnotation?.coordinate = displayCoord

        // Use route-based bearing for stable camera
        let routeBearing = Self.bearingAlongRoute(from: location.coordinate, routeCoords: navRouteCoords)
        let course = routeBearing > 0 ? routeBearing : (location.course >= 0 ? location.course : smoothedBearing)
        smoothedBearing = Self.smoothBearing(current: smoothedBearing, target: course, factor: 0.2)

        applyCameraForNav(at: displayCoord, course: smoothedBearing, animated: true)
    }

    /// Apply the navigation camera — matches Apple Maps driving view behavior
    private func applyCameraForNav(at coord: CLLocationCoordinate2D, course: Double, animated: Bool) {
        if currentIs3D {
            // 3D driving view: tilted, course-up, user in lower third
            let lookAhead = Self.offsetCoordinate(coord, distanceMeters: 60, bearingDegrees: course)
            let camera = MKMapCamera(
                lookingAtCenter: lookAhead,
                fromDistance: 600,
                pitch: 45,
                heading: course
            )
            if animated {
                UIView.animate(withDuration: 0.8, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                    self.mapView.setCamera(camera, animated: false)
                }
            } else {
                mapView.setCamera(camera, animated: false)
            }
        } else {
            // 2D driving view: flat, course-up, centered on user
            let camera = MKMapCamera(
                lookingAtCenter: coord,
                fromDistance: 1200,
                pitch: 0,
                heading: course
            )
            if animated {
                UIView.animate(withDuration: 0.8, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                    self.mapView.setCamera(camera, animated: false)
                }
            } else {
                mapView.setCamera(camera, animated: false)
            }
        }
    }
}
