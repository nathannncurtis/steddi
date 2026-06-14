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
protocol SearchCost {
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
/// - **Dense state:** g-scores, came-from edge, and closed flag are `[Float]` /
///   `[Int32]` arrays indexed by `NodeIndex`, not dictionaries — CSR + dense
///   arrays is the whole performance point.
/// - **Turn cost needs predecessor context.** A turn cost depends on
///   `(incoming edge → node → outgoing edge)`, so the search records, per node,
///   the incoming edge that produced its best `g` (`cameFromEdge`). When
///   relaxing an out-edge we charge `turnCost(cameFromEdge → outEdge)`. This is
///   the spec's "carry incoming edge" formulation; it is exact for turn
///   penalties that depend only on the immediate predecessor edge (everything in
///   §5.1).
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

        let nodeCount = graph.nodes.count
        var gScore = [Double](repeating: .infinity, count: nodeCount)
        var cameFromEdge = [Int32](repeating: -1, count: nodeCount)   // edge index into graph.edges
        var closed = [Bool](repeating: false, count: nodeCount)

        var heap = BinaryHeap<Double>(minimumCapacity: nodeCount)

        for entry in start.entries {
            let startNode = entry.node
            if entry.g < gScore[Int(startNode)] {
                gScore[Int(startNode)] = entry.g
                cameFromEdge[Int(startNode)] = entry.viaEdge
                let h = cost.heuristic(from: graph.nodes[Int(startNode)].coordinate, to: target, in: graph)
                heap.push(Int(startNode), priority: entry.g + h)
            }
        }

        while let popped = heap.popMin() {
            let current = NodeIndex(popped.id)
            if closed[Int(current)] { continue }
            closed[Int(current)] = true

            // Goal reached: the popped node is the goal's upstream graph node.
            if current == goal.node {
                return reconstruct(
                    goalNode: goal,
                    gScore: gScore,
                    cameFromEdge: cameFromEdge,
                    start: start,
                    in: graph
                )
            }

            let incomingEdgeIndex = cameFromEdge[Int(current)]
            let incomingEdge: GraphEdge? = incomingEdgeIndex >= 0 ? graph.edges[Int(incomingEdgeIndex)] : nil
            let currentNode = graph.nodes[Int(current)]
            let gCurrent = gScore[Int(current)]

            let range = graph.outEdgeRange(of: current)
            for edgeIndex in range {
                let edge = graph.edges[Int(edgeIndex)]
                let neighbor = edge.to
                if closed[Int(neighbor)] { continue }

                let stepEdge = cost.edgeCost(edge, in: graph)
                guard stepEdge.isFinite else { continue }
                let stepTurn = cost.turnCost(from: incomingEdge, to: edge, at: currentNode, in: graph)
                guard stepTurn.isFinite else { continue }

                // If this edge is the goal's terminal partial edge, charge only
                // the partial-length portion when arriving at the goal node.
                let tentativeG = gCurrent + stepEdge + stepTurn
                if tentativeG < gScore[Int(neighbor)] {
                    gScore[Int(neighbor)] = tentativeG
                    cameFromEdge[Int(neighbor)] = Int32(edgeIndex)
                    let h = cost.heuristic(from: graph.nodes[Int(neighbor)].coordinate, to: target, in: graph)
                    heap.push(Int(neighbor), priority: tentativeG + h)
                }
            }
        }

        return nil   // no path
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

    /// A resolved destination: the single graph node A* must reach (the upstream
    /// end of the goal edge for a mid-edge end), the trailing partial edge (or
    /// -1), the end fraction, and the target coordinate the heuristic aims at.
    private struct ResolvedGoal {
        let node: NodeIndex
        let trailingEdge: Int32
        let endFraction: Double
        /// Extra cost charged when the goal node is reached: the partial trailing
        /// edge time from the goal node to the snapped end. Added in reconstruct
        /// so it never perturbs the heuristic.
        let trailingCost: Double
        let targetCoordinate: CLLocationCoordinate2D
    }

    private func resolveOrigin(_ endpoint: SearchEndpoint, in graph: RoadGraph, cost: SearchCost) -> ResolvedOrigin? {
        switch endpoint {
        case .node(let n):
            guard Int(n) < graph.nodes.count else { return nil }
            return ResolvedOrigin(
                entries: [.init(node: n, g: 0, viaEdge: -1)],
                startFraction: 0,
                leadingEdge: -1
            )

        case .coordinate(let coord, let heading):
            guard let snap = graph.snap(coord, heading: heading, maxDistanceMeters: snapMaxDistanceMeters) else {
                return nil
            }
            let edge = graph.edges[Int(snap.edge)]
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
            guard Int(n) < graph.nodes.count else { return nil }
            return ResolvedGoal(
                node: n,
                trailingEdge: -1,
                endFraction: 1,
                trailingCost: 0,
                targetCoordinate: graph.nodes[Int(n)].coordinate
            )

        case .coordinate(let coord, let heading):
            guard let snap = graph.snap(coord, heading: heading, maxDistanceMeters: snapMaxDistanceMeters) else {
                return nil
            }
            let edge = graph.edges[Int(snap.edge)]
            // Mid-edge end: A* must reach the edge's upstream node (`edge.from`),
            // then travel the partial edge cost to the snapped end. The heuristic
            // aims at `edge.from`'s coordinate so it stays a lower bound on
            // reaching that node (the trailing partial cost is added separately).
            let full = cost.edgeCost(edge, in: graph)
            let partial = full.isFinite ? full * snap.fraction : .infinity
            guard partial.isFinite else { return nil }
            return ResolvedGoal(
                node: edge.from,
                trailingEdge: snap.edge,
                endFraction: snap.fraction,
                trailingCost: partial,
                targetCoordinate: graph.nodes[Int(edge.from)].coordinate
            )
        }
    }

    // MARK: - Reconstruction

    private func reconstruct(
        goalNode goal: ResolvedGoal,
        gScore: [Double],
        cameFromEdge: [Int32],
        start: ResolvedOrigin,
        in graph: RoadGraph
    ) -> SearchResult {
        // Walk `cameFromEdge` back from the goal node to a start node. Stop when
        // we reach a node whose incoming edge is the leading partial edge (or -1
        // for a node start), which marks the true origin.
        var edges: [EdgeIndex] = []
        var nodes: [NodeIndex] = [goal.node]

        var current = goal.node
        while true {
            let viaEdge = cameFromEdge[Int(current)]
            if viaEdge < 0 { break }                 // node start reached
            if viaEdge == start.leadingEdge {
                // The leading partial edge is the origin's synthetic incoming
                // edge — it's prepended below, not walked as an interior edge.
                break
            }
            edges.append(viaEdge)
            let predecessor = graph.edges[Int(viaEdge)].from
            nodes.append(predecessor)
            current = predecessor
        }

        // We built the path goal→origin; reverse to origin→goal order.
        edges.reverse()
        nodes.reverse()

        // Prepend the leading partial start edge, if any.
        if start.leadingEdge >= 0 {
            edges.insert(start.leadingEdge, at: 0)
            nodes.insert(graph.edges[Int(start.leadingEdge)].from, at: 0)
        }
        // Append the trailing partial end edge, if any.
        if goal.trailingEdge >= 0 {
            edges.append(goal.trailingEdge)
            nodes.append(graph.edges[Int(goal.trailingEdge)].to)
        }

        let total = gScore[Int(goal.node)] + goal.trailingCost
        return SearchResult(
            nodePath: nodes,
            edgePath: edges,
            totalCost: total,
            startFraction: start.startFraction,
            endFraction: goal.endFraction
        )
    }
}
