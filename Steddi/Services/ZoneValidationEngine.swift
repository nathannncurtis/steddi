import Foundation
import CoreLocation

/// Pure-geometry validation of candidate routes against no-go zones. Decodes a
/// route polyline once and tests every active zone's geometry against it,
/// reusing the predicates in `RouteGeometry`. Stateless — safe to reuse.
final class ZoneValidationEngine {

    init() {}

    /// Validate a route (encoded polyline, precision 6) against the given zones.
    /// Zones whose time window is inactive at `now` are skipped.
    func validateRoute(
        _ routePolyline: String,
        againstZones zones: [NoGoZone],
        now: Date = Date()
    ) -> RouteValidationResult {
        let routeCoords = PolylineEncoder.decode(routePolyline, precision: 6)
        return validateRoute(coordinates: routeCoords, againstZones: zones, now: now)
    }

    /// Validate a route already decoded to coordinates.
    func validateRoute(
        coordinates routeCoords: [CLLocationCoordinate2D],
        againstZones zones: [NoGoZone],
        now: Date = Date()
    ) -> RouteValidationResult {
        var violations: [ZoneViolation] = []

        for zone in zones {
            guard zone.isActive(now: now) else { continue }
            if let type = violationType(routeCoords: routeCoords, geometry: zone.geometry) {
                violations.append(ZoneViolation(zone: zone, violationType: type))
            }
        }

        return RouteValidationResult(violations: violations)
    }

    /// Whether a single route violates a single geometry, and how. Returns the
    /// nearest/most-severe contact for richer messaging where applicable.
    ///
    /// Tests the route's SEGMENTS, not merely its vertices. MKDirections/OSRM
    /// place a vertex only at a shape change, so a straight run can be hundreds
    /// of meters between consecutive vertices; a small zone sitting on that
    /// segment between two outside vertices would be missed by a vertex-only
    /// test, and the route would drive straight through an avoided area. The
    /// segment-vs-zone predicates mirror `RoutedZone.intersects` (the hard
    /// no-go check in `DefaultCostModel`) so validation and routing agree.
    private func violationType(
        routeCoords: [CLLocationCoordinate2D],
        geometry: ZoneGeometry
    ) -> ViolationType? {
        switch geometry {
        case .circle(let center, let radiusMeters):
            for i in routeCoords.indices {
                // Vertex inside the circle (covers a route that starts/ends or
                // turns inside the zone).
                if RouteGeometry.isPoint(routeCoords[i], withinCircleCenter: center, radiusMeters: radiusMeters) {
                    return .pointInZone
                }
                // Segment passing within the radius with neither endpoint inside
                // (the straight edge that pierces a small zone between vertices).
                if i + 1 < routeCoords.count {
                    let d = RouteGeometry.projectOntoSegment(
                        point: center, segStart: routeCoords[i], segEnd: routeCoords[i + 1]
                    ).distance
                    if d <= radiusMeters { return .pointInZone }
                }
            }
            return nil

        case .corridor(let encodedPolyline, let bufferMeters):
            // decodeValidated guards against a precision-mismatched polyline
            // silently misaligning the buffer; an out-of-bounds decode is
            // skipped rather than mis-tested.
            guard let centerline = PolylineEncoder.decodeValidated(encodedPolyline, precision: 6),
                  !centerline.isEmpty else { return nil }
            var nearest = Double.greatestFiniteMagnitude
            // Vertex-to-centerline distance (point-to-segment under the hood).
            for coord in routeCoords {
                let d = RouteGeometry.distance(from: coord, toPolyline: centerline)
                if d < nearest { nearest = d }
            }
            // Segment-to-segment distance: catches a long straight route edge
            // crossing a narrow corridor perpendicular with both endpoints
            // farther than `bufferMeters` from the centerline. Symmetric with
            // the polygon/circle cases above.
            if routeCoords.count >= 2, centerline.count >= 2 {
                for i in 0..<(routeCoords.count - 1) {
                    let a = routeCoords[i], b = routeCoords[i + 1]
                    for j in 0..<(centerline.count - 1) {
                        let d = RoutedZone.segmentToSegmentDistance(a, b, centerline[j], centerline[j + 1])
                        if d < nearest { nearest = d }
                    }
                }
            }
            return nearest <= bufferMeters ? .corridorViolation(distanceMeters: nearest) : nil

        case .polygon(let encodedPolyline):
            guard let polygon = PolylineEncoder.decodeValidated(encodedPolyline, precision: 6) else { return nil }
            // A route VERTEX inside the polygon (covers a route that starts/ends
            // or turns inside the zone).
            for coord in routeCoords {
                if RouteGeometry.isPoint(coord, insidePolygon: polygon) {
                    return .polygonViolation
                }
            }
            // Drop a duplicated closing vertex so the wrap-around edge isn't
            // tested twice; the boundary scan below closes the ring itself.
            var ring = polygon
            if ring.count >= 2, let first = ring.first, let last = ring.last,
               first.latitude == last.latitude, first.longitude == last.longitude {
                ring.removeLast()
            }
            guard ring.count >= 3, routeCoords.count >= 2 else { return nil }
            // A route SEGMENT that crosses a polygon boundary edge — catches the
            // straight edge running through a zone smaller than the block with
            // neither endpoint inside.
            for i in 0..<(routeCoords.count - 1) {
                let a = routeCoords[i], b = routeCoords[i + 1]
                var k = ring.count - 1
                for j in 0..<ring.count {
                    if RoutedZone.segmentsIntersect(a, b, ring[k], ring[j]) {
                        return .polygonViolation
                    }
                    k = j
                }
            }
            // A polygon wholly contained within a single route segment crosses
            // no boundary edge and contains no route vertex; catch it via
            // polygon-vertex-to-route-segment distance, mirroring RoutedZone.
            for v in ring {
                for i in 0..<(routeCoords.count - 1) {
                    let proj = RouteGeometry.projectOntoSegment(
                        point: v, segStart: routeCoords[i], segEnd: routeCoords[i + 1]
                    )
                    if proj.distance <= RoutedZone.containedVertexToleranceMeters {
                        return .polygonViolation
                    }
                }
            }
            return nil
        }
    }

    /// Among candidate routes (encoded polylines), the index of the one with
    /// the fewest violations — the "least-violation" fallback when every route
    /// passes through an excluded area. This predicate has no duration data, so
    /// ties on violation count break toward the earlier index only; callers that
    /// can compare travel time (e.g. `DirectionsService.fetchRouteWithExclusions`)
    /// should break ties by duration to honor "only reroute if it saves time".
    /// nil when there are no candidates.
    func leastViolatingRouteIndex(
        candidates: [String],
        againstZones zones: [NoGoZone],
        now: Date = Date()
    ) -> Int? {
        guard !candidates.isEmpty else { return nil }
        var bestIndex = 0
        var bestCount = Int.max
        for (index, polyline) in candidates.enumerated() {
            let count = validateRoute(polyline, againstZones: zones, now: now).violationCount
            if count < bestCount {
                bestCount = count
                bestIndex = index
            }
        }
        return bestIndex
    }
}

// MARK: - Result Types

/// A single zone violation: which zone and how it was contacted.
struct ZoneViolation {
    let zone: NoGoZone
    let violationType: ViolationType
}

/// How a route contacts a zone.
enum ViolationType: Equatable {
    case pointInZone
    case corridorViolation(distanceMeters: Double)
    case polygonViolation
}

/// Outcome of validating one route against a set of zones.
struct RouteValidationResult {
    let violations: [ZoneViolation]

    var isValid: Bool { violations.isEmpty }
    var violationCount: Int { violations.count }
    var violatedZones: [NoGoZone] { violations.map(\.zone) }

    var severity: ValidationSeverity {
        switch violationCount {
        case 0: return .clear
        case 1: return .warning
        default: return .critical
        }
    }
}

enum ValidationSeverity {
    case clear
    case warning
    case critical
}
