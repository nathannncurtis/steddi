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
    /// Input-point overlap fed to consecutive chunks. The new chunk re-traces
    /// roughly this many input intervals of geometry already present at the
    /// stitched tail, so the seam dedupe must compare against a TAIL REGION at
    /// least this deep, not just the single last vertex.
    static let chunkOverlap = 5
    /// How many trailing stitched coordinates the seam dedupe compares each
    /// leading new-chunk point against. Sized a bit beyond `chunkOverlap` so a
    /// coarse OSRM resample (overlap emitted as a few widely-spaced vertices)
    /// still has a tail vertex within `seamEpsilon` of each overlap point.
    static let seamTailWindow = 8
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
        let overlap = Self.chunkOverlap
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
                // seam gaps or overlaps. Instead dedupe by matched geometry
                // against the previous chunk's TAIL REGION (the last
                // `seamTailWindow` stitched coords spanning the overlap), not
                // just the single last vertex — a coarse OSRM resample emits the
                // overlap as a few widely-spaced points that never land within
                // `seamEpsilon` of the lone tail, so a single-vertex compare
                // re-appends the whole overlap and inflates the trace distance.
                let tailRegion = allCoordinates.suffix(Self.seamTailWindow)
                allCoordinates.append(contentsOf: Self.stitchSeam(tailRegion: Array(tailRegion), chunk: coords))
            }
        }

        // Distance is measured from the final stitched polyline, not summed per
        // chunk — summing would double-count the overlapping segments.
        let totalDistance = RouteGeometry.cumulativeDistances(allCoordinates).last ?? 0
        let polyline = PolylineEncoder.encode(allCoordinates)
        return MatchedRoute(encodedPolyline: polyline, coordinates: allCoordinates, distanceMeters: totalDistance)
    }

    /// Dedupe a subsequent chunk against the stitched tail REGION by
    /// matched-geometry proximity. Each leading point of `chunk` that falls
    /// within `seamEpsilon` of ANY point in `tailRegion` (the last few stitched
    /// coords spanning the input overlap) is the overlap re-trace and is
    /// dropped; the first point that has moved clear of the whole tail region
    /// (and everything after it) is what we keep.
    ///
    /// Comparing against the region, not just the single last vertex, is what
    /// makes this robust to a coarse OSRM resample: when the matcher emits the
    /// overlap as a handful of widely-spaced vertices, an overlap point can sit
    /// >`seamEpsilon` from the lone tail yet still be within `seamEpsilon` of an
    /// earlier tail-region vertex, so it is correctly dropped instead of
    /// re-appended (which would backtrack the polyline and inflate distance).
    ///
    /// We stop at the first leading point clear of the entire region so a later
    /// genuine pass back near the tail (e.g. a loop) is preserved.
    static func stitchSeam(tailRegion: [CLLocationCoordinate2D], chunk: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard !tailRegion.isEmpty else { return chunk }
        var dropCount = 0
        for coord in chunk {
            let nearTail = tailRegion.contains {
                NavigationEngine.haversineDistance(from: $0, to: coord) <= seamEpsilon
            }
            if nearTail {
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
