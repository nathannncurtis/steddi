import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - Fixture helpers (mirror DefaultCostModelTests / AStarSearchTests)

private func node(_ id: Int64, _ lat: Double, _ lon: Double, tags: [String: String] = [:]) -> String {
    let tagJSON = tags.map { #""\#($0.key)":"\#($0.value)""# }.joined(separator: ",")
    let tagPart = tags.isEmpty ? "" : #","tags":{\#(tagJSON)}"#
    return #"{"type":"node","id":\#(id),"lat":\#(lat),"lon":\#(lon)\#(tagPart)}"#
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

// MARK: - Fixture 1: a multi-road mini-network with turns (a 3x3 grid)

/// A 3x3 lattice of secondary streets. Node ids are row*10 + col over a small
/// patch near (34.00, -117.00). All bidirectional. The optimal SW->NE route
/// involves real turns, exercising the turn-cost path.
///
///   13 - 23 - 33      (north row, lat 34.0020)
///    |    |    |
///   12 - 22 - 32      (mid row,   lat 34.0010)
///    |    |    |
///   11 - 21 - 31      (south row, lat 34.0000)
///  lon -117.0000  -116.9990  -116.9980
private func gridGraph() -> RoadGraph {
    func n(_ id: Int64, _ row: Int, _ col: Int) -> String {
        node(id, 34.0000 + Double(row) * 0.0010, -117.0000 + Double(col) * 0.0010)
    }
    let secondary = ["highway": "secondary", "maxspeed": "35 mph"]
    return buildGraph(
        n(11, 0, 0), n(21, 0, 1), n(31, 0, 2),
        n(12, 1, 0), n(22, 1, 1), n(32, 1, 2),
        n(13, 2, 0), n(23, 2, 1), n(33, 2, 2),
        // horizontal ways (one per row)
        way(100, [11, 21, 31], tags: secondary),
        way(101, [12, 22, 32], tags: secondary),
        way(102, [13, 23, 33], tags: secondary),
        // vertical ways (one per col)
        way(110, [11, 12, 13], tags: secondary),
        way(111, [21, 22, 23], tags: secondary),
        way(112, [31, 32, 33], tags: secondary)
    )
}

@Suite("CorridorValidator: grid network with turns")
struct GridValidatorTests {
    private let sw = coord(34.0000, -117.0000)  // node 11
    private let ne = coord(34.0020, -116.9980)  // node 33

    @Test("Router produces a connected, monotone, in-corridor, sane route")
    func validRoute() {
        let g = gridGraph()
        let cost = DefaultCostModel()
        let v = CorridorValidator.validate(from: sw, to: ne, in: g, cost: cost)
        #expect(v != nil)
        guard let v else { return }
        #expect(v.result.isValid)
        #expect(v.result.failures.isEmpty)
        #expect(v.result.isConnected)
        #expect(v.result.isMonotone)
        #expect(v.result.isWithinCorridor)
    }

    @Test("Router free-flow cost matches the brute-force reference shortest path")
    func matchesReference() {
        let g = gridGraph()
        // Use TravelTimeCost so the router reduces to pure shortest time, exactly
        // what referenceShortestCost computes (no turn cost in either).
        let cost = TravelTimeCost()
        let v = CorridorValidator.validate(from: sw, to: ne, in: g, cost: cost)
        let ref = CorridorValidator.referenceShortestCost(from: sw, to: ne, in: g, cost: cost)
        #expect(v != nil)
        #expect(ref != nil)
        guard let v, let ref else { return }
        // A* with an admissible heuristic finds the same optimal cost as Dijkstra.
        #expect(abs(v.searchResult.totalCost - ref) < 0.5)
    }

    @Test("Destination reachable from origin (a path exists)")
    func reachable() {
        let g = gridGraph()
        let result = AStarSearch().search(from: .coordinate(sw), to: .coordinate(ne), in: g, cost: TravelTimeCost())
        #expect(result != nil)
        #expect(!(result?.edgePath.isEmpty ?? true))
    }

    @Test("reference shortest cost matches the router on a same-edge origin/destination")
    func referenceMatchesRouterSameEdge() {
        let g = gridGraph()
        let cost = TravelTimeCost()
        // Two points mid-way along the bottom edge 11→21 (lat 34.0000, between
        // lon -117.0000 and -116.9990). Both snap onto the SAME directed edge with
        // origin behind destination, so the router takes its same-edge branch and
        // the reference must agree (not route around the grid).
        let originSE = coord(34.0000, -116.99970)   // ~30% along 11→21
        let destSE = coord(34.0000, -116.99930)     // ~70% along 11→21

        let v = CorridorValidator.validate(from: originSE, to: destSE, in: g, cost: cost)
        let ref = CorridorValidator.referenceShortestCost(from: originSE, to: destSE, in: g, cost: cost)
        #expect(v != nil)
        #expect(ref != nil)
        guard let v, let ref else { return }
        // Confirm this really exercised the same-edge degenerate branch.
        #expect(v.searchResult.edgePath.count == 1)
        // Router sub-cost and the reference must agree (both = full * Δfraction).
        #expect(abs(v.searchResult.totalCost - ref) < 0.01)
    }

    @Test("reference shortest cost mirrors the router's same-street REVERSE collapse")
    func referenceMatchesRouterSameEdgeReverse() {
        let g = gridGraph()
        let cost = TravelTimeCost()
        // Same physical street (the two-way bottom block between nodes 11 and 21)
        // but the origin is AHEAD of the destination — origin nearer node 21,
        // destination nearer node 11. The router takes its Case-2 reverse collapse
        // (a short reverse sub-segment on the co-located reverse edge, NOT a
        // block-around + U-turn). With referenceShortestCost now mirroring Case 2,
        // the reference must agree rather than returning the full overshoot cost.
        let originAhead = coord(34.0000, -116.99930)   // ~70% from node 11 toward 21
        let destBehind = coord(34.0000, -116.99970)    // ~30% from node 11 toward 21

        let v = CorridorValidator.validate(from: originAhead, to: destBehind, in: g, cost: cost)
        let ref = CorridorValidator.referenceShortestCost(from: originAhead, to: destBehind, in: g, cost: cost)
        #expect(v != nil)
        #expect(ref != nil)
        guard let v, let ref else { return }
        // The collapse keeps the whole trip on one (reverse) edge.
        #expect(v.searchResult.edgePath.count == 1)
        // Reference now matches the router's short reverse sub-segment, not the
        // full-block-around detour the old node-to-node Dijkstra would return.
        #expect(abs(v.searchResult.totalCost - ref) < 0.01)
    }
}

// MARK: - Fixture 2: a one-way couplet (parallel one-way pair)

/// A one-way pair like a downtown couplet: A-street runs EAST only, one block
/// north B-street runs WEST only, joined at both ends by two-way cross streets.
/// Travelling east must use A; travelling west must use B (you can't go the
/// wrong way down a one-way).
///
///   w(west end)            e(east end)
///        b4 <----B(west)---- b3        (north, lat 34.0010)   one-way W
///        |                    |
///        a1 ----A(east)----> a2        (south, lat 34.0000)   one-way E
///   cross-west (a1<->b4)   cross-east (a2<->b3)  two-way
private func coupletGraph() -> RoadGraph {
    buildGraph(
        node(1, 34.0000, -117.0000),   // a1  SW
        node(2, 34.0000, -116.9980),   // a2  SE
        node(3, 34.0010, -116.9980),   // b3  NE
        node(4, 34.0010, -117.0000),   // b4  NW
        // A-street: EAST one-way (node order a1 -> a2)
        way(10, [1, 2], tags: ["highway": "primary", "oneway": "yes", "maxspeed": "30 mph"]),
        // B-street: WEST one-way (node order b3 -> b4)
        way(11, [3, 4], tags: ["highway": "primary", "oneway": "yes", "maxspeed": "30 mph"]),
        // cross streets, two-way
        way(12, [2, 3], tags: ["highway": "residential"]),   // east connector
        way(13, [4, 1], tags: ["highway": "residential"])    // west connector
    )
}

@Suite("CorridorValidator: one-way couplet")
struct CoupletValidatorTests {
    // Endpoints are given as graph NODES (not coordinates) so the test isolates
    // one-way directionality without the snap ambiguity that arises when an
    // origin/destination lands exactly on a shared intersection node.
    private func nodeIndex(_ g: RoadGraph, _ osm: Int64) -> NodeIndex { g.osmToIndex[osm]! }
    private func edgeIndex(_ g: RoadGraph, from a: Int64, to b: Int64) -> EdgeIndex? {
        g.outEdgeRange(of: g.osmToIndex[a]!).first { g.edges[Int($0)].to == g.osmToIndex[b]! }
    }

    @Test("Eastbound uses the eastbound one-way directly (a single edge)")
    func eastboundDirect() {
        let g = coupletGraph()
        let result = AStarSearch().search(
            from: .node(nodeIndex(g, 1)), to: .node(nodeIndex(g, 2)),
            in: g, cost: TravelTimeCost())
        #expect(result != nil)
        guard let result else { return }
        let directEdge = edgeIndex(g, from: 1, to: 2)
        #expect(directEdge != nil)
        #expect(result.edgePath == [directEdge!])   // exactly the one eastbound edge

        // Geometry validates structurally (connected, monotone, in corridor).
        let coords = CorridorValidator.geometry(of: result, in: g)
        let v = CorridorValidator.validate(
            coordinates: coords,
            origin: g.nodes[Int(nodeIndex(g, 1))].coordinate,
            destination: g.nodes[Int(nodeIndex(g, 2))].coordinate,
            timeSeconds: result.totalCost,
            graphMaxSpeedMPS: Double(g.graphMaxSpeedMPS))
        #expect(v.isValid)
    }

    @Test("Westbound can't use the eastbound street; it routes via the couplet")
    func westboundDetoursViaCouplet() {
        let g = coupletGraph()
        // East end (node 2) back to west end (node 1). A street is EAST-only, so
        // the only legal path is 2 -> 3 -> 4 -> 1 (east connector, B street, west
        // connector).
        let result = AStarSearch().search(
            from: .node(nodeIndex(g, 2)), to: .node(nodeIndex(g, 1)),
            in: g, cost: TravelTimeCost())
        #expect(result != nil)
        guard let result else { return }
        // Must NOT traverse the eastbound A edge (1->2) — there's no reverse of it.
        if let eastEdge = edgeIndex(g, from: 1, to: 2) {
            #expect(!result.edgePath.contains(eastEdge))
        }
        // The west-running B edge (3->4) must be used.
        let westEdge = edgeIndex(g, from: 3, to: 4)!
        #expect(result.edgePath.contains(westEdge))

        let coords = CorridorValidator.geometry(of: result, in: g)
        let v = CorridorValidator.validate(
            coordinates: coords,
            origin: g.nodes[Int(nodeIndex(g, 2))].coordinate,
            destination: g.nodes[Int(nodeIndex(g, 1))].coordinate,
            timeSeconds: result.totalCost,
            graphMaxSpeedMPS: Double(g.graphMaxSpeedMPS))
        #expect(v.isConnected)
        #expect(v.isWithinCorridor)
    }

    @Test("No reverse edge exists on a one-way street")
    func onewayHasNoReverse() {
        let g = coupletGraph()
        // node 2 -> node 1 (reverse of the east-only A street) must not exist.
        #expect(edgeIndex(g, from: 2, to: 1) == nil)
    }
}

// MARK: - Fixture 3: a divided road (dual carriageway)

/// A divided arterial modeled as two separate one-way carriageways a few metres
/// apart, joined by cross streets at each end (the only legal U-turn points). The
/// NB carriageway runs north; the SB runs south. A trip up the corridor uses NB;
/// a trip back down uses SB.
///
///   nbN(34.0030)   sbN(34.0030)
///      ^               |
///      | NB            | SB
///   nbS(34.0000)   sbS(34.0000)
///   joined at both ends by short two-way cross links.
private func dividedRoadGraph() -> RoadGraph {
    buildGraph(
        node(1, 34.0000, -117.00000),  // nbS  (NB south end)
        node(2, 34.0030, -117.00000),  // nbN  (NB north end)
        node(3, 34.0030, -116.99990),  // sbN  (SB north end)
        node(4, 34.0000, -116.99990),  // sbS  (SB south end)
        // NB carriageway: north one-way (1 -> 2)
        way(10, [1, 2], tags: ["highway": "primary", "oneway": "yes", "lanes": "2", "maxspeed": "45 mph"]),
        // SB carriageway: south one-way (3 -> 4)
        way(11, [3, 4], tags: ["highway": "primary", "oneway": "yes", "lanes": "2", "maxspeed": "45 mph"]),
        // cross links at each end, two-way (the median breaks)
        way(12, [2, 3], tags: ["highway": "secondary"]),   // north crossover
        way(13, [4, 1], tags: ["highway": "secondary"])    // south crossover
    )
}

@Suite("CorridorValidator: divided road")
struct DividedRoadValidatorTests {
    private func nodeIndex(_ g: RoadGraph, _ osm: Int64) -> NodeIndex { g.osmToIndex[osm]! }

    @Test("Northbound trip uses the NB carriageway and validates")
    func northboundUsesNB() {
        let g = dividedRoadGraph()
        let result = AStarSearch().search(
            from: .node(nodeIndex(g, 1)), to: .node(nodeIndex(g, 2)),
            in: g, cost: TravelTimeCost())
        #expect(result != nil)
        guard let result else { return }
        let nbEdge = g.outEdgeRange(of: nodeIndex(g, 1)).first { g.edges[Int($0)].to == nodeIndex(g, 2) }!
        #expect(result.edgePath == [nbEdge])

        let coords = CorridorValidator.geometry(of: result, in: g)
        let v = CorridorValidator.validate(
            coordinates: coords,
            origin: g.nodes[Int(nodeIndex(g, 1))].coordinate,
            destination: g.nodes[Int(nodeIndex(g, 2))].coordinate,
            timeSeconds: result.totalCost,
            graphMaxSpeedMPS: Double(g.graphMaxSpeedMPS))
        #expect(v.isValid)
    }

    @Test("No reverse edge on a carriageway: you can't drive the NB lane south")
    func noWrongWayDrive() {
        let g = dividedRoadGraph()
        // The NB carriageway is one-way (1->2); 2->1 must not exist. A southbound
        // trip from node 2 to node 1 must use the SB carriageway via the north
        // crossover (2 -> 3 -> 4 -> 1).
        let nbReverse = g.outEdgeRange(of: nodeIndex(g, 2)).first { g.edges[Int($0)].to == nodeIndex(g, 1) }
        #expect(nbReverse == nil)
        let result = AStarSearch().search(
            from: .node(nodeIndex(g, 2)), to: .node(nodeIndex(g, 1)),
            in: g, cost: TravelTimeCost())
        #expect(result != nil)
        guard let result else { return }
        let sbEdge = g.outEdgeRange(of: nodeIndex(g, 3)).first { g.edges[Int($0)].to == nodeIndex(g, 4) }!
        #expect(result.edgePath.contains(sbEdge))
    }
}

// MARK: - Regression guard: the validator REJECTS a wild detour

@Suite("CorridorValidator: detects bad routes (the regression net)")
struct DetourRejectionTests {
    private let origin = coord(34.0000, -117.0000)
    private let destination = coord(34.0000, -116.9000)   // ~9.2 km due east

    @Test("A straight route on-corridor passes every check")
    func straightPasses() {
        // Synthesize a clean straight polyline along the corridor.
        let coords = stride(from: 0.0, through: 1.0, by: 0.1).map { t in
            coord(34.0000, -117.0000 + t * 0.1)
        }
        let v = CorridorValidator.validate(
            coordinates: coords, origin: origin, destination: destination,
            timeSeconds: nil, graphMaxSpeedMPS: 25
        )
        #expect(v.isValid)
    }

    @Test("A route that leaves the corridor fails the corridor check")
    func leavesCorridorFails() {
        // Detours far north (well beyond the 8 km half-width) then back.
        let coords = [
            origin,
            coord(34.2000, -116.9500),   // ~22 km north of the centerline
            destination
        ]
        let v = CorridorValidator.validate(
            coordinates: coords, origin: origin, destination: destination,
            timeSeconds: nil, graphMaxSpeedMPS: 25
        )
        #expect(!v.isValid)
        #expect(!v.isWithinCorridor)
    }

    @Test("A grossly long route fails the distance ratio check")
    func grossDetourFailsDistance() {
        // A zig-zag whose total length far exceeds the crow-flight, but stays
        // (barely) within the corridor half-width to isolate the distance check.
        var coords: [CLLocationCoordinate2D] = []
        for i in 0...40 {
            let t = Double(i) / 40.0
            // Saw-tooth in latitude (+/- ~5.5 km) along the east progression.
            let wobble = (i % 2 == 0) ? 0.05 : -0.05
            coords.append(coord(34.0000 + wobble, -117.0000 + t * 0.1))
        }
        coords.append(destination)
        let v = CorridorValidator.validate(
            coordinates: coords, origin: origin, destination: destination,
            timeSeconds: nil, graphMaxSpeedMPS: 25,
            config: .init(corridorHalfWidthMeters: 8000, maxTimeRatio: 100, maxDistanceRatio: 4)
        )
        #expect(!v.isDistanceSane)
    }

    @Test("A route that wanders backward fails the monotone check")
    func backwardWanderFails() {
        let coords = [
            origin,
            coord(34.0000, -116.9500),       // halfway east (good progress)
            coord(34.0000, -117.0300),       // back WEST past the origin (wander)
            destination
        ]
        let v = CorridorValidator.validate(
            coordinates: coords, origin: origin, destination: destination,
            timeSeconds: nil, graphMaxSpeedMPS: 25,
            config: .init(maxStepMeters: 20000, corridorHalfWidthMeters: 20000,
                          maxTimeRatio: 100, maxDistanceRatio: 100,
                          maxBackwardProgressMeters: 4000)
        )
        #expect(!v.isMonotone)
    }

    @Test("A disconnected (teleporting) route fails the connectivity check")
    func teleportFails() {
        let coords = [
            origin,
            coord(34.0000, -116.9950),       // small step
            coord(34.0000, -116.9000)        // a ~7.7 km jump (teleport)
        ]
        let v = CorridorValidator.validate(
            coordinates: coords, origin: origin, destination: destination,
            timeSeconds: nil, graphMaxSpeedMPS: 25,
            config: .init(maxStepMeters: 3000, corridorHalfWidthMeters: 20000,
                          maxTimeRatio: 100, maxDistanceRatio: 100,
                          maxBackwardProgressMeters: 20000)
        )
        #expect(!v.isConnected)
    }
}
