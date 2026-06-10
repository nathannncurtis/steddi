import Foundation
import CoreLocation
import CryptoKit
import Observation

/// A road segment with a known or estimated speed limit, sourced from OpenStreetMap.
struct SpeedLimitWay: Codable {
    let wayID: Int
    let limitMph: Double
    let isEstimated: Bool
    let geometry: [SpeedLimitPoint]
}

/// A single way geometry vertex. Field names match Overpass `out geom` output.
struct SpeedLimitPoint: Codable {
    let lat: Double
    let lon: Double
}

/// On-disk cache payload for one route's speed-limit data.
struct CachedSpeedLimits: Codable {
    let ways: [SpeedLimitWay]
    let fetchedAt: Date
}

/// Fetches real speed limits along a route from OpenStreetMap via the Overpass API.
/// Prefetch once per route (one POST, disk-cached for 30 days), then answer
/// synchronous in-memory lookups during navigation.
@Observable
@MainActor
final class OSMSpeedLimitService {

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Route key of the currently indexed speed-limit data.
    private(set) var loadedRouteKey: String?
    private(set) var isPrefetching = false

    private let transport: Transport
    private let cacheDirectory: URL
    private let now: () -> Date

    /// Ways currently loaded for lookup.
    private var ways: [SpeedLimitWay] = []

    init(
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        cacheDirectory: URL? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.transport = transport
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.cacheDirectory = caches.appendingPathComponent("SpeedLimits", isDirectory: true)
        }
        self.now = now
    }

    // MARK: - Prefetch

    /// Fetch speed limits for all roads within 25m of the route polyline.
    /// Disk cache hit short-circuits the network entirely.
    func prefetch(for polyline: [CLLocationCoordinate2D], routeKey: String) async {
        guard polyline.count >= 2 else { return }
        isPrefetching = true
        defer { isPrefetching = false }

        let key = Self.cacheKey(for: polyline)
        if let cached = loadCachedPayload(key: key) {
            loadWays(cached.ways, routeKey: routeKey)
            return
        }

        let sampled = Self.downsample(
            polyline,
            tolerance: Tuning.downsampleToleranceMeters,
            maxPoints: Tuning.maxQueryPoints
        )
        let query = Self.overpassQuery(for: sampled)
        guard let fetched = await fetch(query: query) else { return }

        savePayload(CachedSpeedLimits(ways: fetched, fetchedAt: now()), key: key)
        loadWays(fetched, routeKey: routeKey)
    }

    /// Replace the in-memory way set used for lookups.
    func loadWays(_ newWays: [SpeedLimitWay], routeKey: String) {
        ways = newWays.filter { $0.geometry.count >= 2 }
        loadedRouteKey = routeKey
    }

    // MARK: - Network

    private func fetch(query: String) async -> [SpeedLimitWay]? {
        guard let encoded = Self.formURLEncoded(query) else { return nil }
        let body = Data("data=\(encoded)".utf8)

        for endpoint in Tuning.endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 30

            do {
                let (data, response) = try await transport(request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                return try Self.parseOverpassResponse(data)
            } catch {
                continue
            }
        }
        return nil
    }

    /// Build the Overpass QL query for a downsampled polyline.
    /// Splits into multiple `around` clauses within one request if the point count exceeds the per-clause cap.
    nonisolated static func overpassQuery(for points: [CLLocationCoordinate2D]) -> String {
        guard !points.isEmpty else { return "" }
        let highwayFilter = #"["highway"~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link)$"]"#

        var clauses: [String] = []
        var start = 0
        repeat {
            let end = min(start + Tuning.maxPointsPerClause, points.count)
            let coords = points[start..<end]
                .map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }
                .joined(separator: ",")
            clauses.append("way(around:\(Tuning.aroundRadiusMeters),\(coords))\(highwayFilter);")
            if end == points.count { break }
            start = end - 1 // overlap one point so coverage is continuous
        } while true

        return "[out:json][timeout:25];(\(clauses.joined()));out tags geom;"
    }

    nonisolated static func formURLEncoded(_ string: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        return string.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    // MARK: - Parsing

    /// Convert an Overpass JSON response into speed-limit ways.
    /// Ways without a usable maxspeed fall back to highway-class defaults, marked estimated.
    nonisolated static func parseOverpassResponse(_ data: Data) throws -> [SpeedLimitWay] {
        let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
        return response.elements.compactMap { element in
            guard let tags = element.tags,
                  let highway = tags["highway"],
                  let geometry = element.geometry,
                  geometry.count >= 2 else { return nil }

            let parsed = parseMaxspeed(tags["maxspeed"])
            guard let limit = parsed ?? defaultSpeedMph(forHighwayClass: highway) else { return nil }

            return SpeedLimitWay(
                wayID: element.id,
                limitMph: limit,
                isEstimated: parsed == nil,
                geometry: geometry
            )
        }
    }

    /// Parse an OSM maxspeed tag value to mph.
    /// "NN mph" -> NN. Bare "NN" is km/h per OSM convention. Non-numeric values
    /// ("none", "signals", "walk", garbage) return nil.
    nonisolated static func parseMaxspeed(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }

        let value: Double?
        if raw.hasSuffix("mph") {
            value = Double(raw.dropLast(3).trimmingCharacters(in: .whitespaces))
        } else if raw.hasSuffix("km/h") {
            value = Double(raw.dropLast(4).trimmingCharacters(in: .whitespaces)).map { $0 * Tuning.mphPerKmh }
        } else {
            value = Double(raw).map { $0 * Tuning.mphPerKmh }
        }

        guard let value, value > 0 else { return nil }
        return value
    }

    /// Typical US speed limit for an OSM highway class, used when no maxspeed tag exists.
    nonisolated static func defaultSpeedMph(forHighwayClass highway: String) -> Double? {
        if highway.hasSuffix("_link") { return 35 }
        switch highway {
        case "motorway": return 65
        case "trunk": return 55
        case "primary": return 45
        case "secondary": return 40
        case "tertiary": return 35
        case "unclassified": return 35
        case "residential": return 25
        default: return nil
        }
    }

    // MARK: - Downsampling

    /// Ramer-Douglas-Peucker simplification with a hard cap on point count.
    nonisolated static func downsample(
        _ coords: [CLLocationCoordinate2D],
        tolerance: Double,
        maxPoints: Int
    ) -> [CLLocationCoordinate2D] {
        guard coords.count > 2, maxPoints >= 2 else { return coords }
        var simplified = rdpSimplify(coords, tolerance: tolerance)

        if simplified.count > maxPoints {
            let step = Double(simplified.count - 1) / Double(maxPoints - 1)
            var capped: [CLLocationCoordinate2D] = []
            capped.reserveCapacity(maxPoints)
            for i in 0..<maxPoints {
                let index = min(simplified.count - 1, Int((Double(i) * step).rounded()))
                capped.append(simplified[index])
            }
            simplified = capped
        }
        return simplified
    }

    private nonisolated static func rdpSimplify(
        _ coords: [CLLocationCoordinate2D],
        tolerance: Double
    ) -> [CLLocationCoordinate2D] {
        guard coords.count > 2 else { return coords }

        // Iterative with an explicit range stack: long polylines would blow the
        // call stack (and debug-build allocations) with naive recursion.
        var keep = [Bool](repeating: false, count: coords.count)
        keep[0] = true
        keep[coords.count - 1] = true
        var ranges: [(start: Int, end: Int)] = [(0, coords.count - 1)]

        while let range = ranges.popLast() {
            guard range.end > range.start + 1 else { continue }

            var maxDist: Double = 0
            var maxIndex = range.start
            for i in (range.start + 1)..<range.end {
                let d = distanceToSegment(coords[i], coords[range.start], coords[range.end])
                if d > maxDist { maxDist = d; maxIndex = i }
            }

            if maxDist > tolerance {
                keep[maxIndex] = true
                ranges.append((range.start, maxIndex))
                ranges.append((maxIndex, range.end))
            }
        }

        return zip(coords, keep).compactMap { $1 ? $0 : nil }
    }

    /// Perpendicular distance in meters from a point to a segment, clamped to the segment.
    nonisolated static func distanceToSegment(
        _ point: CLLocationCoordinate2D,
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> Double {
        let cosLat = cos(point.latitude * .pi / 180)
        let px = (point.longitude - a.longitude) * cosLat
        let py = point.latitude - a.latitude
        let dx = (b.longitude - a.longitude) * cosLat
        let dy = b.latitude - a.latitude
        let segLenSq = dx * dx + dy * dy
        var t: Double = 0
        if segLenSq > 0 { t = max(0, min(1, (px * dx + py * dy) / segLenSq)) }
        let projected = CLLocationCoordinate2D(
            latitude: a.latitude + t * (b.latitude - a.latitude),
            longitude: a.longitude + t * (b.longitude - a.longitude)
        )
        return NavigationEngine.haversineDistance(from: point, to: projected)
    }

    // MARK: - Disk Cache

    /// Cache key: SHA256 of the precision-6 encoded polyline.
    nonisolated static func cacheKey(for polyline: [CLLocationCoordinate2D]) -> String {
        let encoded = PolylineEncoder.encode(polyline, precision: 6)
        return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func cacheFileURL(key: String) -> URL {
        cacheDirectory.appendingPathComponent("\(key).json")
    }

    private func loadCachedPayload(key: String) -> CachedSpeedLimits? {
        let fileURL = cacheFileURL(key: key)
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(CachedSpeedLimits.self, from: data) else { return nil }

        guard now().timeIntervalSince(payload.fetchedAt) < Tuning.cacheTTL else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return payload
    }

    private func savePayload(_ payload: CachedSpeedLimits, key: String) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheFileURL(key: key))
    }
}

// MARK: - Overpass Response

private struct OverpassResponse: Decodable {
    let elements: [Element]

    struct Element: Decodable {
        let id: Int
        let tags: [String: String]?
        let geometry: [SpeedLimitPoint]?
    }
}

// MARK: - Tuning

private enum Tuning {
    /// Overpass mirrors, tried in order until one succeeds.
    static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    ]
    static let downsampleToleranceMeters: Double = 25
    static let maxQueryPoints = 250
    static let maxPointsPerClause = 250
    static let aroundRadiusMeters = 25
    static let cacheTTL: TimeInterval = 30 * 24 * 3600
    static let mphPerKmh = 0.621371
}
