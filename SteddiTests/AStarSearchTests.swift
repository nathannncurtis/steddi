import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - Fixture helpers

/// Build an Overpass node element JSON (id + lat/lon + optional tags).
private func node(_ id: Int64, _ lat: Double, _ lon: Double, tags: [String: String] = [:]) -> String {
    let tagJSON = tags.map { #""\#($0.key)":"\#($0.value)""# }.joined(separator: ",")
    let tagPart = tags.isEmpty ? "" : #","tags":{\#(tagJSON)}"#
    return #"{"type":"node","id":\#(id),"lat":\#(lat),"lon":\#(lon)\#(tagPart)}"#
}

/// Build an Overpass way element JSON (id + ordered node ids + tags).
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

// MARK: - Brute-force reference

/// A reference Dijkstra over the same edge model the A* search uses, with the
/// same `SearchCost` (so it's a true differential check, not a different cost).
/// No heuristic, no closed-set early-exit games — the textbook settling Dijkstra
/// whose result is the provably-optimal node-to-node cost. Returns the optimal
/// cost to every node from `source`, plus the came-from edge for path recovery.
private func dijkstra(
    from source: NodeIndex,
    in graph: RoadGraph,
    cost: SearchCost
) -> (dist: [Double], cameFrom: [Int32]) {
    let n = graph.nodes.count
    var dist = [Double](repeating: .infinity, count: n)
    var cameFrom = [Int32](repeating: -1, count: n)
    var done = [Bool](repeating: false, count: n)
    dist[Int(source)] = 0

    for _ in 0..<n {
        // Linear-scan the unsettled minimum — n is tiny in these fixtures.
        var u = -1
        var best = Double.infinity
        for v in 0..<n where !done[v] && dist[v] < best {
            best = dist[v]; u = v
        }
        if u < 0 { break }
        done[u] = true

        let incomingEdgeIndex = cameFrom[u]
        let incomingEdge: GraphEdge? = incomingEdgeIndex >= 0 ? graph.edges[Int(incomingEdgeIndex)] : nil
        let node = graph.nodes[u]
        for e in graph.outEdgeRange(of: NodeIndex(u)) {
            let edge = graph.edges[Int(e)]
            let stepEdge = cost.edgeCost(edge, in: graph)
            guard stepEdge.isFinite else { continue }
            let stepTurn = cost.turnCost(from: incomingEdge, to: edge, at: node, in: graph)
            guard stepTurn.isFinite else { continue }
            let nd = dist[u] + stepEdge + stepTurn
            if nd < dist[Int(edge.to)] {
                dist[Int(edge.to)] = nd
                cameFrom[Int(edge.to)] = e
            }
        }
    }
    return (dist, cameFrom)
}

/// The true remaining optimal cost from each node to `target`, computed by a
/// reverse Dijkstra on the transpose graph. Used to assert heuristic
/// admissibility (`h ≤ trueRemaining`).
private func trueRemainingCost(
    to target: NodeIndex,
    in graph: RoadGraph,
    cost: SearchCost
) -> [Double] {
    // Build reverse adjacency: for each edge u->v store (v -> [(u, edgeIndex)]).
    let n = graph.nodes.count
    var reverse: [[(from: Int, edge: Int32)]] = Array(repeating: [], count: n)
    for (i, edge) in graph.edges.enumerated() {
        reverse[Int(edge.to)].append((Int(edge.from), Int32(i)))
    }
    var dist = [Double](repeating: .infinity, count: n)
    var done = [Bool](repeating: false, count: n)
    dist[Int(target)] = 0
    for _ in 0..<n {
        var u = -1
        var best = Double.infinity
        for v in 0..<n where !done[v] && dist[v] < best { best = dist[v]; u = v }
        if u < 0 { break }
        done[u] = true
        for (predecessor, edgeIndex) in reverse[u] {
            let edge = graph.edges[Int(edgeIndex)]
            let stepEdge = cost.edgeCost(edge, in: graph)
            guard stepEdge.isFinite else { continue }
            // Turn cost ignored for the admissibility bound — TravelTimeCost has
            // zero turn cost so the bound is exact; with penalised models the
            // heuristic (pure travel time) is still ≤ this edge-only remaining.
            let nd = dist[u] + stepEdge
            if nd < dist[predecessor] {
                dist[predecessor] = nd
            }
        }
    }
    return dist
}

// MARK: - Tests

@Suite("AStarSearch")
struct AStarSearchTests {

    private let search = AStarSearch()
    private let cost = TravelTimeCost()

    /// A small grid corridor: a 3×3 lattice of residential ways so there are many
    /// alternate paths, used for the differential check.
    private func gridGraph() -> RoadGraph {
        // 9 nodes laid out on a ~111 m grid (0.001°). Connect horizontally and
        // vertically with bidirectional residential ways.
        var elements: [String] = []
        var id: Int64 = 1
        var coords: [(Int64, Double, Double)] = []
        for r in 0..<3 {
            for c in 0..<3 {
                let lat = Double(r) * 0.001
                let lon = Double(c) * 0.001
                elements.append(node(id, lat, lon))
                coords.append((id, lat, lon))
                id += 1
            }
        }
        func nid(_ r: Int, _ c: Int) -> Int64 { Int64(r * 3 + c + 1) }
        var wid: Int64 = 1000
        for r in 0..<3 {
            for c in 0..<3 {
                if c < 2 {
                    elements.append(way(wid, [nid(r, c), nid(r, c + 1)], tags: ["highway": "residential"])); wid += 1
                }
                if r < 2 {
                    elements.append(way(wid, [nid(r, c), nid(r + 1, c)], tags: ["highway": "residential"])); wid += 1
                }
            }
        }
        let json = #"{"version":0.6,"elements":[\#(elements.joined(separator: ","))]}"#
        let response = try! JSONDecoder().decode(OverpassGraphResponse.self, from: Data(json.utf8))
        return RoadGraphBuilder.buildGraph(from: response)
    }

    @Test("differential vs brute-force Dijkstra on a grid: identical optimal cost")
    func differentialAgainstDijkstra() {
        let graph = gridGraph()
        // For every (source, target) node pair, A* node→node cost must equal the
        // settling Dijkstra optimum.
        for s in 0..<graph.nodes.count {
            let (dist, _) = dijkstra(from: NodeIndex(s), in: graph, cost: cost)
            for t in 0..<graph.nodes.count where s != t {
                let result = search.search(
                    from: .node(NodeIndex(s)),
                    to: .node(NodeIndex(t)),
                    in: graph,
                    cost: cost
                )
                guard let result else { Issue.record("A* found no path \(s)->\(t)"); continue }
                #expect(abs(result.totalCost - dist[t]) < 1e-6,
                        "A* \(result.totalCost) vs Dijkstra \(dist[t]) for \(s)->\(t)")
            }
        }
    }

    @Test("A* picks the genuinely faster road even when geometrically longer")
    func prefersFasterRoad() {
        // Two paths from A(node1) to D(node4):
        //  - direct slow residential A-D (one short 25mph edge)
        //  - longer fast detour A-B-C-D on a primary 45mph road
        // Lay them out so the fast road's travel time is lower despite the detour.
        // Slow direct edge: 111 m at ~25 mph (11.2 m/s) ≈ 9.9 s.
        // Fast detour: three 111 m edges at ~45 mph (20.1 m/s) ≈ 16.5 s total.
        // Here the DIRECT one is actually faster — flip it: make detour speeds high
        // enough. Use a long direct residential vs short fast detour.
        let graph = buildGraph(
            node(1, 0.0, 0.0),
            node(2, 0.0005, 0.0),
            node(3, 0.0005, 0.001),
            node(4, 0.0, 0.001),
            // Direct A(1)->D(4): a long residential running the full width.
            way(100, [1, 4], tags: ["highway": "residential", "maxspeed": "25 mph"]),
            // Detour A(1)->B(2)->C(3)->D(4) over a motorway.
            way(101, [1, 2], tags: ["highway": "motorway", "maxspeed": "65 mph"]),
            way(102, [2, 3], tags: ["highway": "motorway", "maxspeed": "65 mph"]),
            way(103, [3, 4], tags: ["highway": "motorway", "maxspeed": "65 mph"])
        )
        // The direct edge is ~111 m at 25 mph ≈ 9.9 s.
        // The detour is ~55+111+55 = 221 m at 65 mph ≈ 7.6 s — faster despite longer.
        let i1 = Int(graph.osmToIndex[1]!)
        let i4 = Int(graph.osmToIndex[4]!)
        let result = search.search(from: .node(NodeIndex(i1)), to: .node(NodeIndex(i4)), in: graph, cost: cost)
        guard let result else { Issue.record("no path"); return }
        // The faster detour goes through node 2 — verify the path is the 3-edge one.
        #expect(result.edgePath.count == 3)
        let (dist, _) = dijkstra(from: NodeIndex(i1), in: graph, cost: cost)
        #expect(abs(result.totalCost - dist[i4]) < 1e-6)
    }

    @Test("heuristic is admissible: h ≤ true remaining cost at every node")
    func heuristicAdmissible() {
        let graph = gridGraph()
        // Target = node index 8 (the far corner).
        let target = NodeIndex(8)
        let targetCoord = graph.nodes[Int(target)].coordinate
        let remaining = trueRemainingCost(to: target, in: graph, cost: cost)
        for v in 0..<graph.nodes.count {
            let h = cost.heuristic(from: graph.nodes[v].coordinate, to: targetCoord, in: graph)
            // h is a lower bound; allow a tiny epsilon for float noise.
            #expect(h <= remaining[v] + 1e-6,
                    "heuristic \(h) exceeds true remaining \(remaining[v]) at node \(v)")
        }
    }

    @Test("no path returns nil (disconnected components)")
    func noPathReturnsNil() {
        // Two separate ways with no shared node — disconnected.
        let graph = buildGraph(
            node(1, 0.0, 0.0),
            node(2, 0.0, 0.001),
            node(3, 0.01, 0.01),
            node(4, 0.01, 0.011),
            way(100, [1, 2], tags: ["highway": "residential"]),
            way(101, [3, 4], tags: ["highway": "residential"])
        )
        let i1 = Int(graph.osmToIndex[1]!)
        let i3 = Int(graph.osmToIndex[3]!)
        let result = search.search(from: .node(NodeIndex(i1)), to: .node(NodeIndex(i3)), in: graph, cost: cost)
        #expect(result == nil)
    }

    @Test("oneway prevents wrong-way traversal -> no path")
    func onewayBlocksReverse() {
        // A oneway forward 1->2; searching 2->1 must fail (no reverse edge).
        let graph = buildGraph(
            node(1, 0.0, 0.0),
            node(2, 0.0, 0.001),
            way(100, [1, 2], tags: ["highway": "primary", "oneway": "yes"])
        )
        let i1 = Int(graph.osmToIndex[1]!)
        let i2 = Int(graph.osmToIndex[2]!)
        #expect(search.search(from: .node(NodeIndex(i1)), to: .node(NodeIndex(i2)), in: graph, cost: cost) != nil)
        #expect(search.search(from: .node(NodeIndex(i2)), to: .node(NodeIndex(i1)), in: graph, cost: cost) == nil)
    }

    // MARK: - Snap / mid-edge

    @Test("snap accuracy: arbitrary coord near an edge snaps onto it")
    func snapAccuracy() {
        // A single long east-west way; a point ~10 m north of its midpoint snaps
        // onto the edge with a small perpendicular distance and fraction ~0.5.
        let graph = buildGraph(
            node(1, 0.0, 0.0),
            node(2, 0.0, 0.002),
            way(100, [1, 2], tags: ["highway": "primary"])
        )
        // Midpoint is (0, 0.001); offset ~10 m north (~0.00009°).
        let probe = CLLocationCoordinate2D(latitude: 0.00009, longitude: 0.001)
        guard let snap = graph.snap(probe, maxDistanceMeters: 50) else {
            Issue.record("snap failed"); return
        }
        #expect(abs(snap.fraction - 0.5) < 0.05)
        #expect(snap.distanceMeters < 12)
        #expect(abs(snap.snapped.latitude) < 1e-6)   // snapped back onto the y=0 line
    }

    @Test("snap finds an edge ~150 m away, outside the old 3x3 cell window")
    func snapBeyondOldWindow() {
        // A short north-south meridian edge at longitude 0.0009 (longitude cell 0),
        // up at latitude 45° where one 0.001° cell is only ~79 m wide in longitude.
        // The probe sits ~150 m EAST of it — within the 200 m router snap radius but
        // two longitude cells away (cell 2), so the OLD fixed 3×3 (radius-1) window
        // could never reach it and `snap` returned nil. The radius now scales with
        // `maxDistanceMeters`, so the edge is found.
        let graph = buildGraph(
            node(1, 45.0, 0.0009),
            node(2, 45.0008, 0.0009),
            way(100, [1, 2], tags: ["highway": "primary"])
        )
        let probe = CLLocationCoordinate2D(latitude: 45.0004, longitude: 0.002805619074132702)

        // Sanity: the edge really is in a longitude cell two cells from the probe,
        // i.e. outside the old radius-1 window (which only covered cells 1...3 here).
        let edgeLonCell = GraphSpatialIndex.cellIndex(0.0009)
        let probeLonCell = GraphSpatialIndex.cellIndex(probe.longitude)
        #expect(abs(probeLonCell - edgeLonCell) >= 2)

        // The old 3×3 window misses it; the radius-scaled window finds it within 200 m.
        #expect(graph.snap(probe, maxDistanceMeters: 200) != nil)
        guard let snap = graph.snap(probe, maxDistanceMeters: 200) else {
            Issue.record("snap should have found the edge within the 200 m radius"); return
        }
        #expect(snap.distanceMeters > 100 && snap.distanceMeters < 200)

        // And the gate is still honored: a 50 m radius must NOT reach a ~150 m edge.
        #expect(graph.snap(probe, maxDistanceMeters: 50) == nil)
    }

    @Test("mid-edge start and end produce a partial-cost path")
    func midEdgeStartEnd() {
        // A straight 3-edge chain 1-2-3-4 along the equator, each ~111 m primary.
        let graph = buildGraph(
            node(1, 0.0, 0.0),
            node(2, 0.0, 0.001),
            node(3, 0.0, 0.002),
            node(4, 0.0, 0.003),
            way(100, [1, 2], tags: ["highway": "primary", "maxspeed": "45 mph"]),
            way(101, [2, 3], tags: ["highway": "primary", "maxspeed": "45 mph"]),
            way(102, [3, 4], tags: ["highway": "primary", "maxspeed": "45 mph"])
        )
        // Start mid-edge 1-2 (around the midpoint) and end mid-edge 3-4.
        let start = CLLocationCoordinate2D(latitude: 0.000005, longitude: 0.0005)
        let end = CLLocationCoordinate2D(latitude: 0.000005, longitude: 0.0025)
        let result = search.search(
            from: .coordinate(start),
            to: .coordinate(end),
            in: graph,
            cost: cost
        )
        guard let result else { Issue.record("no mid-edge path"); return }
        // Fractions record where on the leading/trailing edges travel begins/ends.
        #expect(result.startFraction > 0 && result.startFraction < 1)
        #expect(result.endFraction > 0 && result.endFraction < 1)
        // The cost must be strictly less than the full node1->node4 cost (we cut
        // off a partial leading and trailing segment).
        let i1 = Int(graph.osmToIndex[1]!)
        let i4 = Int(graph.osmToIndex[4]!)
        let fullResult = search.search(from: .node(NodeIndex(i1)), to: .node(NodeIndex(i4)), in: graph, cost: cost)
        #expect(result.totalCost < (fullResult?.totalCost ?? .infinity))
        // Path should still traverse the middle edge 2-3.
        #expect(result.edgePath.count >= 1)
    }

    @Test("mid-edge start and end on the SAME edge")
    func midEdgeSameEdge() {
        // One long primary edge (bidirectional, so a forward AND reverse edge
        // both exist over the same geometry). Start at ~0.25 and end at ~0.75.
        let graph = buildGraph(
            node(1, 0.0, 0.0),
            node(2, 0.0, 0.004),
            way(100, [1, 2], tags: ["highway": "primary", "maxspeed": "45 mph"])
        )
        let start = CLLocationCoordinate2D(latitude: 0.000005, longitude: 0.001)
        let end = CLLocationCoordinate2D(latitude: 0.000005, longitude: 0.003)
        let result = search.search(from: .coordinate(start), to: .coordinate(end), in: graph, cost: cost)
        // Both snap to the same directed edge. The journey lives entirely inside
        // that one edge: the path must be a single edge with the two endpoint
        // nodes, NOT a round-trip [A,B,A,B] over the bidirectional pair.
        guard let result else { Issue.record("no same-edge path"); return }
        #expect(result.edgePath.count == 1)
        #expect(result.nodePath.count == 2)
        // No node may repeat — a round-trip reconstruction would duplicate one.
        #expect(Set(result.nodePath).count == result.nodePath.count)
        #expect(result.startFraction < result.endFraction)
        #expect(result.totalCost > 0)
        // Sub-edge cost is the fraction of the full edge actually travelled, well
        // under the full single-edge traversal cost.
        let full = cost.edgeCost(graph.edges[Int(result.edgePath[0])], in: graph)
        #expect(result.totalCost < full)
        let expected = full * (result.endFraction - result.startFraction)
        #expect(abs(result.totalCost - expected) < 1e-6)
    }

    @Test("destination behind the origin on a two-way street: short reverse, not overshoot + U-turn")
    func midEdgeSameEdgeReverse() {
        // One long two-way primary edge (forward AND reverse directed edges over
        // the same geometry). The ORIGIN snaps AHEAD of the DESTINATION on that
        // street: origin at arc-fraction ~0.8, destination at ~0.3. Both snap to
        // the lower-indexed FORWARD edge, so the same-edge forward fast path is
        // skipped (0.8 > 0.3). Pre-fix, A* could only reach the destination by
        // driving to the block end, U-turning onto the reverse edge, and driving
        // all the way back — a ~1.5x-block overshoot with a spurious "Make a
        // U-turn". The fix terminates on the co-located reverse edge: a short
        // reverse from the origin straight back to the destination.
        let graph = buildGraph(
            node(1, 0.0, 0.0),
            node(2, 0.0, 0.004),
            way(100, [1, 2], tags: ["highway": "primary", "maxspeed": "45 mph"])
        )
        let origin = CLLocationCoordinate2D(latitude: 0.000005, longitude: 0.0032)   // ~fraction 0.8
        let dest = CLLocationCoordinate2D(latitude: 0.000005, longitude: 0.0012)     // ~fraction 0.3

        // Both endpoints snap to the SAME (forward) directed edge — the trigger.
        guard let originSnap = graph.snap(origin, maxDistanceMeters: 200),
              let destSnap = graph.snap(dest, maxDistanceMeters: 200) else {
            Issue.record("snap failed"); return
        }
        #expect(originSnap.edge == destSnap.edge)
        #expect(originSnap.fraction > destSnap.fraction)   // origin AHEAD of destination

        guard let result = search.search(from: .coordinate(origin), to: .coordinate(dest), in: graph, cost: cost) else {
            Issue.record("no path"); return
        }
        // A single short sub-segment on the reverse edge — NOT a 3-edge
        // overshoot+U-turn round trip.
        #expect(result.edgePath.count == 1)
        #expect(result.nodePath.count == 2)
        #expect(Set(result.nodePath).count == result.nodePath.count)   // no repeated node
        #expect(result.startFraction < result.endFraction)            // travel runs the reverse way

        // Cost is the short reverse (~0.5 of the block), well under both a full
        // block traversal and the overshoot+U-turn the bug produced (~1.5 blocks).
        let edge = graph.edges[Int(result.edgePath[0])]
        let full = cost.edgeCost(edge, in: graph)
        let expected = full * (result.endFraction - result.startFraction)
        #expect(abs(result.totalCost - expected) < 1e-6)
        #expect(result.totalCost < full)                  // less than one full block
        #expect(result.totalCost < 0.7 * full)            // and far below the ~1.5-block overshoot

        // The drawn route must start at the origin and END at the destination, with
        // no U-turn maneuver anywhere in the synthesized steps.
        guard let synth = StepSynthesizer.synthesize(result, in: graph) else {
            Issue.record("synthesis failed"); return
        }
        #expect(RouteGeometry.haversineDistance(from: synth.coordinates.first!, to: originSnap.snapped) < 2.0)
        #expect(RouteGeometry.haversineDistance(from: synth.coordinates.last!, to: destSnap.snapped) < 2.0)
        #expect(!synth.steps.contains { $0.instruction.lowercased().contains("u-turn") })
    }

    @Test("origin == destination on the same edge (equal fraction): degenerate point route, no full-edge draw")
    func sameEdgeEqualFractionIsDegenerate() {
        // One long primary edge. Origin and destination snap to the EXACT same
        // mid-edge point, so Case 1 fires with startFraction == endFraction (the
        // `<=` admits equality) and totalCost 0. Pre-fix, StepSynthesizer's
        // trimSubSegment guard `from < to` rejected the equal fractions and returned
        // the FULL untrimmed edge — drawing the whole block and reporting a full-edge
        // distance for a zero-length trip. The fix collapses the sub-segment to a
        // single interpolated point, so synthesis yields no >=2-coord polyline and
        // the leg falls back to MapKit rather than a phantom full-block drive.
        let graph = buildGraph(
            node(1, 0.0, 0.0),
            node(2, 0.0, 0.004),
            way(100, [1, 2], tags: ["highway": "primary", "maxspeed": "45 mph"])
        )
        let point = CLLocationCoordinate2D(latitude: 0.000005, longitude: 0.002)   // mid-edge
        let result = search.search(from: .coordinate(point), to: .coordinate(point), in: graph, cost: cost)
        guard let result else { Issue.record("no path for coincident endpoints"); return }
        // The same-edge fast path returns a degenerate single-edge result with
        // equal fractions and zero cost.
        #expect(result.edgePath.count == 1)
        #expect(result.startFraction == result.endFraction)
        #expect(result.totalCost == 0)

        // The travelled geometry is a single point, so synthesize collapses to a
        // <2-coordinate polyline and returns nil (no full-block route is drawn).
        let stitched = StepSynthesizer.stitchedPolyline(result, in: graph)
        #expect(stitched.count <= 1, "zero-length route must not draw the full edge (\(stitched.count) coords)")
        #expect(StepSynthesizer.synthesize(result, in: graph) == nil)
        // And the per-step length of that edge is ~0, not the full block length.
        let edgeFull = Double(graph.edges[Int(result.edgePath[0])].lengthMeters)
        #expect(StepSynthesizer.freeFlowSeconds(result, in: graph) < edgeFull / 1000,
                "zero-length route must report ~0 travel time, not a full-edge duration")
    }

    @Test("destination near the A-end of a long two-way edge, approached from the B-end: no full-edge overshoot + double-back")
    func midEdgeDestinationApproachedFromWrongEnd() {
        // A long two-way edge A(1) <-> B(2) (~445 m). A short two-way connector
        // C(3) <-> B(2) feeds the ORIGIN into the street at the B-end. The ORIGIN is
        // node C, so its single out-edge C->B is deterministic; the DESTINATION snaps
        // mid-edge at ~fraction 0.2 from A (i.e. ~0.8 of the edge AWAY from B). The
        // origin is NOT on the A<->B road, so the same-road fast path does NOT fire —
        // plain A* runs against a mid-edge destination on a long two-way edge.
        //
        // Pre-fix, resolveDestination modelled the mid-edge end as a SINGLE goal:
        // reach `edge.from` (= A) then drive fraction 0.2 forward. Coming from B,
        // A* had to traverse the WHOLE A<->B edge in reverse to reach A, then the
        // trailing partial drove 0.2 back toward B — overshooting the destination and
        // doubling back (~1.2 edge-lengths, with a U-turn at A, for a point only 0.8
        // of an edge away). The fix offers the reverse-orientation arrival: stop at B
        // and take the short 0.8 reverse partial straight to the destination.
        let graph = buildGraph(
            node(1, 0.0, 0.0),        // A
            node(2, 0.0, 0.004),      // B  (~445 m east of A)
            node(3, 0.0009, 0.004),   // C  (~100 m north of B)
            way(100, [1, 2], tags: ["highway": "primary", "maxspeed": "45 mph"]),  // A<->B long two-way
            way(101, [2, 3], tags: ["highway": "primary", "maxspeed": "45 mph"])   // B<->C connector
        )
        // Origin at node C — enters the A<->B street at the B-end via C->B.
        let originNode = NodeIndex(graph.osmToIndex[3]!)
        let origin = graph.nodes[Int(originNode)].coordinate
        // Destination at ~fraction 0.2 from A along the long edge.
        let dest = CLLocationCoordinate2D(latitude: 0.000005, longitude: 0.0008)

        guard let destSnap = graph.snap(dest, maxDistanceMeters: 200) else {
            Issue.record("destination snap failed"); return
        }
        // Snapped onto the long A<->B edge, near the A-end (geometry-based so the
        // check is independent of which directed orientation snap happened to pick).
        let nodeA = graph.nodes[Int(graph.osmToIndex[1]!)].coordinate
        let nodeB = graph.nodes[Int(graph.osmToIndex[2]!)].coordinate
        #expect(RouteGeometry.haversineDistance(from: destSnap.snapped, to: nodeA)
                < RouteGeometry.haversineDistance(from: destSnap.snapped, to: nodeB),
                "destination should snap nearer the A-end than the B-end")
        let longEdge = graph.edges[Int(destSnap.edge)]
        let longEdgeLen = Double(longEdge.lengthMeters)

        guard let result = search.search(from: .node(originNode), to: .coordinate(dest), in: graph, cost: cost) else {
            Issue.record("no path"); return
        }

        // The synthesized route must END at the destination point (within snap
        // noise), NOT a block past it at node A.
        guard let synth = StepSynthesizer.synthesize(result, in: graph) else {
            Issue.record("synthesis failed"); return
        }
        let endPoint = synth.coordinates.last!
        #expect(RouteGeometry.haversineDistance(from: endPoint, to: destSnap.snapped) < 2.0,
                "route should end at the destination, ended \(RouteGeometry.haversineDistance(from: endPoint, to: destSnap.snapped)) m away")

        // No overshoot + double-back: the drawn route travels essentially the
        // straight-line origin->dest distance, NOT a full edge plus a 0.2 backtrack.
        // Straight-line origin->dest is ~connector + 0.8 of the long edge. A full
        // overshoot would add ~2 * 0.2 * edgeLen of pointless extra distance.
        let drawnLength = RouteGeometry.cumulativeDistances(synth.coordinates).last ?? .infinity
        let straight = RouteGeometry.haversineDistance(from: destSnap.snapped, to: origin)
        #expect(drawnLength < straight + 0.25 * longEdgeLen,
                "route length \(drawnLength) m overshoots straight-line \(straight) m by more than a fifth of the edge (\(longEdgeLen) m)")

        // No U-turn maneuver — the overshoot bug emitted a turn back at node A.
        #expect(!synth.steps.contains { $0.instruction.lowercased().contains("u-turn") })

        // The route must not traverse the long edge and then re-traverse part of it
        // in the opposite direction: the long edge's two directed orientations must
        // not BOTH appear in the path (that is the overshoot signature).
        let forwardLong = result.edgePath.contains { e in
            let ge = graph.edges[Int(e)]
            return ge.osmWayID == longEdge.osmWayID && ge.from == longEdge.from && ge.to == longEdge.to
        }
        let reverseLong = result.edgePath.contains { e in
            let ge = graph.edges[Int(e)]
            return ge.osmWayID == longEdge.osmWayID && ge.from == longEdge.to && ge.to == longEdge.from
        }
        #expect(!(forwardLong && reverseLong),
                "route traverses the long edge in BOTH directions — full-edge overshoot + double-back")
    }

    // MARK: - Boundary snap (endpoint projects exactly onto a graph node)

    /// A straight 3-edge chain 1-2-3-4 along the equator, each ~111 m primary —
    /// the shared fixture for the boundary-snap tests below.
    private func equatorChain() -> RoadGraph {
        buildGraph(
            node(1, 0.0, 0.0),
            node(2, 0.0, 0.001),
            node(3, 0.0, 0.002),
            node(4, 0.0, 0.003),
            way(100, [1, 2], tags: ["highway": "primary", "maxspeed": "45 mph"]),
            way(101, [2, 3], tags: ["highway": "primary", "maxspeed": "45 mph"]),
            way(102, [3, 4], tags: ["highway": "primary", "maxspeed": "45 mph"])
        )
    }

    @Test("destination snapping onto a node (fraction 1) terminates AT that node, no full-edge overshoot")
    func destinationSnapsToNodeFractionOne() {
        // The destination sits just PAST node 4 (the chain's far end), slightly
        // north and east, so its foot on edge 3-4 clamps to the TO vertex: t=1 ⇒
        // fraction=1.0 exactly. Pre-fix this returned a trailing partial edge with
        // endFraction=1 and (for the symmetric origin case) overshot; here the
        // destination must resolve to node 4 itself.
        let graph = equatorChain()
        let origin = CLLocationCoordinate2D(latitude: 0.000005, longitude: 0.0005)   // mid edge 1-2
        let dest = CLLocationCoordinate2D(latitude: 0.00001, longitude: 0.0035)       // past node 4
        guard let snap = graph.snap(dest, maxDistanceMeters: 200) else {
            Issue.record("destination snap failed"); return
        }
        #expect(snap.fraction == 1.0)   // exact clamp boundary

        guard let result = search.search(from: .coordinate(origin), to: .coordinate(dest), in: graph, cost: cost) else {
            Issue.record("no path"); return
        }
        // Terminates at a node, so there is no trailing partial edge: endFraction
        // is the node sentinel 1, and the last node is node 4.
        #expect(result.endFraction == 1)
        let i4 = NodeIndex(graph.osmToIndex[4]!)
        #expect(result.nodePath.last == i4)

        // The drawn polyline must END at node 4's coordinate — NOT a block past it.
        guard let synth = StepSynthesizer.synthesize(result, in: graph) else {
            Issue.record("synthesis failed"); return
        }
        let node4 = graph.nodes[Int(i4)].coordinate
        let endPoint = synth.coordinates.last!
        #expect(RouteGeometry.haversineDistance(from: endPoint, to: node4) < 1.0,
                "route should end at node 4, ended \(RouteGeometry.haversineDistance(from: endPoint, to: node4)) m away")

        // Total distance equals origin→node4: from the snapped origin to node 2
        // (~55 m), then 2-3 and 3-4 (~111 m each) — and crucially NOT one extra
        // ~111 m edge of overshoot. Compare against the explicit node-4 destination.
        let viaNode = search.search(from: .coordinate(origin), to: .node(i4), in: graph, cost: cost)
        #expect(abs(result.totalCost - (viaNode?.totalCost ?? -1)) < 1e-6)
    }

    @Test("destination snapping onto a node (fraction 0) terminates AT the FROM node, no full-edge overshoot")
    func destinationSnapsToNodeFractionZero() {
        // The destination sits just BEFORE node 1 (the chain's near end), so its
        // foot on edge 1-2 clamps to the FROM vertex: t=0 ⇒ fraction=0.0 exactly.
        // This is the headline overshoot bug: pre-fix, resolveDestination returned
        // trailingEdge=edge(1-2), endFraction=0, and stitchedPolyline drew the WHOLE
        // edge to node 2 — a full block PAST the real destination at node 1.
        let graph = equatorChain()
        // Origin mid edge 3-4 travelling back toward node 1 needs a reverse edge;
        // the ways are bidirectional so 4->3->2->1 exists. Place origin past node 4.
        let origin = CLLocationCoordinate2D(latitude: 0.00001, longitude: 0.0025)     // mid edge 3-4
        let dest = CLLocationCoordinate2D(latitude: 0.00001, longitude: -0.0005)      // before node 1
        guard let snap = graph.snap(dest, maxDistanceMeters: 200) else {
            Issue.record("destination snap failed"); return
        }
        #expect(snap.fraction == 0.0)   // exact clamp boundary

        guard let result = search.search(from: .coordinate(origin), to: .coordinate(dest), in: graph, cost: cost) else {
            Issue.record("no path"); return
        }
        #expect(result.endFraction == 1)   // node sentinel, no trailing partial
        let i1 = NodeIndex(graph.osmToIndex[1]!)
        #expect(result.nodePath.last == i1)

        guard let synth = StepSynthesizer.synthesize(result, in: graph) else {
            Issue.record("synthesis failed"); return
        }
        let node1 = graph.nodes[Int(i1)].coordinate
        let endPoint = synth.coordinates.last!
        let overshoot = RouteGeometry.haversineDistance(from: endPoint, to: node1)
        #expect(overshoot < 1.0,
                "route should END at node 1, ended \(overshoot) m away (full-edge overshoot bug)")

        // Distance matches an explicit node-1 destination — no phantom extra edge.
        let viaNode = search.search(from: .coordinate(origin), to: .node(i1), in: graph, cost: cost)
        #expect(abs(result.totalCost - (viaNode?.totalCost ?? -1)) < 1e-6)
    }

    @Test("origin snapping onto a node (fraction 1) starts AT that node, no leading-edge overshoot")
    func originSnapsToNodeFractionOne() {
        // The origin sits just PAST node 4, clamping its foot on edge 3-4 to the
        // TO vertex: fraction=1.0. Pre-fix resolveOrigin returned leadingEdge=edge,
        // startFraction=1, and stitchedPolyline (isFirst true for 1) drew the FULL
        // leading edge from node 3 — a block BEFORE the real origin at node 4.
        let graph = equatorChain()
        let origin = CLLocationCoordinate2D(latitude: 0.00001, longitude: 0.0035)     // past node 4
        let dest = CLLocationCoordinate2D(latitude: 0.000005, longitude: 0.0015)      // mid edge 2-3, heading back
        guard let snap = graph.snap(origin, maxDistanceMeters: 200) else {
            Issue.record("origin snap failed"); return
        }
        #expect(snap.fraction == 1.0)

        guard let result = search.search(from: .coordinate(origin), to: .coordinate(dest), in: graph, cost: cost) else {
            Issue.record("no path"); return
        }
        // No leading partial edge: startFraction is the node sentinel 0 and the
        // first node is node 4.
        #expect(result.startFraction == 0)
        let i4 = NodeIndex(graph.osmToIndex[4]!)
        #expect(result.nodePath.first == i4)

        guard let synth = StepSynthesizer.synthesize(result, in: graph) else {
            Issue.record("synthesis failed"); return
        }
        let node4 = graph.nodes[Int(i4)].coordinate
        let startPoint = synth.coordinates.first!
        #expect(RouteGeometry.haversineDistance(from: startPoint, to: node4) < 1.0,
                "route should START at node 4, started \(RouteGeometry.haversineDistance(from: startPoint, to: node4)) m away")

        // Distance matches starting explicitly from node 4 — no leading-edge overshoot.
        let viaNode = search.search(from: .node(i4), to: .coordinate(dest), in: graph, cost: cost)
        #expect(abs(result.totalCost - (viaNode?.totalCost ?? -1)) < 1e-6)
    }

    @Test("origin snapping onto a node (fraction 0) starts AT the FROM node")
    func originSnapsToNodeFractionZero() {
        // Origin just before node 1, clamping to the FROM vertex of edge 1-2:
        // fraction=0.0. Must resolve to node 1 with no leading partial edge.
        let graph = equatorChain()
        let origin = CLLocationCoordinate2D(latitude: 0.00001, longitude: -0.0005)    // before node 1
        let dest = CLLocationCoordinate2D(latitude: 0.000005, longitude: 0.0015)      // mid edge 2-3
        guard let snap = graph.snap(origin, maxDistanceMeters: 200) else {
            Issue.record("origin snap failed"); return
        }
        #expect(snap.fraction == 0.0)

        guard let result = search.search(from: .coordinate(origin), to: .coordinate(dest), in: graph, cost: cost) else {
            Issue.record("no path"); return
        }
        #expect(result.startFraction == 0)
        let i1 = NodeIndex(graph.osmToIndex[1]!)
        #expect(result.nodePath.first == i1)

        guard let synth = StepSynthesizer.synthesize(result, in: graph) else {
            Issue.record("synthesis failed"); return
        }
        let node1 = graph.nodes[Int(i1)].coordinate
        let startPoint = synth.coordinates.first!
        #expect(RouteGeometry.haversineDistance(from: startPoint, to: node1) < 1.0)

        let viaNode = search.search(from: .node(i1), to: .coordinate(dest), in: graph, cost: cost)
        #expect(abs(result.totalCost - (viaNode?.totalCost ?? -1)) < 1e-6)
    }

    @Test("mid-edge fractions are unchanged by the boundary-snap fix")
    func midEdgeFractionsUnchanged() {
        // Regression guard: an interior snap (foot strictly between vertices) must
        // still produce a partial leading/trailing edge with an open-interval
        // fraction — the boundary normalization must NOT collapse it to a node.
        let graph = equatorChain()
        let start = CLLocationCoordinate2D(latitude: 0.000005, longitude: 0.0005)     // mid edge 1-2
        let end = CLLocationCoordinate2D(latitude: 0.000005, longitude: 0.0025)       // mid edge 3-4
        guard let result = search.search(from: .coordinate(start), to: .coordinate(end), in: graph, cost: cost) else {
            Issue.record("no mid-edge path"); return
        }
        #expect(result.startFraction > 0 && result.startFraction < 1)
        #expect(result.endFraction > 0 && result.endFraction < 1)
        // Distinct from the full node-to-node traversal (a partial leading and
        // trailing segment are cut off).
        let i1 = NodeIndex(graph.osmToIndex[1]!)
        let i4 = NodeIndex(graph.osmToIndex[4]!)
        let full = search.search(from: .node(i1), to: .node(i4), in: graph, cost: cost)
        #expect(result.totalCost < (full?.totalCost ?? .infinity))
    }

    @Test("node-to-same-node degenerate path has zero cost")
    func sameNode() {
        let graph = buildGraph(
            node(1, 0.0, 0.0),
            node(2, 0.0, 0.001),
            way(100, [1, 2], tags: ["highway": "residential"])
        )
        let i1 = Int(graph.osmToIndex[1]!)
        let result = search.search(from: .node(NodeIndex(i1)), to: .node(NodeIndex(i1)), in: graph, cost: cost)
        #expect(result?.totalCost == 0)
        #expect(result?.edgePath.isEmpty == true)
    }

    @Test("empty graph returns nil")
    func emptyGraph() {
        let graph = RoadGraph(
            nodes: [], edges: [], geometry: [], osmToIndex: [:],
            snapIndex: GraphSpatialIndex(grid: [:]), graphMaxSpeedMPS: 0
        )
        let result = search.search(
            from: .coordinate(CLLocationCoordinate2D(latitude: 0, longitude: 0)),
            to: .coordinate(CLLocationCoordinate2D(latitude: 1, longitude: 1)),
            in: graph, cost: cost
        )
        #expect(result == nil)
    }

    @Test("a negative .node index fails clean instead of trapping (origin and destination)")
    func negativeNodeIndexFailsClean() {
        // NodeIndex is Int32, so `.node(-1)` is representable. Both endpoint
        // resolvers must bounds-check the low end and return nil rather than trap
        // on the negative `graph.nodes` subscript.
        let graph = buildGraph(
            node(1, 0.0, 0.0),
            node(2, 0.0, 0.001),
            way(100, [1, 2], tags: ["highway": "residential"])
        )
        let valid = NodeIndex(Int(graph.osmToIndex[1]!))

        // Negative origin.
        #expect(search.search(from: .node(-1), to: .node(valid), in: graph, cost: cost) == nil)
        // Negative destination.
        #expect(search.search(from: .node(valid), to: .node(-1), in: graph, cost: cost) == nil)
        // Both negative.
        #expect(search.search(from: .node(-5), to: .node(-3), in: graph, cost: cost) == nil)
        // Sanity: the valid pair still routes (guard didn't over-reject).
        #expect(search.search(from: .node(valid), to: .node(NodeIndex(Int(graph.osmToIndex[2]!))), in: graph, cost: cost) != nil)
    }

    // MARK: - Turn-aware optimality (edge-keyed state regression)

    /// A cost where the turn penalty into one specific edge depends on which edge
    /// you arrived on — the exact shape that breaks node-keyed A*. The cheaper
    /// approach to the junction forces an expensive turn; the costlier approach
    /// enables a free turn. Node-keyed search commits to the cheaper approach and
    /// can never recover the cheaper downstream turn; edge-keyed search keeps both
    /// approaches and finds the true optimum. Heuristic is 0 (trivially admissible).
    private struct TurnTrapCost: SearchCost {
        /// Per-edge traversal cost, keyed by (from, to) node index.
        let edgeCosts: [EdgePair: Double]
        /// The junction node M where the trap turn lives.
        let junction: NodeIndex
        /// The expensive approach edge (P -> M); turning M -> D off it costs a lot.
        let expensiveApproach: EdgePair
        /// The cheap approach edge (Q -> M); turning M -> D off it is free.
        let cheapApproach: EdgePair
        /// The trapped outgoing edge (M -> D).
        let trappedOut: EdgePair
        let trapPenalty: Double

        struct EdgePair: Hashable { let from: NodeIndex; let to: NodeIndex }

        func edgeCost(_ edge: GraphEdge, in graph: RoadGraph) -> Double {
            edgeCosts[EdgePair(from: edge.from, to: edge.to)] ?? .infinity
        }

        func turnCost(from incoming: GraphEdge?, to outgoing: GraphEdge, at node: GraphNode, in graph: RoadGraph) -> Double {
            guard let incoming else { return 0 }
            let inPair = EdgePair(from: incoming.from, to: incoming.to)
            let outPair = EdgePair(from: outgoing.from, to: outgoing.to)
            // Only the trapped outgoing edge off the expensive approach is penalised.
            if outPair == trappedOut && inPair == expensiveApproach { return trapPenalty }
            return 0
        }

        func heuristic(from coordinate: CLLocationCoordinate2D, to target: CLLocationCoordinate2D, in graph: RoadGraph) -> Double {
            0
        }
    }

    /// Resolve a directed edge's index by its (fromOSM -> toOSM) node ids.
    private func directedEdge(_ fromOSM: Int64, _ toOSM: Int64, in graph: RoadGraph) -> EdgeIndex? {
        guard let from = graph.osmToIndex[fromOSM], let to = graph.osmToIndex[toOSM] else { return nil }
        for e in graph.outEdgeRange(of: from) where graph.edges[Int(e)].to == to { return e }
        return nil
    }

    @Test("edge-keyed A* beats the node-keyed turn trap: costlier approach wins for a cheaper turn")
    func turnAwareOptimalityBeatsNodeKeyed() {
        // S(1) reaches junction M(4) two ways:
        //   cheap approach  S->P->M  (1 + 1 = 2)
        //   costly approach S->Q->M  (1 + 3 = 4)
        // From M the only way on is M->D(5)->G(6). Turning M->D off the CHEAP
        // approach (P->M) costs +100; off the COSTLY approach (Q->M) it is free.
        //   via P: 1 + 1 + 1 + 100 + 1 = 104
        //   via Q: 1 + 3 + 1 +   0 + 1 = 6   (optimal)
        // Node-keyed A* settles M via the cheaper P approach (g=2) and can only
        // ever charge the +100 turn, yielding 104. Edge-keyed keeps both approach
        // edges as distinct states and finds 6 through Q.
        let graph = buildGraph(
            node(1, 0.0, 0.0),       // S
            node(2, 0.001, 0.0),     // P
            node(3, -0.001, 0.0),    // Q
            node(4, 0.0, 0.001),     // M (junction)
            node(5, 0.0, 0.002),     // D
            node(6, 0.0, 0.003),     // G
            way(100, [1, 2], tags: ["highway": "residential"]),  // S-P
            way(101, [1, 3], tags: ["highway": "residential"]),  // S-Q
            way(102, [2, 4], tags: ["highway": "residential"]),  // P-M
            way(103, [3, 4], tags: ["highway": "residential"]),  // Q-M
            way(104, [4, 5], tags: ["highway": "residential"]),  // M-D
            way(105, [5, 6], tags: ["highway": "residential"])   // D-G
        )
        let M = graph.osmToIndex[4]!
        let cost = TurnTrapCost(
            edgeCosts: [
                .init(from: graph.osmToIndex[1]!, to: graph.osmToIndex[2]!): 1,  // S->P
                .init(from: graph.osmToIndex[2]!, to: graph.osmToIndex[4]!): 1,  // P->M
                .init(from: graph.osmToIndex[1]!, to: graph.osmToIndex[3]!): 1,  // S->Q
                .init(from: graph.osmToIndex[3]!, to: graph.osmToIndex[4]!): 3,  // Q->M
                .init(from: graph.osmToIndex[4]!, to: graph.osmToIndex[5]!): 1,  // M->D
                .init(from: graph.osmToIndex[5]!, to: graph.osmToIndex[6]!): 1,  // D->G
            ],
            junction: M,
            expensiveApproach: .init(from: graph.osmToIndex[2]!, to: M),  // P->M
            cheapApproach: .init(from: graph.osmToIndex[3]!, to: M),      // Q->M
            trappedOut: .init(from: M, to: graph.osmToIndex[5]!),         // M->D
            trapPenalty: 100
        )

        let s = NodeIndex(graph.osmToIndex[1]!)
        let g = NodeIndex(graph.osmToIndex[6]!)
        guard let result = search.search(from: .node(s), to: .node(g), in: graph, cost: cost) else {
            Issue.record("no path S->G"); return
        }
        // The true optimum is 6 via Q. The old node-keyed search returns 104.
        #expect(abs(result.totalCost - 6) < 1e-9,
                "expected turn-aware optimum 6 via Q, got \(result.totalCost)")
        // The route must pass through Q (node 3), not P (node 2).
        let qEdge = directedEdge(3, 4, in: graph)!
        let pEdge = directedEdge(2, 4, in: graph)!
        #expect(result.edgePath.contains(qEdge), "route should approach M via Q")
        #expect(!result.edgePath.contains(pEdge), "route should NOT approach M via the trapped P")
    }

    // MARK: - Reverse-arrival terminal U-turn must be priced

    @Test("reverse arrival that needs a U-turn is NOT chosen over a cheaper-with-turns forward arrival")
    func reverseArrivalUTurnIsPriced() {
        // A two-way destination street A(1) <-> B(2) (~445m, forward A->B heads
        // east). The destination snaps mid-edge NEAR A (~fraction 0.15), so two
        // arrivals exist: FORWARD (reach A, drive 0.15 east to the point) and
        // REVERSE (reach B, take the co-located reverse twin B->A west and drive
        // 0.85 back to the point).
        //
        // The origin O(3) sits near B and reaches B cheaply via O->W->B (way 101),
        // whose final segment W->B heads EAST — so turning onto the reverse twin
        // B->A (which heads WEST) is a physical U-turn. The only U-turn-FREE way to
        // the destination is the forward arrival, reached via the longer detour
        // O->G->A (way 102) whose final segment G->A heads east into A, so the
        // forward continuation A->B is straight.
        //
        // Pre-fix the reverse arrival's trailing partial was charged as pure edge
        // time with NO terminal-maneuver cost, so the cheap-to-reach-B + long
        // reverse partial looked cheaper than the longer forward detour, and the
        // engine returned a route ending in an UNPRICED U-turn. Pricing the terminal
        // maneuver onto the reverse twin (uTurnPenalty=140) makes the reverse
        // arrival honestly expensive, so the forward arrival — genuinely cheaper once
        // every turn is counted — is chosen.
        let graph = buildGraph(
            node(1, 0.0, 0.0),            // A
            node(2, 0.0, 0.004),          // B  (~445m east of A)
            node(3, 0.00004, 0.003),      // O  (origin, near B)
            node(4, 0.00002, 0.0035),     // W  (just west of B, ~2m off the line)
            node(5, 0.0, -0.001),         // G  (west of A, forward feeder)
            way(100, [1, 2], tags: ["highway": "primary", "maxspeed": "45 mph"]),       // A<->B dest street
            way(101, [3, 4, 2], tags: ["highway": "primary", "maxspeed": "45 mph"]),    // O->W->B (arrives east → reverse is a U-turn)
            way(102, [3, 5, 1], tags: ["highway": "primary", "maxspeed": "45 mph"])     // O->G->A (forward feeder, no U-turn)
        )
        let cost = DefaultCostModel()   // production weights: uTurnPenalty=140

        let originNode = NodeIndex(graph.osmToIndex[3]!)
        // Destination ~fraction 0.15 along A->B (near A).
        let dest = CLLocationCoordinate2D(latitude: 0.000005, longitude: 0.0006)
        guard let destSnap = graph.snap(dest, maxDistanceMeters: 200) else {
            Issue.record("destination snap failed"); return
        }
        let nodeA = graph.nodes[Int(graph.osmToIndex[1]!)].coordinate
        let nodeB = graph.nodes[Int(graph.osmToIndex[2]!)].coordinate
        #expect(RouteGeometry.haversineDistance(from: destSnap.snapped, to: nodeA)
                < RouteGeometry.haversineDistance(from: destSnap.snapped, to: nodeB),
                "destination should snap nearer the A-end")

        guard let result = search.search(from: .node(originNode), to: .coordinate(dest), in: graph, cost: cost) else {
            Issue.record("no path"); return
        }

        let destEdge = graph.edges[Int(destSnap.edge)]
        // G and W are MIDDLE vertices of ways 102/101, so the builder folds them into
        // edge geometry rather than emitting graph nodes — way 102 is a single O->A
        // edge (bending through G, arriving at A heading east) and way 101 a single
        // O->B edge (bending through W, arriving at B heading east). Identify arrivals
        // by OSM way, not by an intermediate node.
        // The co-located reverse twin of the destination edge (same OSM way, swapped
        // endpoints) — terminating on it from the east-aligned approach is the
        // unpriced-U-turn signature.
        let reverseTwinPresent = result.edgePath.contains { e in
            let ge = graph.edges[Int(e)]
            return ge.osmWayID == destEdge.osmWayID && ge.from == destEdge.to && ge.to == destEdge.from
        }
        // Forward arrival: the path uses the O->A feeder (way 102) and continues onto
        // the FORWARD destination edge A->B (way 100, A->B), never the reverse twin.
        let viaForwardFeeder = result.edgePath.contains { graph.edges[Int($0)].osmWayID == 102 }
        #expect(viaForwardFeeder, "forward arrival via the O->A feeder (way 102) should be chosen")
        #expect(!reverseTwinPresent, "route must NOT terminate on the reverse twin B->A (an unpriced U-turn)")
        // And it does NOT use the O->B feeder (way 101) that would force the U-turn.
        #expect(!result.edgePath.contains { graph.edges[Int($0)].osmWayID == 101 },
                "route must not use the O->B feeder that requires the terminal U-turn")

        // No U-turn maneuver in the synthesized steps.
        guard let synth = StepSynthesizer.synthesize(result, in: graph) else {
            Issue.record("synthesis failed"); return
        }
        #expect(!synth.steps.contains { $0.instruction.lowercased().contains("u-turn") },
                "the chosen route must not contain a U-turn")

        // The reported cost equals the honest forward-arrival cost (reach A via the
        // feeder, straight onto A->B, 0.15 partial) — well under what an honestly-
        // priced reverse U-turn arrival would cost (which now includes +140).
        let viaNodeA = search.search(from: .node(originNode), to: .node(NodeIndex(graph.osmToIndex[1]!)), in: graph, cost: cost)
        let forwardLowerBound = viaNodeA?.totalCost ?? .infinity
        #expect(result.totalCost >= forwardLowerBound - 1e-6,
                "forward arrival cost should be at least the cost to reach A")
        #expect(result.totalCost < forwardLowerBound + 0.16 * cost.edgeCost(destEdge, in: graph) + 1e-6,
                "forward arrival should add only the ~0.15 forward partial, no U-turn")
    }

    @Test("reverse arrival with NO U-turn still wins the no-overshoot case (regression guard)")
    func reverseArrivalWithoutUTurnPreserved() {
        // Regression guard for the no-overshoot win: when reaching edge.to does NOT
        // require a U-turn onto the reverse twin, the reverse arrival must still be
        // chosen over a full-edge forward overshoot. Mirrors the existing
        // wrong-end fixture but explicitly under the production cost model: origin C
        // feeds the B-end via a connector arriving roughly perpendicular (a normal
        // turn, not a U-turn), so the short reverse partial back to a near-A
        // destination remains the optimal arrival.
        let graph = buildGraph(
            node(1, 0.0, 0.0),        // A
            node(2, 0.0, 0.004),      // B  (~445m east of A)
            node(3, 0.0009, 0.004),   // C  (~100m north of B)
            way(100, [1, 2], tags: ["highway": "primary", "maxspeed": "45 mph"]),  // A<->B long two-way
            way(101, [2, 3], tags: ["highway": "primary", "maxspeed": "45 mph"])   // B<->C connector
        )
        let cost = DefaultCostModel()
        let originNode = NodeIndex(graph.osmToIndex[3]!)
        let dest = CLLocationCoordinate2D(latitude: 0.000005, longitude: 0.0008)   // ~fraction 0.2 from A

        guard let destSnap = graph.snap(dest, maxDistanceMeters: 200),
              let result = search.search(from: .node(originNode), to: .coordinate(dest), in: graph, cost: cost) else {
            Issue.record("no path"); return
        }
        // The route ends at the destination (within snap noise), not a block past it.
        guard let synth = StepSynthesizer.synthesize(result, in: graph) else {
            Issue.record("synthesis failed"); return
        }
        #expect(RouteGeometry.haversineDistance(from: synth.coordinates.last!, to: destSnap.snapped) < 2.0)
        // Approaching B from the north and turning onto B->A is a normal turn, not a
        // U-turn — so the reverse no-overshoot arrival is still taken.
        let longEdge = graph.edges[Int(destSnap.edge)]
        let forwardLong = result.edgePath.contains { e in
            let ge = graph.edges[Int(e)]
            return ge.osmWayID == longEdge.osmWayID && ge.from == graph.osmToIndex[1]! && ge.to == graph.osmToIndex[2]!
        }
        let reverseLong = result.edgePath.contains { e in
            let ge = graph.edges[Int(e)]
            return ge.osmWayID == longEdge.osmWayID && ge.from == graph.osmToIndex[2]! && ge.to == graph.osmToIndex[1]!
        }
        #expect(!(forwardLong && reverseLong), "must not traverse the long edge in BOTH directions (overshoot)")
    }

    @Test("self-touching one-way way: a same-direction co-located arm is NOT mistaken for the reverse twin")
    func selfTouchingOneWayNoFalseReverseTwin() {
        // A self-touching ONE-WAY way 100 visits node A twice: [A, P, B, Q, A] — a
        // one-way loop. A is the way endpoint (always promoted) and B is shared with
        // a second way (way 101 -> C), so B is promoted as an intersection. The
        // builder therefore emits TWO forward edges on way 100: A->B (geometry
        // A,P,B, the upper arm) and B->A (geometry B,Q,A, the lower arm). Both run
        // FORWARD (one-way); B->A is a distinct physical arm, NOT the reverse twin
        // of A->B. Endpoint+wayID matching alone (`rev.to==edge.from &&
        // rev.osmWayID==edge.osmWayID`) wrongly accepts B->A as the reverse twin of
        // A->B; the genuine-reversed-geometry guard rejects it (B,Q,A is not the
        // point-wise reverse of A,P,B). Drives a rectangular loop so the two arms
        // pass through clearly different interior coords (P != Q).
        let graph = buildGraph(
            node(1, 0.000, 0.000),   // A — way endpoint (visited twice)
            node(2, 0.001, 0.000),   // P — interior, upper arm
            node(3, 0.001, 0.002),   // B — intersection (also on way 101)
            node(4, 0.000, 0.002),   // Q — interior, lower arm
            node(5, 0.001, 0.004),   // C — stub past B
            way(100, [1, 2, 3, 4, 1], tags: ["highway": "primary", "oneway": "yes", "maxspeed": "30 mph"]),
            way(101, [3, 5], tags: ["highway": "primary", "maxspeed": "30 mph"])   // promotes B
        )
        let a = NodeIndex(graph.osmToIndex[1]!)
        let b = NodeIndex(graph.osmToIndex[3]!)

        // The self-touching fixture built as intended: forward A->B and forward
        // B->A both exist on way 100 (the two one-way arms of the loop).
        func edgeIndex(from: NodeIndex, to: NodeIndex, way: OSMNodeID) -> EdgeIndex? {
            for (i, e) in graph.edges.enumerated()
            where e.from == from && e.to == to && e.osmWayID == way {
                return EdgeIndex(i)
            }
            return nil
        }
        guard let aToB = edgeIndex(from: a, to: b, way: 100),
              let bToA = edgeIndex(from: b, to: a, way: 100) else {
            Issue.record("self-touching one-way fixture did not emit both A->B and B->A arms on way 100")
            return
        }
        // Sanity: these are the two arms — they are NOT each other's point-wise
        // reverse (P and Q differ), so neither is the other's reverse twin.
        #expect(!CorridorValidator.isReverseTwinGeometry(bToA, of: aToB, in: graph),
                "same-direction arm B->A must NOT be treated as the reverse twin of A->B")
        #expect(!CorridorValidator.isReverseTwinGeometry(aToB, of: bToA, in: graph),
                "same-direction arm A->B must NOT be treated as the reverse twin of B->A")

        // Control: a genuine TWO-WAY street DOES have its reverse twin detected, so
        // the predicate isn't trivially false. Way 200 is two-way A2<->B2 with an
        // interior bend; its forward and reverse edges share reversed geometry.
        let twoWay = buildGraph(
            node(10, 0.0, 0.0),
            node(11, 0.0005, 0.001),   // bend so geometry has >2 vertices
            node(12, 0.0, 0.002),
            way(200, [10, 11, 12], tags: ["highway": "primary", "maxspeed": "30 mph"])
        )
        let n10 = NodeIndex(twoWay.osmToIndex[10]!)
        let n12 = NodeIndex(twoWay.osmToIndex[12]!)
        func twEdge(from: NodeIndex, to: NodeIndex) -> EdgeIndex? {
            for (i, e) in twoWay.edges.enumerated() where e.from == from && e.to == to {
                return EdgeIndex(i)
            }
            return nil
        }
        guard let fwd = twEdge(from: n10, to: n12), let rev = twEdge(from: n12, to: n10) else {
            Issue.record("two-way control fixture missing forward/reverse edges")
            return
        }
        #expect(CorridorValidator.isReverseTwinGeometry(rev, of: fwd, in: twoWay),
                "a genuine two-way reverse twin (reversed geometry) must still be detected")
        #expect(CorridorValidator.isReverseTwinGeometry(fwd, of: rev, in: twoWay))
    }
}
