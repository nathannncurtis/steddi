import Foundation
import CoreLocation

/// Handles snapping raw GPS traces to the road network via OSRM Map Matching API.
/// Chunks traces that exceed the 100-coordinate API limit.
final class MapMatchingService {
    private let maxCoordinatesPerRequest = 100
    /// Matched points within this distance (meters) of the previous chunk's
    /// tail are treated as the same seam geometry and dropped. ~10m comfortably
    /// covers OSRM's re-snap jitter at the overlap without eating a genuine
    /// short segment.
    static let seamEpsilon: CLLocationDistance = 10
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
            // Once we've consumed the whole trace, stop — otherwise a tail
            // shorter than `overlap` leaves `start = end - overlap` stuck below
            // points.count and the loop spins forever.
            if end == points.count { break }
            start = end - overlap
        }

        // Match each chunk and stitch polylines
        var allCoordinates: [CLLocationCoordinate2D] = []

        for (index, chunk) in chunks.enumerated() {
            let result = try await matchChunk(chunk)
            let coords = result.coordinates

            if index == 0 {
                allCoordinates.append(contentsOf: coords)
            } else {
                // Matched coordinates do NOT map 1:1 to the `overlap` input
                // points OSRM is fed at the seam — the matcher resamples and
                // snaps to the road, so the leading matched coords of this
                // chunk re-trace some length already present at the tail of the
                // stitched output. Dropping a fixed input-point count leaves
                // seam gaps or overlaps. Instead dedupe by matched geometry:
                // drop leading points of this chunk that fall within `seamEpsilon`
                // of the previous chunk's tail, then append the remainder.
                allCoordinates.append(contentsOf: Self.stitchSeam(tail: allCoordinates.last, chunk: coords))
            }
        }

        // Distance is measured from the final stitched polyline, not summed per
        // chunk — summing would double-count the overlapping segments.
        let totalDistance = RouteGeometry.cumulativeDistances(allCoordinates).last ?? 0
        let polyline = PolylineEncoder.encode(allCoordinates)
        return MatchedRoute(encodedPolyline: polyline, coordinates: allCoordinates, distanceMeters: totalDistance)
    }

    /// Dedupe a subsequent chunk against the stitched tail by matched-geometry
    /// proximity. Leading points of `chunk` within `seamEpsilon` of `tail` are
    /// the overlap re-trace and are dropped; the first point that has moved
    /// clear of the tail (and everything after it) is what we keep. Stops at the
    /// first point beyond the epsilon so a later pass back near the tail (e.g. a
    /// loop) is preserved.
    static func stitchSeam(tail: CLLocationCoordinate2D?, chunk: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard let tail else { return chunk }
        var dropCount = 0
        for coord in chunk {
            if NavigationEngine.haversineDistance(from: tail, to: coord) <= seamEpsilon {
                dropCount += 1
            } else {
                break
            }
        }
        return Array(chunk.dropFirst(dropCount))
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
