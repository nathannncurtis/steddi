import Testing
import Foundation
import CoreLocation
@testable import Steddi

// Phase-2 loader tests. Fully network-free: a `Transport` stub records requests
// and serves canned topology JSON. Covers query construction, cache round-trip,
// TTL expiry, stale-generation drop, mirror failover, graceful degradation, and
// OSM-response -> graph construction through the real builder.

// MARK: - Helpers

/// Records requests and serves canned responses, keeping tests network-free.
private final class GraphTransportStub: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: @Sendable (URLRequest) throws -> (Data, URLResponse)

    init(handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    var transport: RoadGraphSource.Transport {
        { request in
            self.lock.withLock { self.recorded.append(request) }
            return try self.handler(request)
        }
    }
}

private func graphHTTP(status: Int, data: Data = Data(), url: URL?) -> (Data, URLResponse) {
    let response = HTTPURLResponse(
        url: url ?? URL(fileURLWithPath: "/"),
        statusCode: status,
        httpVersion: nil,
        headerFields: nil
    )
    return (data, response ?? URLResponse())
}

private func graphHTTPOK(_ data: Data, url: URL?) -> (Data, URLResponse) {
    graphHTTP(status: 200, data: data, url: url)
}

private func gcoord(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

private func gtempDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("RoadGraphSourceTests-\(UUID().uuidString)", isDirectory: true)
}

/// Build a topology Overpass JSON node element (id + lat/lon + optional tags).
private func nodeJSON(id: Int64, lat: Double, lon: Double, tags: [String: String] = [:]) -> String {
    var s = #"{"type":"node","id":\#(id),"lat":\#(lat),"lon":\#(lon)"#
    if !tags.isEmpty {
        let body = tags.map { #""\#($0.key)":"\#($0.value)""# }.joined(separator: ",")
        s += #","tags":{\#(body)}"#
    }
    return s + "}"
}

/// Build a topology Overpass JSON way element (id + node-id sequence + tags).
private func wayElementJSON(id: Int64, nodes: [Int64], tags: [String: String]) -> String {
    let nodeList = nodes.map(String.init).joined(separator: ",")
    let tagBody = tags.map { #""\#($0.key)":"\#($0.value)""# }.joined(separator: ",")
    return #"{"type":"way","id":\#(id),"nodes":[\#(nodeList)],"tags":{\#(tagBody)}}"#
}

private func overpassGraphData(_ elements: String...) -> Data {
    Data(#"{"version":0.6,"elements":[\#(elements.joined(separator: ","))]}"#.utf8)
}

/// A minimal two-node residential way, returned topology-complete.
private func twoNodeWayData() -> Data {
    overpassGraphData(
        nodeJSON(id: 1, lat: 0, lon: 0),
        nodeJSON(id: 2, lat: 0.001, lon: 0),
        wayElementJSON(id: 100, nodes: [1, 2], tags: ["highway": "residential", "maxspeed": "25 mph"])
    )
}

// MARK: - Query construction

@Suite("RoadGraphSource.overpassQuery")
struct RoadGraphSourceQueryTests {

    @Test("Query requests topology (body + recurse + skel)")
    func requestsTopology() {
        let query = RoadGraphSource.overpassQuery(for: [gcoord(33.1, -117.2), gcoord(33.2, -117.3)])
        #expect(query.hasPrefix("[out:json][timeout:60];"))
        // The three-part topology output — node ids must be resolvable.
        #expect(query.contains("out body;"))
        #expect(query.contains(">;"))
        #expect(query.contains("out skel qt;"))
        // NOT geometry-only like the speed service.
        #expect(!query.contains("out tags geom;"))
    }

    @Test("Single corridor yields one around clause at the 1500m buffer")
    func singleAroundClause() {
        let query = RoadGraphSource.overpassQuery(for: [gcoord(33.1, -117.2), gcoord(33.2, -117.3)])
        #expect(query.components(separatedBy: "way(around:1500,").count - 1 == 1)
        #expect(query.contains("33.100000,-117.200000,33.200000,-117.300000"))
    }

    @Test("Highway filter includes service and living_street, excludes footway")
    func highwayFilterScope() {
        let query = RoadGraphSource.overpassQuery(for: [gcoord(0, 0), gcoord(0.001, 0)])
        #expect(query.contains("service"))
        #expect(query.contains("living_street"))
        #expect(!query.contains("footway"))
    }

    @Test("Corridor beyond the per-clause cap splits into multiple around clauses")
    func splitsClauses() {
        let points = (0..<210).map { gcoord(Double($0) * 0.001, 0) }
        let query = RoadGraphSource.overpassQuery(for: points)
        #expect(query.components(separatedBy: "way(around:1500,").count - 1 == 2)
    }

    @Test("Empty corridor yields an empty query")
    func emptyQuery() {
        #expect(RoadGraphSource.overpassQuery(for: []).isEmpty)
    }

    @Test("Cache key is deterministic and corridor-sensitive")
    func cacheKey() {
        let a = [gcoord(0, 0), gcoord(0.001, 0)]
        let b = [gcoord(0, 0), gcoord(0.002, 0)]
        #expect(RoadGraphSource.cacheKey(for: a) == RoadGraphSource.cacheKey(for: a))
        #expect(RoadGraphSource.cacheKey(for: a) != RoadGraphSource.cacheKey(for: b))
        #expect(RoadGraphSource.cacheKey(for: a).count == 64)
    }
}

// MARK: - Load + graph construction

@Suite("RoadGraphSource.load", .serialized)
@MainActor
struct RoadGraphSourceLoadTests {

    private let corridor = [gcoord(0, 0), gcoord(0.001, 0)]

    @Test("Load fetches once, builds a graph, and publishes it")
    func loadBuildsGraph() async {
        let directory = gtempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transport = GraphTransportStub { request in graphHTTPOK(twoNodeWayData(), url: request.url) }
        let source = RoadGraphSource(transport: transport.transport, cacheDirectory: directory)
        let graph = await source.load(corridor: corridor, corridorKey: "commute-1")

        #expect(transport.requests.count == 1)
        #expect(transport.requests.first?.httpMethod == "POST")
        #expect(transport.requests.first?.httpBody?.starts(with: Data("data=".utf8)) == true)
        #expect(source.loadedCorridorKey == "commute-1")
        #expect(source.isLoading == false)

        let g = try! #require(graph)
        #expect(source.graph != nil)
        // Two graph nodes (endpoints), one both-direction way -> two directed edges.
        #expect(g.nodes.count == 2)
        #expect(g.edges.count == 2)
        // Free-flow from "25 mph" -> ~11.176 m/s.
        #expect(abs(g.graphMaxSpeedMPS - Float(25 * 0.44704)) < 0.01)
    }

    @Test("Topology is preserved: crossing ways with no shared node stay disconnected")
    func gradeSeparationPreserved() async {
        let directory = gtempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Two ways visually crossing at (0,0) but with DIFFERENT node ids there —
        // an overpass over an underpass. They must not connect.
        let data = overpassGraphData(
            nodeJSON(id: 1, lat: -0.001, lon: 0),
            nodeJSON(id: 2, lat: 0.001, lon: 0),
            nodeJSON(id: 3, lat: 0, lon: -0.001),
            nodeJSON(id: 4, lat: 0, lon: 0.001),
            wayElementJSON(id: 10, nodes: [1, 2], tags: ["highway": "primary", "bridge": "yes"]),
            wayElementJSON(id: 20, nodes: [3, 4], tags: ["highway": "primary"])
        )
        let transport = GraphTransportStub { request in graphHTTPOK(data, url: request.url) }
        let source = RoadGraphSource(transport: transport.transport, cacheDirectory: directory)
        let g = try! #require(await source.load(corridor: corridor, corridorKey: "x"))

        // 4 endpoints, no intersection -> no node has degree > 0 from the other way.
        #expect(g.nodes.count == 4)
        #expect(g.nodes.allSatisfy { !$0.isIntersection })
    }

    @Test("Shared node connects two ways into an intersection")
    func sharedNodeConnects() async {
        let directory = gtempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Both ways reference node 3 at the center -> a real intersection.
        let data = overpassGraphData(
            nodeJSON(id: 1, lat: -0.001, lon: 0),
            nodeJSON(id: 2, lat: 0, lon: -0.001),
            nodeJSON(id: 3, lat: 0, lon: 0, tags: ["highway": "traffic_signals"]),
            nodeJSON(id: 4, lat: 0.001, lon: 0),
            nodeJSON(id: 5, lat: 0, lon: 0.001),
            wayElementJSON(id: 10, nodes: [1, 3, 4], tags: ["highway": "primary"]),
            wayElementJSON(id: 20, nodes: [2, 3, 5], tags: ["highway": "primary"])
        )
        let transport = GraphTransportStub { request in graphHTTPOK(data, url: request.url) }
        let source = RoadGraphSource(transport: transport.transport, cacheDirectory: directory)
        let g = try! #require(await source.load(corridor: corridor, corridorKey: "x"))

        let center = try! #require(g.nodes.first { $0.osmID == 3 })
        #expect(center.isIntersection)
        #expect(center.hasTrafficSignal)
        // 5 graph nodes; both ways are bidirectional and split at node 3 -> 8 edges.
        #expect(g.nodes.count == 5)
        #expect(g.edges.count == 8)
    }

    @Test("Two-point corridor degrades to nil with no usable input")
    func tooShortCorridor() async {
        let directory = gtempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = GraphTransportStub { request in graphHTTPOK(twoNodeWayData(), url: request.url) }
        let source = RoadGraphSource(transport: transport.transport, cacheDirectory: directory)
        let g = await source.load(corridor: [gcoord(0, 0)], corridorKey: "x")
        #expect(g == nil)
        #expect(transport.requests.isEmpty)
    }
}

// MARK: - Cache behavior

@Suite("RoadGraphSource cache", .serialized)
@MainActor
struct RoadGraphSourceCacheTests {

    private let corridor = [gcoord(0, 0), gcoord(0.001, 0)]

    @Test("Cache hit short-circuits the network")
    func cacheHitSkipsNetwork() async {
        let directory = gtempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date()
        let first = GraphTransportStub { request in graphHTTPOK(twoNodeWayData(), url: request.url) }
        let warm = RoadGraphSource(transport: first.transport, cacheDirectory: directory, now: { base })
        _ = await warm.load(corridor: corridor, corridorKey: "c")
        #expect(first.requests.count == 1)

        // Second source, 29 days later: still inside TTL, network never touched.
        let second = GraphTransportStub { _ in throw URLError(.notConnectedToInternet) }
        let cached = RoadGraphSource(
            transport: second.transport,
            cacheDirectory: directory,
            now: { base.addingTimeInterval(29 * 24 * 3600) }
        )
        let g = await cached.load(corridor: corridor, corridorKey: "c")
        #expect(second.requests.isEmpty)
        #expect(g != nil)
        #expect(g?.edges.count == 2)
    }

    @Test("Expired cache refetches after 30 days")
    func ttlExpiryRefetches() async {
        let directory = gtempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date()
        let first = GraphTransportStub { request in graphHTTPOK(twoNodeWayData(), url: request.url) }
        let warm = RoadGraphSource(transport: first.transport, cacheDirectory: directory, now: { base })
        _ = await warm.load(corridor: corridor, corridorKey: "c")
        #expect(first.requests.count == 1)

        let second = GraphTransportStub { request in graphHTTPOK(twoNodeWayData(), url: request.url) }
        let expired = RoadGraphSource(
            transport: second.transport,
            cacheDirectory: directory,
            now: { base.addingTimeInterval(31 * 24 * 3600) }
        )
        _ = await expired.load(corridor: corridor, corridorKey: "c")
        #expect(second.requests.count == 1)
    }

    @Test("Stale cache is used when all mirrors fail (graceful degradation)")
    func staleCacheOnNetworkFailure() async {
        let directory = gtempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date()
        let first = GraphTransportStub { request in graphHTTPOK(twoNodeWayData(), url: request.url) }
        let warm = RoadGraphSource(transport: first.transport, cacheDirectory: directory, now: { base })
        _ = await warm.load(corridor: corridor, corridorKey: "c")

        // 31 days later (TTL expired) AND every mirror is down: must still serve
        // the stale graph rather than returning nil.
        let down = GraphTransportStub { _ in throw URLError(.timedOut) }
        let degraded = RoadGraphSource(
            transport: down.transport,
            cacheDirectory: directory,
            now: { base.addingTimeInterval(31 * 24 * 3600) }
        )
        let g = await degraded.load(corridor: corridor, corridorKey: "c")
        #expect(down.requests.count == 3)   // all three mirrors tried
        #expect(g != nil)
        #expect(g?.edges.count == 2)
    }

    @Test("Total failure with no cache returns nil and loads nothing")
    func totalFailureNoCache() async {
        let directory = gtempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        let down = GraphTransportStub { _ in throw URLError(.timedOut) }
        let source = RoadGraphSource(transport: down.transport, cacheDirectory: directory)
        let g = await source.load(corridor: corridor, corridorKey: "c")
        #expect(down.requests.count == 3)
        #expect(g == nil)
        #expect(source.loadedCorridorKey == nil)
        #expect(source.graph == nil)
    }

    @Test("Corrupt cache file is ignored and the load falls back to the network")
    func corruptCacheFallsBack() async throws {
        let directory = gtempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = RoadGraphSource.cacheKey(for: corridor)
        // 8-byte recent timestamp header + garbage blob: inside TTL but undecodable.
        var junk = Data()
        let millis = UInt64(Date().timeIntervalSince1970 * 1000)
        for shift in stride(from: 56, through: 0, by: -8) { junk.append(UInt8((millis >> UInt64(shift)) & 0xff)) }
        junk.append(contentsOf: Array("not a graph blob".utf8))
        try junk.write(to: directory.appendingPathComponent("\(key).srg"))

        let transport = GraphTransportStub { request in graphHTTPOK(twoNodeWayData(), url: request.url) }
        let source = RoadGraphSource(transport: transport.transport, cacheDirectory: directory)
        let g = await source.load(corridor: corridor, corridorKey: "c")
        #expect(transport.requests.count == 1)
        #expect(g?.edges.count == 2)
    }
}

// MARK: - Mirror failover & headers

@Suite("RoadGraphSource network", .serialized)
@MainActor
struct RoadGraphSourceNetworkTests {

    private let corridor = [gcoord(0, 0), gcoord(0.001, 0)]

    @Test("Failed mirror rotates to the next endpoint")
    func mirrorRotation() async {
        let directory = gtempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transport = GraphTransportStub { request in
            if request.url?.host?.contains("overpass-api.de") == true { throw URLError(.timedOut) }
            return graphHTTPOK(twoNodeWayData(), url: request.url)
        }
        let source = RoadGraphSource(transport: transport.transport, cacheDirectory: directory)
        let g = await source.load(corridor: corridor, corridorKey: "c")
        #expect(transport.requests.count == 2)
        #expect(transport.requests.first?.url?.host?.contains("overpass-api.de") == true)
        #expect(transport.requests.last?.url?.host?.contains("overpass.kumi.systems") == true)
        #expect(g != nil)
    }

    @Test("429 and 5xx rotate to the next mirror", arguments: [429, 503])
    func statusRotation(status: Int) async {
        let directory = gtempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transport = GraphTransportStub { request in
            if request.url?.host?.contains("overpass-api.de") == true {
                return graphHTTP(status: status, url: request.url)
            }
            return graphHTTPOK(twoNodeWayData(), url: request.url)
        }
        let source = RoadGraphSource(transport: transport.transport, cacheDirectory: directory)
        let g = await source.load(corridor: corridor, corridorKey: "c")
        #expect(transport.requests.count == 2)
        #expect(g != nil)
    }

    @Test("Deterministic 4xx aborts without trying remaining mirrors")
    func badRequestDoesNotRotate() async {
        let directory = gtempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transport = GraphTransportStub { request in graphHTTP(status: 400, url: request.url) }
        let source = RoadGraphSource(transport: transport.transport, cacheDirectory: directory)
        let g = await source.load(corridor: corridor, corridorKey: "c")
        #expect(transport.requests.count == 1)
        #expect(g == nil)
    }

    @Test("Every request carries the identifying User-Agent")
    func userAgentOnEveryRequest() async {
        let directory = gtempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transport = GraphTransportStub { _ in throw URLError(.timedOut) }
        let source = RoadGraphSource(transport: transport.transport, cacheDirectory: directory)
        _ = await source.load(corridor: corridor, corridorKey: "c")
        #expect(transport.requests.count == 3)
        for request in transport.requests {
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "Steddi/1.0 (steddi.io)")
        }
    }

    @Test("Cancellation stops mirror rotation immediately", arguments: [true, false])
    func cancellationStops(swiftCancellation: Bool) async {
        let directory = gtempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transport = GraphTransportStub { _ in
            if swiftCancellation { throw CancellationError() }
            throw URLError(.cancelled)
        }
        let source = RoadGraphSource(transport: transport.transport, cacheDirectory: directory)
        let g = await source.load(corridor: corridor, corridorKey: "c")
        #expect(transport.requests.count == 1)
        #expect(g == nil)
    }
}
