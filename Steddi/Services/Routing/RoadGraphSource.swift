import Foundation
import CoreLocation
import CryptoKit
import Observation

/// Loads a routable `RoadGraph` for a commute corridor from OpenStreetMap via
/// the Overpass API, then caches it on-device.
///
/// This is the Phase-2 keystone loader. It mirrors `OSMSpeedLimitService`'s
/// proven production scaffolding exactly — the same Overpass mirror list,
/// identifying User-Agent, POST form-encoding, 429/5xx failover, monotonic
/// generation token, off-main fetch/decode/build, and a SHA256-keyed disk cache
/// with a 30-day TTL. The two differences are deliberate and load-bearing:
///
/// 1. The query requests **topology** (`out body; >; out skel qt;`) so ways
///    carry their node-id sequences and nodes carry id + lat/lon. Two ways that
///    cross without a shared node stay disconnected (grade separation) — the
///    speed service's geometry-only `out tags geom;` cannot express this.
/// 2. The cached payload is the **binary graph blob** (`RoadGraphSerializer`),
///    not JSON — a corridor graph is multi-MB and JSON tag-soup is slow and huge
///    (§3.8). The corridor cache key hashes the corridor geometry, so a commuter
///    re-uses one blob for 30 days.
///
/// Network failure degrades gracefully: a stale-but-present cache is preferred,
/// and a total miss returns `nil` rather than throwing, so the router can fall
/// back to MapKit (Phase 5) without crashing the drive.
@Observable
@MainActor
final class RoadGraphSource {

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Corridor key of the currently loaded graph, if any.
    private(set) var loadedCorridorKey: String?
    private(set) var isLoading = false

    /// The graph for the active corridor. `nil` until a load succeeds.
    private(set) var graph: RoadGraph?

    /// Monotonic load token. A new corridor request can start while an older
    /// one is still in flight; only the newest generation may publish its graph
    /// or clear `isLoading`, so a slow stale load can never clobber the active
    /// corridor (identical discipline to `OSMSpeedLimitService.prefetchGeneration`).
    private var loadGeneration = 0

    private let transport: Transport
    private let cacheDirectory: URL
    private let now: () -> Date

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
            self.cacheDirectory = caches.appendingPathComponent("RoadGraphs", isDirectory: true)
        }
        self.now = now
    }

    // MARK: - Load

    /// Load (or refresh) the road graph for a corridor. The corridor is the
    /// union of the commute's preferred polyline(s); a buffered `around` clause
    /// per downsampled vertex captures the road network plus obvious alternates.
    ///
    /// A fresh disk-cache hit short-circuits the network entirely. Everything
    /// heavy — disk IO, JSON decode, the split-at-intersections build, binary
    /// (de)serialize — runs off the main actor, because a 70-mile corridor graph
    /// is multi-MB and would hitch the UI at route start.
    ///
    /// - Returns: the loaded graph, or `nil` if neither the cache nor any mirror
    ///   could supply one (the caller then falls back to MapKit).
    @discardableResult
    func load(corridor: [CLLocationCoordinate2D], corridorKey: String) async -> RoadGraph? {
        guard corridor.count >= 2 else { return nil }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }

        let directory = cacheDirectory
        let currentDate = now()
        let (fileURL, cached) = await Task.detached(priority: .userInitiated) { () -> (URL, RoadGraph?) in
            let fileURL = directory.appendingPathComponent("\(Self.cacheKey(for: corridor)).srg")
            return (fileURL, Self.loadCachedGraph(at: fileURL, now: currentDate))
        }.value
        if let cached {
            return publish(cached, corridorKey: corridorKey, generation: generation)
        }

        let query = await Task.detached(priority: .userInitiated) {
            let sampled = OSMSpeedLimitService.downsample(
                corridor,
                tolerance: Tuning.downsampleToleranceMeters,
                maxPoints: Tuning.maxQueryPoints
            )
            return Self.overpassQuery(for: sampled)
        }.value

        guard let built = await fetchAndBuild(query: query) else {
            // Total network failure: prefer a stale-but-present cache over nothing
            // (graceful degradation — an old corridor graph still routes).
            let stale = await Task.detached(priority: .userInitiated) { () -> RoadGraph? in
                Self.loadCachedGraph(at: fileURL, now: currentDate, ignoreTTL: true)
            }.value
            if let stale {
                return publish(stale, corridorKey: corridorKey, generation: generation)
            }
            return nil
        }

        // Persist the binary blob regardless (it is keyed by this corridor), but
        // only the newest load may publish for use.
        let blob = await Task.detached(priority: .utility) { () -> Data in
            let data = RoadGraphSerializer.serialize(built)
            Self.saveBlob(data, fetchedAt: currentDate, to: fileURL)
            return data
        }.value
        _ = blob
        return publish(built, corridorKey: corridorKey, generation: generation)
    }

    /// Install a freshly loaded graph, unless a newer load superseded this one.
    @discardableResult
    private func publish(_ newGraph: RoadGraph, corridorKey: String, generation: Int) -> RoadGraph? {
        guard generation == loadGeneration else { return nil }
        graph = newGraph
        loadedCorridorKey = corridorKey
        return newGraph
    }

    // MARK: - Network

    /// POST the query to each mirror in turn, decode the topology response off
    /// the main actor, and build the graph. Mirror-specific failures (429, 5xx,
    /// timeouts) rotate to the next endpoint; a deterministic 4xx aborts.
    private func fetchAndBuild(query: String) async -> RoadGraph? {
        guard let encoded = Self.formURLEncoded(query) else { return nil }
        let body = Data("data=\(encoded)".utf8)

        for endpoint in Tuning.endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            // Overpass usage policy requires an identifying User-Agent; generic
            // agents are rejected with 406.
            request.setValue(Tuning.userAgent, forHTTPHeaderField: "User-Agent")
            request.httpBody = body
            request.timeoutInterval = Tuning.requestTimeout

            do {
                let (data, response) = try await transport(request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    // 429 and 5xx are mirror-specific; any other 4xx means the
                    // query itself is bad and would fail identically everywhere.
                    if http.statusCode == 429 || http.statusCode >= 500 { continue }
                    return nil
                }
                // Decode + build off-main: a long-corridor response is several MB
                // and the split-at-intersections build is CPU-bound.
                return try await Task.detached(priority: .userInitiated) {
                    let parsed = try JSONDecoder().decode(OverpassGraphResponse.self, from: data)
                    return RoadGraphBuilder.buildGraph(from: parsed)
                }.value
            } catch is CancellationError {
                return nil
            } catch {
                // URLSession surfaces task cancellation as URLError(.cancelled);
                // a cancelled load must not keep POSTing to the next mirror.
                if (error as? URLError)?.code == .cancelled || Task.isCancelled { return nil }
                continue
            }
        }
        return nil
    }

    // MARK: - Query

    /// OSM highway classes the driving graph keeps. Includes `service` and
    /// `living_street` (first/last-mile, parking-lot egress); excludes
    /// track/path/footway/cycleway/steps/pedestrian. Matches the loader's
    /// `OSMTagParsing.parseRoadClass` filter so the query and the builder agree.
    static let highwayFilter = #"["highway"~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|service|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link)$"]"#

    /// Build the Overpass QL query for a routable corridor graph.
    ///
    /// Unlike the speed service's `out tags geom;` (geometry only), this requests
    /// **topology**: `out body;` emits each way's node-id sequence and tags, `>;`
    /// recurses to the referenced nodes, and `out skel qt;` emits node id +
    /// lat/lon (plus node tags like traffic_signals). Shared node ids are the
    /// only reliable signal that two ways connect.
    ///
    /// Splits into multiple `around` clauses within one request when the corridor
    /// exceeds the per-clause cap, overlapping one point so coverage is continuous.
    nonisolated static func overpassQuery(for points: [CLLocationCoordinate2D]) -> String {
        guard !points.isEmpty else { return "" }

        var clauses: [String] = []
        var start = 0
        repeat {
            let end = min(start + Tuning.maxPointsPerClause, points.count)
            let coords = points[start..<end]
                .map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }
                .joined(separator: ",")
            clauses.append("way(around:\(Tuning.corridorBufferMeters),\(coords))\(highwayFilter);")
            if end == points.count { break }
            start = end - 1 // overlap one point so coverage is continuous
        } while true

        return "[out:json][timeout:60];(\(clauses.joined()));out body;>;out skel qt;"
    }

    nonisolated static func formURLEncoded(_ string: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        return string.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    // MARK: - Disk Cache

    /// Cache key: SHA256 of the precision-6 encoded corridor polyline. Identical
    /// approach to `OSMSpeedLimitService.cacheKey` so two corridors that differ
    /// even slightly get distinct blobs.
    nonisolated static func cacheKey(for corridor: [CLLocationCoordinate2D]) -> String {
        let encoded = PolylineEncoder.encode(corridor, precision: 6)
        return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// On-disk corridor blob: an 8-byte fetched-at timestamp header (big-endian
    /// `UInt64` epoch millis) followed by the serialized graph. Keeping the TTL
    /// stamp in the same file as the graph means one atomic write and one read.
    private static let timestampHeaderBytes = 8

    private nonisolated static func loadCachedGraph(at fileURL: URL, now: Date, ignoreTTL: Bool = false) -> RoadGraph? {
        guard let data = try? Data(contentsOf: fileURL), data.count > timestampHeaderBytes else { return nil }
        let fetchedAt = readTimestamp(data)
        if !ignoreTTL {
            guard now.timeIntervalSince(fetchedAt) < Tuning.cacheTTL else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
        }
        let blob = data.subdata(in: (data.startIndex + timestampHeaderBytes)..<data.endIndex)
        return RoadGraphSerializer.deserialize(blob)
    }

    private nonisolated static func saveBlob(_ blob: Data, fetchedAt: Date, to fileURL: URL) {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var data = Data()
        appendTimestamp(fetchedAt, to: &data)
        data.append(blob)
        try? data.write(to: fileURL, options: .atomic)
    }

    private nonisolated static func appendTimestamp(_ date: Date, to data: inout Data) {
        let millis = UInt64((date.timeIntervalSince1970 * 1000).rounded())
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((millis >> UInt64(shift)) & 0xff))
        }
    }

    private nonisolated static func readTimestamp(_ data: Data) -> Date {
        var millis: UInt64 = 0
        let base = data.startIndex
        for i in 0..<timestampHeaderBytes {
            millis = (millis << 8) | UInt64(data[base + i])
        }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}

// MARK: - Tuning

/// Loader tuning. The Overpass scaffolding (mirror list, User-Agent, cache TTL)
/// matches `OSMSpeedLimitService.Tuning` exactly; the corridor buffer is wider
/// because routing needs the alternates a reroute might use, not just the road
/// under the wheels (§3.1).
private enum Tuning {
    /// Overpass mirrors, tried in order until one succeeds. Same set the speed
    /// service proved in production.
    static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    ]
    /// Identifying User-Agent per Overpass usage policy. Public instances reject
    /// generic agents with 406, so keep this exact and recognizable.
    static let userAgent = "Steddi/1.0 (steddi.io)"
    /// Corridor `around` buffer: ~1500 m each side captures parallel arterials
    /// and the obvious alternates a reroute might take (§3.1).
    static let corridorBufferMeters = 1500
    /// RDP tolerance for the corridor centerline before building `around`
    /// clauses. Wider than the speed service's 25 m because the 1500 m buffer
    /// already swallows centerline detail — fewer points keeps the payload small.
    static let downsampleToleranceMeters: Double = 100
    static let maxQueryPoints = 200
    static let maxPointsPerClause = 200
    static let requestTimeout: TimeInterval = 60
    static let cacheTTL: TimeInterval = 30 * 24 * 3600
}
