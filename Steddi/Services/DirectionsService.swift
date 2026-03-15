import Foundation
import CoreLocation

/// Wraps Mapbox Directions API for route fetching and ETA estimation.
final class DirectionsService {
    private let accessToken: String
    private let session: URLSession

    init(accessToken: String, session: URLSession = .shared) {
        self.accessToken = accessToken
        self.session = session
    }

    /// Fetch a route between two points using the specified profile.
    func fetchRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        profile: String = "driving-traffic"
    ) async throws -> DirectionsRoute {
        let coordinates = "\(origin.longitude),\(origin.latitude);\(destination.longitude),\(destination.latitude)"

        var components = URLComponents(string: "https://api.mapbox.com/directions/v5/mapbox/\(profile)/\(coordinates)")!
        components.queryItems = [
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "geometries", value: "polyline6"),
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "steps", value: "true"),
        ]

        let (data, response) = try await session.data(from: components.url!)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DirectionsError.apiError
        }

        let result = try JSONDecoder().decode(DirectionsResponse.self, from: data)
        guard let route = result.routes.first else {
            throw DirectionsError.noRoute
        }

        return DirectionsRoute(
            encodedPolyline: route.geometry,
            distanceMeters: route.distance,
            durationSeconds: route.duration,
            legs: route.legs.map { leg in
                DirectionsRoute.Leg(
                    distanceMeters: leg.distance,
                    durationSeconds: leg.duration,
                    steps: leg.steps.map { step in
                        DirectionsRoute.Leg.Step(
                            instruction: step.maneuver.instruction,
                            distanceMeters: step.distance,
                            durationSeconds: step.duration
                        )
                    }
                )
            }
        )
    }

    /// Get the current ETA from a position along a stored route.
    /// Snaps the origin to the encoded polyline and returns remaining travel time.
    func fetchETA(
        from origin: CLLocationCoordinate2D,
        along encodedPolyline: String
    ) async throws -> TimeInterval {
        let routeCoords = PolylineEncoder.decode(encodedPolyline, precision: 6)

        // Find the closest point on the route to snap the origin
        guard let snappedIndex = closestPointIndex(to: origin, in: routeCoords) else {
            throw DirectionsError.noRoute
        }

        // Build a coordinate string from current position to the end of the route
        let remaining = [origin.asDirectionsString] + routeCoords[snappedIndex...].suffix(98).map(\.asDirectionsString)
        let coordinates = remaining.joined(separator: ";")

        var components = URLComponents(string: "https://api.mapbox.com/directions/v5/mapbox/driving-traffic/\(coordinates)")!
        components.queryItems = [
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "geometries", value: "polyline6"),
            URLQueryItem(name: "overview", value: "false"),
        ]

        let (data, response) = try await session.data(from: components.url!)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DirectionsError.apiError
        }

        let result = try JSONDecoder().decode(DirectionsResponse.self, from: data)
        guard let route = result.routes.first else {
            throw DirectionsError.noRoute
        }

        return route.duration
    }

    /// Fetch a route that avoids the given no-go zones.
    /// Converts circular no-go zones into exclude bounding boxes for the API.
    func fetchRouteWithExclusions(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        excluding noGoZones: [NoGoZone]
    ) async throws -> DirectionsRoute {
        let coordinates = "\(origin.longitude),\(origin.latitude);\(destination.longitude),\(destination.latitude)"

        var components = URLComponents(string: "https://api.mapbox.com/directions/v5/mapbox/driving-traffic/\(coordinates)")!
        var queryItems = [
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "geometries", value: "polyline6"),
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "steps", value: "true"),
        ]

        if !noGoZones.isEmpty {
            let exclusions = noGoZones.map { zone -> String in
                let bbox = zone.toBoundingBox()
                return "\(bbox.minLng),\(bbox.minLat),\(bbox.maxLng),\(bbox.maxLat)"
            }.joined(separator: ";")
            queryItems.append(URLQueryItem(name: "exclude", value: exclusions))
        }

        components.queryItems = queryItems

        let (data, response) = try await session.data(from: components.url!)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DirectionsError.apiError
        }

        let result = try JSONDecoder().decode(DirectionsResponse.self, from: data)
        guard let route = result.routes.first else {
            throw DirectionsError.noRoute
        }

        return DirectionsRoute(
            encodedPolyline: route.geometry,
            distanceMeters: route.distance,
            durationSeconds: route.duration,
            legs: route.legs.map { leg in
                DirectionsRoute.Leg(
                    distanceMeters: leg.distance,
                    durationSeconds: leg.duration,
                    steps: leg.steps.map { step in
                        DirectionsRoute.Leg.Step(
                            instruction: step.maneuver.instruction,
                            distanceMeters: step.distance,
                            durationSeconds: step.duration
                        )
                    }
                )
            }
        )
    }

    // MARK: - Private

    private func closestPointIndex(to target: CLLocationCoordinate2D, in coords: [CLLocationCoordinate2D]) -> Int? {
        guard !coords.isEmpty else { return nil }
        let targetLocation = CLLocation(latitude: target.latitude, longitude: target.longitude)
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude

        for (index, coord) in coords.enumerated() {
            let distance = targetLocation.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        return bestIndex
    }
}

// MARK: - Route Types

struct DirectionsRoute {
    let encodedPolyline: String
    let distanceMeters: Double
    let durationSeconds: TimeInterval
    let legs: [Leg]

    struct Leg {
        let distanceMeters: Double
        let durationSeconds: TimeInterval
        let steps: [Step]

        struct Step {
            let instruction: String
            let distanceMeters: Double
            let durationSeconds: TimeInterval
        }
    }
}

// MARK: - API Response Types

private struct DirectionsResponse: Decodable {
    let routes: [ResponseRoute]
    let code: String

    struct ResponseRoute: Decodable {
        let geometry: String
        let distance: Double
        let duration: Double
        let legs: [ResponseLeg]
    }

    struct ResponseLeg: Decodable {
        let distance: Double
        let duration: Double
        let steps: [ResponseStep]
    }

    struct ResponseStep: Decodable {
        let maneuver: Maneuver
        let distance: Double
        let duration: Double
    }

    struct Maneuver: Decodable {
        let instruction: String
    }
}

// MARK: - Errors

enum DirectionsError: Error, LocalizedError {
    case apiError
    case noRoute

    var errorDescription: String? {
        switch self {
        case .apiError: return "Directions API request failed."
        case .noRoute: return "No route found between the given points."
        }
    }
}

// MARK: - Helpers

private extension CLLocationCoordinate2D {
    var asDirectionsString: String {
        "\(longitude),\(latitude)"
    }
}

private extension NoGoZone {
    struct BoundingBox {
        let minLat: Double
        let minLng: Double
        let maxLat: Double
        let maxLng: Double
    }

    /// Convert a circular no-go zone to a bounding box for the Mapbox exclude parameter.
    func toBoundingBox() -> BoundingBox {
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLng = metersPerDegreeLat * cos(latitude * .pi / 180)

        let latOffset = radiusMeters / metersPerDegreeLat
        let lngOffset = radiusMeters / metersPerDegreeLng

        return BoundingBox(
            minLat: latitude - latOffset,
            minLng: longitude - lngOffset,
            maxLat: latitude + latOffset,
            maxLng: longitude + lngOffset
        )
    }
}
