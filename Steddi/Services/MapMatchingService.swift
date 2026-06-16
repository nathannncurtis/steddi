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
    /// FLOOR for how many trailing stitched coordinates the seam dedupe compares
    /// each leading new-chunk point against. The real window is ADAPTIVE — it
    /// extends back far enough to span the actual overlap geometry (see
    /// `adaptiveTailRegion`) — because the `chunkOverlap` input points can map to
    /// far more than this many matched vertices when OSRM resamples finely. A fixed
    /// window then stops short of the overlap and the seam is under-dropped
    /// (duplicate/backtracking geometry at the boundary). This value is only the
    /// minimum depth, used when the overlap span is short or its length is unknown.
    static let seamTailWindow = 8
    /// Safety multiplier on the measured overlap length when sizing the adaptive
    /// tail window, so OSRM's re-snap jitter (the seam can wander a few meters off
    /// the input line) is comfortably covered without over-eating genuine geometry.
    static let seamTailLengthSlack = 1.5
    /// HARD CAP on how many trailing vertices the adaptive tail window may include,
    /// independent of length. The overlap is only `chunkOverlap` input points, so
    /// even a fine OSRM resample maps it to a bounded handful of matched vertices;
    /// a few × `seamTailWindow` brackets every realistic overlap. The cap stops the
    /// length-sized walk from reaching deep, NON-overlap geometry on a tightly
    /// folded trace (a switchback / narrow divided road whose carriageways sit
    /// within `seamEpsilon`), where comparing leading points against far-back tail
    /// vertices would drop genuine fold geometry, not just seam duplicates.
    static let seamTailVertexCap = 32
    /// Bearing reversal (degrees) that marks a switchback apex / hairpin fold in the
    /// stitched tail. The adaptive tail walk STOPS at such an apex so the comparison
    /// region never crosses a fold: only the post-apex segment (where the genuine
    /// overlap re-trace lives) is compared, so a leading point that legitimately
    /// doubles back past the apex is not matched against pre-apex tail vertices and
    /// wrongly dropped. ~150° is a near-U-turn — well past any normal road bend.
    static let seamFoldBearingReversalDegrees: Double = 150
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
                // against the previous chunk's TAIL REGION — the trailing stitched
                // coords that SPAN the overlap, not just the single last vertex —
                // because a coarse OSRM resample emits the overlap as a few
                // widely-spaced points that never land within `seamEpsilon` of the
                // lone tail, so a single-vertex compare re-appends the whole
                // overlap and inflates the trace distance.
                //
                // The window is ADAPTIVE: the `overlap` leading input points of
                // this chunk are the same physical points fed at the seam, so their
                // cumulative geometry length is the true overlap span — and the
                // tail region must reach back at least that far. A fixed
                // `seamTailWindow` of vertices falls short whenever the overlap maps
                // to MORE than that many matched vertices (a fine OSRM resample),
                // re-admitting the un-dropped tail of the overlap. Sizing the window
                // by length covers it regardless of vertex density.
                let overlapInput = chunk.prefix(overlap).map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                let overlapMeters = RouteGeometry.cumulativeDistances(overlapInput).last ?? 0
                let tailRegion = Self.adaptiveTailRegion(allCoordinates, overlapMeters: overlapMeters)
                allCoordinates.append(contentsOf: Self.stitchSeam(tailRegion: tailRegion, chunk: coords))
            }
        }

        // Distance is measured from the final stitched polyline, not summed per
        // chunk — summing would double-count the overlapping segments.
        let totalDistance = RouteGeometry.cumulativeDistances(allCoordinates).last ?? 0
        let polyline = PolylineEncoder.encode(allCoordinates)
        return MatchedRoute(encodedPolyline: polyline, coordinates: allCoordinates, distanceMeters: totalDistance)
    }

    /// The trailing slice of the stitched output the seam dedupe compares
    /// against, sized to SPAN the overlap geometry rather than a fixed vertex
    /// count. Walks back from the tail accumulating arc length until it covers
    /// `overlapMeters` (times `seamTailLengthSlack` for re-snap jitter), with
    /// `seamTailWindow` as a vertex-count floor so a short or unknown-length
    /// overlap still gets a sensible window. This is what makes the dedupe robust
    /// when the `chunkOverlap` input points map to MANY matched vertices: a fixed
    /// 8-vertex window would stop short of such an overlap and leave its tail
    /// un-dropped; a length-sized window reaches the whole overlap regardless of
    /// how finely OSRM resampled it.
    ///
    /// The length-sized walk is BOUNDED two ways so it can't consume a genuine fold
    /// on a tightly-folded trace (a switchback / narrow divided road that doubles
    /// back within the overlap distance), where pulling in non-overlap geometry
    /// would let `stitchSeam` drop real fold vertices, not just seam duplicates:
    ///   1. It stops at a SWITCHBACK APEX — a sharp bearing reversal in the tail
    ///      (`seamFoldBearingReversalDegrees`). The genuine overlap re-trace lives
    ///      on the LAST physical segment driven, i.e. after the most recent apex; a
    ///      region that crossed the apex would also span the pre-apex leg, against
    ///      which a legitimately doubling-back leading point falsely matches.
    ///   2. It is HARD-CAPPED at `seamTailVertexCap` vertices, so even an
    ///      apex-free but pathologically dense/long stretch can't reach deep
    ///      non-overlap geometry. The overlap is only `chunkOverlap` input points,
    ///      so this cap comfortably brackets every realistic seam.
    /// The `seamTailWindow` vertex FLOOR still applies for short/unknown overlaps.
    static func adaptiveTailRegion(_ coords: [CLLocationCoordinate2D], overlapMeters: Double) -> [CLLocationCoordinate2D] {
        guard !coords.isEmpty else { return [] }

        // FOLD BOUNDARY first: the maximum number of trailing vertices the region
        // may include without crossing a switchback apex. Walking back from the
        // tail, the FIRST sharp bearing reversal (a hairpin) is a fold; the region
        // must not reach past it, or `stitchSeam` would compare leading points
        // against pre-apex geometry and drop genuine fold vertices, not just seam
        // duplicates. This bound caps BOTH the length walk AND the vertex floor, so
        // neither can reintroduce the fold.
        let foldLimit = Self.verticesBeforeFold(coords)

        // The length-sized reach (R19): include vertices until cumulative arc length
        // covers the overlap span (× slack), so a fine OSRM resample of the overlap
        // is fully bracketed. Bounded by the hard vertex cap and the fold limit.
        let target = max(0, overlapMeters) * seamTailLengthSlack
        let hardCap = min(coords.count, seamTailVertexCap)
        var accumulated: Double = 0
        var count = 0
        var i = coords.count - 1
        while i >= 0 {
            count += 1
            if count >= hardCap || count >= foldLimit { break }
            if i > 0 {
                accumulated += NavigationEngine.haversineDistance(from: coords[i - 1], to: coords[i])
            }
            if accumulated >= target { break }
            i -= 1
        }
        // Floor at `seamTailWindow` vertices so short overlaps still compare against
        // a few coords (matches the prior fixed-window behaviour at minimum) — but
        // never exceed the hard cap OR the fold limit, so the floor can't reach
        // across a switchback into non-overlap geometry.
        count = max(count, min(coords.count, seamTailWindow))
        count = min(count, hardCap, foldLimit)
        return Array(coords.suffix(count))
    }

    /// How many trailing vertices of `coords` lie on the SAME side of the most
    /// recent switchback apex as the tail — i.e. the deepest the seam region may
    /// reach before crossing a fold. Walks back from the tail comparing successive
    /// segment bearings; the first reversal of `seamFoldBearingReversalDegrees`+
    /// (a hairpin / near-U-turn) is the apex, and the apex vertex itself is the
    /// last one included (so the post-apex leg is fully covered, the pre-apex leg
    /// excluded). Returns `coords.count` when there is no fold.
    static func verticesBeforeFold(_ coords: [CLLocationCoordinate2D]) -> Int {
        guard coords.count >= 3 else { return coords.count }
        // Bearing of the most recently walked segment (toward the tail).
        var lastBearing = RouteGeometry.bearing(from: coords[coords.count - 2], to: coords[coords.count - 1])
        // i indexes the vertex whose INCOMING segment (coords[i-1] -> coords[i]) we
        // test next. Start one segment back from the tail.
        var i = coords.count - 2
        while i >= 1 {
            let segBearing = RouteGeometry.bearing(from: coords[i - 1], to: coords[i])
            if Self.bearingReversal(segBearing, lastBearing) >= seamFoldBearingReversalDegrees {
                // Apex at coords[i]: include the tail down to and INCLUDING coords[i].
                return coords.count - i
            }
            lastBearing = segBearing
            i -= 1
        }
        return coords.count
    }

    /// Absolute heading change between two bearings, 0...180 degrees (handles the
    /// 360/0 wraparound). 180 is a perfect U-turn.
    static func bearingReversal(_ a: Double, _ b: Double) -> Double {
        var diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff = 360 - diff }
        return diff
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
