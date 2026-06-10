import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - Shared Helpers

/// Records requests and serves canned responses. Keeps tests fully network-free.
private final class TransportStub: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: @Sendable (URLRequest) throws -> (Data, URLResponse)

    init(handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    var transport: OSMSpeedLimitService.Transport {
        { request in
            self.lock.withLock { self.recorded.append(request) }
            return try self.handler(request)
        }
    }
}

private func httpOK(_ data: Data, url: URL?) -> (Data, URLResponse) {
    let response = HTTPURLResponse(
        url: url ?? URL(fileURLWithPath: "/"),
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )
    return (data, response ?? URLResponse())
}

private func wayJSON(id: Int, highway: String, maxspeed: String?, coords: [(Double, Double)]) -> String {
    var tags = #""highway":"\#(highway)""#
    if let maxspeed {
        tags += #","maxspeed":"\#(maxspeed)""#
    }
    let geometry = coords.map { #"{"lat":\#($0.0),"lon":\#($0.1)}"# }.joined(separator: ",")
    return #"{"type":"way","id":\#(id),"tags":{\#(tags)},"geometry":[\#(geometry)]}"#
}

private func overpassData(_ elements: String...) -> Data {
    Data(#"{"version":0.6,"elements":[\#(elements.joined(separator: ","))]}"#.utf8)
}

private func tempCacheDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("OSMSpeedLimitTests-\(UUID().uuidString)", isDirectory: true)
}

private func coord(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

private func makeWay(id: Int, mph: Double, estimated: Bool = false, coords: [(Double, Double)]) -> SpeedLimitWay {
    SpeedLimitWay(
        wayID: id,
        limitMph: mph,
        isEstimated: estimated,
        geometry: coords.map { SpeedLimitPoint(lat: $0.0, lon: $0.1) }
    )
}

@MainActor
private func makeOfflineService(cacheDirectory: URL? = nil) -> OSMSpeedLimitService {
    OSMSpeedLimitService(
        transport: { _ in throw URLError(.notConnectedToInternet) },
        cacheDirectory: cacheDirectory ?? tempCacheDirectory()
    )
}

// MARK: - Maxspeed Parsing

@Suite("OSMSpeedLimitService.parseMaxspeed")
struct OSMSpeedLimitParseMaxspeedTests {

    @Test("mph value parses directly")
    func mphValue() {
        #expect(OSMSpeedLimitService.parseMaxspeed("35 mph") == 35)
    }

    @Test("mph without space parses")
    func mphNoSpace() {
        #expect(OSMSpeedLimitService.parseMaxspeed("65mph") == 65)
    }

    @Test("Uppercase MPH parses")
    func mphUppercase() {
        #expect(OSMSpeedLimitService.parseMaxspeed("25 MPH") == 25)
    }

    @Test("Bare number is km/h converted to mph")
    func bareNumberIsKmh() throws {
        let result = try #require(OSMSpeedLimitService.parseMaxspeed("50"))
        #expect(abs(result - 31.06855) < 0.001)
    }

    @Test("Explicit km/h suffix converts to mph")
    func explicitKmh() throws {
        let result = try #require(OSMSpeedLimitService.parseMaxspeed("30 km/h"))
        #expect(abs(result - 18.64113) < 0.001)
    }

    @Test("none returns nil")
    func noneValue() {
        #expect(OSMSpeedLimitService.parseMaxspeed("none") == nil)
    }

    @Test("signals returns nil")
    func signalsValue() {
        #expect(OSMSpeedLimitService.parseMaxspeed("signals") == nil)
    }

    @Test("walk returns nil")
    func walkValue() {
        #expect(OSMSpeedLimitService.parseMaxspeed("walk") == nil)
    }

    @Test("Garbage returns nil")
    func garbageValue() {
        #expect(OSMSpeedLimitService.parseMaxspeed("fast") == nil)
    }

    @Test("Empty string returns nil")
    func emptyValue() {
        #expect(OSMSpeedLimitService.parseMaxspeed("") == nil)
    }

    @Test("nil returns nil")
    func nilValue() {
        #expect(OSMSpeedLimitService.parseMaxspeed(nil) == nil)
    }

    @Test("Zero returns nil")
    func zeroValue() {
        #expect(OSMSpeedLimitService.parseMaxspeed("0") == nil)
    }

    @Test("Negative returns nil")
    func negativeValue() {
        #expect(OSMSpeedLimitService.parseMaxspeed("-10") == nil)
    }

    @Test("Surrounding whitespace is trimmed")
    func whitespacePadded() {
        #expect(OSMSpeedLimitService.parseMaxspeed("  35 mph  ") == 35)
    }

    @Test("Uppercase KM/H suffix converts")
    func uppercaseKmh() throws {
        let result = try #require(OSMSpeedLimitService.parseMaxspeed("30 KM/H"))
        #expect(abs(result - 18.64113) < 0.001)
    }

    @Test("Decimal bare value converts as km/h")
    func decimalKmh() throws {
        let result = try #require(OSMSpeedLimitService.parseMaxspeed("32.5"))
        #expect(abs(result - 32.5 * 0.621371) < 0.001)
    }

    @Test("Multi-value tag returns nil (falls back to class default)")
    func multiValueTag() {
        #expect(OSMSpeedLimitService.parseMaxspeed("30 mph;45 mph") == nil)
    }

    @Test("Knots unit returns nil")
    func knotsUnit() {
        #expect(OSMSpeedLimitService.parseMaxspeed("10 knots") == nil)
    }

    @Test("variable returns nil")
    func variableValue() {
        #expect(OSMSpeedLimitService.parseMaxspeed("variable") == nil)
    }
}

// MARK: - Highway Class Defaults

@Suite("OSMSpeedLimitService.defaultSpeedMph")
struct OSMSpeedLimitClassDefaultTests {

    @Test("Highway class defaults", arguments: [
        ("motorway", 65.0),
        ("trunk", 55.0),
        ("primary", 45.0),
        ("secondary", 40.0),
        ("tertiary", 35.0),
        ("unclassified", 35.0),
        ("residential", 25.0),
        ("motorway_link", 35.0),
        ("trunk_link", 35.0),
        ("primary_link", 35.0),
        ("secondary_link", 35.0),
        ("tertiary_link", 35.0),
    ])
    func classDefault(highway: String, expected: Double) {
        #expect(OSMSpeedLimitService.defaultSpeedMph(forHighwayClass: highway) == expected)
    }

    @Test("Unknown class returns nil")
    func unknownClass() {
        #expect(OSMSpeedLimitService.defaultSpeedMph(forHighwayClass: "footway") == nil)
        #expect(OSMSpeedLimitService.defaultSpeedMph(forHighwayClass: "cycleway") == nil)
    }
}

// MARK: - Overpass Response Parsing

@Suite("OSMSpeedLimitService.parseOverpassResponse")
struct OSMSpeedLimitResponseParsingTests {

    @Test("Tagged maxspeed way is not estimated")
    func taggedWay() throws {
        let data = overpassData(wayJSON(id: 7, highway: "residential", maxspeed: "25 mph", coords: [(0, 0), (0.001, 0)]))
        let ways = try OSMSpeedLimitService.parseOverpassResponse(data)
        #expect(ways.count == 1)
        #expect(ways.first?.wayID == 7)
        #expect(ways.first?.limitMph == 25)
        #expect(ways.first?.isEstimated == false)
    }

    @Test("Missing maxspeed falls back to class default, marked estimated")
    func missingMaxspeed() throws {
        let data = overpassData(wayJSON(id: 8, highway: "motorway", maxspeed: nil, coords: [(0, 0), (0.001, 0)]))
        let ways = try OSMSpeedLimitService.parseOverpassResponse(data)
        #expect(ways.first?.limitMph == 65)
        #expect(ways.first?.isEstimated == true)
    }

    @Test("Unparseable maxspeed falls back to class default, marked estimated")
    func unparseableMaxspeed() throws {
        let data = overpassData(wayJSON(id: 9, highway: "trunk", maxspeed: "none", coords: [(0, 0), (0.001, 0)]))
        let ways = try OSMSpeedLimitService.parseOverpassResponse(data)
        #expect(ways.first?.limitMph == 55)
        #expect(ways.first?.isEstimated == true)
    }

    @Test("Way with single geometry point is skipped")
    func singlePointGeometry() throws {
        let data = overpassData(wayJSON(id: 10, highway: "primary", maxspeed: "45 mph", coords: [(0, 0)]))
        let ways = try OSMSpeedLimitService.parseOverpassResponse(data)
        #expect(ways.isEmpty)
    }

    @Test("Unknown class without maxspeed is skipped")
    func unknownClassSkipped() throws {
        let data = overpassData(wayJSON(id: 11, highway: "service", maxspeed: nil, coords: [(0, 0), (0.001, 0)]))
        let ways = try OSMSpeedLimitService.parseOverpassResponse(data)
        #expect(ways.isEmpty)
    }

    @Test("Malformed JSON throws")
    func malformedJSON() {
        #expect(throws: (any Error).self) {
            try OSMSpeedLimitService.parseOverpassResponse(Data("not json".utf8))
        }
    }
}

// MARK: - Downsampling & Query Building

@Suite("OSMSpeedLimitService downsampling and query")
struct OSMSpeedLimitDownsampleTests {

    @Test("Collinear points collapse to endpoints")
    func collinearCollapses() {
        let line = (0..<100).map { coord(Double($0) * 0.0001, 0) }
        let result = OSMSpeedLimitService.downsample(line, tolerance: 25, maxPoints: 250)
        #expect(result.count == 2)
        #expect(result.first?.latitude == 0)
        #expect(result.last?.latitude == line.last?.latitude)
    }

    @Test("Zigzag polyline is capped at maxPoints with endpoints preserved")
    func capAtMaxPoints() {
        // 66m lateral swings survive a 25m RDP tolerance, forcing the cap.
        let zigzag = (0..<1000).map { coord(Double($0) * 0.0001, $0 % 2 == 0 ? 0 : 0.0006) }
        let result = OSMSpeedLimitService.downsample(zigzag, tolerance: 25, maxPoints: 250)
        #expect(result.count <= 250)
        #expect(result.count > 2)
        #expect(result.first?.latitude == zigzag.first?.latitude)
        #expect(result.last?.latitude == zigzag.last?.latitude)
    }

    @Test("Two points pass through unchanged")
    func twoPointsUnchanged() {
        let pair = [coord(0, 0), coord(0.001, 0.001)]
        let result = OSMSpeedLimitService.downsample(pair, tolerance: 25, maxPoints: 250)
        #expect(result.count == 2)
    }

    @Test("Query has one around clause for small polylines")
    func singleAroundClause() {
        let query = OSMSpeedLimitService.overpassQuery(for: [coord(33.1, -117.2), coord(33.2, -117.3)])
        #expect(query.hasPrefix("[out:json][timeout:25];"))
        #expect(query.hasSuffix("out tags geom;"))
        #expect(query.components(separatedBy: "way(around:25,").count - 1 == 1)
        #expect(query.contains("33.100000,-117.200000,33.200000,-117.300000"))
        #expect(query.contains(#"["highway"~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link)$"]"#))
    }

    @Test("Query splits into multiple around clauses beyond 250 points")
    func multipleAroundClauses() {
        let points = (0..<260).map { coord(Double($0) * 0.0001, 0) }
        let query = OSMSpeedLimitService.overpassQuery(for: points)
        #expect(query.components(separatedBy: "way(around:25,").count - 1 == 2)
    }

    @Test("Cache key is deterministic and polyline-sensitive")
    func cacheKeyBehavior() {
        let a = [coord(0, 0), coord(0.001, 0)]
        let b = [coord(0, 0), coord(0.002, 0)]
        #expect(OSMSpeedLimitService.cacheKey(for: a) == OSMSpeedLimitService.cacheKey(for: a))
        #expect(OSMSpeedLimitService.cacheKey(for: a) != OSMSpeedLimitService.cacheKey(for: b))
        #expect(OSMSpeedLimitService.cacheKey(for: a).count == 64)
    }
}

// MARK: - Cache Round-Trip & TTL

@Suite("OSMSpeedLimitService cache", .serialized)
@MainActor
struct OSMSpeedLimitCacheTests {

    private let polyline = [coord(0, 0), coord(0.001, 0)]
    private let onRoad = coord(0.0005, 0)

    private func stub(mph: String) -> TransportStub {
        TransportStub { request in
            httpOK(overpassData(wayJSON(id: 1, highway: "residential", maxspeed: mph, coords: [(0, 0), (0.001, 0)])), url: request.url)
        }
    }

    @Test("Prefetch fetches once and serves lookups")
    func prefetchFetches() async {
        let directory = tempCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transport = stub(mph: "25 mph")
        let service = OSMSpeedLimitService(transport: transport.transport, cacheDirectory: directory)
        await service.prefetch(for: polyline, routeKey: "route-1")

        #expect(transport.requests.count == 1)
        #expect(service.loadedRouteKey == "route-1")
        #expect(transport.requests.first?.httpMethod == "POST")
        #expect(transport.requests.first?.httpBody?.starts(with: Data("data=".utf8)) == true)

        let result = service.speedLimit(at: onRoad, heading: nil)
        #expect(result?.mph == 25)
        #expect(result?.isEstimated == false)
    }

    @Test("Cache hit short-circuits the network")
    func cacheHitSkipsNetwork() async {
        let directory = tempCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date()
        let first = stub(mph: "25 mph")
        let warm = OSMSpeedLimitService(transport: first.transport, cacheDirectory: directory, now: { base })
        await warm.prefetch(for: polyline, routeKey: "route-1")
        #expect(first.requests.count == 1)

        // Second service, 29 days later: still inside TTL, network never touched.
        let second = stub(mph: "99 mph")
        let cached = OSMSpeedLimitService(
            transport: second.transport,
            cacheDirectory: directory,
            now: { base.addingTimeInterval(29 * 24 * 3600) }
        )
        await cached.prefetch(for: polyline, routeKey: "route-1")

        #expect(second.requests.isEmpty)
        #expect(cached.speedLimit(at: onRoad, heading: nil)?.mph == 25)
    }

    @Test("Expired cache refetches after 30 days")
    func ttlExpiryRefetches() async {
        let directory = tempCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date()
        let first = stub(mph: "25 mph")
        let warm = OSMSpeedLimitService(transport: first.transport, cacheDirectory: directory, now: { base })
        await warm.prefetch(for: polyline, routeKey: "route-1")
        #expect(first.requests.count == 1)

        let second = stub(mph: "35 mph")
        let expired = OSMSpeedLimitService(
            transport: second.transport,
            cacheDirectory: directory,
            now: { base.addingTimeInterval(31 * 24 * 3600) }
        )
        await expired.prefetch(for: polyline, routeKey: "route-1")

        #expect(second.requests.count == 1)
        #expect(expired.speedLimit(at: onRoad, heading: nil)?.mph == 35)
    }

    @Test("Failed mirror rotates to the next endpoint")
    func mirrorRotation() async {
        let directory = tempCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transport = TransportStub { request in
            if request.url?.host?.contains("overpass-api.de") == true {
                throw URLError(.timedOut)
            }
            return httpOK(overpassData(wayJSON(id: 1, highway: "residential", maxspeed: "25 mph", coords: [(0, 0), (0.001, 0)])), url: request.url)
        }
        let service = OSMSpeedLimitService(transport: transport.transport, cacheDirectory: directory)
        await service.prefetch(for: polyline, routeKey: "route-1")

        #expect(transport.requests.count == 2)
        #expect(transport.requests.first?.url?.host?.contains("overpass-api.de") == true)
        #expect(transport.requests.last?.url?.host?.contains("overpass.kumi.systems") == true)
        #expect(service.speedLimit(at: onRoad, heading: nil)?.mph == 25)
    }

    @Test("All mirrors failing leaves no data and no cache")
    func allMirrorsFail() async {
        let directory = tempCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transport = TransportStub { _ in throw URLError(.timedOut) }
        let service = OSMSpeedLimitService(transport: transport.transport, cacheDirectory: directory)
        await service.prefetch(for: polyline, routeKey: "route-1")

        #expect(transport.requests.count == 3)
        #expect(service.loadedRouteKey == nil)
        #expect(service.speedLimit(at: onRoad, heading: nil) == nil)
    }
}

// MARK: - Spatial Lookup

@Suite("OSMSpeedLimitService.speedLimit lookup")
@MainActor
struct OSMSpeedLimitLookupTests {

    // Equator geometry: 0.0001 deg of longitude is roughly 11.1m.

    @Test("No ways loaded returns nil")
    func emptyIndex() {
        let service = makeOfflineService()
        #expect(service.speedLimit(at: coord(0, 0), heading: nil) == nil)
    }

    @Test("Nearest way wins")
    func nearestWayWins() {
        let service = makeOfflineService()
        service.loadWays([
            makeWay(id: 1, mph: 25, coords: [(0, 0), (0.001, 0)]),
            makeWay(id: 2, mph: 45, coords: [(0, 0.0002), (0.001, 0.0002)]),
        ], routeKey: "r")

        // 5.5m from way 1, 16.7m from way 2.
        let result = service.speedLimit(at: coord(0.0005, 0.00005), heading: nil)
        #expect(result?.mph == 25)
    }

    @Test("Returns estimated flag from the matched way")
    func estimatedFlagPropagates() {
        let service = makeOfflineService()
        service.loadWays([makeWay(id: 1, mph: 35, estimated: true, coords: [(0, 0), (0.001, 0)])], routeKey: "r")

        let result = service.speedLimit(at: coord(0.0005, 0), heading: nil)
        #expect(result?.mph == 35)
        #expect(result?.isEstimated == true)
    }

    @Test("No match beyond 30 meters")
    func thirtyMeterGate() {
        let service = makeOfflineService()
        service.loadWays([makeWay(id: 1, mph: 25, coords: [(0, 0), (0.001, 0)])], routeKey: "r")

        // ~22m: inside the gate.
        #expect(service.speedLimit(at: coord(0.0005, 0.0002), heading: nil) != nil)
        // ~55m: outside the gate.
        #expect(service.speedLimit(at: coord(0.0005, 0.0005), heading: nil) == nil)
    }

    @Test("Heading disambiguates crossing ways")
    func headingDisambiguation() {
        let service = makeOfflineService()
        service.loadWays([
            makeWay(id: 1, mph: 25, coords: [(0, 0.0005), (0.001, 0.0005)]),   // north-south
            makeWay(id: 2, mph: 50, coords: [(0.0005, 0), (0.0005, 0.001)]),   // east-west
        ], routeKey: "r")
        let intersection = coord(0.0005, 0.0005)

        #expect(service.speedLimit(at: intersection, heading: 0)?.mph == 25)
        #expect(service.speedLimit(at: intersection, heading: 90)?.mph == 50)
        // Reverse direction of travel still matches the east-west way (mod 180).
        #expect(service.speedLimit(at: intersection, heading: 270)?.mph == 50)
    }

    @Test("Heading more than 50 degrees off discards the only candidate")
    func headingFiltersOut() {
        let service = makeOfflineService()
        service.loadWays([makeWay(id: 1, mph: 25, coords: [(0, 0), (0.001, 0)])], routeKey: "r")

        // Way runs north-south; traveling due east should not match it.
        #expect(service.speedLimit(at: coord(0.0005, 0), heading: 90) == nil)
        // Within tolerance keeps the match.
        #expect(service.speedLimit(at: coord(0.0005, 0), heading: 40) != nil)
    }

    @Test("Hysteresis sticks with last way until challenger wins 3 lookups")
    func hysteresisSwitchesAfterThree() {
        let service = makeOfflineService()
        service.loadWays([
            makeWay(id: 1, mph: 25, coords: [(0, 0), (0.001, 0)]),
            makeWay(id: 2, mph: 45, coords: [(0, 0.0002), (0.001, 0.0002)]),
        ], routeKey: "r")

        let nearWayOne = coord(0.0005, 0.00005)  // 5.5m vs 16.7m
        let nearWayTwo = coord(0.0005, 0.00015)  // 16.7m vs 5.5m

        #expect(service.speedLimit(at: nearWayOne, heading: nil)?.mph == 25)
        #expect(service.speedLimit(at: nearWayTwo, heading: nil)?.mph == 25) // challenger lookup 1
        #expect(service.speedLimit(at: nearWayTwo, heading: nil)?.mph == 25) // challenger lookup 2
        #expect(service.speedLimit(at: nearWayTwo, heading: nil)?.mph == 45) // switches on 3
        #expect(service.speedLimit(at: nearWayTwo, heading: nil)?.mph == 45) // stays switched
    }

    @Test("Challenger within 5m margin never triggers a switch")
    func hysteresisIgnoresSmallMargin() {
        let service = makeOfflineService()
        service.loadWays([
            makeWay(id: 1, mph: 25, coords: [(0, 0), (0.001, 0)]),
            makeWay(id: 2, mph: 45, coords: [(0, 0.0002), (0.001, 0.0002)]),
        ], routeKey: "r")

        // Lock onto way 1 first.
        #expect(service.speedLimit(at: coord(0.0005, 0.00005), heading: nil)?.mph == 25)

        // Way 2 is closer here, but only by ~3m — under the 5m hysteresis margin.
        let slightlyCloserToTwo = coord(0.0005, 0.0001135)
        for _ in 0..<5 {
            #expect(service.speedLimit(at: slightlyCloserToTwo, heading: nil)?.mph == 25)
        }
    }

    @Test("Hysteresis resets when last way drops out of range")
    func hysteresisResetsWhenLastWayGone() {
        let service = makeOfflineService()
        service.loadWays([
            makeWay(id: 1, mph: 25, coords: [(0, 0), (0.001, 0)]),
            makeWay(id: 2, mph: 45, coords: [(0, 0.0005), (0.001, 0.0005)]),
        ], routeKey: "r")

        // Lock onto way 1, then jump next to way 2 (way 1 now ~44m away, out of range).
        #expect(service.speedLimit(at: coord(0.0005, 0.00005), heading: nil)?.mph == 25)
        #expect(service.speedLimit(at: coord(0.0005, 0.00045), heading: nil)?.mph == 45)
    }

    @Test("Bearing delta folds across 180 degrees")
    func bearingDeltaFolds() {
        #expect(OSMSpeedLimitService.bearingDelta(0, 180) == 0)
        #expect(OSMSpeedLimitService.bearingDelta(0, 170) == 10)
        #expect(OSMSpeedLimitService.bearingDelta(350, 10) == 20)
        #expect(OSMSpeedLimitService.bearingDelta(90, 0) == 90)
    }

    // MARK: Equidistant ties

    @Test("Equidistant point keeps the previously locked way")
    func equidistantKeepsLockedWay() {
        let service = makeOfflineService()
        service.loadWays([
            makeWay(id: 1, mph: 25, coords: [(0, 0), (0.001, 0)]),
            makeWay(id: 2, mph: 45, coords: [(0, 0.0002), (0.001, 0.0002)]),
        ], routeKey: "r")

        // Lock onto way 1, then sit exactly midway between the two parallel ways.
        // The challenger is never 5m closer, so hysteresis must hold way 1 forever.
        #expect(service.speedLimit(at: coord(0.0005, 0.00005), heading: nil)?.mph == 25)
        let midpoint = coord(0.0005, 0.0001)
        for _ in 0..<10 {
            #expect(service.speedLimit(at: midpoint, heading: nil)?.mph == 25)
        }
    }

    @Test("Cold equidistant lookup returns a way and stays consistent")
    func equidistantColdLookupIsStable() throws {
        let service = makeOfflineService()
        service.loadWays([
            makeWay(id: 1, mph: 25, coords: [(0, 0), (0.001, 0)]),
            makeWay(id: 2, mph: 45, coords: [(0, 0.0002), (0.001, 0.0002)]),
        ], routeKey: "r")

        // First-ever lookup exactly midway: either way is acceptable, but the
        // choice must be locked in and never flap on repeated identical lookups.
        let midpoint = coord(0.0005, 0.0001)
        let first = try #require(service.speedLimit(at: midpoint, heading: nil))
        #expect(first.mph == 25 || first.mph == 45)
        for _ in 0..<10 {
            #expect(service.speedLimit(at: midpoint, heading: nil)?.mph == first.mph)
        }
    }

    // MARK: Heading boundary at 50 degrees

    @Test("Heading delta exactly 50 degrees still matches; just over is filtered")
    func headingBoundaryExact() {
        let service = makeOfflineService()
        // Due-north way along lon 0 at the equator: segment bearing is exactly 0.
        service.loadWays([makeWay(id: 1, mph: 25, coords: [(0, 0), (0.001, 0)])], routeKey: "r")
        let onRoad = coord(0.0005, 0)

        #expect(service.speedLimit(at: onRoad, heading: 50)?.mph == 25)
        #expect(service.speedLimit(at: onRoad, heading: 51) == nil)
    }

    @Test("Heading boundary holds across the 180-degree fold")
    func headingBoundaryFolded() {
        let service = makeOfflineService()
        service.loadWays([makeWay(id: 1, mph: 25, coords: [(0, 0), (0.001, 0)])], routeKey: "r")
        let onRoad = coord(0.0005, 0)

        // Folded delta: |0 - 130| -> 130 -> 180 - 130 = 50 (match); 129 -> 51 (filtered).
        #expect(service.speedLimit(at: onRoad, heading: 130)?.mph == 25)
        #expect(service.speedLimit(at: onRoad, heading: 129) == nil)
        // Southbound equivalents of the direct case.
        #expect(service.speedLimit(at: onRoad, heading: 230)?.mph == 25)
        #expect(service.speedLimit(at: onRoad, heading: 231) == nil)
    }

    // MARK: Grid cell boundaries

    @Test("Query point in the neighboring cell still finds the way")
    func cellBoundaryNeighborLookup() {
        let service = makeOfflineService()
        // East-west way near the top of lat cell 0 (cell size 0.001 deg).
        service.loadWays([makeWay(id: 1, mph: 25, coords: [(0.00095, 0), (0.00095, 0.001)])], routeKey: "r")

        // Query from lat cell 1, ~11m above the way.
        #expect(service.speedLimit(at: coord(0.00105, 0.0005), heading: nil)?.mph == 25)
        // And from inside the same cell, just below the boundary.
        #expect(service.speedLimit(at: coord(0.00099, 0.0005), heading: nil)?.mph == 25)
    }

    @Test("Segment spanning two cells is reachable from both")
    func segmentSpansCells() {
        let service = makeOfflineService()
        // Single segment crossing the lat 0.001 cell boundary.
        service.loadWays([makeWay(id: 1, mph: 40, coords: [(0.0005, 0), (0.0015, 0)])], routeKey: "r")

        #expect(service.speedLimit(at: coord(0.0007, 0.0001), heading: nil)?.mph == 40)  // cell 0 side
        #expect(service.speedLimit(at: coord(0.0013, 0.0001), heading: nil)?.mph == 40)  // cell 1 side
        #expect(service.speedLimit(at: coord(0.0010, 0.0001), heading: nil)?.mph == 40)  // on the boundary
    }

    @Test("Negative coordinates straddling the zero cell boundary match")
    func negativeCoordinateCellBoundary() {
        let service = makeOfflineService()
        // Way just south of the equator; query just north. floor()-based cell
        // indexing must put these in adjacent cells (-1 and 0), not the same cell.
        service.loadWays([makeWay(id: 1, mph: 30, coords: [(-0.00005, 0), (-0.00005, 0.001)])], routeKey: "r")

        #expect(service.speedLimit(at: coord(0.00005, 0.0005), heading: nil)?.mph == 30)
        #expect(service.speedLimit(at: coord(-0.00015, 0.0005), heading: nil)?.mph == 30)
    }

    @Test("Way two cells away but outside 30m is not matched")
    func farCellNoMatch() {
        let service = makeOfflineService()
        service.loadWays([makeWay(id: 1, mph: 25, coords: [(0.0001, 0), (0.0001, 0.001)])], routeKey: "r")

        // ~211m north: out of grid neighborhood and out of the 30m gate.
        #expect(service.speedLimit(at: coord(0.002, 0.0005), heading: nil) == nil)
    }
}
