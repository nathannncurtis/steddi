import Foundation
import CoreLocation

/// Handles snapping raw GPS traces to the road network via OSRM Map Matching API.
/// Chunks traces that exceed the 100-coordinate API limit.
final class MapMatchingService {
    private let maxCoordinatesPerRequest = 100
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Snap a GPS trace to the road network.
    /// Automatically chunks traces longer than 100 points and stitches results.
    func matchTrace(_ points: [GPSPoint]) async throws -> MatchedRoute {
        guard points.count >= 2 else {
            throw MapMatchingError.insufficientPoints
        }

        // If trace fits in one request, send directly
        if points.count <= maxCoordinatesPerRequest {
            return try await matchChunk(points)
        }

        // Chunk with overlap so segments connect cleanly
        let overlap = 5
        var chunks: [[GPSPoint]] = []
        var start = 0
        while start < points.count {
            let end = min(start + maxCoordinatesPerRequest, points.count)
            chunks.append(Array(points[start..<end]))
            start = end - overlap
            if start >= points.count { break }
        }

        // Match each chunk and stitch polylines
        var allCoordinates: [CLLocationCoordinate2D] = []
        var totalDistance: Double = 0

        for (index, chunk) in chunks.enumerated() {
            let result = try await matchChunk(chunk)
            let coords = result.coordinates

            if index == 0 {
                allCoordinates.append(contentsOf: coords)
            } else {
                // Skip overlapping points from the start of subsequent chunks
                let skipCount = min(overlap, coords.count)
                allCoordinates.append(contentsOf: coords.dropFirst(skipCount))
            }
            totalDistance += result.distanceMeters
        }

        let polyline = PolylineEncoder.encode(allCoordinates)
        return MatchedRoute(encodedPolyline: polyline, coordinates: allCoordinates, distanceMeters: totalDistance)
    }

    private func matchChunk(_ points: [GPSPoint]) async throws -> MatchedRoute {
        let coordinates = points.map { "\($0.longitude),\($0.latitude)" }.joined(separator: ";")
        let timestamps = points.map { String(Int($0.timestamp.timeIntervalSince1970)) }.joined(separator: ";")

        guard var components = URLComponents(string: "https://router.project-osrm.org/match/v1/driving/\(coordinates)") else {
            throw MapMatchingError.apiError
        }
        components.queryItems = [
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "geometries", value: "polyline6"),
            URLQueryItem(name: "timestamps", value: timestamps),
        ]

        guard let url = components.url else {
            throw MapMatchingError.apiError
        }

        let (data, response) = try await session.data(for: URLRequest(url: url))

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw MapMatchingError.apiError
        }

        let result = try JSONDecoder().decode(MapMatchingResponse.self, from: data)
        guard let matching = result.matchings?.first else {
            throw MapMatchingError.noMatch
        }

        let coords = PolylineEncoder.decode(matching.geometry, precision: 6)
        return MatchedRoute(
            encodedPolyline: matching.geometry,
            coordinates: coords,
            distanceMeters: matching.distance
        )
    }
}

struct MatchedRoute {
    let encodedPolyline: String
    let coordinates: [CLLocationCoordinate2D]
    let distanceMeters: Double
}

// MARK: - API Response Types

struct MapMatchingResponse: Decodable {
    let matchings: [Matching]?
    let code: String

    struct Matching: Decodable {
        let geometry: String
        let distance: Double
    }
}

enum MapMatchingError: Error, LocalizedError {
    case insufficientPoints
    case apiError
    case noMatch

    var errorDescription: String? {
        switch self {
        case .insufficientPoints: return "Need at least 2 GPS points to match a route."
        case .apiError: return "Map Matching API request failed."
        case .noMatch: return "Could not match GPS trace to any road."
        }
    }
}
