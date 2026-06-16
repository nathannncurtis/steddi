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
    var savedRoutePolyline: [CLLocationCoordinate2D]?
    var engine: NavigationEngine?
    /// Active conditions for the displayed route, rendered as map badges.
    var roadConditions: [RoadCondition] = []
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
        vc.navigationEngine = engine
        vc.setRoadConditions(roadConditions)
        if isNavigating, let route = navigationRoute {
            // MKRoute path (dumb nav / search)
            print("[STEDDI-MAP] updateUI: MKRoute path, isInNav=\(vc.isInNavigation)")
            if !vc.isInNavigation {
                vc.savedPolylineOverride = savedRoutePolyline
                vc.startNavigation(route: route)
            }
            vc.set3DView(is3DView)
        } else if isNavigating, navigationRoute == nil, let savedCoords = savedRoutePolyline, !savedCoords.isEmpty {
            // Custom route navigation (no MKRoute, just saved polyline)
            print("[STEDDI-MAP] updateUI: Custom polyline path, \(savedCoords.count) coords, isInNav=\(vc.isInNavigation)")
            if !vc.isInNavigation {
                vc.startCustomNavigation(polyline: savedCoords)
            }
            vc.set3DView(is3DView)
        } else if isNavigating {
            // isNavigating is true but no route data yet — waiting
            print("[STEDDI-MAP] updateUI: isNavigating=true but no route data. navigationRoute=\(navigationRoute != nil), savedRoutePolyline=\(savedRoutePolyline?.count ?? 0)")
        } else if !isNavigating && vc.isInNavigation {
            print("[STEDDI-MAP] updateUI: stopping navigation")
            vc.stopNavigation()
        }
    }
}

class SteddiMapContainer: UIViewController, UIGestureRecognizerDelegate {

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    private var mapView: MKMapView!
    var isInNavigation = false
    private var currentIs3D = true
    private var navRouteCoords: [CLLocationCoordinate2D] = []
    private var smoothedBearing: Double = 0
    private var routeOverlay: MKPolyline?

    // MARK: - Route draw-on animation
    /// Short-lived link that drives the route line's trace-on (0->1 over ~1.2s)
    /// when navigation starts. Self-invalidates on completion; cancelled the
    /// moment the pose loop starts following so an early fix never fights it.
    private var drawOnLink: CADisplayLink?
    private var drawOnStart: TimeInterval = 0
    /// The renderer currently tracing the active route, if any.
    private weak var activeRouteRenderer: RouteDrawRenderer?

    // MARK: - Traveled-portion fade
    /// Behind the puck: the already-driven segment, stroked dimmed.
    private var traveledOverlay: MKPolyline?
    /// Ahead of the puck: the remaining route, stroked at full accent.
    private var remainingOverlay: MKPolyline?
    /// Last split distance (meters along route) we rebuilt the overlays at; the
    /// pair is only rebuilt when the puck advances past it by `splitThreshold` to
    /// avoid per-frame overlay churn (redraw storms).
    private var lastSplitDistance: Double = -1
    /// Minimum advance before the traveled/remaining split is rebuilt.
    private let splitThreshold: Double = 50

    /// Engine whose published pose drives the puck, camera, and compass.
    weak var navigationEngine: NavigationEngine?

    /// Steddi's own navigation puck — driven by the engine's snapped pose, so
    /// it rides the route polyline instead of MapKit's raw-GPS user dot.
    private var puckAnnotation: SteddiPuckAnnotation?

    /// Road-condition badge annotations currently on the map, keyed by id so
    /// re-syncs are diffed instead of churning the whole set.
    private var roadConditionAnnotations: [UUID: RoadConditionAnnotation] = [:]
    /// Last conditions handed to `setRoadConditions`, retained so toggling out of
    /// FreeLook can restore badges that were suppressed while panning freely.
    private var pendingRoadConditions: [RoadCondition] = []

    // Per-frame pose interpolation — one clock for puck AND camera
    private var displayLink: CADisplayLink?
    private var interpolator = NavPoseInterpolator()
    private var routeCumulativeDistances: [Double] = []
    private var lastPoseTimestamp: Date?
    private var lastFrameTimestamp: TimeInterval = 0
    private var hasSmoothedBearing = false

    deinit {
        // Both display links retain their proxy target on the run loop; the
        // observers retain self. Tear them all down so a deallocated container
        // doesn't leave links firing or stale observers registered.
        displayLink?.invalidate()
        drawOnLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    private var lastDisplayCoordinate: CLLocationCoordinate2D?
    /// Per-frame camera writes are suppressed until this time while a one-shot
    /// camera animation (recenter, 2D/3D toggle, nav start) is in flight.
    private var cameraTransitionUntil: TimeInterval = 0
    /// Time constant of the per-frame heading low-pass, seconds.
    private let headingTau: Double = 0.7
    /// The puck blends back toward raw GPS beyond this perpendicular distance —
    /// never snap-display a driver who genuinely left the route.
    private let offRouteBlendStartMeters: Double = 30

    /// When true, camera auto-follow is paused (user is panning/exploring the map)
    private var isFreeLook = false
    private var recenterButton: UIButton?

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
        // Position the recenter chip so it never collides with the nav overlay's
        // floating control cluster (compass / voice / view / report).
        //
        // In PORTRAIT that cluster is pinned top-TRAILING (SteddiNavOverlay
        // `floatingClusterTopOffset` + .padding(.trailing,16)), and on a short
        // device (e.g. 4.7" SE, 667pt) its bottom button reaches down into the
        // same trailing column the recenter chip used to share — overlapping the
        // hazard-report control mid-drive. So in portrait the chip moves to the
        // LEADING side, a column the portrait overlay never occupies.
        //
        // In LANDSCAPE the overlay's control cluster + ETA bar live bottom-LEADING
        // instead, so the chip stays on the TRAILING side there. Either way it sits
        // above the bottom bar and inside the horizontal safe area.
        let recenterSize: CGFloat = 44
        let isLandscape = view.bounds.width > view.bounds.height
        let recenterX: CGFloat = isLandscape
            ? view.bounds.width - insets.right - 16 - recenterSize
            : insets.left + 16
        // Anchor the chip dynamically above the bottom bar + safe area instead of
        // a fixed `height - 200`. The nav overlay's bottom bar scales with the
        // user's icon scale (speedometer = 64*iconScale framed in 14pt vertical
        // padding, mirroring SteddiNavOverlay.bottomBar), so at large Dynamic
        // Type / Accessibility icon scale a fixed 200pt line fell INSIDE the bar
        // (and the reroute/camera banners that stack above it), hiding the only
        // mid-drive exit from free-look back to follow mode. Derive the clearance
        // from the actual scaled bar height + the home-indicator safe area, with
        // the original 200pt as a never-lower-than floor so this only ever lifts
        // the chip at large scales, never drops it below where it sat before.
        let iconScale = CGFloat(DisplayModeService.shared.iconScale)
        let scaledBottomBarHeight = 64 * iconScale + 28      // speedometer + 14*2 vpad
        let clearance: CGFloat = 24                          // gap above the bar
        let dynamicBottomOffset = insets.bottom + scaledBottomBarHeight + clearance
        let recenterY = view.bounds.height - max(200, dynamicBottomOffset + recenterSize)
        recenterButton?.frame = CGRect(
            x: recenterX,
            y: recenterY,
            width: recenterSize,
            height: recenterSize
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        mapView = MKMapView(frame: view.bounds)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.insetsLayoutMarginsFromSafeArea = false
        mapView.delegate = self

        mapView.preferredConfiguration = SteddiTheme.mapConfiguration(traffic: true, poiFilter: .excludingAll)
        applyThemeStyle()

        // Show user location with custom puck (handled in delegate)
        mapView.showsUserLocation = true

        // Hide ornaments that clash with Steddi UI
        mapView.showsCompass = false
        mapView.showsScale = false

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

        // Detect user pan/pinch to pause auto-follow
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleUserMapInteraction(_:)))
        pan.delegate = self
        mapView.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleUserMapInteraction(_:)))
        pinch.delegate = self
        mapView.addGestureRecognizer(pinch)

        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleUserMapInteraction(_:)))
        rotate.delegate = self
        mapView.addGestureRecognizer(rotate)

        // Recenter button (hidden until free-look)
        let btn = UIButton(type: .system)
        // SF Symbol scaled by a text style so the glyph tracks Dynamic Type
        // (the body-style metrics grow it for larger content sizes) while the
        // chip stays in its fixed 44pt frame — the glyph alone scales, not the
        // touch target.
        let recenterGlyph = UIImage(
            systemName: "location.fill",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)
        )
        btn.setImage(recenterGlyph, for: .normal)
        // VoiceOver: a bare SF Symbol does not derive a meaningful name, so this
        // would otherwise announce as just "Button". This is the only mid-drive
        // exit from free-look back to follow-mode, so it must be clearly labeled.
        btn.accessibilityLabel = NSLocalizedString("Recenter map", comment: "Recenter button accessibility label")
        btn.accessibilityTraits = .button
        // Glyph that CONTRASTS the fill, not the raw brand accent. The brand
        // accents are mid/light hues — on the near-white light-mode fill below
        // they fail the 3:1 large-glyph floor (gold ~2.2:1, lavender ~2.7:1).
        // `contrastingForeground(on:)` returns near-black on the light fill and
        // near-white on the dark fill, so the location arrow clears contrast in
        // every theme (the fill carries the brand surface; the glyph stays legible).
        btn.tintColor = UIColor { traits in
            let white: Double = traits.userInterfaceStyle == .dark ? 0.1 : 0.96
            let fill = RGBColor(white, white, white)
            return ContrastRatio.contrastingForeground(on: fill).uiColor
        }
        // Theme- and contrast-aware: light surface in light mode, dark in dark
        // mode, and fully opaque under Increase Contrast so it never washes out
        // over the map (was a hardcoded dark translucent fill for both themes).
        // Default alpha raised 0.9 → 0.95 so the fill reads as a solid chip
        // rather than a translucent wash that lets bright map detail bleed through.
        btn.backgroundColor = UIColor { traits in
            let white: CGFloat = traits.userInterfaceStyle == .dark ? 0.1 : 0.96
            let alpha: CGFloat = traits.accessibilityContrast == .high ? 1.0 : 0.95
            return UIColor(white: white, alpha: alpha)
        }
        // Give the button a visible BOUNDARY independent of fill-vs-map
        // luminance: over the near-white light-map cartography the 0.96 fill was
        // within a couple percent of the tiles, so the circle's edge vanished.
        // A hairline stroke in the contrasting foreground color + a soft drop
        // shadow make the 44pt affordance read on any tile (this is the only
        // exit from free-look back to follow-mode mid-drive).
        btn.layer.borderWidth = 1
        Self.applyRecenterBorderColor(to: btn)
        btn.layer.shadowColor = UIColor.black.cgColor
        btn.layer.shadowOpacity = 0.2
        btn.layer.shadowRadius = 6
        btn.layer.shadowOffset = CGSize(width: 0, height: 2)
        btn.layer.cornerRadius = 22
        btn.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        btn.addTarget(self, action: #selector(recenterTapped), for: .touchUpInside)
        btn.isHidden = true
        view.addSubview(btn)
        recenterButton = btn

        // Observe accent color changes
        NotificationCenter.default.addObserver(self, selector: #selector(accentColorChanged), name: .steddiAccentColorChanged, object: nil)

        // Observe theme mode changes
        NotificationCenter.default.addObserver(self, selector: #selector(themeModeChanged), name: .steddiThemeModeChanged, object: nil)

        // Pause the per-frame nav loop while backgrounded
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)

        // Center on user location once available
        mapView.setUserTrackingMode(.follow, animated: false)
    }

    private func applyThemeStyle() {
        let style = SteddiTheme.currentThemeMode.mapInterfaceStyle
        // Apply on BOTH the container view and the map view. Setting it only on
        // the MKMapView in `viewDidLoad` (before the view is in a window) let
        // MapKit fetch its first cartography tiles against the inherited
        // scene/window style — so the Dark / dynamic-night map rendered LIGHT at
        // cold launch until the next `.steddiThemeModeChanged` (which never fires
        // for a fresh map). Overriding the container view's trait first
        // propagates the dark style down before the map renders, and reasserting
        // it on the map view makes the cold-launch cartography deterministic.
        view.overrideUserInterfaceStyle = style
        mapView.overrideUserInterfaceStyle = style
    }

    @objc private func themeModeChanged() {
        applyThemeStyle()
        // borderColor is a frozen CGColor (CALayer can't resolve a dynamic
        // UIColor across a theme switch), so recompute it for the new style.
        if let btn = recenterButton { Self.applyRecenterBorderColor(to: btn) }
    }

    /// Hairline border that contrasts the recenter button's own fill, resolved
    /// against the button's effective light/dark style. Frozen as a CGColor, so
    /// it is re-applied on every theme switch (see themeModeChanged).
    private static func applyRecenterBorderColor(to btn: UIButton) {
        let style = SteddiTheme.currentThemeMode.mapInterfaceStyle
        let isDark: Bool = {
            switch style {
            case .dark: return true
            case .light: return false
            default: return UITraitCollection.current.userInterfaceStyle == .dark
            }
        }()
        let white: Double = isDark ? 0.1 : 0.96
        let fill = RGBColor(white, white, white)
        btn.layer.borderColor = ContrastRatio.contrastingForeground(on: fill).uiColor
            .withAlphaComponent(0.25).cgColor
    }

    @objc private func accentColorChanged() {
        // Update the puck image directly on the existing annotation views
        if let userLocation = mapView.userLocation as MKAnnotation?,
           let annotationView = mapView.view(for: userLocation) {
            annotationView.image = Self.makePuckImage()
        }
        if let puck = puckAnnotation, let puckView = mapView.view(for: puck) {
            puckView.image = Self.makePuckImage()
        }

        // Refresh route line if showing — the single overlay and either half of
        // the traveled/remaining split.
        if isInNavigation {
            if let overlay = routeOverlay,
               let renderer = mapView.renderer(for: overlay) as? MKPolylineRenderer {
                renderer.strokeColor = SteddiTheme.accentUIColor
                renderer.setNeedsDisplay()
            }
            if let overlay = remainingOverlay,
               let renderer = mapView.renderer(for: overlay) as? MKPolylineRenderer {
                renderer.strokeColor = SteddiTheme.accentUIColor
                renderer.setNeedsDisplay()
            }
            if let overlay = traveledOverlay,
               let renderer = mapView.renderer(for: overlay) as? MKPolylineRenderer {
                renderer.strokeColor = SteddiTheme.accentUIColor.withAlphaComponent(0.3)
                renderer.setNeedsDisplay()
            }
        }
    }

    @objc private func handleUserMapInteraction(_ gesture: UIGestureRecognizer) {
        guard isInNavigation else { return }
        if gesture.state == .began {
            isFreeLook = true
            recenterButton?.isHidden = false
            // Free-looking: pull badges so they don't churn while panning.
            syncRoadConditionAnnotations()
        }
    }

    @objc private func recenterTapped() {
        isFreeLook = false
        recenterButton?.isHidden = true
        // Restore any badges that were suppressed while panning freely.
        syncRoadConditionAnnotations()
        // Snap back to the last interpolated pose position
        let coord = lastDisplayCoordinate ?? mapView.userLocation.location?.coordinate
        if let coord, CLLocationCoordinate2DIsValid(coord) {
            applyCameraForNav(at: coord, course: smoothedBearing, animated: true)
        }
    }

    // MARK: - Road Condition Badges

    /// Update the route-scoped condition badges shown on the map. Diffs against
    /// what's already displayed so unchanged badges aren't recreated.
    func setRoadConditions(_ conditions: [RoadCondition]) {
        guard mapView != nil else { return }
        pendingRoadConditions = conditions
        syncRoadConditionAnnotations()
    }

    /// Reconcile on-map condition annotations with `pendingRoadConditions`.
    /// Suppressed entirely while the user is free-looking so badges don't pop in
    /// and out as they pan; restored on recenter.
    private func syncRoadConditionAnnotations() {
        guard mapView != nil else { return }

        if isFreeLook {
            if !roadConditionAnnotations.isEmpty {
                mapView.removeAnnotations(Array(roadConditionAnnotations.values))
                roadConditionAnnotations.removeAll()
            }
            return
        }

        let desired = Dictionary(uniqueKeysWithValues: pendingRoadConditions.map { ($0.id, $0) })

        // Remove badges no longer present.
        let stale = roadConditionAnnotations.filter { desired[$0.key] == nil }
        if !stale.isEmpty {
            mapView.removeAnnotations(Array(stale.values))
            for key in stale.keys { roadConditionAnnotations[key] = nil }
        }

        // Add badges not yet on the map.
        for (id, condition) in desired where roadConditionAnnotations[id] == nil {
            let annotation = RoadConditionAnnotation(condition: condition)
            roadConditionAnnotations[id] = annotation
            mapView.addAnnotation(annotation)
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
        // Update camera immediately from the last interpolated pose
        let coord = lastDisplayCoordinate ?? mapView.userLocation.coordinate
        guard CLLocationCoordinate2DIsValid(coord) else { return }
        applyCameraForNav(at: coord, course: smoothedBearing, animated: true)
    }

    /// Saved polyline override — when set, the map renders this instead of MKRoute's polyline.
    var savedPolylineOverride: [CLLocationCoordinate2D]?

    /// Swap the raw-GPS system dot for Steddi's engine-driven puck.
    private func beginCustomPuck() {
        mapView.view(for: mapView.userLocation)?.isHidden = true
        let coord = mapView.userLocation.coordinate
        if CLLocationCoordinate2DIsValid(coord), coord.latitude != 0 || coord.longitude != 0 {
            updatePuck(coordinate: coord)
        }
    }

    /// Remove the custom puck and restore the system dot.
    private func endCustomPuck() {
        if let puck = puckAnnotation {
            mapView.removeAnnotation(puck)
            puckAnnotation = nil
        }
        mapView.view(for: mapView.userLocation)?.isHidden = false
    }

    /// Move the custom puck, creating it lazily on the first real coordinate.
    private func updatePuck(coordinate: CLLocationCoordinate2D) {
        if let puck = puckAnnotation {
            puck.coordinate = coordinate
        } else {
            let puck = SteddiPuckAnnotation(coordinate: coordinate)
            puckAnnotation = puck
            mapView.addAnnotation(puck)
        }
    }

    func startNavigation(route: MKRoute) {
        guard !isInNavigation else { return }
        isInNavigation = true
        beginCustomPuck()

        // Use saved polyline if available, otherwise use the MKRoute polyline
        if let savedCoords = savedPolylineOverride, savedCoords.count >= 2 {
            navRouteCoords = savedCoords
            let polyline = MKPolyline(coordinates: savedCoords, count: savedCoords.count)
            routeOverlay = polyline
            mapView.addOverlay(polyline, level: .aboveRoads)
        } else {
            let polyline = route.polyline
            let pointCount = polyline.pointCount
            var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
            polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
            navRouteCoords = coords
            routeOverlay = polyline
            mapView.addOverlay(polyline, level: .aboveRoads)
        }

        // Don't use userTrackingMode — we manage the camera manually like Apple Maps does
        mapView.setUserTrackingMode(.none, animated: false)

        // Set initial nav camera immediately so it doesn't stay zoomed out
        let userCoord = mapView.userLocation.coordinate
        if CLLocationCoordinate2DIsValid(userCoord) {
            applyCameraForNav(at: userCoord, course: mapView.userLocation.location?.course ?? 0, animated: true)
        }

        beginPoseDrivenFollowing()
        scheduleRouteDrawOn()
    }

    /// Start navigation with just a polyline (no MKRoute). Used for saved/custom routes.
    func startCustomNavigation(polyline: [CLLocationCoordinate2D]) {
        guard !isInNavigation, polyline.count >= 2 else { return }
        isInNavigation = true
        beginCustomPuck()
        navRouteCoords = polyline

        let mkPolyline = MKPolyline(coordinates: polyline, count: polyline.count)
        routeOverlay = mkPolyline
        mapView.addOverlay(mkPolyline, level: .aboveRoads)

        mapView.setUserTrackingMode(.none, animated: false)

        let userCoord = mapView.userLocation.coordinate
        if CLLocationCoordinate2DIsValid(userCoord) {
            applyCameraForNav(at: userCoord, course: mapView.userLocation.location?.course ?? 0, animated: true)
        }

        beginPoseDrivenFollowing()
        scheduleRouteDrawOn()
    }

    /// Kick the draw-on after MapKit has had a runloop turn to build the route
    /// renderer (rendererFor captures it). The pose loop runs in parallel and
    /// cancels the trace once the puck starts genuinely advancing.
    private func scheduleRouteDrawOn() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isInNavigation else { return }
            self.beginRouteDrawOn()
        }
    }

    func stopNavigation() {
        guard isInNavigation else { return }
        isInNavigation = false
        isFreeLook = false
        recenterButton?.isHidden = true
        endRouteDrawOn()
        activeRouteRenderer = nil
        clearTraveledSplit()
        endPoseDrivenFollowing()
        endCustomPuck()

        // Remove route overlay
        if let overlay = routeOverlay {
            mapView.removeOverlay(overlay)
            routeOverlay = nil
        }

        navRouteCoords = []

        // Reset to follow mode (no heading) for home screen
        mapView.setUserTrackingMode(.follow, animated: true)
    }

    // MARK: - Pose-Driven Following (display link)

    /// Start the per-frame loop that drives puck and camera from the engine's
    /// interpolated pose — one position, one heading, one clock.
    private func beginPoseDrivenFollowing() {
        endPoseDrivenFollowing()
        interpolator.reset()
        routeCumulativeDistances = RouteGeometry.cumulativeDistances(navRouteCoords)
        lastPoseTimestamp = nil
        lastFrameTimestamp = 0
        hasSmoothedBearing = false
        lastDisplayCoordinate = nil

        // Weak proxy target — CADisplayLink retains its target strongly
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func endPoseDrivenFollowing() {
        displayLink?.invalidate()
        displayLink = nil
        routeCumulativeDistances = []
    }

    // MARK: - Route Draw-On

    /// Trace the route line on from the user toward the destination over ~1.2s.
    /// Reduce Motion (or a missing renderer) jumps straight to the full line.
    private func beginRouteDrawOn() {
        endRouteDrawOn()
        guard SteddiMotion.shouldAnimate, let renderer = activeRouteRenderer else {
            activeRouteRenderer?.animationProgress = 1
            return
        }
        renderer.animationProgress = 0
        drawOnStart = CACurrentMediaTime()
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.drawOnTick(_:)))
        link.add(to: .main, forMode: .common)
        drawOnLink = link
    }

    /// Finish the trace immediately (route render complete) and tear down the
    /// link. Called on completion, on nav stop, and the moment the pose loop
    /// takes over so an early GPS fix never strokes a half-drawn line.
    private func endRouteDrawOn() {
        drawOnLink?.invalidate()
        drawOnLink = nil
        activeRouteRenderer?.animationProgress = 1
    }

    fileprivate func drawOnTick(_ link: CADisplayLink) {
        guard let renderer = activeRouteRenderer else { endRouteDrawOn(); return }
        let elapsed = CACurrentMediaTime() - drawOnStart
        let t = min(1, elapsed / TransitionKit.routeDrawDuration)
        renderer.animationProgress = CGFloat(RouteDrawGeometry.easeOut(t))
        if t >= 1 { endRouteDrawOn() }
    }

    // MARK: - Traveled-Portion Fade

    /// Split the route into a dimmed traveled segment (start -> puck) and a
    /// bright remaining segment (puck -> end). Threshold-gated so the overlay
    /// pair is only rebuilt when the puck has advanced enough — never per frame.
    /// Skipped under Reduce Motion and while the draw-on is still tracing.
    private func updateTraveledSplit(distance: Double) {
        guard SteddiMotion.shouldAnimate, isInNavigation, drawOnLink == nil,
              navRouteCoords.count >= 2,
              let total = routeCumulativeDistances.last, total > 0 else { return }

        // Only rebuild when the split has moved past the threshold.
        if lastSplitDistance >= 0, abs(distance - lastSplitDistance) < splitThreshold { return }
        lastSplitDistance = distance

        let split = min(max(distance, 0), total)
        let traveled = RouteDrawGeometry.partialPath(
            coords: navRouteCoords, cumulative: routeCumulativeDistances,
            progress: split / total
        )
        // Remaining = the rest of the line, anchored on the same split tip.
        var remaining: [CLLocationCoordinate2D] = []
        if let tip = traveled.last { remaining.append(tip) }
        for (i, dist) in routeCumulativeDistances.enumerated() where dist > split {
            remaining.append(navRouteCoords[i])
        }

        // Remove the prior pair (and the original single overlay) before re-adding.
        if let o = traveledOverlay { mapView.removeOverlay(o); traveledOverlay = nil }
        if let o = remainingOverlay { mapView.removeOverlay(o); remainingOverlay = nil }
        if let o = routeOverlay { mapView.removeOverlay(o); routeOverlay = nil }

        if traveled.count >= 2 {
            let poly = MKPolyline(coordinates: traveled, count: traveled.count)
            traveledOverlay = poly
            mapView.addOverlay(poly, level: .aboveRoads)
        }
        if remaining.count >= 2 {
            let poly = MKPolyline(coordinates: remaining, count: remaining.count)
            remainingOverlay = poly
            mapView.addOverlay(poly, level: .aboveRoads)
        }
    }

    private func clearTraveledSplit() {
        if let o = traveledOverlay { mapView.removeOverlay(o); traveledOverlay = nil }
        if let o = remainingOverlay { mapView.removeOverlay(o); remainingOverlay = nil }
        lastSplitDistance = -1
    }

    /// Every nav start hands the map and the engine the same polyline, but an
    /// automatic off-route reroute restarts only the engine. When the engine's
    /// route no longer matches ours, adopt it: overlay, cumulative distances,
    /// and a fresh interpolator (pose distances reference the new route).
    private func syncRouteWithEngineIfNeeded(_ engine: NavigationEngine) {
        let engineCoords = engine.routePolylineCoordinates
        guard engineCoords.count >= 2 else { return }

        if engineCoords.count == navRouteCoords.count,
           let engineFirst = engineCoords.first, let mapFirst = navRouteCoords.first,
           let engineLast = engineCoords.last, let mapLast = navRouteCoords.last,
           engineFirst.latitude == mapFirst.latitude, engineFirst.longitude == mapFirst.longitude,
           engineLast.latitude == mapLast.latitude, engineLast.longitude == mapLast.longitude {
            return // same route
        }

        navRouteCoords = engineCoords
        routeCumulativeDistances = RouteGeometry.cumulativeDistances(engineCoords)
        interpolator.reset()
        lastPoseTimestamp = nil

        // A reroute replaces the line entirely — drop the old single overlay and
        // any traveled/remaining split so the fresh route renders bright.
        if let overlay = routeOverlay {
            mapView.removeOverlay(overlay)
        }
        clearTraveledSplit()
        let polyline = MKPolyline(coordinates: engineCoords, count: engineCoords.count)
        routeOverlay = polyline
        mapView.addOverlay(polyline, level: .aboveRoads)
    }

    @objc private func appDidEnterBackground() {
        displayLink?.isPaused = true
    }

    @objc private func appWillEnterForeground() {
        displayLink?.isPaused = false
    }

    fileprivate func displayLinkFired(_ link: CADisplayLink) {
        guard isInNavigation, let engine = navigationEngine, engine.isNavigating else { return }
        // Phone locked with CarPlay connected: the app-level background
        // notification never fires (the CarPlay scene stays foreground), but
        // the PHONE scene does background on lock — gate on the hosting
        // scene's activation state so an unseen map never burns 30fps writes.
        guard let scene = view.window?.windowScene, scene.activationState == .foregroundActive else { return }
        let now = link.timestamp

        // Auto-reroute swaps the engine's polyline without restarting the map —
        // adopt it before interpreting arc lengths against the wrong route
        syncRouteWithEngineIfNeeded(engine)

        // Feed any new fix into the interpolator (deduped by fix timestamp)
        if let pose = engine.navPose, pose.fixTimestamp != lastPoseTimestamp {
            lastPoseTimestamp = pose.fixTimestamp
            interpolator.push(pose, at: now)
        }
        guard let currentPose = interpolator.currentPose else { return }

        // Never extrapolate past the next maneuver or the route end
        var maxDistance = currentPose.distanceAlongRoute + max(0, engine.stepDistanceRaw)
        if let total = routeCumulativeDistances.last {
            maxDistance = min(maxDistance, total)
        }
        guard let distance = interpolator.distanceAlongRoute(at: now, maxDistance: maxDistance) else { return }

        // Cancel the route trace-on the moment the driver starts moving — the
        // line should be whole before the puck overtakes the drawn tip.
        if drawOnLink != nil, distance > 5 {
            endRouteDrawOn()
        }

        // Dim the segment already driven (threshold-gated, no redraw storm).
        updateTraveledSplit(distance: distance)

        // Walk the polyline back to a coordinate — stays on the line through curves
        var displayCoord = RouteGeometry.coordinate(
            atDistance: distance,
            polyline: navRouteCoords,
            cumulative: routeCumulativeDistances
        ) ?? currentPose.snappedCoordinate

        // Off-route honesty: blend the puck back toward raw GPS when the fix is
        // genuinely far from the line, instead of pretending we're on-route
        var offRouteBlend: Double = 0
        if let raw = engine.currentCoordinate {
            let perpendicular = RouteGeometry.haversineDistance(from: raw, to: currentPose.snappedCoordinate)
            if perpendicular > offRouteBlendStartMeters {
                offRouteBlend = min(1, (perpendicular - offRouteBlendStartMeters) / offRouteBlendStartMeters)
                displayCoord = RouteGeometry.interpolate(from: displayCoord, to: raw, t: offRouteBlend)
            }
        }

        // Heading: route tangent at the interpolated position while on-route,
        // the engine's published bearing (GPS-course based) while blending off
        let routeBearing = RouteGeometry.bearing(
            atDistance: distance,
            polyline: navRouteCoords,
            cumulative: routeCumulativeDistances
        )
        let targetBearing = offRouteBlend > 0
            ? (engine.headingDegrees ?? routeBearing)
            : (routeBearing ?? engine.headingDegrees)

        let dt = lastFrameTimestamp > 0 ? max(0.001, now - lastFrameTimestamp) : link.duration
        lastFrameTimestamp = now
        if let targetBearing {
            if hasSmoothedBearing {
                // Per-frame exponential low-pass with time constant headingTau
                let alpha = 1 - exp(-dt / headingTau)
                smoothedBearing = RouteGeometry.smoothBearing(current: smoothedBearing, target: targetBearing, factor: alpha)
            } else {
                smoothedBearing = targetBearing
                hasSmoothedBearing = true
            }
        }

        lastDisplayCoordinate = displayCoord

        // One transaction, no implicit animations: puck and camera move from
        // the same interpolated pose on the same frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updatePuck(coordinate: displayCoord)
        if !isFreeLook, CACurrentMediaTime() >= cameraTransitionUntil {
            applyCameraForNav(at: displayCoord, course: smoothedBearing, animated: false)
        }
        // Counter-rotate the puck so it points along the travel bearing even
        // when the camera heading lags or the user is free-looking
        if let puck = puckAnnotation, let puckView = mapView.view(for: puck) {
            let angle = (smoothedBearing - mapView.camera.heading) * .pi / 180
            puckView.transform = CGAffineTransform(rotationAngle: angle)
        }
        CATransaction.commit()
    }
}

/// Breaks the CADisplayLink -> target retain cycle.
private final class DisplayLinkProxy {
    private weak var container: SteddiMapContainer?

    init(_ container: SteddiMapContainer) {
        self.container = container
    }

    @objc func tick(_ link: CADisplayLink) {
        container?.displayLinkFired(link)
    }

    @objc func drawOnTick(_ link: CADisplayLink) {
        container?.drawOnTick(link)
    }
}

// MARK: - MKMapViewDelegate

extension SteddiMapContainer: MKMapViewDelegate {

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation is SteddiPuckAnnotation {
            let identifier = "SteddiNavPuck"
            let puckView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            puckView.annotation = annotation
            puckView.image = Self.makePuckImage()
            puckView.canShowCallout = false
            // Anchor the triangle's visual centroid — not the image center —
            // on the coordinate so the puck pivots around its own body
            puckView.centerOffset = CGPoint(x: 0, y: -6)
            puckView.zPriority = .max
            return puckView
        }

        if annotation is RoadConditionAnnotation {
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: RoadConditionMarkerView.reuseIdentifier
            ) as? RoadConditionMarkerView
                ?? RoadConditionMarkerView(
                    annotation: annotation,
                    reuseIdentifier: RoadConditionMarkerView.reuseIdentifier
                )
            view.annotation = annotation
            return view
        }

        guard annotation is MKUserLocation else { return nil }

        let identifier = "SteddiPuck"
        let annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        annotationView.image = Self.makePuckImage()
        annotationView.canShowCallout = false
        annotationView.centerOffset = .zero
        // The system annotation tracks raw GPS on MapKit's own animation clock —
        // hidden during nav in favor of the engine-snapped custom puck
        annotationView.isHidden = isInNavigation
        return annotationView
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        // Traveled (behind the puck): a dimmed breadcrumb trail.
        if let polyline = overlay as? MKPolyline, polyline === traveledOverlay {
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = SteddiTheme.accentUIColor.withAlphaComponent(0.3)
            renderer.lineWidth = 6
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
        // Remaining (ahead of the puck): full-accent bright line, with a
        // contrasting casing so it stays legible over any map tile.
        if let polyline = overlay as? MKPolyline, polyline === remainingOverlay {
            let renderer = CasedPolylineRenderer(polyline: polyline)
            renderer.strokeColor = SteddiTheme.accentUIColor
            renderer.lineWidth = 6
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
        // The active nav route gets the trace-on renderer; capture it so the
        // draw-on link can drive its progress.
        if let polyline = overlay as? MKPolyline, polyline === routeOverlay {
            let renderer = RouteDrawRenderer(polyline: polyline)
            renderer.strokeColor = SteddiTheme.accentUIColor
            activeRouteRenderer = renderer
            return renderer
        }
        if let polyline = overlay as? MKPolyline {
            let renderer = CasedPolylineRenderer(polyline: polyline)
            renderer.strokeColor = SteddiTheme.accentUIColor
            renderer.lineWidth = 6
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    /// Apply the navigation camera — matches Apple Maps driving view behavior.
    /// The per-frame pose loop calls this with animated:false; one-shot
    /// transitions (recenter, 2D/3D toggle, nav start) use animated:true and
    /// briefly suppress the per-frame writes so the two never fight.
    private func applyCameraForNav(at coord: CLLocationCoordinate2D, course: Double, animated: Bool) {
        let camera: MKMapCamera
        if currentIs3D {
            // 3D driving view: tilted, course-up, user in lower third — the
            // look-ahead offset comes from the same smoothed heading as the camera
            let lookAhead = RouteGeometry.offsetCoordinate(coord, distanceMeters: 60, bearingDegrees: course)
            camera = MKMapCamera(
                lookingAtCenter: lookAhead,
                fromDistance: 600,
                pitch: 45,
                heading: course
            )
        } else {
            // 2D driving view: flat, course-up, centered on user
            camera = MKMapCamera(
                lookingAtCenter: coord,
                fromDistance: 1200,
                pitch: 0,
                heading: course
            )
        }

        if animated {
            cameraTransitionUntil = CACurrentMediaTime() + 0.8
            mapView.setCamera(camera, animated: true)
        } else {
            mapView.setCamera(camera, animated: false)
        }
    }
}

// MARK: - Custom Puck Annotation

/// Annotation backing Steddi's navigation puck. The coordinate is KVO-compliant
/// so MKMapView repositions the view when it changes — and updates wrapped in a
/// CATransaction with actions disabled move it with no implicit animation,
/// keeping the puck on the same clock as the camera.
final class SteddiPuckAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        super.init()
    }
}
