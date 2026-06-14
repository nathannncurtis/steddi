import Testing
import Foundation
import CoreLocation
@testable import Steddi

// Hardening tests for CorridorValidator: prove the harness actually REJECTS a
// route produced by the real A* search (not just synthetic polylines), that it
// returns nil for an unroutable pair, and that each individual check can be the
// sole failure (no check masks another). Complements CorridorValidatorTests.

private func node(_ id: Int64, _ lat: Double, _ lon: Double) -> String {
    #"{"type":"node","id":\#(id),"lat":\#(lat),"lon":\#(lon)}"#
}
private func way(_ id: Int64, _ nodes: [Int64], tags: [String: String]) -> String {
    let nodeList = nodes.map(String.init).joined(separator: ",")
    let tagJSON = tags.map { #""\#($0.key)":"\#($0.value)""# }.joined(separator: ",")
    return #"{"type":"way","id":\#(id),"nodes":[\#(nodeList)],"tags":{\#(tagJSON)}}"#
}
private func buildGraph(_ elements: String...) -> RoadGraph {
    let json = #"{"version":0.6,"elements":[\#(elements.joined(separator: ","))]}"#
    let response = try! JSONDecoder().decode(OverpassGraphResponse.self, from: Data(json.utf8))
    return RoadGraphBuilder.buildGraph(from: response)
}
private func coord(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

@Suite("CorridorValidator rejects a real router's wild route")
struct CorridorValidatorHardeningTests {

    /// A graph where the ONLY path from origin to destination is a giant U-shaped
    /// detour: there is no direct edge, so A* must route far north and back. With
    /// tight corridor thresholds the validator must flag this real router output
    /// as invalid — proving the harness catches a genuine detour, not just a
    /// hand-built polyline.
    ///
    ///        2 ------------- 3        (far north, lat 34.20)
    ///        |               |
    ///        1               4        (origin lat 34.00, dest lat 34.00)
    ///   origin               destination, ~9 km due east
    private func detourOnlyGraph() -> RoadGraph {
        buildGraph(
            node(1, 34.0000, -117.0000),   // origin
            node(2, 34.2000, -117.0000),   // far NW
            node(3, 34.2000, -116.9000),   // far NE
            node(4, 34.0000, -116.9000),   // destination
            // The only connectivity is the U: 1->2->3->4 (and reverses). No direct
            // 1->4 edge exists, so the shortest path IS the wild northern detour.
            way(10, [1, 2], tags: ["highway": "primary", "maxspeed": "55 mph"]),
            way(11, [2, 3], tags: ["highway": "primary", "maxspeed": "55 mph"]),
            way(12, [3, 4], tags: ["highway": "primary", "maxspeed": "55 mph"])
        )
    }

    @Test("The real A* route over a detour-only graph is REJECTED by the validator")
    func realDetourRejected() {
        let g = detourOnlyGraph()
        let origin = coord(34.0000, -117.0000)
        let dest = coord(34.0000, -116.9000)
        // Sanity: a path exists (the detour), so this isn't a no-path nil.
        let pair = CorridorValidator.validate(from: origin, to: dest, in: g, cost: TravelTimeCost())
        #expect(pair != nil)
        guard let pair else { return }
        // The route is real and non-empty...
        #expect(!pair.searchResult.edgePath.isEmpty)
        // ...but it leaves the 8 km corridor (peaks ~22 km north) AND blows the
        // distance ratio — the harness catches the genuine detour.
        #expect(!pair.result.isValid)
        #expect(!pair.result.isWithinCorridor)
        #expect(!pair.result.failures.isEmpty)
    }

    @Test("The SAME detour passes only when thresholds are widened to admit it")
    func detourPassesWhenThresholdsWidened() {
        let g = detourOnlyGraph()
        let origin = coord(34.0000, -117.0000)
        let dest = coord(34.0000, -116.9000)
        let loose = CorridorValidator.Config(
            maxStepMeters: 100_000, corridorHalfWidthMeters: 60_000,
            maxTimeRatio: 100, maxDistanceRatio: 100, maxBackwardProgressMeters: 100_000)
        let pair = CorridorValidator.validate(from: origin, to: dest, in: g, cost: TravelTimeCost(), config: loose)
        #expect(pair != nil)
        #expect(pair?.result.isValid == true)
    }

    @Test("Unroutable endpoints (disconnected components) => nil, not a false pass")
    func unroutableReturnsNil() {
        // Two disjoint edges far apart: no path between them.
        let g = buildGraph(
            node(1, 34.0000, -117.0000),
            node(2, 34.0000, -116.9990),
            node(3, 40.0000, -100.0000),
            node(4, 40.0000, -99.9990),
            way(10, [1, 2], tags: ["highway": "primary"]),
            way(11, [3, 4], tags: ["highway": "primary"])
        )
        let pair = CorridorValidator.validate(
            from: coord(34.0000, -117.0000), to: coord(40.0000, -99.9990),
            in: g, cost: TravelTimeCost())
        #expect(pair == nil)
    }

    @Test("Time-ratio check fails in isolation (geometry otherwise clean)")
    func timeRatioIsolated() {
        // A clean straight corridor polyline, but pass an inflated explicit time.
        let origin = coord(34.0, -117.0)
        let dest = coord(34.0, -116.9)
        let coords = stride(from: 0.0, through: 1.0, by: 0.1).map { coord(34.0, -117.0 + $0 * 0.1) }
        let v = CorridorValidator.validate(
            coordinates: coords, origin: origin, destination: dest,
            timeSeconds: 100_000,   // absurdly slow for ~9 km
            graphMaxSpeedMPS: 25,
            config: .init(maxStepMeters: 20_000, corridorHalfWidthMeters: 20_000,
                          maxTimeRatio: 6, maxDistanceRatio: 100,
                          maxBackwardProgressMeters: 20_000))
        #expect(!v.isTimeSane)
        // The other checks are NOT tripped — time ratio is the sole failure.
        #expect(v.isConnected)
        #expect(v.isWithinCorridor)
        #expect(v.isMonotone)
        #expect(v.isDistanceSane)
    }

    @Test("A single-coordinate (degenerate) route is rejected as disconnected")
    func degenerateRouteRejected() {
        let v = CorridorValidator.validate(
            coordinates: [coord(34.0, -117.0)],
            origin: coord(34.0, -117.0), destination: coord(34.0, -116.9),
            timeSeconds: 0, graphMaxSpeedMPS: 25)
        #expect(!v.isValid)
        #expect(!v.isConnected)
    }
}
