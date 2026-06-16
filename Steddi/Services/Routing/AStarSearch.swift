import Foundation
import CoreLocation

/// Where a search begins or ends. Either a graph node directly, or an arbitrary
/// coordinate that the search snaps onto the nearest edge (the common case —
/// origin/destination are GPS coords, not graph nodes; §3.7, §4.1).
enum SearchEndpoint: Sendable {
    /// Start/end exactly at a graph node.
    case node(NodeIndex)
    /// Start/end at an arbitrary coordinate, snapped onto the nearest edge.
    case coordinate(CLLocationCoordinate2D, heading: Double?)

    static func coordinate(_ c: CLLocationCoordinate2D) -> SearchEndpoint {
        .coordinate(c, heading: nil)
    }
}

/// A solved path: the sequence of graph edges taken, the node sequence, and the
/// total accumulated cost (seconds-equivalent). For a mid-edge start/end the
/// terminal edges are partial — `startFraction`/`endFraction` record where on
/// the first/last edge the path actually begins/ends so the step synthesizer
/// (Phase 5) can trim geometry.
struct SearchResult: Sendable, Equatable {
    /// Graph nodes visited, in order. For a mid-edge start the first node is the
    /// downstream end of the start edge; for a mid-edge end the last node is the
    /// upstream end of the end edge.
    let nodePath: [NodeIndex]
    /// Graph edges traversed, in order. `nodePath.count == edgePath.count + 1`
    /// when both endpoints are graph nodes; mid-edge endpoints add a partial
    /// leading/trailing edge.
    let edgePath: [EdgeIndex]
    /// Total cost in the cost model's currency (seconds-equivalent).
    let totalCost: Double
    /// Fraction (0...1) along `edgePath.first` at which travel begins, for a
    /// mid-edge start. 0 when the start is a graph node.
    let startFraction: Double
    /// Fraction (0...1) along `edgePath.last` at which travel ends, for a
    /// mid-edge end. 1 when the end is a graph node.
    let endFraction: Double
}

/// The pluggable cost interface the search consults. Phase 3 drives A* with a
/// trivial fixed implementation (`TravelTimeCost`, pure travel time + zero turn
/// cost) so the search is validated independently of the real cost model;
/// Phase 4's `CostModel` conforms to the same shape so it drops in unchanged.
///
/// Kept deliberately minimal — three pure functions, all in seconds-equivalent.
/// `heuristic` MUST be an admissible lower bound (≤ true remaining cost) or A*
/// loses optimality; this is asserted in tests (§4.1).
///
/// `Sendable`: a resolved cost model is captured by the `Task.detached` that runs
/// the search off the main actor (`CustomRouter.generateRoute`), so it crosses an
/// isolation boundary. Conformers are value-like cost models (their stored state
/// is itself `Sendable` — `CostWeights`/`RoutingContext`), so the bound is safe
/// and makes the cross-actor capture sound under Swift 6 strict concurrency.
protocol SearchCost: Sendable {
    /// Cost of traversing one edge.
    func edgeCost(_ edge: GraphEdge, in graph: RoadGraph) -> Double
    /// Cost of the maneuver from `incoming` to `outgoing` through their shared
    /// node. nil incoming means the search is at its origin (no predecessor edge,
    /// hence no turn). The node is passed so signal/stop attributes feed the cost.
    func turnCost(from incoming: GraphEdge?, to outgoing: GraphEdge, at node: GraphNode, in graph: RoadGraph) -> Double
    /// Admissible lower bound on remaining cost from `node`'s coordinate to the
    /// target coordinate.
    func heuristic(from coordinate: CLLocationCoordinate2D, to target: CLLocationCoordinate2D, in graph: RoadGraph) -> Double
}

/// The Phase-3 fixed trivial cost: pure free-flow travel time, zero turn cost.
/// `h = haversine / graphMaxSpeedMPS` — a time heuristic that never
/// overestimates (nothing is faster than the fastest road in a straight line),
/// so A* stays optimal and reduces exactly to Dijkstra-with-a-heuristic. This is
/// the reference cost for differential testing against brute-force Dijkstra.
struct TravelTimeCost: SearchCost {
    init() {}

    func edgeCost(_ edge: GraphEdge, in graph: RoadGraph) -> Double {
        let speed = Double(edge.freeFlowSpeedMPS)
        guard speed > 0 else { return .infinity }
        return Double(edge.lengthMeters) / speed
    }

    func turnCost(from incoming: GraphEdge?, to outgoing: GraphEdge, at node: GraphNode, in graph: RoadGraph) -> Double {
        0
    }

    func heuristic(from coordinate: CLLocationCoordinate2D, to target: CLLocationCoordinate2D, in graph: RoadGraph) -> Double {
        let maxSpeed = Double(graph.graphMaxSpeedMPS)
        guard maxSpeed > 0 else { return 0 }
        return RouteGeometry.haversineDistance(from: coordinate, to: target) / maxSpeed
    }
}

/// A graph search that turns two endpoints into an edge path. The protocol so
/// the search is swappable (A* now, bidirectional A* later) and so cost-model
/// tests can drive a reference implementation (§4.1).
protocol PathSearch {
    func search(
        from origin: SearchEndpoint,
        to destination: SearchEndpoint,
        in graph: RoadGraph,
        cost: SearchCost
    ) -> SearchResult?
}

/// Unidirectional A* over the CSR `RoadGraph` with an admissible time heuristic
/// (§4.1). The shipping search for v1.
///
/// Key design points carried from the spec:
/// - **Open set:** the indexed `BinaryHeap` keyed by `f = g + h`.
/// - **Edge-keyed state.** Turn costs depend on `(incoming edge → node →
///   outgoing edge)`, so the node alone is NOT a valid search state: a node-keyed
///   search commits to a single incoming edge per node and can never trade a
///   costlier approach for a cheaper downstream turn, which breaks turn-aware
///   optimality (the engine's whole purpose). The state is therefore the
///   **directed edge just traversed** — `g[e]` is the optimal cost to arrive
///   having crossed edge `e` (i.e. standing at `e.to`). Two different approach
///   edges to the same node are distinct states, so the search keeps both and
///   picks whichever yields the cheaper continuation. Exact for any turn penalty
///   that depends on the immediate predecessor edge (everything in §5.1).
/// - **Dense state:** g-scores, came-from edge, and closed flag are `[Double]` /
///   `[Int32]` arrays indexed by `EdgeIndex` (into `graph.edges`), not
///   dictionaries — CSR + dense arrays is the whole performance point.
/// - **Snap-to-graph overlay.** Arbitrary coordinates are snapped onto an edge
///   (`GraphSpatialIndex.snap`), and the search runs on a thin overlay that
///   splices the mid-edge start/end without mutating the shared, cacheable
///   `RoadGraph` value.
struct AStarSearch: PathSearch {

    /// Max snap distance for endpoint coordinates. Generous — origin/destination
    /// can be a parking lot away from the nearest routable edge.
    var snapMaxDistanceMeters: Double = 200

    init(snapMaxDistanceMeters: Double = 200) {
        self.snapMaxDistanceMeters = snapMaxDistanceMeters
    }

    func search(
        from origin: SearchEndpoint,
        to destination: SearchEndpoint,
        in graph: RoadGraph,
        cost: SearchCost
    ) -> SearchResult? {
        guard !graph.nodes.isEmpty else { return nil }

        // Resolve both endpoints to a concrete graph node plus the partial-edge
        // bookkeeping the overlay needs.
        guard let start = resolveOrigin(origin, in: graph, cost: cost),
              let goal = resolveDestination(destination, in: graph, cost: cost) else {
            return nil
        }

        // Degenerate: origin and goal collapse to the same node and there is no
        // leading/trailing partial edge to stitch — empty path at the cost of
        // the (possibly partial) start edge alone, handled below in `reconstruct`.
        let target = goal.targetCoordinate

        // Same-edge / same-physical-road degenerate: origin and destination snap
        // onto the same physical street and the whole journey lives inside one
        // directed edge, so A* must not run — reaching `goal.node` the long way
        // would synthesize a full overshoot + U-turn (a topologically valid but
        // markedly suboptimal round-trip). Pick the directed edge along which the
        // origin precedes the destination and return the direct sub-edge path.
        //
        // Two cases collapse here:
        //  1. Both snap to the SAME directed edge with start at/behind the end
        //     (origin upstream of destination) — use that edge directly.
        //  2. Both snap to the two opposite directed edges of a TWO-WAY street and
        //     the natural forward approach reaches the destination from DOWNSTREAM
        //     (origin ahead of destination). Terminating on the forward edge would
        //     force the driver to the block end and U-turn back; instead terminate
        //     on the co-located REVERSE edge so the route stops at the destination
        //     from whichever side is reached first (a short reverse, no U-turn).
        // One-way correctness is preserved: a one-way street has no co-located
        // reverse edge, so case 2 never fires against it.
        if let direct = sameRoadDirectPath(start: start, goal: goal, in: graph, cost: cost) {
            return direct
        }

        // Edge-keyed A*: the state is the directed edge just traversed (we are
        // standing at `edge.to`). `gScore[e]` is the optimal cost to arrive having
        // crossed edge `e`; `cameFromEdge[e]` is the edge crossed immediately
        // before `e` (-1 if `e` is a seed edge with no predecessor). This keeps
        // distinct approach edges to the same node as distinct states so a costlier
        // approach can win when it enables a cheaper downstream turn.
        let edgeCount = graph.edges.count
        var gScore = [Double](repeating: .infinity, count: edgeCount)
        var cameFromEdge = [Int32](repeating: -1, count: edgeCount)   // predecessor edge index
        var closed = [Bool](repeating: false, count: edgeCount)

        var heap = BinaryHeap<Double>(minimumCapacity: edgeCount)

        // Map each goal-arrival node to its arrival(s), so the loop can recognise
        // every legal termination — for a two-way mid-edge destination that is BOTH
        // the forward upstream node and the reverse upstream node. The best total
        // (settled g + that arrival's trailing cost) across all goal nodes is the
        // answer; because the two arrivals carry DIFFERENT trailing costs and the
        // heuristic targets the destination point (not a node), the first goal edge
        // popped is not automatically optimal, so we keep the best candidate and
        // stop only once the heap can no longer beat it (standard multi-goal A*
        // with goal-dependent terminal cost; see the loop's exit condition).
        var goalNodes: [NodeIndex: [GoalArrival]] = [:]
        for arrival in goal.arrivals {
            goalNodes[arrival.node, default: []].append(arrival)
        }

        // The best destination arrival found so far: its total cost, the edge whose
        // traversal reached the goal node (-1 for a degenerate node-start arrival),
        // and which arrival orientation it used.
        var bestTotal = Double.infinity
        var bestArrivalEdge: EdgeIndex = -1
        var bestArrival: GoalArrival? = nil

        func consider(arrivalEdge: EdgeIndex, gAtNode: Double, arrivals: [GoalArrival]) {
            for arrival in arrivals {
                let total = gAtNode + arrival.trailingCost
                if total < bestTotal {
                    bestTotal = total
                    bestArrivalEdge = arrivalEdge
                    bestArrival = arrival
                }
            }
        }

        // Degenerate node-start arrival: a node start whose node IS already a goal
        // arrival node. No edge is traversed, so there is no edge state to settle —
        // it is a candidate at cost `entry.g` plus that arrival's trailing partial.
        for entry in start.entries where entry.viaEdge < 0 {
            if let arrivals = goalNodes[entry.node] {
                consider(arrivalEdge: -1, gAtNode: entry.g, arrivals: arrivals)
            }
        }

        // Seed the open set. A mid-edge start arrives having "traversed" its
        // leading partial edge, so its edge state is that edge directly. A node
        // start has no incoming edge, so relax each out-edge of the start node
        // with a nil-incoming turn (the origin maneuver) to produce the first edge
        // states.
        for entry in start.entries {
            if entry.viaEdge >= 0 {
                let e = Int(entry.viaEdge)
                if entry.g < gScore[e] {
                    gScore[e] = entry.g
                    cameFromEdge[e] = -1
                    let h = cost.heuristic(from: graph.nodes[Int(entry.node)].coordinate, to: target, in: graph)
                    heap.push(e, priority: entry.g + h)
                }
            } else {
                let startNode = entry.node
                let node = graph.nodes[Int(startNode)]
                for edgeIndex in graph.outEdgeRange(of: startNode) {
                    let edge = graph.edges[Int(edgeIndex)]
                    let stepEdge = cost.edgeCost(edge, in: graph)
                    guard stepEdge.isFinite else { continue }
                    let stepTurn = cost.turnCost(from: nil, to: edge, at: node, in: graph)
                    guard stepTurn.isFinite else { continue }
                    let g = entry.g + stepEdge + stepTurn
                    let e = Int(edgeIndex)
                    if g < gScore[e] {
                        gScore[e] = g
                        cameFromEdge[e] = -1
                        let h = cost.heuristic(from: graph.nodes[Int(edge.to)].coordinate, to: target, in: graph)
                        heap.push(e, priority: g + h)
                    }
                }
            }
        }

        while let popped = heap.popMin() {
            // Optimality cut-off: every edge still in (or yet to enter) the open set
            // has f = g + h ≤ its true total cost to the destination point (h is an
            // admissible lower bound). Once the smallest such f cannot beat the best
            // arrival already found, no remaining path can either — stop. This is
            // the multi-goal generalisation of A*'s single-goal "first pop wins":
            // with goal-dependent trailing costs the first goal edge popped need not
            // be optimal, but this bound still guarantees the returned arrival is.
            if popped.priority >= bestTotal { break }

            let currentEdgeIndex = Int32(popped.id)
            if closed[Int(currentEdgeIndex)] { continue }
            closed[Int(currentEdgeIndex)] = true

            let currentEdge = graph.edges[Int(currentEdgeIndex)]
            let v = currentEdge.to   // node we are standing at, having crossed this edge

            // Goal reached: arrived at a goal arrival node via this edge. Record it
            // as a candidate (the trailing partial cost is added here so it never
            // perturbs the heuristic) and keep searching — a cheaper arrival, on this
            // or the opposite orientation, may still settle before the cut-off above.
            if let arrivals = goalNodes[v] {
                consider(arrivalEdge: currentEdgeIndex, gAtNode: gScore[Int(currentEdgeIndex)], arrivals: arrivals)
            }

            let gCurrent = gScore[Int(currentEdgeIndex)]
            let vNode = graph.nodes[Int(v)]

            for outIndex in graph.outEdgeRange(of: v) {
                let out = graph.edges[Int(outIndex)]
                if closed[Int(outIndex)] { continue }

                let stepEdge = cost.edgeCost(out, in: graph)
                guard stepEdge.isFinite else { continue }
                let stepTurn = cost.turnCost(from: currentEdge, to: out, at: vNode, in: graph)
                guard stepTurn.isFinite else { continue }

                let tentativeG = gCurrent + stepEdge + stepTurn
                if tentativeG < gScore[Int(outIndex)] {
                    gScore[Int(outIndex)] = tentativeG
                    cameFromEdge[Int(outIndex)] = currentEdgeIndex
                    let h = cost.heuristic(from: graph.nodes[Int(out.to)].coordinate, to: target, in: graph)
                    heap.push(Int(outIndex), priority: tentativeG + h)
                }
            }
        }

        // Settle the best arrival found (if any). For the reverse-orientation
        // arrival on a two-way destination edge this terminates at `edge.to` and
        // takes the short trailing partial back to the destination point, instead
        // of routing to `edge.from` and traversing the whole edge.
        guard let arrival = bestArrival else { return nil }
        return reconstruct(
            arrival: arrival,
            arrivalEdge: bestArrivalEdge,
            gAtGoal: bestTotal - arrival.trailingCost,
            cameFromEdge: cameFromEdge,
            start: start,
            in: graph
        )
    }

    // MARK: - Same-road direct sub-segment

    /// The co-located REVERSE directed edge of `edgeIndex` on a two-way street:
    /// the edge over the same physical OSM way that runs in the opposite direction
    /// (`from`/`to` swapped). Identified by matching `osmWayID` so a genuinely
    /// distinct parallel road is never mistaken for the reverse twin. Returns -1
    /// when none exists — most importantly for a ONE-WAY street, which emits only
    /// one directed edge, so a search can never terminate against its flow.
    private func coLocatedReverseEdge(of edgeIndex: Int32, in graph: RoadGraph) -> Int32 {
        guard edgeIndex >= 0, Int(edgeIndex) < graph.edges.count else { return -1 }
        let edge = graph.edges[Int(edgeIndex)]
        for candidate in graph.outEdgeRange(of: edge.to) {
            let rev = graph.edges[Int(candidate)]
            if rev.to == edge.from && rev.osmWayID == edge.osmWayID {
                return candidate
            }
        }
        return -1
    }

    /// When the origin and destination snap onto the same physical street and the
    /// entire trip lives inside one directed edge, return the direct sub-segment
    /// path instead of running A* (which would route a full overshoot + U-turn).
    /// Returns nil when the endpoints are not on the same physical road, or when
    /// they ARE on the same forward edge but the destination is upstream of the
    /// origin AND no reverse edge exists to reach it (a genuine one-way overshoot
    /// the search must resolve normally). The chosen directed edge is whichever
    /// one places the origin fraction at/behind the destination fraction.
    private func sameRoadDirectPath(
        start: ResolvedOrigin,
        goal: ResolvedGoal,
        in graph: RoadGraph,
        cost: SearchCost
    ) -> SearchResult? {
        guard start.leadingEdge >= 0, goal.trailingEdge >= 0 else { return nil }

        // Case 1: both endpoints on the SAME directed edge with the origin at/behind
        // the destination — the journey is the forward sub-segment of that edge.
        if start.leadingEdge == goal.trailingEdge, start.startFraction <= goal.endFraction {
            return directSubSegment(
                edgeIndex: start.leadingEdge,
                from: start.startFraction,
                to: goal.endFraction,
                in: graph,
                cost: cost
            )
        }

        // Case 2: origin and destination snapped onto the same physical street but
        // the origin is AHEAD of the destination along the bound directed edge —
        // either both on the same forward edge with `startFraction > endFraction`,
        // or each bound to one of the two opposite directed edges of the two-way.
        // Both reduce to: travel runs the OPPOSITE way down the street. Re-express
        // the trip on the co-located reverse edge of the origin's leading edge.
        // On that reverse edge the origin sits at fraction `1 - startFraction` and
        // the destination at `1 - endFraction` (when the destination was bound to
        // the same forward edge as the origin) or directly at `endFraction` (when
        // it was already bound to that reverse edge). Whichever, the result is a
        // short reverse sub-segment that stops at the destination from the side
        // first reached — no overshoot, no U-turn. A one-way street has no reverse
        // edge, so this never fires against its flow.
        let reverse = coLocatedReverseEdge(of: start.leadingEdge, in: graph)
        guard reverse >= 0 else { return nil }
        let reverseStart = 1 - start.startFraction
        let reverseEnd: Double
        if goal.trailingEdge == start.leadingEdge {
            // Destination bound to the SAME forward edge as the origin: its position
            // on the reverse edge is the complement of its forward fraction.
            reverseEnd = 1 - goal.endFraction
        } else if goal.trailingEdge == reverse {
            // Destination already bound to the reverse edge: use its fraction as-is.
            reverseEnd = goal.endFraction
        } else {
            return nil
        }
        guard reverseStart <= reverseEnd else { return nil }
        return directSubSegment(
            edgeIndex: reverse,
            from: reverseStart,
            to: reverseEnd,
            in: graph,
            cost: cost
        )
    }

    /// The single-edge sub-segment path from fraction `from` to `to` along one
    /// directed edge. `from <= to` is the caller's contract.
    private func directSubSegment(
        edgeIndex: Int32,
        from: Double,
        to: Double,
        in graph: RoadGraph,
        cost: SearchCost
    ) -> SearchResult {
        let edge = graph.edges[Int(edgeIndex)]
        let full = cost.edgeCost(edge, in: graph)
        let subCost = full.isFinite ? full * (to - from) : .infinity
        return SearchResult(
            nodePath: [edge.from, edge.to],
            edgePath: [edgeIndex],
            totalCost: subCost,
            startFraction: from,
            endFraction: to
        )
    }

    // MARK: - Endpoint resolution (snap overlay)

    /// A resolved origin: one or more graph nodes the search may start from, each
    /// with the initial `g` cost of reaching it (0 for a node start; the partial
    /// edge time for a mid-edge start) and the edge that "led" to it (for turn
    /// context and reconstruction).
    private struct ResolvedOrigin {
        struct Entry {
            let node: NodeIndex
            let g: Double
            /// The (partial) start edge index, or -1 for a node start. Used as
            /// the incoming-edge for the first real turn, and as the leading edge
            /// in the reconstructed path.
            let viaEdge: Int32
        }
        let entries: [Entry]
        /// Fraction along the leading partial edge at which travel begins (0 for
        /// a node start).
        let startFraction: Double
        /// The leading partial edge index, or -1 for a node start.
        let leadingEdge: Int32
    }

    /// One way the search may legally arrive at the destination: the graph node it
    /// must reach, the trailing partial edge taken from that node to the snapped
    /// end (or -1 for a node destination), the end fraction along that edge, and
    /// the extra (trailing) cost charged on arrival. A mid-edge destination on a
    /// TWO-WAY street offers two such arrivals — one per directed orientation —
    /// so the search can stop on whichever side it reaches more cheaply instead of
    /// being forced to the single upstream node and overshooting a long edge.
    private struct GoalArrival {
        let node: NodeIndex
        let trailingEdge: Int32
        let endFraction: Double
        /// Partial trailing-edge time from `node` to the snapped end. Added in
        /// reconstruct so it never perturbs the heuristic.
        let trailingCost: Double
    }

    /// A resolved destination: the PRIMARY (forward) arrival A* aims at, plus any
    /// co-located alternate arrivals (the reverse twin of a two-way destination
    /// edge), and the coordinate the heuristic aims at — the snapped destination
    /// point itself, an admissible lower-bound target shared by every arrival.
    private struct ResolvedGoal {
        /// The forward arrival's upstream graph node. Also the node `sameRoadDirectPath`
        /// and the degenerate node-start exit compare against.
        let node: NodeIndex
        let trailingEdge: Int32
        let endFraction: Double
        let trailingCost: Double
        let targetCoordinate: CLLocationCoordinate2D
        /// Every legal arrival, primary first. For a node destination or a one-way
        /// mid-edge destination this is a single element; a two-way mid-edge
        /// destination adds the reverse-orientation arrival.
        let arrivals: [GoalArrival]
    }

    private func resolveOrigin(_ endpoint: SearchEndpoint, in graph: RoadGraph, cost: SearchCost) -> ResolvedOrigin? {
        switch endpoint {
        case .node(let n):
            // Bounds-check both ends: NodeIndex is Int32, so a negative `.node(-1)`
            // is representable and would otherwise pass an upper-bound-only guard
            // and trap on the negative array subscript. Mirror the snap-edge guards
            // below (`>= 0 && < count`) and fail clean instead.
            guard n >= 0, Int(n) < graph.nodes.count else { return nil }
            return ResolvedOrigin(
                entries: [.init(node: n, g: 0, viaEdge: -1)],
                startFraction: 0,
                leadingEdge: -1
            )

        case .coordinate(let coord, let heading):
            guard let snap = graph.snap(coord, heading: heading, maxDistanceMeters: snapMaxDistanceMeters) else {
                return nil
            }
            guard snap.edge >= 0, Int(snap.edge) < graph.edges.count else { return nil }
            let edge = graph.edges[Int(snap.edge)]
            guard Int(edge.to) >= 0, Int(edge.to) < graph.nodes.count,
                  Int(edge.from) >= 0, Int(edge.from) < graph.nodes.count else { return nil }
            // Boundary snap: the projected foot landed exactly on a vertex, so the
            // origin IS a graph node, not a mid-edge point. Resolve it as a node
            // start (no leading partial edge) — otherwise the leading edge is drawn
            // in full from `edge.from`, overshooting the real origin by a block.
            //  - fraction >= 1 ⇒ snapped to the edge's TO node: stand at `edge.to`.
            //  - fraction <= 0 ⇒ snapped to the edge's FROM node: stand at `edge.from`.
            if snap.fraction >= 1 {
                return ResolvedOrigin(
                    entries: [.init(node: edge.to, g: 0, viaEdge: -1)],
                    startFraction: 0,
                    leadingEdge: -1
                )
            }
            if snap.fraction <= 0 {
                return ResolvedOrigin(
                    entries: [.init(node: edge.from, g: 0, viaEdge: -1)],
                    startFraction: 0,
                    leadingEdge: -1
                )
            }
            // Mid-edge start: travel runs from the snapped point to the edge's
            // downstream node (`edge.to`). Its partial cost is the edge cost
            // scaled by the remaining fraction (1 - snap.fraction).
            let full = cost.edgeCost(edge, in: graph)
            let partial = full.isFinite ? full * (1 - snap.fraction) : .infinity
            guard partial.isFinite else { return nil }
            return ResolvedOrigin(
                entries: [.init(node: edge.to, g: partial, viaEdge: snap.edge)],
                startFraction: snap.fraction,
                leadingEdge: snap.edge
            )
        }
    }

    private func resolveDestination(_ endpoint: SearchEndpoint, in graph: RoadGraph, cost: SearchCost) -> ResolvedGoal? {
        switch endpoint {
        case .node(let n):
            // Symmetric lower-bound guard (see resolveOrigin): a negative
            // `.node(-1)` is a representable Int32 and must fail clean, not trap on
            // the negative `graph.nodes` subscript.
            guard n >= 0, Int(n) < graph.nodes.count else { return nil }
            return ResolvedGoal(
                node: n,
                trailingEdge: -1,
                endFraction: 1,
                trailingCost: 0,
                targetCoordinate: graph.nodes[Int(n)].coordinate,
                arrivals: [GoalArrival(node: n, trailingEdge: -1, endFraction: 1, trailingCost: 0)]
            )

        case .coordinate(let coord, let heading):
            guard let snap = graph.snap(coord, heading: heading, maxDistanceMeters: snapMaxDistanceMeters) else {
                return nil
            }
            guard snap.edge >= 0, Int(snap.edge) < graph.edges.count else { return nil }
            let edge = graph.edges[Int(snap.edge)]
            guard Int(edge.from) >= 0, Int(edge.from) < graph.nodes.count,
                  Int(edge.to) >= 0, Int(edge.to) < graph.nodes.count else { return nil }
            // Boundary snap: the projected foot landed exactly on a vertex, so the
            // destination IS a graph node, not a mid-edge point. Resolve it as a
            // node end (no trailing partial edge) — otherwise the trailing edge is
            // drawn/charged in full and the route overshoots the real destination
            // by a block, terminating at the wrong vertex.
            //  - fraction <= 0 ⇒ snapped to the edge's FROM node: terminate AT
            //    `edge.from` (the overshoot bug: previously appended the whole edge
            //    to `edge.to`).
            //  - fraction >= 1 ⇒ snapped to the edge's TO node: terminate AT
            //    `edge.to` directly rather than reaching `edge.from` and crossing
            //    the full phantom edge.
            if snap.fraction <= 0 {
                return ResolvedGoal(
                    node: edge.from,
                    trailingEdge: -1,
                    endFraction: 1,
                    trailingCost: 0,
                    targetCoordinate: graph.nodes[Int(edge.from)].coordinate,
                    arrivals: [GoalArrival(node: edge.from, trailingEdge: -1, endFraction: 1, trailingCost: 0)]
                )
            }
            if snap.fraction >= 1 {
                return ResolvedGoal(
                    node: edge.to,
                    trailingEdge: -1,
                    endFraction: 1,
                    trailingCost: 0,
                    targetCoordinate: graph.nodes[Int(edge.to)].coordinate,
                    arrivals: [GoalArrival(node: edge.to, trailingEdge: -1, endFraction: 1, trailingCost: 0)]
                )
            }
            // Mid-edge end. The FORWARD arrival reaches the edge's upstream node
            // (`edge.from`) and travels `snap.fraction` of the edge to the snapped
            // point. On a TWO-WAY street the co-located reverse twin gives a SECOND,
            // equally-valid arrival: reach the reverse edge's upstream node
            // (`edge.to`) and travel `1 - snap.fraction` of it back to the SAME
            // point. Offering both lets A* terminate on whichever side it reaches
            // more cheaply, so a destination near the `to`-end of a long edge no
            // longer forces a full-edge traversal to `edge.from` plus a U-turn.
            //
            // The heuristic aims at the snapped destination POINT (not either node):
            // it stays an admissible lower bound for both arrivals, since every edge
            // cost is >= its free-flow time >= straight-line/maxSpeed and the
            // straight line to the point never exceeds the real remaining cost
            // through either node's trailing partial.
            let full = cost.edgeCost(edge, in: graph)
            let partial = full.isFinite ? full * snap.fraction : .infinity
            guard partial.isFinite else { return nil }

            var arrivals = [GoalArrival(
                node: edge.from,
                trailingEdge: snap.edge,
                endFraction: snap.fraction,
                trailingCost: partial
            )]

            // Reverse-orientation arrival, when a co-located reverse twin exists
            // (always for a two-way street, never for a one-way — preserving
            // one-way correctness). The destination point sits at fraction
            // `1 - snap.fraction` along the reverse edge.
            let reverse = coLocatedReverseEdge(of: snap.edge, in: graph)
            if reverse >= 0 {
                let revEdge = graph.edges[Int(reverse)]
                let revFull = cost.edgeCost(revEdge, in: graph)
                let revFraction = 1 - snap.fraction
                let revPartial = revFull.isFinite ? revFull * revFraction : .infinity
                if revPartial.isFinite {
                    arrivals.append(GoalArrival(
                        node: revEdge.from,   // == edge.to
                        trailingEdge: reverse,
                        endFraction: revFraction,
                        trailingCost: revPartial
                    ))
                }
            }

            return ResolvedGoal(
                node: edge.from,
                trailingEdge: snap.edge,
                endFraction: snap.fraction,
                trailingCost: partial,
                targetCoordinate: snap.snapped,
                arrivals: arrivals
            )
        }
    }

    // MARK: - Reconstruction

    private func reconstruct(
        arrival: GoalArrival,
        arrivalEdge: EdgeIndex,
        gAtGoal: Double,
        cameFromEdge: [Int32],
        start: ResolvedOrigin,
        in graph: RoadGraph
    ) -> SearchResult {
        // Walk the edge-keyed `cameFromEdge` back from the arrival edge to a seed
        // edge. Each step collects the traversed edge and the node it departed
        // from; the chain terminates at a seed edge (predecessor -1). The leading
        // partial start edge, when it is the seed, is included by this walk (it is
        // a real edge state) — we must NOT also prepend it below, so the leading
        // edge is prepended only for a NODE start (where no edge state carries it).
        var edges: [EdgeIndex] = []
        var nodes: [NodeIndex] = [arrival.node]

        var current = arrivalEdge   // -1 only for the degenerate node-start == goal case
        while current >= 0 {
            edges.append(current)
            let predecessor = graph.edges[Int(current)].from
            nodes.append(predecessor)
            current = cameFromEdge[Int(current)]
        }

        // We built the path goal→origin; reverse to origin→goal order.
        edges.reverse()
        nodes.reverse()

        // For a NODE start the first interior edge already begins at the start
        // node, so nothing is prepended. For a MID-EDGE start the leading partial
        // edge IS the seed edge and is therefore already the first element of
        // `edges` (with its `from` node leading `nodes`) — also nothing to add.
        // The leading edge is never double-counted.

        // Append the trailing partial end edge, if any. For the reverse-orientation
        // arrival this is the co-located REVERSE directed edge (from the goal node
        // `edge.to` back toward `edge.from`), trimmed to `endFraction`.
        if arrival.trailingEdge >= 0 {
            edges.append(arrival.trailingEdge)
            nodes.append(graph.edges[Int(arrival.trailingEdge)].to)
        }

        let total = gAtGoal + arrival.trailingCost
        return SearchResult(
            nodePath: nodes,
            edgePath: edges,
            totalCost: total,
            startFraction: start.startFraction,
            endFraction: arrival.endFraction
        )
    }
}
