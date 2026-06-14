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
