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

    /// Stitched output: the full route polyline and the synthesized steps.
    struct Synthesis: Sendable, Equatable {
        let coordinates: [CLLocationCoordinate2D]
        let steps: [NavStep]

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

        let steps = buildSteps(result, polyline: coordinates, in: graph)
        // Degrade guard: a multi-edge route that produced fewer than 2 steps lost
        // its maneuvers; let the caller fall back to the geometric builder.
        if steps.count < 2 && result.edgePath.count > 1 {
            let geometric = CustomRouteBuilder.buildSteps(from: coordinates)
            guard geometric.count >= 2 else { return nil }
            return Synthesis(coordinates: coordinates, steps: geometric)
        }
        return Synthesis(coordinates: coordinates, steps: steps)
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
            guard coords.count >= 2 else { continue }

            // Trim leading partial edge: travel begins at startFraction along it.
            // If trimming can't resolve a cut point, keep the FULL edge geometry
            // rather than silently truncating it to a single point or dropping it.
            if i == 0 && result.startFraction > 0 {
                coords = trimLeading(coords, fraction: result.startFraction) ?? coords
            }
            // Trim trailing partial edge: travel ends at endFraction along it.
            if i == result.edgePath.count - 1 && result.endFraction < 1 {
                coords = trimTrailing(coords, fraction: result.endFraction) ?? coords
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
        var pendingDistance = edgeLength(edges[0], result: result, in: graph)
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
            let edgeLen = edgeLength(edges[i], result: result, in: graph)

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

    /// The travel length of an edge in meters, charging only the partial portion
    /// for the leading/trailing edges of a mid-edge start/end.
    ///
    /// For partial (trimmed) edges the length is measured from the SAME trimmed
    /// geometry that `stitchedPolyline` produces — a haversine walk over the
    /// trimmed coords — rather than `lengthMeters * fraction`. That keeps the
    /// reported step distance consistent with the polyline actually drawn and
    /// driven (the interpolated cut point sits slightly off the great circle, so
    /// the linear `full * fraction` estimate drifts from the displayed geometry).
    private static func edgeLength(_ edgeIndex: EdgeIndex, result: SearchResult, in graph: RoadGraph) -> Double {
        let full = Double(graph.edges[Int(edgeIndex)].lengthMeters)
        let isFirst = edgeIndex == result.edgePath.first && result.startFraction > 0
        let isLast = edgeIndex == result.edgePath.last && result.endFraction < 1
        guard isFirst || isLast else { return full }

        var coords = Array(graph.geometry(of: edgeIndex))
        guard coords.count >= 2 else {
            // No geometry to measure — fall back to the linear estimate.
            var len = full
            if isFirst { len *= (1 - result.startFraction) }
            if isLast { len *= result.endFraction }
            return len
        }
        if isFirst { coords = trimLeading(coords, fraction: result.startFraction) ?? coords }
        if isLast { coords = trimTrailing(coords, fraction: result.endFraction) ?? coords }
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

    private static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: a.latitude + t * (b.latitude - a.latitude),
            longitude: a.longitude + t * (b.longitude - a.longitude)
        )
    }
}
