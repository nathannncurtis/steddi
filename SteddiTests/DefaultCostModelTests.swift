import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - Fixture helpers (mirrors AStarSearchTests; kept local to this file)

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

/// Find the edge from OSM node `a` to OSM node `b` in travel order.
private func edge(in graph: RoadGraph, from a: Int64, to b: Int64) -> GraphEdge? {
    guard let fromIdx = graph.osmToIndex[a], let toIdx = graph.osmToIndex[b] else { return nil }
    for e in graph.outEdgeRange(of: fromIdx) where graph.edges[Int(e)].to == toIdx {
        return graph.edges[Int(e)]
    }
    return nil
}

// MARK: - Turn classification

@Suite("DefaultCostModel turn classification")
struct TurnClassificationTests {
    // A "+" junction centred at node 1: north(2)/south(3)/east(4)/west(5).
    // Approaching the centre from the south (3 -> 1, heading north).
    private func plusGraph() -> RoadGraph {
        buildGraph(
            node(1, 34.0000, -117.0000),
            node(2, 34.0010, -117.0000),  // north
            node(3, 33.9990, -117.0000),  // south
            node(4, 34.0000, -116.9988),  // east
            node(5, 34.0000, -117.0012),  // west
            way(10, [3, 1, 2], tags: ["highway": "secondary"]),     // S-N through
            way(11, [5, 1, 4], tags: ["highway": "secondary"])      // W-E through
        )
    }

    @Test("Continuing straight is classified straight")
    func straight() {
        let g = plusGraph()
        let incoming = edge(in: g, from: 3, to: 1)!  // heading north
        let outgoing = edge(in: g, from: 1, to: 2)!  // continue north
        #expect(DefaultCostModel.classifyTurn(from: incoming, to: outgoing, in: g) == .straight)
    }

    @Test("Heading north then to the east node is a right turn")
    func right() {
        let g = plusGraph()
        let incoming = edge(in: g, from: 3, to: 1)!  // north
        let outgoing = edge(in: g, from: 1, to: 4)!  // east = right
        #expect(DefaultCostModel.classifyTurn(from: incoming, to: outgoing, in: g) == .right)
    }

    @Test("Heading north then to the west node is a left turn")
    func left() {
        let g = plusGraph()
        let incoming = edge(in: g, from: 3, to: 1)!  // north
        let outgoing = edge(in: g, from: 1, to: 5)!  // west = left
        #expect(DefaultCostModel.classifyTurn(from: incoming, to: outgoing, in: g) == .left)
    }

    @Test("Signed angle: right is positive, left is negative")
    func signedAngle() {
        let g = plusGraph()
        let incoming = edge(in: g, from: 3, to: 1)!
        #expect(DefaultCostModel.signedTurnAngle(from: incoming, to: edge(in: g, from: 1, to: 4)!, in: g) > 0)
        #expect(DefaultCostModel.signedTurnAngle(from: incoming, to: edge(in: g, from: 1, to: 5)!, in: g) < 0)
    }

    @Test("Duplicate consecutive geometry points do not corrupt turn classification")
    func degenerateGeometryDoesNotCorruptTurn() {
        // An E-W through-road crossing a N-S road at the junction node 1. The
        // straight-through maneuver is 2 -> 1 -> 3 (heading WEST the whole way), so
        // the correct classification is `.straight`.
        //
        // The E-W way carries an INTERIOR through-node 6 whose coordinates exactly
        // duplicate the junction node 1's (a real OSM digitizing artifact —
        // RoadGraphBuilder de-dups nothing). That makes the LAST segment of the
        // incoming edge 2->1 zero-length. `RouteGeometry.bearing` of two identical
        // points is a false due-north (0); reading it as the approach bearing would
        // turn the true WEST (~270) approach into a 270 vs west(270) departure that
        // wrongly classifies the straight-through as a hard LEFT and charges a
        // spurious turn penalty. The fix skips the degenerate segment and uses the
        // nearest distinct pair, so the approach reads WEST and the turn stays
        // straight — matching the clean-geometry reference exactly.
        let degenerate = buildGraph(
            node(1, 34.0000, -117.0000),               // junction
            node(2, 34.0000, -116.9980),               // east endpoint
            node(3, 34.0000, -117.0020),               // west endpoint
            node(4, 34.0010, -117.0000),               // north (crossing road)
            node(5, 33.9990, -117.0000),               // south (crossing road)
            node(6, 34.0000, -117.0000),               // through-point DUPLICATING node 1
            way(10, [2, 6, 1, 3], tags: ["highway": "secondary"]),  // E-W with dup node before the junction
            way(11, [4, 1, 5], tags: ["highway": "secondary"])      // N-S crossing road
        )
        // Reference graph: identical layout WITHOUT the duplicate node.
        let clean = buildGraph(
            node(1, 34.0000, -117.0000),
            node(2, 34.0000, -116.9980),
            node(3, 34.0000, -117.0020),
            node(4, 34.0010, -117.0000),
            node(5, 33.9990, -117.0000),
            way(10, [2, 1, 3], tags: ["highway": "secondary"]),
            way(11, [4, 1, 5], tags: ["highway": "secondary"])
        )

        // Sanity: the incoming edge's final geometry segment really is degenerate.
        let dIncomingIdx = Int(directedEdgeIndex(in: degenerate, from: 2, to: 1)!)
        let dCoords = Array(degenerate.geometry(of: Int32(dIncomingIdx)))
        #expect(dCoords.count >= 3)
        #expect(RouteGeometry.haversineDistance(from: dCoords[dCoords.count - 2], to: dCoords[dCoords.count - 1]) == 0,
                "fixture should produce a zero-length trailing segment")

        let dIn = edge(in: degenerate, from: 2, to: 1)!
        let dOut = edge(in: degenerate, from: 1, to: 3)!
        let cIn = edge(in: clean, from: 2, to: 1)!
        let cOut = edge(in: clean, from: 1, to: 3)!

        // The degenerate approach must NOT read as a spurious north bearing: it
        // matches the clean reference and stays straight.
        #expect(DefaultCostModel.classifyTurn(from: dIn, to: dOut, in: degenerate) == .straight,
                "duplicate-point geometry misclassified a straight-through as a turn")
        #expect(DefaultCostModel.classifyTurn(from: dIn, to: dOut, in: degenerate)
                == DefaultCostModel.classifyTurn(from: cIn, to: cOut, in: clean))

        // The signed angle agrees with the clean reference (both ~0), proving the
        // degenerate segment was skipped rather than read as 0/north.
        let dAngle = DefaultCostModel.signedTurnAngle(from: dIn, to: dOut, in: degenerate)
        let cAngle = DefaultCostModel.signedTurnAngle(from: cIn, to: cOut, in: clean)
        #expect(abs(dAngle - cAngle) < 1.0)
        #expect(abs(dAngle) < 12.0)   // genuinely straight, not a ~90 phantom turn

        // And the turn cost is the straight penalty, not a turn/U-turn penalty.
        let node1 = degenerate.nodes[Int(degenerate.osmToIndex[1]!)]
        let turnCost = DefaultCostModel().turnCost(from: dIn, to: dOut, at: node1, in: degenerate)
        #expect(turnCost == CostWeights.default.straightPenalty)
    }

    /// Directed edge index by its (fromOSM -> toOSM) node ids, for geometry checks.
    private func directedEdgeIndex(in graph: RoadGraph, from a: Int64, to b: Int64) -> EdgeIndex? {
        guard let fromIdx = graph.osmToIndex[a], let toIdx = graph.osmToIndex[b] else { return nil }
        for e in graph.outEdgeRange(of: fromIdx) where graph.edges[Int(e)].to == toIdx { return e }
        return nil
    }
}

// MARK: - Protected vs unprotected left

@Suite("DefaultCostModel left-turn cost")
struct LeftTurnCostTests {
    /// Approach node 1 from the south (3->1) and turn left/west toward 5.
    private func graph(signal: Bool, leftLane: Bool, oncomingLanes: Int) -> RoadGraph {
        let nodeTags = signal ? ["highway": "traffic_signals"] : [:]
        var westTags = ["highway": "primary", "lanes": "\(max(2, oncomingLanes * 2))"]
        if leftLane { westTags["turn:lanes"] = "left|through" }
        return buildGraph(
            node(1, 34.0000, -117.0000, tags: nodeTags),
            node(2, 34.0010, -117.0000),
            node(3, 33.9990, -117.0000),
            node(5, 34.0000, -117.0012),
            way(10, [3, 1, 2], tags: ["highway": "primary"]),
            way(11, [1, 5], tags: westTags)
        )
    }

    @Test("Protected left (signal + dedicated left lane) is far cheaper than unprotected")
    func protectedCheaperThanUnprotected() {
        let weights = CostWeights.default
        let model = DefaultCostModel(weights: weights)

        let pg = graph(signal: true, leftLane: true, oncomingLanes: 2)
        let pIn = edge(in: pg, from: 3, to: 1)!
        let pOut = edge(in: pg, from: 1, to: 5)!
        let pNode = pg.nodes[Int(pg.osmToIndex[1]!)]
        let protectedCost = model.turnCost(from: pIn, to: pOut, at: pNode, in: pg)

        let ug = graph(signal: false, leftLane: false, oncomingLanes: 2)
        let uIn = edge(in: ug, from: 3, to: 1)!
        let uOut = edge(in: ug, from: 1, to: 5)!
        let uNode = ug.nodes[Int(ug.osmToIndex[1]!)]
        let unprotectedCost = model.turnCost(from: uIn, to: uOut, at: uNode, in: ug)

        #expect(unprotectedCost > protectedCost)
        // Unprotected base alone should already exceed the protected penalty.
        #expect(unprotectedCost >= weights.unprotectedLeftBase)
    }

    @Test("Unprotected left cost rises with oncoming lanes")
    func scalesWithOncomingLanes() {
        let model = DefaultCostModel()
        let oneLane = graph(signal: false, leftLane: false, oncomingLanes: 1)
        let manyLane = graph(signal: false, leftLane: false, oncomingLanes: 4)
        let c1 = model.turnCost(from: edge(in: oneLane, from: 3, to: 1)!, to: edge(in: oneLane, from: 1, to: 5)!, at: oneLane.nodes[Int(oneLane.osmToIndex[1]!)], in: oneLane)
        let c4 = model.turnCost(from: edge(in: manyLane, from: 3, to: 1)!, to: edge(in: manyLane, from: 1, to: 5)!, at: manyLane.nodes[Int(manyLane.osmToIndex[1]!)], in: manyLane)
        #expect(c4 > c1)
    }

    @Test("Origin maneuver (nil incoming) has zero turn cost")
    func originNoTurn() {
        let g = graph(signal: false, leftLane: false, oncomingLanes: 2)
        let out = edge(in: g, from: 1, to: 5)!
        let node = g.nodes[Int(g.osmToIndex[1]!)]
        #expect(DefaultCostModel().turnCost(from: nil, to: out, at: node, in: g) == 0)
    }

    /// A Y-fork approached from the south (3->1, heading north) that splits into a
    /// SLIGHT-left branch (~25° west of north -> node 5) and a HARD-left branch
    /// (~65° west of north -> node 6) at an unsignalized node. The slight branch is
    /// a benign bear-left that crosses no oncoming flow; the hard branch is a real
    /// unprotected left. Both branches carry a normal `lanes` tag so the hard left
    /// resolves a real oncoming count.
    private func forkGraph() -> RoadGraph {
        buildGraph(
            node(1, 34.0000, -117.0000),
            node(3, 33.9985, -117.0000),               // south approach
            node(5, 34.001359, -117.000765),           // ~25° west of north (slight left)
            node(6, 34.000634, -117.001640),           // ~65° west of north (hard left)
            way(10, [3, 1], tags: ["highway": "secondary"]),
            way(11, [1, 5], tags: ["highway": "secondary", "lanes": "2"]),
            way(12, [1, 6], tags: ["highway": "secondary", "lanes": "2"])
        )
    }

    @Test("Slight-left penalty is far below the full unprotected-left penalty")
    func slightLeftCheaperThanLeft() {
        let g = forkGraph()
        let incoming = edge(in: g, from: 3, to: 1)!
        let slightOut = edge(in: g, from: 1, to: 5)!
        let hardOut = edge(in: g, from: 1, to: 6)!
        let node = g.nodes[Int(g.osmToIndex[1]!)]

        // Self-validate the fixture: the branches really classify slight vs hard.
        #expect(DefaultCostModel.classifyTurn(from: incoming, to: slightOut, in: g) == .slightLeft)
        #expect(DefaultCostModel.classifyTurn(from: incoming, to: hardOut, in: g) == .left)

        let weights = CostWeights.default
        let model = DefaultCostModel(weights: weights)
        let slightCost = model.turnCost(from: incoming, to: slightOut, at: node, in: g)
        let hardCost = model.turnCost(from: incoming, to: hardOut, at: node, in: g)

        // The slight-left fork must NOT be billed the full unprotected-left cost.
        #expect(slightCost < hardCost)
        #expect(slightCost == weights.slightLeftPenalty)
        // The full unprotected-left penalty is preserved for the real (≥40°) left.
        #expect(hardCost >= weights.unprotectedLeftBase)
    }

    @Test("A slight-left fork is not avoided like a hard unprotected left")
    func slightLeftForkNotAvoided() {
        let g = forkGraph()
        let incoming = edge(in: g, from: 3, to: 1)!
        let slightOut = edge(in: g, from: 1, to: 5)!
        let node = g.nodes[Int(g.osmToIndex[1]!)]

        // Even with the unprotected-left penalty cranked sky-high (the UPS signal),
        // a benign slight-left fork stays cheap — it isn't dragged up with hard lefts.
        var weights = CostWeights.default
        weights.unprotectedLeftBase = 500
        weights.unprotectedLeftPerOncomingLane = 50
        let model = DefaultCostModel(weights: weights)
        let slightCost = model.turnCost(from: incoming, to: slightOut, at: node, in: g)

        // A right turn is the cheap baseline the router would otherwise prefer; the
        // slight-left fork must stay within a hair of it, not balloon toward the
        // 500+ hard-left cost that would make the router detour around it.
        #expect(slightCost <= weights.rightTurnPenalty + weights.slightLeftPenalty)
        #expect(slightCost < weights.unprotectedLeftBase)
    }
}

// MARK: - Edge cost: preferences, rush hour

@Suite("DefaultCostModel edge cost")
struct EdgeCostTests {
    private func highwayGraph() -> RoadGraph {
        buildGraph(
            node(1, 34.0000, -117.0000),
            node(2, 34.0100, -117.0000),
            way(10, [1, 2], tags: ["highway": "motorway", "maxspeed": "65 mph"])
        )
    }
    private func tollGraph() -> RoadGraph {
        buildGraph(
            node(1, 34.0000, -117.0000),
            node(2, 34.0100, -117.0000),
            way(10, [1, 2], tags: ["highway": "primary", "toll": "yes", "maxspeed": "45 mph"])
        )
    }

    @Test("avoidsHighways multiplies motorway edge cost")
    func avoidHighways() {
        let g = highwayGraph()
        let e = edge(in: g, from: 1, to: 2)!
        let plain = DefaultCostModel(context: RoutingContext(avoidsHighways: false)).edgeCost(e, in: g)
        let avoid = DefaultCostModel(context: RoutingContext(avoidsHighways: true)).edgeCost(e, in: g)
        #expect(avoid > plain)
    }

    @Test("avoidsTolls adds a penalty to tolled edges only")
    func avoidTolls() {
        let g = tollGraph()
        let e = edge(in: g, from: 1, to: 2)!
        let plain = DefaultCostModel(context: RoutingContext(avoidsTolls: false)).edgeCost(e, in: g)
        let avoid = DefaultCostModel(context: RoutingContext(avoidsTolls: true)).edgeCost(e, in: g)
        #expect(avoid - plain >= CostWeights.default.tollPenalty - 0.001)
    }

    @Test("Rush hour inflates edge time")
    func rushHour() {
        let g = highwayGraph()
        let e = edge(in: g, from: 1, to: 2)!
        let off = DefaultCostModel(context: RoutingContext(departureHour: 13)).edgeCost(e, in: g)
        let rush = DefaultCostModel(context: RoutingContext(departureHour: 8)).edgeCost(e, in: g)
        #expect(rush > off)
    }

    @Test("Edge cost never drops below free-flow time (admissibility invariant)")
    func neverBelowFreeFlow() {
        let g = highwayGraph()
        let e = edge(in: g, from: 1, to: 2)!
        let freeFlow = Double(e.lengthMeters) / Double(e.freeFlowSpeedMPS)
        // Across a matrix of contexts, cost is always >= free-flow time.
        for ctx in [RoutingContext(), RoutingContext(avoidsHighways: true), RoutingContext(avoidsTolls: true), RoutingContext(departureHour: 8)] {
            #expect(DefaultCostModel(context: ctx).edgeCost(e, in: g) >= freeFlow - 0.001)
        }
    }
}

// MARK: - No-go zones

@Suite("DefaultCostModel no-go zones")
struct ZoneCostTests {
    private func lineGraph() -> RoadGraph {
        buildGraph(
            node(1, 34.0000, -117.0000),
            node(2, 34.0050, -117.0000),
            way(10, [1, 2], tags: ["highway": "primary", "maxspeed": "40 mph"])
        )
    }

    @Test("Hard zone over an edge makes it impassable")
    func hardExclude() {
        let g = lineGraph()
        let e = edge(in: g, from: 1, to: 2)!
        let zone = RoutedZone(shape: .circle(center: CLLocationCoordinate2D(latitude: 34.0025, longitude: -117.0000), radiusMeters: 300))
        let cost = DefaultCostModel(context: RoutingContext(hardZones: [zone])).edgeCost(e, in: g)
        #expect(cost == .infinity)
    }

    @Test("Soft zone raises cost but keeps the edge passable")
    func softPenalty() {
        let g = lineGraph()
        let e = edge(in: g, from: 1, to: 2)!
        let zone = RoutedZone(shape: .circle(center: CLLocationCoordinate2D(latitude: 34.0025, longitude: -117.0000), radiusMeters: 300))
        let plain = DefaultCostModel().edgeCost(e, in: g)
        let soft = DefaultCostModel(context: RoutingContext(softZones: [zone])).edgeCost(e, in: g)
        #expect(soft > plain)
        #expect(soft < .infinity)
    }

    @Test("Direct edge-geometry slice matches the index-based RoadGraph lookup")
    func geometryMatchesGraphLookup() {
        // The zone-cost path resolves an edge's geometry in O(1) from the edge's
        // own `geometryRange` instead of an O(degree) edge-index relookup. This is
        // a pure perf change: for EVERY directed edge the direct slice must equal
        // what `RoadGraph.geometry(of: index)` returns. Use a multi-edge junction
        // so several edges share a from-node (the case the relookup scanned).
        let g = buildGraph(
            node(1, 34.0000, -117.0000),
            node(2, 34.0010, -117.0000),  // north
            node(3, 33.9990, -117.0000),  // south
            node(4, 34.0000, -116.9988),  // east
            node(5, 34.0000, -117.0012),  // west
            way(10, [3, 1, 2], tags: ["highway": "secondary"]),
            way(11, [5, 1, 4], tags: ["highway": "secondary"])
        )
        #expect(!g.edges.isEmpty)
        for idx in 0..<g.edges.count {
            let viaIndex = Array(g.geometry(of: Int32(idx)))
            let viaEdge = Array(DefaultCostModel.geometry(of: g.edges[idx], in: g))
            #expect(viaEdge.count == viaIndex.count)
            for (a, b) in zip(viaEdge, viaIndex) {
                #expect(a.latitude == b.latitude)
                #expect(a.longitude == b.longitude)
            }
        }
    }

    @Test("Hard-zone edge cost is unchanged by the direct-slice resolution")
    func hardZoneCostStableAcrossJunction() {
        // Two parallel two-node edges that share NO endpoint, so a zone over one
        // can never touch the other. The old relookup matched an edge by scanning
        // its from-node's out-edges; the direct slice reads the edge's own range.
        // The far edge staying finite while the near edge goes impassable proves
        // the O(1) slice resolves the SAME geometry the index lookup did.
        let g = buildGraph(
            node(1, 34.0000, -117.0000),
            node(2, 34.0020, -117.0000),   // NEAR edge 1->2 (will be zoned)
            node(3, 34.0000, -116.9000),   // far west, well clear (~9 km away)
            node(4, 34.0020, -116.9000),   // FAR edge 3->4
            way(10, [1, 2], tags: ["highway": "secondary"]),
            way(11, [3, 4], tags: ["highway": "secondary"])
        )
        // Zone squarely over the NEAR edge's midpoint; the far edge is ~9 km off.
        let zone = RoutedZone(shape: .circle(
            center: CLLocationCoordinate2D(latitude: 34.0010, longitude: -117.0000),
            radiusMeters: 300
        ))
        let model = DefaultCostModel(context: RoutingContext(hardZones: [zone]))
        let near = edge(in: g, from: 1, to: 2)!
        let far = edge(in: g, from: 3, to: 4)!
        #expect(model.edgeCost(near, in: g) == .infinity)
        #expect(model.edgeCost(far, in: g).isFinite)
    }

    @Test("Polygon point-in-polygon containment")
    func polygonContains() {
        let square = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 2),
            CLLocationCoordinate2D(latitude: 2, longitude: 2),
            CLLocationCoordinate2D(latitude: 2, longitude: 0),
        ]
        #expect(RoutedZone.polygonContains(square, CLLocationCoordinate2D(latitude: 1, longitude: 1)))
        #expect(!RoutedZone.polygonContains(square, CLLocationCoordinate2D(latitude: 3, longitude: 1)))
    }

    // A small square zone straddling the middle of a single straight edge: both
    // edge endpoints are OUTSIDE the polygon, but the road runs straight through
    // it. The vertex-only test would miss this; the segment-crossing test must
    // catch it.
    private func crossSquare() -> [CLLocationCoordinate2D] {
        [
            CLLocationCoordinate2D(latitude: 34.0024, longitude: -117.0001),
            CLLocationCoordinate2D(latitude: 34.0024, longitude: -116.9999),
            CLLocationCoordinate2D(latitude: 34.0026, longitude: -116.9999),
            CLLocationCoordinate2D(latitude: 34.0026, longitude: -117.0001),
        ]
    }

    @Test("Polygon zone catches an edge crossing it with neither endpoint inside")
    func polygonCrossingEdgeExcluded() {
        // lineGraph: a straight S->N edge from (34.0000,-117) to (34.0050,-117).
        // Both endpoints are far outside the tiny mid-edge square.
        let g = lineGraph()
        let e = edge(in: g, from: 1, to: 2)!
        let square = crossSquare()
        #expect(!RoutedZone.polygonContains(square, CLLocationCoordinate2D(latitude: 34.0000, longitude: -117.0000)))
        #expect(!RoutedZone.polygonContains(square, CLLocationCoordinate2D(latitude: 34.0050, longitude: -117.0000)))
        let zone = RoutedZone(shape: .polygon(vertices: square))
        let cost = DefaultCostModel(context: RoutingContext(hardZones: [zone])).edgeCost(e, in: g)
        #expect(cost == .infinity)
    }

    @Test("Polygon zone leaves an edge that does not cross it passable")
    func polygonNonCrossingEdgePassable() {
        // A square well to the east of the S->N edge (which sits at lon -117):
        // no crossing, no vertex inside, no polygon vertex on the road.
        let g = lineGraph()
        let e = edge(in: g, from: 1, to: 2)!
        let away = [
            CLLocationCoordinate2D(latitude: 34.0024, longitude: -116.9000),
            CLLocationCoordinate2D(latitude: 34.0024, longitude: -116.8998),
            CLLocationCoordinate2D(latitude: 34.0026, longitude: -116.8998),
            CLLocationCoordinate2D(latitude: 34.0026, longitude: -116.9000),
        ]
        let zone = RoutedZone(shape: .polygon(vertices: away))
        let cost = DefaultCostModel(context: RoutingContext(hardZones: [zone])).edgeCost(e, in: g)
        #expect(cost < .infinity)
    }

    @Test("segmentsIntersect predicate: crossing, touching, parallel, collinear")
    func segmentIntersectionPredicate() {
        func c(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        // Proper crossing (an X).
        #expect(RoutedZone.segmentsIntersect(c(0, 0), c(2, 2), c(0, 2), c(2, 0)))
        // Disjoint, no crossing.
        #expect(!RoutedZone.segmentsIntersect(c(0, 0), c(0, 1), c(1, 0), c(1, 1)))
        // Parallel, offset.
        #expect(!RoutedZone.segmentsIntersect(c(0, 0), c(2, 0), c(0, 1), c(2, 1)))
        // T-junction: endpoint of one lies on the other.
        #expect(RoutedZone.segmentsIntersect(c(0, 0), c(2, 0), c(1, 0), c(1, 2)))
        // Collinear overlap.
        #expect(RoutedZone.segmentsIntersect(c(0, 0), c(2, 0), c(1, 0), c(3, 0)))
    }

    // A narrow E-W corridor centerline that crosses the S->N road perpendicular
    // at its midpoint (lat 34.0025). The road runs along lon -117.0000; the
    // corridor centerline spans lon -117.0010..-116.9990, so BOTH corridor
    // endpoints are ~90 m from the road (> 30 m width) and BOTH road endpoints
    // (lat 34.0000 / 34.0050) are ~277 m from the centerline. No route vertex is
    // within the buffer, yet the edge runs straight through the corridor.
    private func crossCorridor() -> [CLLocationCoordinate2D] {
        [
            CLLocationCoordinate2D(latitude: 34.0025, longitude: -117.0010),
            CLLocationCoordinate2D(latitude: 34.0025, longitude: -116.9990),
        ]
    }

    @Test("Corridor zone catches an edge crossing it between vertices")
    func corridorCrossingEdgeExcluded() {
        // lineGraph: a straight S->N edge from (34.0000,-117) to (34.0050,-117).
        let g = lineGraph()
        let e = edge(in: g, from: 1, to: 2)!
        let centerline = crossCorridor()
        // Sanity: neither route endpoint is within the 30 m buffer of the corridor.
        let width = 30.0
        for v in [CLLocationCoordinate2D(latitude: 34.0000, longitude: -117.0000),
                  CLLocationCoordinate2D(latitude: 34.0050, longitude: -117.0000)] {
            #expect(RouteGeometry.distance(from: v, toPolyline: centerline) > width)
        }
        let zone = RoutedZone(shape: .corridor(polyline: centerline, widthMeters: width))
        let cost = DefaultCostModel(context: RoutingContext(hardZones: [zone])).edgeCost(e, in: g)
        #expect(cost == .infinity)
    }

    @Test("Corridor zone leaves an edge that does not cross it passable")
    func corridorNonCrossingEdgePassable() {
        // The same E-W corridor, but shifted well east of the road: no crossing,
        // no vertex within the buffer.
        let g = lineGraph()
        let e = edge(in: g, from: 1, to: 2)!
        let away = [
            CLLocationCoordinate2D(latitude: 34.0025, longitude: -116.9010),
            CLLocationCoordinate2D(latitude: 34.0025, longitude: -116.8990),
        ]
        let zone = RoutedZone(shape: .corridor(polyline: away, widthMeters: 30))
        let cost = DefaultCostModel(context: RoutingContext(hardZones: [zone])).edgeCost(e, in: g)
        #expect(cost < .infinity)
    }
}

// MARK: - Access restrictions

@Suite("DefaultCostModel access restrictions")
struct AccessRestrictionCostTests {
    /// A straight S->N road, tagged via `access`.
    private func accessGraph(_ access: String) -> RoadGraph {
        buildGraph(
            node(1, 34.0000, -117.0000),
            node(2, 34.0050, -117.0000),
            way(10, [1, 2], tags: ["highway": "service", "maxspeed": "15 mph", "access": access])
        )
    }

    @Test("access=private edge is impassable (infinite cost)")
    func privateExcluded() {
        let g = accessGraph("private")
        let e = edge(in: g, from: 1, to: 2)!
        #expect(e.attrs.contains(.privateAccess))
        #expect(DefaultCostModel().edgeCost(e, in: g) == .infinity)
    }

    @Test("access=no edge is impassable (infinite cost)")
    func noAccessExcluded() {
        let g = accessGraph("no")
        let e = edge(in: g, from: 1, to: 2)!
        #expect(e.attrs.contains(.privateAccess))
        #expect(DefaultCostModel().edgeCost(e, in: g) == .infinity)
    }

    @Test("access=destination edge is heavily penalized but stays passable")
    func destinationPenalized() {
        let g = accessGraph("destination")
        let e = edge(in: g, from: 1, to: 2)!
        #expect(e.attrs.contains(.destinationOnly))
        let cost = DefaultCostModel().edgeCost(e, in: g)
        let freeFlow = Double(e.lengthMeters) / Double(e.freeFlowSpeedMPS)
        #expect(cost < .infinity)
        #expect(cost - freeFlow >= CostWeights.default.destinationOnlyPenalty - 0.001)
    }

    @Test("A* routes around a private road, even when it is the shorter way")
    func aStarAvoidsPrivateRoad() throws {
        // Two ways from S (node 1) to D (node 9):
        //  - a SHORT direct PRIVATE diagonal 1->9, and
        //  - a longer all-public ring around the block.
        // Layout:
        //   7 --- 8 --- 9(D)
        //   |           |
        //   4           6
        //   |           |
        //   1(S)- 2 --- 3
        // Public ring: 1-2-3-6-9 and 1-4-7-8-9. The direct private diagonal would
        // win on time alone, so it is the temptation A* must refuse.
        let g = buildGraph(
            node(1, 34.0000, -117.0020),
            node(2, 34.0000, -117.0010),
            node(3, 34.0000, -117.0000),
            node(4, 34.0010, -117.0020),
            node(6, 34.0010, -117.0000),
            node(7, 34.0020, -117.0020),
            node(8, 34.0020, -117.0010),
            node(9, 34.0020, -117.0000),
            // Public block ring.
            way(10, [1, 2, 3], tags: ["highway": "residential"]),
            way(11, [3, 6, 9], tags: ["highway": "residential"]),
            way(12, [1, 4, 7], tags: ["highway": "residential"]),
            way(13, [7, 8, 9], tags: ["highway": "residential"]),
            // A short PRIVATE diagonal shortcut straight from S to D.
            way(20, [1, 9], tags: ["highway": "service", "access": "private"])
        )
        let start = SearchEndpoint.node(g.osmToIndex[1]!)
        let dest = SearchEndpoint.node(g.osmToIndex[9]!)
        let search = AStarSearch()
        let result = try #require(search.search(from: start, to: dest, in: g, cost: DefaultCostModel()))
        // The chosen path must not traverse the private way (osmWayID 20).
        let usedPrivate = result.edgePath.contains { g.edges[Int($0)].osmWayID == 20 }
        #expect(!usedPrivate)
        // And the destination is still reached via the public ring.
        #expect(result.nodePath.last == g.osmToIndex[9]!)
    }
}

// MARK: - UPS scenario (end-to-end through A*)

@Suite("DefaultCostModel UPS scenario")
struct UPSScenarioTests {
    /// Two ways to get from the start (S, node 1) to the destination (D, node 9):
    /// a SHORT path that requires a left turn across traffic at a busy unprotected
    /// junction, and a slightly LONGER all-right-turns loop. With a high
    /// unprotected-left penalty, the router should prefer the longer right-turn
    /// path — the UPS principle, generalized.
    ///
    /// Layout (a square block, start at SW corner heading north):
    ///   7 --- 8 --- 9(D)
    ///   |     |     |
    ///   4 --- 5 --- 6
    ///   |     |     |
    ///   1(S)- 2 --- 3
    /// The short route 1->2->5->8->9 needs a left at 8 (heading N, turn W... )
    /// We instead make the natural short route require a left and the detour all rights.
    private func blockGraph() -> RoadGraph {
        buildGraph(
            node(1, 34.0000, -117.0020),
            node(2, 34.0000, -117.0010),
            node(3, 34.0000, -117.0000),
            node(4, 34.0010, -117.0020),
            node(5, 34.0010, -117.0010),
            node(6, 34.0010, -117.0000),
            node(7, 34.0020, -117.0020),
            node(8, 34.0020, -117.0010),
            node(9, 34.0020, -117.0000),
            // horizontal streets
            way(10, [1, 2, 3], tags: ["highway": "secondary"]),
            way(11, [4, 5, 6], tags: ["highway": "secondary"]),
            way(12, [7, 8, 9], tags: ["highway": "secondary"]),
            // vertical streets
            way(13, [1, 4, 7], tags: ["highway": "secondary"]),
            way(14, [2, 5, 8], tags: ["highway": "secondary"]),
            way(15, [3, 6, 9], tags: ["highway": "secondary"])
        )
    }

    @Test("High left penalty routes around via right turns to the same destination")
    func avoidsLeftTurns() throws {
        let g = blockGraph()
        let start = SearchEndpoint.node(g.osmToIndex[1]!)
        let dest = SearchEndpoint.node(g.osmToIndex[9]!)
        let search = AStarSearch()

        // Baseline: pure travel time picks some shortest path (ties possible).
        let baseline = try #require(search.search(from: start, to: dest, in: g, cost: TravelTimeCost()))

        // Crank the unprotected-left penalty way up, zero out rights.
        var weights = CostWeights.default
        weights.unprotectedLeftBase = 300
        weights.unprotectedLeftPerOncomingLane = 0
        weights.rightTurnPenalty = 0
        weights.straightPenalty = 0
        let model = DefaultCostModel(weights: weights)
        let avoided = try #require(search.search(from: start, to: dest, in: g, cost: model))

        // Both reach the destination.
        #expect(avoided.edgePath.last != nil)
        // Count left turns along each path; the left-averse route must have fewer.
        func leftTurns(_ result: SearchResult) -> Int {
            let edges = result.edgePath.map { g.edges[Int($0)] }
            var lefts = 0
            for i in 1..<max(1, edges.count) {
                if DefaultCostModel.classifyTurn(from: edges[i - 1], to: edges[i], in: g) == .left { lefts += 1 }
            }
            return lefts
        }
        #expect(leftTurns(avoided) <= leftTurns(baseline))
    }
}

// MARK: - Admissibility with penalties present

@Suite("DefaultCostModel admissibility")
struct AdmissibilityTests {
    @Test("Heuristic never exceeds true remaining cost under DefaultCostModel")
    func heuristicAdmissible() throws {
        let g = buildGraph(
            node(1, 34.0000, -117.0020),
            node(2, 34.0000, -117.0010),
            node(3, 34.0000, -117.0000),
            node(4, 34.0010, -117.0010),
            way(10, [1, 2, 3], tags: ["highway": "primary", "maxspeed": "50 mph"]),
            way(11, [2, 4], tags: ["highway": "residential"])
        )
        let model = DefaultCostModel(context: RoutingContext(departureHour: 8))  // rush, penalties on
        let target = g.nodes[Int(g.osmToIndex[3]!)].coordinate
        // For every node, h(node -> target) must be <= the cheapest real path cost.
        // The pure-time heuristic uses graphMaxSpeed; with all penalties >= 0 the
        // real cost only grows, so admissibility must hold at every node.
        for n in g.nodes {
            let h = model.heuristic(from: n.coordinate, to: target, in: g)
            #expect(h >= 0)
            // h is distance/maxspeed; real remaining cost >= straight-line/maxspeed.
            let straight = RouteGeometry.haversineDistance(from: n.coordinate, to: target) / Double(g.graphMaxSpeedMPS)
            #expect(abs(h - straight) < 0.001)
        }
    }
}
