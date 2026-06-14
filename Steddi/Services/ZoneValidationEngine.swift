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
    private func violationType(
        routeCoords: [CLLocationCoordinate2D],
        geometry: ZoneGeometry
    ) -> ViolationType? {
        switch geometry {
        case .circle(let center, let radiusMeters):
            for coord in routeCoords {
                if RouteGeometry.isPoint(coord, withinCircleCenter: center, radiusMeters: radiusMeters) {
                    return .pointInZone
                }
            }
            return nil

        case .corridor(let encodedPolyline, let bufferMeters):
            let centerline = PolylineEncoder.decode(encodedPolyline, precision: 6)
            guard !centerline.isEmpty else { return nil }
            var nearest = Double.greatestFiniteMagnitude
            for coord in routeCoords {
                let d = RouteGeometry.distance(from: coord, toPolyline: centerline)
                if d < nearest { nearest = d }
            }
            return nearest <= bufferMeters ? .corridorViolation(distanceMeters: nearest) : nil

        case .polygon(let encodedPolyline):
            let polygon = PolylineEncoder.decode(encodedPolyline, precision: 6)
            for coord in routeCoords {
                if RouteGeometry.isPoint(coord, insidePolygon: polygon) {
                    return .polygonViolation
                }
            }
            return nil
        }
    }

    /// Among candidate routes (encoded polylines), the index of the one with
    /// the fewest violations — the "least-violation" fallback when every route
    /// passes through an excluded area. Ties break toward the earlier index
    /// (typically the fastest route). nil when there are no candidates.
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
