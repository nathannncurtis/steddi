import MapKit
import UIKit

/// Pure geometry for the route draw-on animation, factored out of the renderer
/// so the partial-path math is unit-testable without a live MapKit context.
///
/// Given a route's vertices, their cumulative arc lengths, and a progress in
/// `0...1`, ``RouteDrawGeometry.partialPath`` returns the run of coordinates that
/// should be stroked — every fully-revealed vertex plus one interpolated tip on
/// the boundary segment. The renderer turns these into device points.
enum RouteDrawGeometry {

    /// The visible prefix of `coords` at `progress`, ending at an interpolated
    /// point partway along the boundary segment.
    ///
    /// - `progress <= 0` → empty (nothing drawn yet).
    /// - `progress >= 1` → the whole polyline.
    /// - otherwise → vertices up to the boundary plus the interpolated tip.
    ///
    /// `cumulative` must be the running arc length per vertex (same count as
    /// `coords`); pass `RouteGeometry.cumulativeDistances(coords)`.
    static func partialPath(
        coords: [CLLocationCoordinate2D],
        cumulative: [Double],
        progress: Double
    ) -> [CLLocationCoordinate2D] {
        guard coords.count >= 2, cumulative.count == coords.count,
              let total = cumulative.last, total > 0 else {
            return coords
        }
        if progress <= 0 { return [] }
        if progress >= 1 { return coords }

        let target = total * progress

        var result: [CLLocationCoordinate2D] = []
        for i in 0..<coords.count {
            if cumulative[i] <= target {
                result.append(coords[i])
            } else {
                // Boundary segment: interpolate the tip between i-1 and i.
                let prevDist = cumulative[i - 1]
                let segLength = cumulative[i] - prevDist
                let t = segLength > 0 ? (target - prevDist) / segLength : 0
                result.append(RouteGeometry.interpolate(from: coords[i - 1], to: coords[i], t: t))
                break
            }
        }
        // A target landing exactly on the last vertex returns the whole line.
        return result
    }

    /// Ease-out cubic — fast start, gentle settle. Matches the spec's
    /// "slight ease-out for delight" without a CAMediaTimingFunction dependency.
    static func easeOut(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        let inv = 1 - clamped
        return 1 - inv * inv * inv
    }
}

/// Custom polyline renderer for the route draw-on (trace-on) animation.
///
/// While `animationProgress < 1`, only the eased prefix of the line is stroked,
/// so the route traces from the user toward the destination. `SteddiMapContainer`
/// drives `animationProgress` 0→1 over ~1.2s on a CADisplayLink; each set calls
/// `setNeedsDisplay()`. At `1` it falls back to `MKPolylineRenderer`'s optimized
/// path. Reduce Motion jumps straight to 1.
///
/// The traveled-portion fade is handled separately by the map container, which
/// swaps this single overlay for a dimmed/bright split pair once tracing ends.
/// Keep the role surgical — this is a drop-in replacement for the plain
/// `MKPolylineRenderer` the map used before, returned from the rendererFor
/// delegate only for the active nav route overlay.
final class RouteDrawRenderer: MKPolylineRenderer {

    /// 0 = nothing drawn, 1 = full polyline. Already eased by the driver.
    var animationProgress: CGFloat = 1.0 {
        didSet {
            guard oldValue != animationProgress else { return }
            setNeedsDisplay()
        }
    }

    private let coords: [CLLocationCoordinate2D]
    private let cumulative: [Double]

    override init(polyline: MKPolyline) {
        var c = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(), count: polyline.pointCount
        )
        polyline.getCoordinates(&c, range: NSRange(location: 0, length: polyline.pointCount))
        self.coords = c
        self.cumulative = RouteGeometry.cumulativeDistances(c)
        super.init(polyline: polyline)
        self.lineWidth = 6
        self.lineCap = .round
        self.lineJoin = .round
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        // Full line: defer to MKPolylineRenderer's optimized clipping path.
        guard animationProgress < 1 else {
            super.draw(mapRect, zoomScale: zoomScale, in: context)
            return
        }

        let visible = RouteDrawGeometry.partialPath(
            coords: coords,
            cumulative: cumulative,
            progress: Double(animationProgress)
        )
        guard visible.count >= 2 else { return }

        let path = CGMutablePath()
        for (i, coord) in visible.enumerated() {
            let mapPoint = MKMapPoint(coord)
            let p = point(for: mapPoint)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }

        context.addPath(path)
        context.setStrokeColor((strokeColor ?? SteddiTheme.accentUIColor).cgColor)
        context.setLineWidth(lineWidth / zoomScale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }
}
