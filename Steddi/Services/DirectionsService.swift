import Foundation
import CoreLocation
import MapKit

/// Wraps Apple MapKit MKDirections for route fetching and ETA estimation.
final class DirectionsService {

    init() {}

    /// Fetch a route between two points.
    func fetchRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        profile: String = "driving"
    ) async throws -> DirectionsRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile

        let directions = MKDirections(request: request)
        let response = try await directions.calculate()

        guard let mkRoute = response.routes.first else {
            throw DirectionsError.noRoute
        }

        return Self.directionsRoute(from: mkRoute)
    }

    /// Get the current ETA from a position to the route's destination.
    /// The `along` polyline parameter is accepted for API compatibility but
    /// the ETA is calculated as a simple origin-to-destination request.
    func fetchETA(
        from origin: CLLocationCoordinate2D,
        along encodedPolyline: String
    ) async throws -> TimeInterval {
        // Decode polyline to get the destination (last coordinate)
        let routeCoords = PolylineEncoder.decode(encodedPolyline, precision: 6)
        guard let destinationCoord = routeCoords.last else {
            throw DirectionsError.noRoute
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destinationCoord))
        request.transportType = .automobile

        let directions = MKDirections(request: request)
        let eta = try await directions.calculateETA()

        return eta.expectedTravelTime
    }

    /// Fetch a route, ignoring exclusion zones.
    /// Note: MKDirections does not support exclusion zones natively.
    /// No-go zone checking should be done post-calculation by the caller.
    func fetchRouteWithExclusions(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        excluding noGoZones: [NoGoZone]
    ) async throws -> DirectionsRoute {
        // MKDirections has no built-in exclusion zone support.
        // Fall back to a regular route; callers should validate the result
        // against no-go zones and warn the user if the route intersects any.
        return try await fetchRoute(from: origin, to: destination)
    }

    // MARK: - Private

    /// Convert an MKRoute into a DirectionsRoute.
    private static func directionsRoute(from mkRoute: MKRoute) -> DirectionsRoute {
        let coordinates = polylineCoordinates(from: mkRoute.polyline)
        let encoded = PolylineEncoder.encode(coordinates, precision: 6)

        let steps: [DirectionsStep] = mkRoute.steps.compactMap { step in
            // MKRoute.Step includes empty-instruction entries for route segments;
            // keep them but fall back to empty string.
            let instruction = step.instructions
            return DirectionsStep(
                instructions: instruction,
                distance: step.distance,
                maneuverType: sfSymbol(for: instruction),
                coordinate: step.polyline.coordinate
            )
        }

        return DirectionsRoute(
            encodedPolyline: encoded,
            distance: mkRoute.distance,
            duration: mkRoute.expectedTravelTime,
            legs: [DirectionsLeg(steps: steps)]
        )
    }

    /// Extract CLLocationCoordinate2D array from an MKPolyline.
    private static func polylineCoordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let count = polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }

    /// Map an instruction string to an SF Symbol name for the maneuver type.
    private static func sfSymbol(for instruction: String) -> String {
        let lower = instruction.lowercased()

        if lower.contains("u-turn") {
            return "arrow.uturn.down"
        }
        if lower.contains("roundabout") {
            return "arrow.triangle.2.circlepath"
        }
        if lower.contains("merge") {
            return "arrow.merge"
        }
        if lower.contains("arrive") || lower.contains("destination") {
            return "flag.fill"
        }
        if lower.contains("ramp") && lower.contains("left") {
            return "arrow.up.left"
        }
        if lower.contains("ramp") && lower.contains("right") {
            return "arrow.up.right"
        }
        if lower.contains("left") {
            return "arrow.turn.up.left"
        }
        if lower.contains("right") {
            return "arrow.turn.up.right"
        }

        return "arrow.up"
    }
}

// MARK: - Route Types

struct DirectionsRoute {
    let encodedPolyline: String
    let distance: Double          // meters
    let duration: TimeInterval    // seconds
    let legs: [DirectionsLeg]
}

struct DirectionsLeg {
    let steps: [DirectionsStep]
}

struct DirectionsStep {
    let instructions: String
    let distance: Double
    let maneuverType: String                 // SF Symbol name
    let coordinate: CLLocationCoordinate2D   // maneuver location
}

// MARK: - Errors

enum DirectionsError: Error, LocalizedError {
    case apiError
    case noRoute

    var errorDescription: String? {
        switch self {
        case .apiError: return "Directions request failed."
        case .noRoute: return "No route found between the given points."
        }
    }
}
