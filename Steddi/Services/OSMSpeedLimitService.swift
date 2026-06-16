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
    static let shared = OSMSpeedLimitService()


    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Route key of the currently indexed speed-limit data.
    private(set) var loadedRouteKey: String?
    private(set) var isPrefetching = false

    /// Monotonic prefetch token. A reroute can start a new prefetch while an
    /// older one is still in flight; only the newest generation may publish
    /// its ways or clear `isPrefetching`, so a slow stale fetch can never
    /// clobber the active route's data.
    private var prefetchGeneration = 0

    private let transport: Transport
    private let cacheDirectory: URL
    private let now: () -> Date

    /// Per-way speed limits for the currently loaded route. Way geometry is
    /// dropped after indexing — the segments carry their own copies, so
    /// retaining the full `SpeedLimitWay` set would hold every vertex twice
    /// for the length of the drive.
    private var wayLimits: [WayLimit] = []

    /// Spatial hash grid: cell -> indices into `segments`.
    private var segments: [Segment] = []
    private var grid: [GridCell: [Int]] = [:]

    /// Hysteresis: stick with the last matched way unless the same challenger
    /// stays meaningfully closer for several consecutive lookups. The streak
    /// is per-challenger — two different ways alternating must not pool one.
    private var lastWayIndex: Int?
    private var challengerIndex: Int?
    private var challengerStreak = 0

    /// Age-out streak for the within-margin case. The fast `challengerStreak`
    /// only accrues when a challenger is closer than the held way by more than
    /// the hysteresis margin, so a genuinely-changed road that runs within the
    /// margin of the old one (tightly-parallel frontage/service roads, slip
    /// lanes) could otherwise pin the readout to the stale way indefinitely.
    /// This slower streak forces a switch once a *different* way has been the
    /// strict-nearest qualifying candidate for long enough that it can't be
    /// jitter — the driver has clearly left the old way. Strict-nearest, so a
    /// truly equidistant co-located pair never trips it (no flicker).
    private var staleChallengerIndex: Int?
    private var staleChallengerStreak = 0

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
    ///
    /// Disk IO, JSON coding, polyline simplification, and the spatial index
    /// build all run off the main actor: a 70-mile corridor payload is
    /// multi-megabyte and would hitch the UI right at route start.
    func prefetch(for polyline: [CLLocationCoordinate2D], routeKey: String) async {
        guard polyline.count >= 2 else { return }
        prefetchGeneration += 1
        let generation = prefetchGeneration
        isPrefetching = true
        defer {
            if generation == prefetchGeneration { isPrefetching = false }
        }

        let directory = cacheDirectory
        let currentDate = now()
        let (fileURL, cached) = await Task.detached(priority: .userInitiated) { () -> (URL, CachedSpeedLimits?) in
            let fileURL = directory.appendingPathComponent("\(Self.cacheKey(for: polyline)).json")
            return (fileURL, Self.loadCachedPayload(at: fileURL, now: currentDate))
        }.value
        if let cached {
            await install(ways: cached.ways, routeKey: routeKey, generation: generation)
            return
        }

        // Cache MISS on a corridor change: the new route's data isn't available
        // yet, and `fetch(query:)` below is a multi-second Overpass round-trip. If
        // a PREVIOUS route's index is still installed (a route switch / recovery
        // splice re-prefetch), leaving it in place means `speedLimit(at:)` keeps
        // serving the abandoned route's posted limit wherever the new geometry
        // incidentally runs within match radius of an old way — a wrong HUD limit
        // (and wrong over-limit/camera comparison) for the whole in-flight window.
        // Clear it up front so lookups return nil (callers fall back to the
        // per-step instruction estimate) until the new corridor's index installs.
        // Only when still the newest generation — a newer prefetch already
        // superseded us, so we must not disturb its data. Mirrors the failed-fetch
        // `clearIndex()` that already closed this exact gap on the failure path.
        if generation == prefetchGeneration {
            clearIndex()
        }

        let query = await Task.detached(priority: .userInitiated) {
            let sampled = Self.downsample(
                polyline,
                tolerance: Tuning.downsampleToleranceMeters,
                maxPoints: Tuning.maxQueryPoints
            )
            return Self.overpassQuery(for: sampled)
        }.value
        guard let fetched = await fetch(query: query) else {
            // The new route's prefetch failed (all mirrors 429/5xx, a bad-query
            // 4xx, or cancellation). If this is still the newest generation,
            // drop any previously-loaded route's index instead of leaving it
            // installed — otherwise speedLimit(at:) keeps serving the abandoned
            // route's limits wherever the new route incidentally runs near the
            // old one. A newer prefetch already superseded us: leave its data
            // alone.
            if generation == prefetchGeneration {
                clearIndex()
            }
            return
        }

        // Cache the result regardless (it is keyed by this polyline), but only
        // the newest prefetch may install ways for lookup.
        let payload = CachedSpeedLimits(ways: fetched, fetchedAt: now())
        await Task.detached(priority: .utility) {
            Self.savePayload(payload, to: fileURL)
        }.value
        await install(ways: fetched, routeKey: routeKey, generation: generation)
    }

    /// Replace the in-memory way set used for lookups and rebuild the spatial
    /// index synchronously. Prefetch goes through `install` instead so the
    /// build happens off the main actor.
    func loadWays(_ newWays: [SpeedLimitWay], routeKey: String) {
        apply(Self.buildIndex(for: newWays), routeKey: routeKey)
    }

    /// Build the spatial index off the main actor, then publish it — unless a
    /// newer prefetch generation started in the meantime.
    private func install(ways newWays: [SpeedLimitWay], routeKey: String, generation: Int) async {
        let index = await Task.detached(priority: .userInitiated) {
            Self.buildIndex(for: newWays)
        }.value
        guard generation == prefetchGeneration else { return }
        apply(index, routeKey: routeKey)
    }

    private func apply(_ index: SpatialIndex, routeKey: String) {
        wayLimits = index.wayLimits
        segments = index.segments
        grid = index.grid
        loadedRouteKey = routeKey
        lastWayIndex = nil
        resetChallenger()
    }

    /// Drop the in-memory index after a failed prefetch. With no segments,
    /// `speedLimit(at:)` returns nil (callers fall back to the per-step
    /// instruction estimate) instead of answering from the abandoned route's
    /// geometry, and `loadedRouteKey` goes nil so callers can tell nothing
    /// valid is loaded — never reporting the stale route as still current.
    private func clearIndex() {
        wayLimits = []
        segments = []
        grid = [:]
        loadedRouteKey = nil
        lastWayIndex = nil
        resetChallenger()
    }

    private func resetChallenger() {
        challengerIndex = nil
        challengerStreak = 0
        staleChallengerIndex = nil
        staleChallengerStreak = 0
    }

    /// Reset only the fast (>margin) streak, leaving the slow age-out streak to
    /// keep accruing across lookups that stay inside the margin.
    private func resetFastChallenger() {
        challengerIndex = nil
        challengerStreak = 0
    }

    private nonisolated static func buildIndex(for newWays: [SpeedLimitWay]) -> SpatialIndex {
        let usable = newWays.filter { $0.geometry.count >= 2 }
        var wayLimits: [WayLimit] = []
        wayLimits.reserveCapacity(usable.count)
        var segments: [Segment] = []
        var grid: [GridCell: [Int]] = [:]

        for (wayIndex, way) in usable.enumerated() {
            wayLimits.append(WayLimit(mph: way.limitMph, isEstimated: way.isEstimated))
            for i in 0..<(way.geometry.count - 1) {
                let a = CLLocationCoordinate2D(latitude: way.geometry[i].lat, longitude: way.geometry[i].lon)
                let b = CLLocationCoordinate2D(latitude: way.geometry[i + 1].lat, longitude: way.geometry[i + 1].lon)
                let segmentIndex = segments.count
                segments.append(Segment(
                    wayIndex: wayIndex,
                    start: a,
                    end: b,
                    bearing: CustomRouteBuilder.bearing(from: a, to: b)
                ))

                // Register the segment in every cell its bounding box covers.
                // A single segment spanning more than ~100km of cells on one
                // axis is corrupt data or an antimeridian crossing (longitude
                // jumping 179.99 -> -179.99 would enumerate ~360k cells), so
                // leave it out of the grid rather than blow up the index.
                let latRange = Self.cellRange(a.latitude, b.latitude)
                let lonRange = Self.cellRange(a.longitude, b.longitude)
                guard latRange.count <= Tuning.maxCellSpanPerSegment,
                      lonRange.count <= Tuning.maxCellSpanPerSegment else { continue }
                for latCell in latRange {
                    for lonCell in lonRange {
                        grid[GridCell(lat: latCell, lon: lonCell), default: []].append(segmentIndex)
                    }
                }
            }
        }
        return SpatialIndex(wayLimits: wayLimits, segments: segments, grid: grid)
    }

    // MARK: - Lookup

    /// Synchronous in-memory speed limit lookup for the current position.
    /// Candidates come from the spatial grid (cell + 8 neighbors), gated to 30m
    /// perpendicular distance, heading-filtered, with way-switch hysteresis.
    func speedLimit(at coordinate: CLLocationCoordinate2D, heading: Double?) -> (mph: Double, isEstimated: Bool)? {
        guard !segments.isEmpty else { return nil }

        let centerLat = Self.cellIndex(coordinate.latitude)
        let centerLon = Self.cellIndex(coordinate.longitude)
        var candidates = Set<Int>()
        for dLat in -1...1 {
            for dLon in -1...1 {
                if let indices = grid[GridCell(lat: centerLat + dLat, lon: centerLon + dLon)] {
                    candidates.formUnion(indices)
                }
            }
        }

        // Nearest qualifying distance per way.
        var wayDistances: [Int: Double] = [:]
        for segmentIndex in candidates {
            let segment = segments[segmentIndex]
            if let heading, Self.bearingDelta(segment.bearing, heading) > Tuning.headingToleranceDegrees {
                continue
            }
            let distance = Self.distanceToSegment(coordinate, segment.start, segment.end)
            guard distance <= Tuning.matchRadiusMeters else { continue }
            if distance < wayDistances[segment.wayIndex] ?? .infinity {
                wayDistances[segment.wayIndex] = distance
            }
        }

        guard let nearest = wayDistances.min(by: { $0.value < $1.value }) else {
            lastWayIndex = nil
            resetChallenger()
            return nil
        }

        var chosen = nearest.key
        if let last = lastWayIndex, last != nearest.key {
            if let lastDistance = wayDistances[last] {
                if nearest.value < lastDistance - Tuning.hysteresisMarginMeters {
                    // Challenger is meaningfully closer — switch only after the
                    // same way sustains the streak.
                    if challengerIndex == nearest.key {
                        challengerStreak += 1
                    } else {
                        challengerIndex = nearest.key
                        challengerStreak = 1
                    }
                    if challengerStreak < Tuning.hysteresisLookups {
                        chosen = last
                    } else {
                        resetChallenger()
                    }
                } else if nearest.value < lastDistance {
                    // Challenger is strictly nearer than the held way but inside
                    // the flicker margin. Normally we hold `last` here so two
                    // co-located ways don't ping-pong, but if the SAME way stays
                    // the strict-nearest for a long run the driver has actually
                    // left the old way (a tightly-parallel road that never gets
                    // >margin closer) — age out the stale lock and switch.
                    resetFastChallenger()
                    if staleChallengerIndex == nearest.key {
                        staleChallengerStreak += 1
                    } else {
                        staleChallengerIndex = nearest.key
                        staleChallengerStreak = 1
                    }
                    if staleChallengerStreak < Tuning.staleWayLookups {
                        chosen = last
                    } else {
                        resetChallenger()
                    }
                } else {
                    // Held way is at least as near (equidistant or nearer):
                    // genuine flicker territory — hold and reset both streaks.
                    resetChallenger()
                    chosen = last
                }
            } else {
                // Last way is no longer a candidate — switch immediately.
                resetChallenger()
            }
        } else {
            resetChallenger()
        }

        // Bounds-check before caching: never store an index we won't read, so a
        // bad `chosen` can't poison `lastWayIndex` for the next lookup's hysteresis.
        guard chosen < wayLimits.count else { return nil }
        lastWayIndex = chosen
        let limit = wayLimits[chosen]
        return (limit.mph, limit.isEstimated)
    }

    /// Angular difference between two bearings, ignoring direction of travel (mod 180).
    nonisolated static func bearingDelta(_ a: Double, _ b: Double) -> Double {
        var diff = abs(a - b).truncatingRemainder(dividingBy: 180)
        if diff > 90 { diff = 180 - diff }
        return diff
    }

    private nonisolated static func cellIndex(_ degrees: Double) -> Int {
        Int(floor(degrees / Tuning.cellSizeDegrees))
    }

    private nonisolated static func cellRange(_ a: Double, _ b: Double) -> ClosedRange<Int> {
        cellIndex(min(a, b))...cellIndex(max(a, b))
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
            // Overpass usage policy asks for an identifying User-Agent.
            request.setValue(Tuning.userAgent, forHTTPHeaderField: "User-Agent")
            request.httpBody = body
            request.timeoutInterval = 30

            do {
                let (data, response) = try await transport(request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    // 429 and 5xx are mirror-specific; any other 4xx means the
                    // query itself is bad and would fail identically everywhere.
                    if http.statusCode == 429 || http.statusCode >= 500 { continue }
                    return nil
                }
                // Decode off-main: a long-corridor response can be several MB.
                return try await Task.detached(priority: .userInitiated) {
                    try Self.parseOverpassResponse(data)
                }.value
            } catch is CancellationError {
                return nil
            } catch {
                // URLSession surfaces task cancellation as URLError(.cancelled);
                // a cancelled prefetch must not keep POSTing to the next mirror.
                if (error as? URLError)?.code == .cancelled || Task.isCancelled { return nil }
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

    /// Parse an OSM maxspeed tag value to mph. Forwards to the shared
    /// `OSMTagParsing` so the speed-limit service and the road-graph loader
    /// derive identical speeds from identical tags.
    nonisolated static func parseMaxspeed(_ raw: String?) -> Double? {
        OSMTagParsing.parseMaxspeed(raw)
    }

    /// Typical US speed limit for an OSM highway class, used when no maxspeed tag
    /// exists. Restricted to the classes this service queries — the shared
    /// `OSMTagParsing.defaultSpeedMph` also covers `service`/`living_street`,
    /// which the speed-limit query deliberately excludes, so they remain nil here
    /// (a `service` way with no maxspeed is skipped, as before).
    nonisolated static func defaultSpeedMph(forHighwayClass highway: String) -> Double? {
        switch highway {
        case "service", "living_street":
            return nil
        default:
            return OSMTagParsing.defaultSpeedMph(forHighwayClass: highway)
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

    private nonisolated static func loadCachedPayload(at fileURL: URL, now: Date) -> CachedSpeedLimits? {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(CachedSpeedLimits.self, from: data) else { return nil }

        guard now.timeIntervalSince(payload.fetchedAt) < Tuning.cacheTTL else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return payload
    }

    private nonisolated static func savePayload(_ payload: CachedSpeedLimits, to fileURL: URL) {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL)
    }
}

// MARK: - Spatial Index Types

/// Speed limit retained per way after its geometry has been indexed.
private struct WayLimit {
    let mph: Double
    let isEstimated: Bool
}

/// Immutable lookup structures, built off-main and installed atomically.
private struct SpatialIndex {
    let wayLimits: [WayLimit]
    let segments: [Segment]
    let grid: [GridCell: [Int]]
}

private struct Segment {
    let wayIndex: Int
    let start: CLLocationCoordinate2D
    let end: CLLocationCoordinate2D
    let bearing: Double
}

private struct GridCell: Hashable {
    let lat: Int
    let lon: Int
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
    /// Identifying User-Agent per Overpass usage policy. Public instances
    /// reject generic agents with 406, so keep this exact and recognizable.
    static let userAgent = "Steddi/1.0 (steddi.io)"
    static let downsampleToleranceMeters: Double = 25
    static let maxQueryPoints = 250
    static let maxPointsPerClause = 250
    static let aroundRadiusMeters = 25
    static let cacheTTL: TimeInterval = 30 * 24 * 3600
    static let cellSizeDegrees = 0.001
    /// Bounding-box guard for grid registration: no plausible OSM way segment
    /// spans 1000 cells (~1.1 degrees) on an axis.
    static let maxCellSpanPerSegment = 1000
    static let matchRadiusMeters: Double = 30
    static let headingToleranceDegrees: Double = 50
    static let hysteresisMarginMeters: Double = 5
    static let hysteresisLookups = 3
    /// Age-out threshold for a challenger that stays strictly nearest but always
    /// inside the flicker margin. Comfortably longer than `hysteresisLookups` so
    /// brief within-margin jitter is still ignored, but bounded so a road that
    /// genuinely changed under a tightly-parallel geometry updates within a few
    /// seconds of GPS fixes rather than pinning to the stale way forever.
    static let staleWayLookups = 8
}
