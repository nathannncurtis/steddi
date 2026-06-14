import SwiftUI
import MapKit
import CoreLocation

/// Drawing modes for the v2 no-go zone editor. Shared by the editor view and
/// its interactive map.
enum ZoneEditorMode: CaseIterable {
    case circlePin     // Original: tap to place a circle
    case freehandDraw  // Draw freely, snap to roads
    case dotToDot      // Tap waypoints, route between them
    case polygonDraw   // Tap points to build a closed shape
    case namedRoad     // Text input for a road name + bounds
}

/// Interactive map for the v2 no-go zone editor. Renders the preview geometry
/// (circle / corridor / polygon) as red overlays and routes gestures to the
/// editor based on the active drawing mode:
///   - circlePin / dotToDot / polygonDraw: single taps emit coordinates
///   - freehandDraw: a pan stroke emits the full coordinate path on release
///   - namedRoad: no map interaction
struct NoGoZoneMapV2: UIViewRepresentable {
    let previewGeometry: ZoneGeometry?
    let mode: ZoneEditorMode
    /// In-progress polygon/dot taps, drawn as a light guide before the geometry
    /// resolves.
    let inProgressPoints: [CLLocationCoordinate2D]
    let onTapMap: (CLLocationCoordinate2D) -> Void
    let onDrawStroke: ([CLLocationCoordinate2D]) -> Void
    @Binding var mapViewRef: MKMapView?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.overrideUserInterfaceStyle = SteddiTheme.currentThemeMode.mapInterfaceStyle
        mapView.delegate = context.coordinator
        mapView.preferredConfiguration = SteddiTheme.mapConfiguration(traffic: false)
        mapView.showsUserLocation = true
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

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        mapView.addGestureRecognizer(pan)
        context.coordinator.drawPan = pan

        context.coordinator.mapView = mapView
        DispatchQueue.main.async { mapViewRef = mapView }
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.onTapMap = onTapMap
        context.coordinator.onDrawStroke = onDrawStroke
        context.coordinator.mode = mode
        // Only intercept pan when drawing freehand; otherwise let the map scroll.
        context.coordinator.drawPan?.isEnabled = (mode == .freehandDraw)

        mapView.removeOverlays(mapView.overlays)
        addGuideOverlay(to: mapView)
        addPreviewOverlay(to: mapView)
    }

    private func addGuideOverlay(to mapView: MKMapView) {
        guard inProgressPoints.count >= 2 else { return }
        let line = GuidePolyline(coordinates: inProgressPoints, count: inProgressPoints.count)
        mapView.addOverlay(line, level: .aboveRoads)
    }

    private func addPreviewOverlay(to mapView: MKMapView) {
        guard let geometry = previewGeometry else { return }
        switch geometry {
        case .circle(let center, let radiusMeters):
            mapView.addOverlay(MKCircle(center: center, radius: radiusMeters), level: .aboveRoads)
        case .corridor(let encodedPolyline, _):
            let coords = PolylineEncoder.decode(encodedPolyline, precision: 6)
            guard coords.count >= 2 else { return }
            mapView.addOverlay(MKPolyline(coordinates: coords, count: coords.count), level: .aboveRoads)
        case .polygon(let encodedPolyline):
            let coords = PolylineEncoder.decode(encodedPolyline, precision: 6)
            guard coords.count >= 3 else { return }
            mapView.addOverlay(MKPolygon(coordinates: coords, count: coords.count), level: .aboveRoads)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        weak var mapView: MKMapView?
        weak var drawPan: UIPanGestureRecognizer?
        var onTapMap: ((CLLocationCoordinate2D) -> Void)?
        var onDrawStroke: (([CLLocationCoordinate2D]) -> Void)?
        var mode: ZoneEditorMode = .circlePin

        private var strokePoints: [CLLocationCoordinate2D] = []

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView, gesture.state == .ended, mode != .freehandDraw, mode != .namedRoad else { return }
            let point = gesture.location(in: mapView)
            onTapMap?(mapView.convert(point, toCoordinateFrom: mapView))
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let mapView, mode == .freehandDraw else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            switch gesture.state {
            case .began:
                strokePoints = [coord]
            case .changed:
                strokePoints.append(coord)
            case .ended:
                strokePoints.append(coord)
                if strokePoints.count >= 2 { onDrawStroke?(strokePoints) }
                strokePoints = []
            case .cancelled, .failed:
                strokePoints = []
            default:
                break
            }
        }

        // Freehand pan must beat the map's own scroll pan; other modes leave it
        // disabled so the map scrolls normally.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            mode == .freehandDraw ? false : true
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let red = UIColor(red: 0.91, green: 0.30, blue: 0.24, alpha: 1)
            if let circle = overlay as? MKCircle {
                let r = MKCircleRenderer(circle: circle)
                r.fillColor = red.withAlphaComponent(0.2)
                r.strokeColor = red.withAlphaComponent(0.8)
                r.lineWidth = 2
                return r
            }
            if let polygon = overlay as? MKPolygon {
                let r = MKPolygonRenderer(polygon: polygon)
                r.fillColor = red.withAlphaComponent(0.2)
                r.strokeColor = red.withAlphaComponent(0.8)
                r.lineWidth = 2
                return r
            }
            if overlay is GuidePolyline {
                let r = MKPolylineRenderer(overlay: overlay)
                r.strokeColor = red.withAlphaComponent(0.4)
                r.lineWidth = 2
                r.lineDashPattern = [4, 6]
                return r
            }
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                // Corridors render as a thick translucent stroke approximating
                // the buffered width on screen.
                r.strokeColor = red.withAlphaComponent(0.4)
                r.lineWidth = 12
                r.lineCap = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

/// Distinguishes the in-progress guide line from a resolved corridor polyline
/// so the renderer can style them differently.
private final class GuidePolyline: MKPolyline {}
