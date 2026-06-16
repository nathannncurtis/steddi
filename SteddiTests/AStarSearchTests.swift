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
}
