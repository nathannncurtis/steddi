import MapKit
import UIKit

/// Shared route-casing constants + helpers. A route line stroked in the raw
/// brand accent (a mid/light hue for several swatches) can wash out over light
/// cartography, park-green fills, and bright traffic overlays. A wider
/// contrasting outline ("casing") under the colored line guarantees a legible
/// edge over any tile — the same technique Apple/Google use, and the same reason
/// the custom puck carries a white border.
enum RouteCasing {
    /// How much wider the casing is than the colored line, in points. Half on
    /// each side, so a 6pt line + 3 → a ~9pt casing showing ~1.5pt of edge.
    static let extraWidth: CGFloat = 3

    /// Casing color for the given map interface style: white under the light
    /// basemap, near-black under the dark one — whichever maximizes the edge
    /// against the accent line and the tiles beneath it.
    static func color(for style: UIUserInterfaceStyle) -> UIColor {
        style == .dark
            ? UIColor(white: 0.0, alpha: 0.55)
            : UIColor(white: 1.0, alpha: 0.9)
    }

    /// Casing color resolved against the current Steddi map interface style.
    static var current: UIColor {
        color(for: SteddiTheme.currentThemeMode.mapInterfaceStyle)
    }
}

/// `MKPolylineRenderer` that draws a contrasting casing under its stroke. Use in
/// place of a plain `MKPolylineRenderer` for any route line that must stay
/// legible over varied map tiles (remaining/active/preview lines). The colored
/// `strokeColor`/`lineWidth` are set by the caller as usual; this just adds the
/// wider outline pass beneath.
final class CasedPolylineRenderer: MKPolylineRenderer {
    /// Casing color. Defaults to the current map style's contrast color; the
    /// caller can override (e.g. to match a per-overlay alpha).
    var casingColor: UIColor = RouteCasing.current

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        // Casing pass: a wider outline in the contrast color, under the line.
        let saved = (color: strokeColor, width: lineWidth)
        strokeColor = casingColor
        lineWidth = saved.width + RouteCasing.extraWidth
        super.draw(mapRect, zoomScale: zoomScale, in: context)
        // Colored pass: the original stroke on top.
        strokeColor = saved.color
        lineWidth = saved.width
        super.draw(mapRect, zoomScale: zoomScale, in: context)
    }
}

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

    /// MapKit constructs overlay renderers through the `init(overlay:)`
    /// designated initializer in some paths (e.g. recreating a renderer for a
    /// re-added overlay). A Swift subclass with non-optional stored properties
    /// must implement it or hit the "unimplemented initializer" trap. Recover
    /// the coordinates when the overlay is a polyline; otherwise degrade to an
    /// empty draw set (the full-line path falls back to the superclass anyway).
    override init(overlay: MKOverlay) {
        if let polyline = overlay as? MKPolyline {
            var c = [CLLocationCoordinate2D](
                repeating: CLLocationCoordinate2D(), count: polyline.pointCount
            )
            polyline.getCoordinates(&c, range: NSRange(location: 0, length: polyline.pointCount))
            self.coords = c
            self.cumulative = RouteGeometry.cumulativeDistances(c)
        } else {
            self.coords = []
            self.cumulative = []
        }
        super.init(overlay: overlay)
        self.lineWidth = 6
        self.lineCap = .round
        self.lineJoin = .round
    }

    /// Contrasting outline drawn under the colored line so the route stays
    /// legible over varied map tiles. Resolved against the live map style.
    var casingColor: UIColor = RouteCasing.current

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        // Full line: defer to MKPolylineRenderer's optimized clipping path, but
        // add the casing pass underneath first (wider outline, then the color).
        guard animationProgress < 1 else {
            let saved = (color: strokeColor, width: lineWidth)
            strokeColor = casingColor
            lineWidth = saved.width + RouteCasing.extraWidth
            super.draw(mapRect, zoomScale: zoomScale, in: context)
            strokeColor = saved.color
            lineWidth = saved.width
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

        context.setLineCap(.round)
        context.setLineJoin(.round)
        // Casing pass: wider contrast outline under the traced colored line.
        context.addPath(path)
        context.setStrokeColor(casingColor.cgColor)
        context.setLineWidth((lineWidth + RouteCasing.extraWidth) / zoomScale)
        context.strokePath()
        // Colored pass on top.
        context.addPath(path)
        context.setStrokeColor((strokeColor ?? SteddiTheme.accentUIColor).cgColor)
        context.setLineWidth(lineWidth / zoomScale)
        context.strokePath()
    }
}
