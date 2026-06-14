import Foundation
import CoreLocation

/// Builds no-go zone geometries from user drawing input. Freehand strokes and
/// dot-to-dot waypoints are snapped to the road network (the former via OSRM
/// Map Matching, the latter via OSRM via-routing); polygons are taken verbatim
/// and named roads are geocoded into a routed corridor.
final class ZoneDrawingService {

    /// Default corridor half-width (meters on each side of the centerline).
    static let defaultBufferMeters: Double = 30

    private let mapMatchingService: MapMatchingService
    private let directionsService: DirectionsService
    private let geocodingService: GeocodingService

    init(
        mapMatchingService: MapMatchingService = MapMatchingService(),
        directionsService: DirectionsService = DirectionsService(),
        geocodingService: GeocodingService = GeocodingService()
    ) {
        self.mapMatchingService = mapMatchingService
        self.directionsService = directionsService
        self.geocodingService = geocodingService
    }

    enum DrawingMode {
        case freehand     // User draws, we snap to road
        case dotToDot     // User taps points, we route between them
        case polygon      // User taps to create a closed shape
        case namedRoad    // User enters "I-91 between Main and Route 15"
    }

    // MARK: - Freehand

    /// Snap a freehand stroke to the road network and return it as a corridor.
    /// Points are stamped with synthetic monotonic timestamps because OSRM Map
    /// Matching wants ordered fixes; the absolute times don't matter.
    func snapFreehandStroke(
        _ points: [CLLocationCoordinate2D]
    ) async throws -> SnappedZoneGeometry {
        guard points.count >= 2 else { throw ZoneDrawingError.insufficientPoints }

        let now = Date()
        let gpsPoints = points.enumerated().map { index, coord in
            GPSPoint(
                latitude: coord.latitude,
                longitude: coord.longitude,
                altitude: 0,
                horizontalAccuracy: 5,
                timestamp: now.addingTimeInterval(Double(index)),
                speed: -1
            )
        }

        let matched = try await mapMatchingService.matchTrace(gpsPoints)
        guard !matched.encodedPolyline.isEmpty else { throw ZoneDrawingError.snapFailed }

        return SnappedZoneGeometry(
            encodedPolyline: matched.encodedPolyline,
            bufferMeters: Self.defaultBufferMeters
        )
    }

    // MARK: - Dot-to-dot

    /// Route through sequential waypoints (OSRM via-routing) and return the
    /// through-route as a corridor.
    func dotToDotCorridor(
        waypoints: [CLLocationCoordinate2D]
    ) async throws -> SnappedZoneGeometry {
        guard waypoints.count >= 2 else { throw ZoneDrawingError.insufficientWaypoints }

        let route = try await directionsService.fetchViaRoute(points: waypoints)
        guard !route.encodedPolyline.isEmpty else { throw ZoneDrawingError.snapFailed }

        return SnappedZoneGeometry(
            encodedPolyline: route.encodedPolyline,
            bufferMeters: Self.defaultBufferMeters
        )
    }

    // MARK: - Polygon

    /// Build a closed polygon from tapped points (no snapping). The ring is
    /// closed by appending the first point so encoders/validators see a loop.
    func polygonFromTaps(_ points: [CLLocationCoordinate2D]) throws -> ZoneGeometry {
        guard points.count >= 3 else { throw ZoneDrawingError.insufficientPoints }

        let closed = points + [points[0]]
        let polyline = PolylineEncoder.encode(closed, precision: 6)
        return .polygon(encodedPolyline: polyline)
    }

    // MARK: - Named road

    /// Geocode a road's bounds and route between them, producing a corridor
    /// labeled by the road name. Requires both bounds to resolve.
    func namedRoadCorridor(
        roadName: String,
        startLocation: String?,
        endLocation: String?,
        proximity: CLLocationCoordinate2D? = nil
    ) async throws -> ZoneGeometry {
        guard let startLocation, let endLocation,
              !startLocation.isEmpty, !endLocation.isEmpty else {
            throw ZoneDrawingError.geocodingFailed
        }

        async let startResults = geocodingService.search(query: "\(roadName) \(startLocation)", proximity: proximity)
        async let endResults = geocodingService.search(query: "\(roadName) \(endLocation)", proximity: proximity)

        guard let start = try await startResults.first?.coordinate,
              let end = try await endResults.first?.coordinate else {
            throw ZoneDrawingError.geocodingFailed
        }

        let route = try await directionsService.fetchViaRoute(points: [start, end])
        guard !route.encodedPolyline.isEmpty else { throw ZoneDrawingError.snapFailed }

        return .corridor(
            encodedPolyline: route.encodedPolyline,
            bufferMeters: Self.defaultBufferMeters
        )
    }
}

/// A snapped corridor result: the encoded centerline and its buffer.
struct SnappedZoneGeometry: Equatable {
    let encodedPolyline: String
    let bufferMeters: Double

    /// Lift into the unified geometry enum.
    var geometry: ZoneGeometry {
        .corridor(encodedPolyline: encodedPolyline, bufferMeters: bufferMeters)
    }
}

enum ZoneDrawingError: Error, LocalizedError {
    case insufficientWaypoints
    case insufficientPoints
    case geocodingFailed
    case snapFailed

    var errorDescription: String? {
        switch self {
        case .insufficientWaypoints: return "Tap at least two waypoints to route a corridor."
        case .insufficientPoints: return "Add at least three points to draw a shape."
        case .geocodingFailed: return "Couldn't find that road or its bounds."
        case .snapFailed: return "Couldn't snap the drawing to a road."
        }
    }
}
