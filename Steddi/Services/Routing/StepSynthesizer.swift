import Foundation
import CoreLocation

/// Turns an A* edge path into turn-by-turn `NavStep`s.
///
/// The custom router knows more than the geometric `CustomRouteBuilder` (it has
/// the actual graph edges, their road classes, and the turn at every node), so it
/// synthesizes steps directly from the maneuver at each graph node rather than
/// re-detecting turns by RDP-simplifying a bare polyline. Crucially it emits the
/// **exact instruction grammar** `DirectionsService.instruction`/`turnPhrase` and
/// `CustomRouteBuilder.turnDescription` already use ("Turn left", "Bear right",
/// "Continue straight", "Make a U-turn", "Head <cardinal>", "Arrive at your
/// destination"), so `NavigationEngine.sfSymbolFromInstruction` classifies the
/// symbol identically and the voice layer speaks it unchanged (§7.1, Phase-5
/// risk: step phrasing drift).
///
/// Pure and static — no graph mutation, no I/O — so it unit-tests like the rest
/// of the routing core. If synthesis degrades (too few maneuvers for a non-trivial
/// route), the caller falls back to `CustomRouteBuilder.buildSteps` on the stitched
/// polyline, the guaranteed geometric baseline.
enum StepSynthesizer {

    /// Stitched output: the full route polyline, the synthesized steps, and the
    /// edge-derived free-flow travel time. `freeFlowSeconds` sums each traversed
    /// edge's `lengthMeters / freeFlowSpeedMPS` (prorating the partial
    /// leading/trailing edges by their fractions), so a motorway leg reports a
    /// realistic duration instead of a flat urban baseline — see
    /// `CustomRouter.freeFlowDuration`.
    struct Synthesis: Sendable, Equatable {
        let coordinates: [CLLocationCoordinate2D]
        let steps: [NavStep]
        /// Edge-speed-based free-flow travel time in seconds for this synthesis.
        /// 0 when no edge carried a usable speed (the caller falls back to a flat
        /// baseline over the geometry distance).
        var freeFlowSeconds: TimeInterval = 0

        static func == (lhs: Synthesis, rhs: Synthesis) -> Bool {
            lhs.coordinates.count == rhs.coordinates.count
                && zip(lhs.coordinates, rhs.coordinates).allSatisfy {
                    $0.latitude == $1.latitude && $0.longitude == $1.longitude
                }
                && lhs.steps.count == rhs.steps.count
                && zip(lhs.steps, rhs.steps).allSatisfy {
                    $0.instruction == $1.instruction && $0.distance == $1.distance
                        && $0.maneuverSymbol == $1.maneuverSymbol
                }
        }
    }

    /// Stitch the edge path's geometry into one polyline and synthesize steps.
    /// Returns `nil` only when the path is empty or yields no geometry — the
    /// caller treats that as "fall back to MapKit".
    static func synthesize(_ result: SearchResult, in graph: RoadGraph) -> Synthesis? {
        let coordinates = stitchedPolyline(result, in: graph)
        guard coordinates.count >= 2 else { return nil }

        let freeFlow = freeFlowSeconds(result, in: graph)
        let steps = buildSteps(result, polyline: coordinates, in: graph)
        // Degrade guard: a multi-edge route that produced fewer than 2 steps lost
        // its maneuvers; let the caller fall back to the geometric builder.
        if steps.count < 2 && result.edgePath.count > 1 {
            let geometric = CustomRouteBuilder.buildSteps(from: coordinates)
            guard geometric.count >= 2 else { return nil }
            return Synthesis(coordinates: coordinates, steps: geometric, freeFlowSeconds: freeFlow)
        }
        return Synthesis(coordinates: coordinates, steps: steps, freeFlowSeconds: freeFlow)
    }

    /// Edge-speed free-flow travel time over the whole edge path: the sum of each
    /// traversed edge's travelled length (the SAME partial-aware length
    /// `edgeLength(at:)` reports for steps) divided by that edge's
    /// `freeFlowSpeedMPS`. This is the honest, traffic-free duration the custom
    /// router reports — a motorway edge contributes far less time per meter than a
    /// residential one of equal length, so a highway route is no longer flattened
    /// to a single urban baseline. Edges with a non-positive speed are skipped
    /// (they contribute no time rather than an infinite one).
    static func freeFlowSeconds(_ result: SearchResult, in graph: RoadGraph) -> TimeInterval {
        guard !result.edgePath.isEmpty else { return 0 }
        var seconds: TimeInterval = 0
        for i in result.edgePath.indices {
            let speed = Double(graph.edges[Int(result.edgePath[i])].freeFlowSpeedMPS)
            guard speed > 0 else { continue }
            seconds += edgeLength(at: i, result: result, in: graph) / speed
        }
        return seconds
    }

    /// Concatenate every edge's geometry into one polyline, trimming the leading
    /// edge to `startFraction` and the trailing edge to `endFraction` for a
    /// mid-edge start/end, and de-duplicating the shared node vertex between
    /// consecutive edges.
    static func stitchedPolyline(_ result: SearchResult, in graph: RoadGraph) -> [CLLocationCoordinate2D] {
        guard !result.edgePath.isEmpty else { return [] }
        var out: [CLLocationCoordinate2D] = []

        for (i, edgeIndex) in result.edgePath.enumerated() {
            var coords = Array(graph.geometry(of: edgeIndex))
            // Degenerate/empty edge geometry (a corrupt blob slips a <2-coord slice
            // past the serializer, or a hand-built graph in a test): the cost was
            // already charged by A*, so silently dropping this edge would leave a
            // GAP — the polyline would teleport from the previous edge's end node
            // straight to the next edge's start node, defeating the route's
            // connectivity guarantee with no detection. Bridge the gap with the
            // edge's own endpoint NODE coordinates so the line stays continuous
            // across the step. The append's <1 m dedup (below) collapses the `from`
            // vertex into the prior edge's terminal vertex, so this contributes only
            // the missing `to` node when stitched after another edge. Fail (drop)
            // only when a node coordinate genuinely can't be resolved.
            if coords.count < 2 {
                guard let bridge = nodeBridge(for: edgeIndex, in: graph) else { continue }
                coords = bridge
            }

            // A partial trim applies only for a strictly-interior fraction. A
            // boundary fraction (start==0 / end==1, including a node endpoint
            // snapped exactly to a vertex) means the FULL edge geometry is the
            // travelled geometry — trimming it would either no-op (the trim guards
            // reject 0/1) or, if mis-gated, draw/charge the full terminal edge and
            // overshoot the real endpoint. Gate on the open interval (0,1).
            let isFirst = i == 0 && result.startFraction > 0 && result.startFraction < 1
            let isLast = i == result.edgePath.count - 1 && result.endFraction < 1 && result.endFraction > 0
            // Single-edge route (start == end edge): BOTH trims apply to this one
            // edge. Cut the sub-segment [startFraction, endFraction] in ONE pass
            // against the ORIGINAL geometry — composing trimLeading then
            // trimTrailing would apply endFraction to the already-shortened length
            // and misplace the destination.
            if isFirst && isLast {
                coords = trimSubSegment(coords, from: result.startFraction, to: result.endFraction) ?? coords
            } else {
                // Trim leading partial edge: travel begins at startFraction along it.
                // If trimming can't resolve a cut point, keep the FULL edge geometry
                // rather than silently truncating it to a single point or dropping it.
                if isFirst {
                    coords = trimLeading(coords, fraction: result.startFraction) ?? coords
                }
                // Trim trailing partial edge: travel ends at endFraction along it.
                if isLast {
                    coords = trimTrailing(coords, fraction: result.endFraction) ?? coords
                }
            }
            guard coords.count >= 1 else { continue }

            if let last = out.last, let first = coords.first,
               RouteGeometry.haversineDistance(from: last, to: first) < 1.0 {
                out.append(contentsOf: coords.dropFirst())
            } else {
                out.append(contentsOf: coords)
            }
        }
        return out
    }

    // MARK: - Step synthesis

    /// One step per maneuver: a "Head <cardinal>" departure, a turn step at every
    /// graph node where the heading changes meaningfully (carrying the distance of
    /// the segment leading INTO it), and an arrival step. Phrasing matches the
    /// existing grammar so symbols and voice are unchanged.
    static func buildSteps(_ result: SearchResult, polyline: [CLLocationCoordinate2D], in graph: RoadGraph) -> [NavStep] {
        let edges = result.edgePath
        guard !edges.isEmpty, polyline.count >= 2 else { return [] }

        var steps: [NavStep] = []

        // Departure step: head out along the first edge's initial bearing.
        let headBearing = RouteGeometry.bearing(from: polyline[0], to: polyline[1])
        var pendingDistance = edgeLength(at: 0, result: result, in: graph)
        var pendingCoordinate = polyline[0]

        steps.append(NavStep(
            instruction: "Head \(CustomRouteBuilder.cardinalDirection(headBearing))",
            distance: 0,
            coordinate: polyline[0],
            maneuverSymbol: "location.fill"
        ))

        // Maneuver at each interior graph node (between consecutive edges).
        for i in 1..<edges.count {
            let incoming = graph.edges[Int(edges[i - 1])]
            let outgoing = graph.edges[Int(edges[i])]
            let nodeIndex = incoming.to
            let node = graph.nodes[Int(nodeIndex)]
            let nodeCoord = node.coordinate

            let turn = DefaultCostModel.classifyTurn(from: incoming, to: outgoing, in: graph)
            let edgeLen = edgeLength(at: i, result: result, in: graph)

            if let phrase = instruction(for: turn) {
                // Close out the leg leading up to this maneuver as the distance on
                // the PREVIOUS step (the distance the driver covers before turning).
                if !steps.isEmpty {
                    steps[steps.count - 1] = withDistance(steps[steps.count - 1], pendingDistance)
                }
                steps.append(NavStep(
                    instruction: phrase,
                    distance: 0,
                    coordinate: nodeCoord,
                    maneuverSymbol: NavigationEngine.sfSymbolFromInstruction(phrase)
                ))
                pendingDistance = edgeLen
                pendingCoordinate = nodeCoord
            } else {
                // Straight-through node: accumulate distance into the current leg.
                pendingDistance += edgeLen
            }
            _ = pendingCoordinate
        }

        // Final leg distance lands on the last maneuver/departure step.
        if !steps.isEmpty {
            steps[steps.count - 1] = withDistance(steps[steps.count - 1], pendingDistance)
        }

        // Arrival.
        if let last = polyline.last {
            steps.append(NavStep(
                instruction: "Arrive at your destination",
                distance: 0,
                coordinate: last,
                maneuverSymbol: "flag.fill"
            ))
        }
        return steps
    }

    /// Maneuver phrase for a turn, in the existing grammar. nil for straight
    /// (no maneuver — the leg folds into the previous step).
    static func instruction(for turn: TurnDirection) -> String? {
        switch turn {
        case .straight: return nil
        case .slightLeft: return "Bear left"
        case .slightRight: return "Bear right"
        case .left: return "Turn left"
        case .right: return "Turn right"
        case .uTurn: return "Make a U-turn"
        }
    }

    // MARK: - Helpers

    /// The travel length of the edge at position `i` in `result.edgePath`, in
    /// meters, charging only the partial portion for the leading/trailing edges of
    /// a mid-edge start/end.
    ///
    /// The leading/trailing edge is identified by POSITION in the path (first/last
    /// array index), mirroring `stitchedPolyline`, NOT by matching the EdgeIndex
    /// VALUE. When the same edge index appears at more than one position — e.g. a
    /// same-edge start/end with `startFraction > endFraction` that loops the block,
    /// so the edge seeds the path AND is appended as the trailing edge — a
    /// value-based test would mark the FIRST occurrence as both first and last and
    /// charge the wrong (full, untrimmed) length, diverging from the drawn polyline.
    ///
    /// For partial (trimmed) edges the length is measured from the SAME trimmed
    /// geometry that `stitchedPolyline` produces — a haversine walk over the
    /// trimmed coords — rather than `lengthMeters * fraction`. That keeps the
    /// reported step distance consistent with the polyline actually drawn and
    /// driven (the interpolated cut point sits slightly off the great circle, so
    /// the linear `full * fraction` estimate drifts from the displayed geometry).
    private static func edgeLength(at i: Int, result: SearchResult, in graph: RoadGraph) -> Double {
        let edgeIndex = result.edgePath[i]
        let full = Double(graph.edges[Int(edgeIndex)].lengthMeters)
        // Mirror `stitchedPolyline`: only an open-interval (0,1) fraction is a
        // partial edge. A boundary fraction means the full edge length is the
        // travelled length, so this returns `full` for any node-snapped endpoint.
        let isFirst = i == 0 && result.startFraction > 0 && result.startFraction < 1
        let isLast = i == result.edgePath.count - 1 && result.endFraction < 1 && result.endFraction > 0
        guard isFirst || isLast else { return full }

        var coords = Array(graph.geometry(of: edgeIndex))
        guard coords.count >= 2 else {
            // No geometry to measure — fall back to the linear estimate.
            var len = full
            if isFirst && isLast {
                len *= (result.endFraction - result.startFraction)
            } else {
                if isFirst { len *= (1 - result.startFraction) }
                if isLast { len *= result.endFraction }
            }
            return len
        }
        // Single-edge route: cut the sub-segment in one pass against the ORIGINAL
        // geometry (mirrors stitchedPolyline) rather than composing the two trims.
        if isFirst && isLast {
            coords = trimSubSegment(coords, from: result.startFraction, to: result.endFraction) ?? coords
        } else {
            if isFirst { coords = trimLeading(coords, fraction: result.startFraction) ?? coords }
            if isLast { coords = trimTrailing(coords, fraction: result.endFraction) ?? coords }
        }
        return RouteGeometry.cumulativeDistances(coords).last ?? full
    }

    private static func withDistance(_ step: NavStep, _ distance: Double) -> NavStep {
        NavStep(
            instruction: step.instruction,
            distance: distance,
            coordinate: step.coordinate,
            maneuverSymbol: step.maneuverSymbol
        )
    }

    /// Keep the portion of an edge's geometry from `fraction` (arc-length) to the
    /// end, inserting the interpolated start point. Returns `coords` unchanged
    /// when no trim is needed, and `nil` if the loop exhausts without locating a
    /// cut point so the caller can fall back to the full geometry instead of a
    /// silently truncated single point.
    private static func trimLeading(_ coords: [CLLocationCoordinate2D], fraction: Double) -> [CLLocationCoordinate2D]? {
        guard coords.count >= 2, fraction > 0, fraction < 1 else { return coords }
        let cumulative = RouteGeometry.cumulativeDistances(coords)
        guard let total = cumulative.last, total > 0 else { return coords }
        let target = total * fraction
        for i in 0..<(coords.count - 1) where cumulative[i + 1] >= target {
            let segLen = cumulative[i + 1] - cumulative[i]
            let t = segLen > 0 ? (target - cumulative[i]) / segLen : 0
            let point = interpolate(coords[i], coords[i + 1], t)
            return [point] + Array(coords[(i + 1)...])
        }
        return nil
    }

    /// Keep the portion of an edge's geometry from the start to `fraction`
    /// (arc-length), inserting the interpolated end point. Returns `coords`
    /// unchanged when no trim is needed, and `nil` if the loop exhausts without
    /// locating a cut point so the caller can fall back to the full geometry.
    private static func trimTrailing(_ coords: [CLLocationCoordinate2D], fraction: Double) -> [CLLocationCoordinate2D]? {
        guard coords.count >= 2, fraction > 0, fraction < 1 else { return coords }
        let cumulative = RouteGeometry.cumulativeDistances(coords)
        guard let total = cumulative.last, total > 0 else { return coords }
        let target = total * fraction
        for i in 0..<(coords.count - 1) where cumulative[i + 1] >= target {
            let segLen = cumulative[i + 1] - cumulative[i]
            let t = segLen > 0 ? (target - cumulative[i]) / segLen : 0
            let point = interpolate(coords[i], coords[i + 1], t)
            return Array(coords[0...i]) + [point]
        }
        return nil
    }

    /// Keep the sub-segment between `from` and `to` (both arc-length fractions of
    /// the FULL edge), inserting interpolated endpoints. Used for a single-edge
    /// route where the start and end snap onto the same edge: both cuts are taken
    /// from the ORIGINAL geometry in one pass, so the trailing cut isn't applied
    /// to an already-shortened length. Returns `coords` unchanged when no trim is
    /// needed, and `nil` if a cut point can't be located so the caller can fall
    /// back to the full geometry.
    private static func trimSubSegment(_ coords: [CLLocationCoordinate2D], from: Double, to: Double) -> [CLLocationCoordinate2D]? {
        guard coords.count >= 2, from >= 0, to <= 1, from <= to else { return coords }
        let cumulative = RouteGeometry.cumulativeDistances(coords)
        guard let total = cumulative.last, total > 0 else { return coords }

        // Zero-length sub-segment (origin == destination at the SAME fraction on
        // one edge): the travelled geometry is a single point, NOT the full edge.
        // Returning the interpolated point collapses the polyline to one coordinate
        // so `stitchedPolyline` yields `count < 2` and `synthesize` falls back to
        // MapKit (a degenerate point route, not a phantom full-block drive). Without
        // this, the old `from < to` guard rejected `from == to` and returned the
        // ENTIRE untrimmed edge — overstating a zero-length trip as a full block.
        if from == to {
            let target = total * from
            for i in 0..<(coords.count - 1) where cumulative[i + 1] >= target {
                let segLen = cumulative[i + 1] - cumulative[i]
                let t = segLen > 0 ? (target - cumulative[i]) / segLen : 0
                return [interpolate(coords[i], coords[i + 1], t)]
            }
            return [coords[coords.count - 1]]
        }

        // The interpolated point at `target` arc-length and the index `i` of the
        // segment [i, i+1] it falls on, resolved against the ORIGINAL cumulative.
        func cut(_ target: Double) -> (point: CLLocationCoordinate2D, seg: Int)? {
            for i in 0..<(coords.count - 1) where cumulative[i + 1] >= target {
                let segLen = cumulative[i + 1] - cumulative[i]
                let t = segLen > 0 ? (target - cumulative[i]) / segLen : 0
                return (interpolate(coords[i], coords[i + 1], t), i)
            }
            return nil
        }

        // Start cut: interpolated point and the first ORIGINAL vertex kept after it.
        let startPoint: CLLocationCoordinate2D
        let startSegEnd: Int
        if from <= 0 {
            startPoint = coords[0]
            startSegEnd = 0
        } else {
            guard let s = cut(total * from) else { return nil }
            startPoint = s.point
            startSegEnd = s.seg + 1
        }

        // End cut: interpolated point and the last ORIGINAL vertex kept before it.
        let endPoint: CLLocationCoordinate2D
        let endSegStart: Int
        if to >= 1 {
            endPoint = coords[coords.count - 1]
            endSegStart = coords.count - 1
        } else {
            guard let e = cut(total * to) else { return nil }
            endPoint = e.point
            endSegStart = e.seg
        }

        // Stitch: start cut point, the interior original vertices strictly between
        // the two cuts, then the end cut point.
        var out: [CLLocationCoordinate2D] = [startPoint]
        if startSegEnd <= endSegStart {
            out.append(contentsOf: coords[startSegEnd...endSegStart])
        }
        out.append(endPoint)
        return out
    }

    /// The two endpoint NODE coordinates of `edgeIndex` — `[from, to]` in travel
    /// direction — used to BRIDGE an edge whose stored geometry is degenerate
    /// (`< 2` coords) so `stitchedPolyline` stays continuous instead of teleporting
    /// across the missing step. Returns `nil` (so the caller drops the edge as a
    /// true gap) when an index is out of bounds or a coordinate is non-finite —
    /// there is no usable substitute geometry to draw.
    private static func nodeBridge(for edgeIndex: EdgeIndex, in graph: RoadGraph) -> [CLLocationCoordinate2D]? {
        guard edgeIndex >= 0, Int(edgeIndex) < graph.edges.count else { return nil }
        let edge = graph.edges[Int(edgeIndex)]
        let fromIdx = Int(edge.from)
        let toIdx = Int(edge.to)
        guard fromIdx >= 0, fromIdx < graph.nodes.count,
              toIdx >= 0, toIdx < graph.nodes.count else { return nil }
        let from = graph.nodes[fromIdx].coordinate
        let to = graph.nodes[toIdx].coordinate
        guard from.latitude.isFinite, from.longitude.isFinite,
              to.latitude.isFinite, to.longitude.isFinite else { return nil }
        return [from, to]
    }

    private static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: a.latitude + t * (b.latitude - a.latitude),
            longitude: a.longitude + t * (b.longitude - a.longitude)
        )
    }
}
