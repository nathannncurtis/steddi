import Foundation
import CoreLocation

/// A single snapshot of the navigation position projected onto the route polyline.
/// One pose is the source of truth for the puck, the camera, and the compass.
struct NavPose {
    /// Position snapped onto the route polyline.
    let snappedCoordinate: CLLocationCoordinate2D
    /// Index of the polyline segment the pose lies on.
    let segmentIndex: Int
    /// Fractional position along that segment (0...1).
    let t: Double
    /// Meters traveled along the route from its start.
    let distanceAlongRoute: Double
    /// Forward bearing of the route at this pose, looking ~35m ahead along the
    /// polyline. nil when no bearing can be derived — never a 0 sentinel.
    let segmentBearingDegrees: Double?
    /// Ground speed in meters per second (>= 0).
    let speedMPS: Double
    /// Timestamp of the GPS fix that produced this pose.
    let fixTimestamp: Date
}

/// Pure coordinate geometry shared by the navigation engine, the map chase-cam,
/// and CarPlay. All functions are stateless.
enum RouteGeometry {

    // MARK: - Distance & Bearing

    static func haversineDistance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let R = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let sinDLat = sin(dLat / 2)
        let sinDLon = sin(dLon / 2)
        let h = sinDLat * sinDLat + cos(lat1) * cos(lat2) * sinDLon * sinDLon
        return 2 * R * asin(sqrt(h))
    }

    /// Great-circle bearing from one coordinate to another, in degrees 0..<360.
    static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return normalizeBearing(atan2(y, x) * 180 / .pi)
    }

    /// Normalize any angle into 0..<360.
    static func normalizeBearing(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Circular low-pass: move `current` toward `target` by `factor`, handling
    /// the 360/0 wraparound so the shortest arc is always taken.
    static func smoothBearing(current: Double, target: Double, factor: Double) -> Double {
        var diff = target - current
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        return normalizeBearing(current + diff * factor)
    }

    /// Offset a coordinate by a distance along a bearing (chase-cam look-ahead).
    static func offsetCoordinate(_ coord: CLLocationCoordinate2D, distanceMeters: Double, bearingDegrees: Double) -> CLLocationCoordinate2D {
        let R = 6_371_000.0
        let d = distanceMeters / R
        let brng = bearingDegrees * .pi / 180
        let lat1 = coord.latitude * .pi / 180
        let lon1 = coord.longitude * .pi / 180

        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(brng))
        let lon2 = lon1 + atan2(sin(brng) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))

        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    /// Linear interpolation between two coordinates (fine at street scale).
    static func interpolate(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, t: Double) -> CLLocationCoordinate2D {
        let clamped = max(0, min(1, t))
        return CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * clamped,
            longitude: a.longitude + (b.longitude - a.longitude) * clamped
        )
    }

    // MARK: - Polyline Walking

    /// Cumulative meters from the polyline start to each vertex.
    /// Result count equals the polyline count; first element is 0.
    static func cumulativeDistances(_ polyline: [CLLocationCoordinate2D]) -> [Double] {
        guard !polyline.isEmpty else { return [] }
        var result = [Double](repeating: 0, count: polyline.count)
        for i in 1..<polyline.count {
            result[i] = result[i - 1] + haversineDistance(from: polyline[i - 1], to: polyline[i])
        }
        return result
    }

    /// Coordinate found by walking `distance` meters along the polyline.
    /// Stays on the line through curves — never cuts corners.
    static func coordinate(
        atDistance distance: Double,
        polyline: [CLLocationCoordinate2D],
        cumulative: [Double]
    ) -> CLLocationCoordinate2D? {
        guard polyline.count >= 2, cumulative.count == polyline.count,
              let total = cumulative.last, total > 0 else { return polyline.first }
        if distance <= 0 { return polyline.first }
        if distance >= total { return polyline.last }

        // Binary search for the segment containing this arc length
        var lo = 0
        var hi = cumulative.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= distance { lo = mid } else { hi = mid }
        }

        let segLength = cumulative[lo + 1] - cumulative[lo]
        let t = segLength > 0 ? (distance - cumulative[lo]) / segLength : 0
        return interpolate(from: polyline[lo], to: polyline[lo + 1], t: t)
    }

    /// Route bearing at an arc-length position, looking `lookAheadMeters` further
    /// along the polyline. Distance-based so dense vertex runs don't shorten the
    /// look-ahead. nil when the polyline is degenerate.
    static func bearing(
        atDistance distance: Double,
        polyline: [CLLocationCoordinate2D],
        cumulative: [Double],
        lookAheadMeters: Double = 35
    ) -> Double? {
        guard polyline.count >= 2, cumulative.count == polyline.count,
              let total = cumulative.last, total > 0 else { return nil }

        // Anchor the look-ahead window inside the route so the bearing stays
        // stable approaching the destination instead of collapsing to nil.
        let clamped = min(max(0, distance), total)
        let fromDistance = min(clamped, max(0, total - lookAheadMeters))
        let toDistance = min(total, fromDistance + lookAheadMeters)

        guard let from = coordinate(atDistance: fromDistance, polyline: polyline, cumulative: cumulative),
              let to = coordinate(atDistance: toDistance, polyline: polyline, cumulative: cumulative),
              haversineDistance(from: from, to: to) > 0.5 else { return nil }

        return bearing(from: from, to: to)
    }

    /// Collapse out-and-back spikes (… A → B → A …) left in stitched geometry
    /// by legacy chained per-leg routing, where every plot point became a trip
    /// destination with a snap-to-address spur. Iterates until stable so
    /// multi-vertex spurs fully unwind. Adjacent near-duplicates are deduped.
    static func removeSpikes(
        _ polyline: [CLLocationCoordinate2D],
        epsilonMeters: Double = 3
    ) -> [CLLocationCoordinate2D] {
        var coords = polyline
        var changed = true
        while changed {
            changed = false

            // Dedupe adjacent vertices within epsilon
            var deduped: [CLLocationCoordinate2D] = []
            for coord in coords {
                if let last = deduped.last, haversineDistance(from: last, to: coord) < epsilonMeters {
                    continue
                }
                deduped.append(coord)
            }
            if deduped.count != coords.count { changed = true }
            coords = deduped

            // Remove spike apexes whose neighbors coincide
            var i = 1
            while i < coords.count - 1 {
                if haversineDistance(from: coords[i - 1], to: coords[i + 1]) < epsilonMeters {
                    coords.remove(at: i)
                    changed = true
                } else {
                    i += 1
                }
            }
        }
        return coords
    }

    /// Project a point onto one segment. Returns the snapped coordinate, the
    /// fractional position t along the segment, and the perpendicular distance.
    static func projectOntoSegment(
        point: CLLocationCoordinate2D,
        segStart: CLLocationCoordinate2D,
        segEnd: CLLocationCoordinate2D
    ) -> (snapped: CLLocationCoordinate2D, t: Double, distance: Double) {
        let cosLat = cos(point.latitude * .pi / 180)
        let px = (point.longitude - segStart.longitude) * cosLat
        let py = point.latitude - segStart.latitude
        let dx = (segEnd.longitude - segStart.longitude) * cosLat
        let dy = segEnd.latitude - segStart.latitude

        let segLenSq = dx * dx + dy * dy
        var t: Double = 0
        if segLenSq > 0 {
            t = max(0, min(1, ((px * dx) + (py * dy)) / segLenSq))
        }

        let snapped = interpolate(from: segStart, to: segEnd, t: t)
        return (snapped, t, haversineDistance(from: point, to: snapped))
    }
}

// MARK: - Route Projection

/// Result of projecting a GPS fix onto the route polyline.
struct RouteProjection {
    let snappedCoordinate: CLLocationCoordinate2D
    let segmentIndex: Int
    let t: Double
    let distanceAlongRoute: Double
    let perpendicularDistance: Double
}

/// Projects GPS fixes onto a route polyline with a sliding segment window so
/// self-proximate routes (out-and-back, parallel legs) snap to the correct leg.
/// One projection per fix replaces the old trio of full-polyline scans.
struct RouteProjector {

    let polyline: [CLLocationCoordinate2D]
    let cumulativeDistances: [Double]

    /// Windowed snap farther than this triggers a full-polyline rescan.
    private let fullRescanThreshold: Double
    /// Segments searched behind / ahead of the last matched segment.
    private let windowBehind = 1
    private let windowAhead = 50
    /// Perpendicular distances within this many meters are treated as a tie
    /// and broken by continuity of distance-along-route.
    private let tieEpsilonMeters = 1.0

    private var lastSegmentIndex: Int?
    private var lastDistanceAlong: Double?

    var totalDistance: Double { cumulativeDistances.last ?? 0 }

    init(polyline: [CLLocationCoordinate2D], fullRescanThreshold: Double = 80) {
        self.polyline = polyline
        self.cumulativeDistances = RouteGeometry.cumulativeDistances(polyline)
        self.fullRescanThreshold = fullRescanThreshold
    }

    /// Forget the window anchor. Call on reroute or confirmed off-route so the
    /// next fix performs a full rescan instead of trusting a stale segment.
    mutating func resetWindow() {
        lastSegmentIndex = nil
        lastDistanceAlong = nil
    }

    /// Project a raw GPS fix onto the route. Searches a window around the last
    /// matched segment, falling back to a full rescan when the windowed snap is
    /// farther than the off-route threshold.
    mutating func project(_ point: CLLocationCoordinate2D) -> RouteProjection? {
        guard polyline.count >= 2 else { return nil }
        let segmentCount = polyline.count - 1

        var projection: RouteProjection?
        if let last = lastSegmentIndex {
            let lower = max(0, last - windowBehind)
            let upper = min(segmentCount, last + windowAhead + 1)
            projection = bestProjection(of: point, in: lower..<upper)
            if let windowed = projection, windowed.perpendicularDistance > fullRescanThreshold {
                projection = bestProjection(of: point, in: 0..<segmentCount)
            }
        } else {
            projection = bestProjection(of: point, in: 0..<segmentCount)
        }

        if let projection {
            lastSegmentIndex = projection.segmentIndex
            lastDistanceAlong = projection.distanceAlongRoute
        }
        return projection
    }

    /// Route bearing at an arc-length position (distance-based look-ahead).
    func bearing(atDistance distance: Double, lookAheadMeters: Double = 35) -> Double? {
        RouteGeometry.bearing(
            atDistance: distance,
            polyline: polyline,
            cumulative: cumulativeDistances,
            lookAheadMeters: lookAheadMeters
        )
    }

    private func bestProjection(of point: CLLocationCoordinate2D, in range: Range<Int>) -> RouteProjection? {
        var best: RouteProjection?
        for i in range {
            let result = RouteGeometry.projectOntoSegment(point: point, segStart: polyline[i], segEnd: polyline[i + 1])
            let segLength = cumulativeDistances[i + 1] - cumulativeDistances[i]
            let candidate = RouteProjection(
                snappedCoordinate: result.snapped,
                segmentIndex: i,
                t: result.t,
                distanceAlongRoute: cumulativeDistances[i] + segLength * result.t,
                perpendicularDistance: result.distance
            )

            guard let current = best else {
                best = candidate
                continue
            }
            if candidate.perpendicularDistance < current.perpendicularDistance - tieEpsilonMeters {
                best = candidate
            } else if candidate.perpendicularDistance < current.perpendicularDistance + tieEpsilonMeters,
                      continuityPenalty(candidate) < continuityPenalty(current) {
                // Same line within noise — prefer the leg consistent with travel
                best = candidate
            }
        }
        return best
    }

    /// Penalty for breaking distance-along continuity. Forward progress is
    /// cheap; jumping backward along the route is heavily penalized so an
    /// out-and-back return leg doesn't re-snap to the outbound leg.
    private func continuityPenalty(_ candidate: RouteProjection) -> Double {
        guard let lastAlong = lastDistanceAlong else { return 0 }
        let delta = candidate.distanceAlongRoute - lastAlong
        return delta >= 0 ? delta : -3 * delta
    }
}
