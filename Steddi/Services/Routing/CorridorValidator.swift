import Foundation
import CoreLocation

/// Deterministic corridor-validation harness (Phase 6).
///
/// This is the regression net that catches "the router returned a wild detour"
/// without any live network. Given a `RoadGraph` fixture plus an origin and
/// destination, it runs the router (or validates an already-produced route) and
/// asserts a handful of structural invariants that any sane route must satisfy:
///
/// 1. **Connected** — every consecutive coordinate pair is close enough to be a
///    real graph step (no teleporting across an overpass / grade separation).
/// 2. **Monotone progress** — the route makes net forward progress toward the
///    destination; it never wanders backward for a sustained stretch (a detour
///    regression signature).
/// 3. **Within corridor** — the geometry stays inside a buffered corridor around
///    the origin→destination straight line, so the router can't loop out to the
///    next county and back.
/// 4. **Sane time ratio** — total free-flow travel time is within a configured
///    ratio of the straight-line lower bound (`crow-flight distance ÷ corridor
///    max speed`). A 10× detour fails this immediately.
///
/// `CorridorValidator` is **pure and deterministic** — it does no I/O and takes
/// the graph + route as values — so it runs as a unit test (§ Phase 6 tests) AND
/// can be invoked as a runnable on-device check against a real corridor graph.
///
/// > **Real-world scope.** Validating the owner's actual 70-mile commute is an
/// > owner/on-device step: it needs a live Overpass corridor fetch and real GPS,
/// > which are explicitly OUT OF SCOPE for these deterministic unit tests (no live
/// > network in unit tests). The harness here proves the router's *structural*
/// > correctness on fixtures; the live commute validation reuses the same
/// > `validate(...)` against a `RoadGraphSource`-loaded graph (see Phase 6 in the
/// > spec).
enum CorridorValidator {

    // MARK: - Configuration

    /// Validation thresholds. Injected data so the harness can be tuned per
    /// fixture (a dense urban grid tolerates a wider time ratio than a freeway).
    struct Config: Sendable, Equatable {
        /// Max gap (m) between consecutive route coordinates for the route to count
        /// as connected. Generous enough for a long straight freeway edge that the
        /// graph stores as just its two endpoints.
        var maxStepMeters: Double = 3000
        /// Corridor half-width (m) around the origin→destination straight line the
        /// geometry must stay within. Wide enough for legitimate arterials and
        /// alternates, tight enough to catch a route that leaves the corridor.
        var corridorHalfWidthMeters: Double = 8000
        /// Allowed multiple of the straight-line lower-bound TIME. A real route is
        /// always slower than the crow-flight-at-max-speed bound; 6× is loose
        /// enough for legitimate dog-legs and slow local roads, tight enough that a
        /// gross detour fails.
        var maxTimeRatio: Double = 6.0
        /// Allowed multiple of the straight-line DISTANCE. Catches a route that is
        /// geometrically far longer than the crow-flight, independent of speed.
        var maxDistanceRatio: Double = 4.0
        /// Net backward-progress tolerance (m): the running closest-approach to the
        /// destination may regress by at most this before it's flagged as a detour
        /// (a route briefly moves away from a destination when rounding a block).
        var maxBackwardProgressMeters: Double = 4000

        static let `default` = Config()
    }

    // MARK: - Result

    /// The outcome of validating one route. `isValid` is the AND of every check;
    /// the individual flags and `failures` make a failing assertion legible.
    struct Result: Sendable, Equatable {
        var isConnected = true
        var isMonotone = true
        var isWithinCorridor = true
        var isTimeSane = true
        var isDistanceSane = true
        /// Human-readable reasons any check failed (empty when valid).
        var failures: [String] = []
        /// Measured total geometry distance (m).
        var routeDistanceMeters: Double = 0
        /// Measured total free-flow travel time (s).
        var routeTimeSeconds: Double = 0
        /// Straight-line lower-bound distance (m) and time (s).
        var lowerBoundDistanceMeters: Double = 0
        var lowerBoundTimeSeconds: Double = 0

        var isValid: Bool {
            isConnected && isMonotone && isWithinCorridor && isTimeSane && isDistanceSane
        }
    }

    // MARK: - Validate a produced route

    /// Validate an already-produced route geometry against the structural
    /// invariants, using the graph only for the speed lower bound (`graphMaxSpeed`)
    /// and as the corridor reference frame.
    ///
    /// - Parameters:
    ///   - coordinates: the produced route polyline.
    ///   - origin: the requested origin.
    ///   - destination: the requested destination.
    ///   - timeSeconds: the route's free-flow travel time, if the caller already
    ///     computed it; otherwise pass nil and a free-flow estimate is derived
    ///     from distance and `graphMaxSpeedMPS`.
    ///   - graphMaxSpeedMPS: the corridor's max free-flow speed (the A* heuristic's
    ///     denominator) — the lower bound divides crow-flight distance by it.
    ///   - config: thresholds.
    static func validate(
        coordinates: [CLLocationCoordinate2D],
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        timeSeconds: Double?,
        graphMaxSpeedMPS: Double,
        config: Config = .default
    ) -> Result {
        var result = Result()

        guard coordinates.count >= 2 else {
            result.isConnected = false
            result.failures.append("route has fewer than 2 coordinates")
            return result
        }

        // --- Distances & time ---
        let routeDistance = RouteGeometry.cumulativeDistances(coordinates).last ?? 0
        let crow = RouteGeometry.haversineDistance(from: origin, to: destination)
        let maxSpeed = graphMaxSpeedMPS > 0 ? graphMaxSpeedMPS : 1
        let routeTime = timeSeconds ?? (routeDistance / maxSpeed)
        let lowerBoundTime = crow / maxSpeed

        result.routeDistanceMeters = routeDistance
        result.routeTimeSeconds = routeTime
        result.lowerBoundDistanceMeters = crow
        result.lowerBoundTimeSeconds = lowerBoundTime

        // --- 1. Connected ---
        for i in 1..<coordinates.count {
            let gap = RouteGeometry.haversineDistance(from: coordinates[i - 1], to: coordinates[i])
            if gap > config.maxStepMeters {
                result.isConnected = false
                result.failures.append(String(format: "disconnected step of %.0f m at index %d (max %.0f)", gap, i, config.maxStepMeters))
                break
            }
        }

        // --- 2. Monotone progress ---
        // Track the closest the route has come to the destination so far; if it
        // ever drifts back past that closest-approach by more than the tolerance,
        // it's wandering (a detour signature).
        var closestSoFar = RouteGeometry.haversineDistance(from: coordinates[0], to: destination)
        for c in coordinates.dropFirst() {
            let d = RouteGeometry.haversineDistance(from: c, to: destination)
            if d < closestSoFar { closestSoFar = d }
            if d > closestSoFar + config.maxBackwardProgressMeters {
                result.isMonotone = false
                result.failures.append(String(format: "backward progress: drifted %.0f m past closest approach (max %.0f)", d - closestSoFar, config.maxBackwardProgressMeters))
                break
            }
        }

        // --- 3. Within corridor ---
        // Every coordinate must lie within the corridor half-width of the
        // origin→destination segment.
        for c in coordinates {
            let perp = RouteGeometry.projectOntoSegment(point: c, segStart: origin, segEnd: destination).distance
            if perp > config.corridorHalfWidthMeters {
                result.isWithinCorridor = false
                result.failures.append(String(format: "left corridor: %.0f m off the centerline (max %.0f)", perp, config.corridorHalfWidthMeters))
                break
            }
        }

        // --- 4. Sane time & distance ratios ---
        if lowerBoundTime > 0, routeTime > lowerBoundTime * config.maxTimeRatio {
            result.isTimeSane = false
            result.failures.append(String(format: "time ratio %.1f× exceeds %.1f×", routeTime / lowerBoundTime, config.maxTimeRatio))
        }
        if crow > 0, routeDistance > crow * config.maxDistanceRatio {
            result.isDistanceSane = false
            result.failures.append(String(format: "distance ratio %.1f× exceeds %.1f×", routeDistance / crow, config.maxDistanceRatio))
        }

        return result
    }

    // MARK: - Validate by running the search

    /// Run A* over the graph for the endpoints and validate the resulting edge
    /// path's geometry. Returns nil if no path is found (the caller asserts that
    /// separately). Pure and deterministic — the search is given as a value.
    static func validate(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        in graph: RoadGraph,
        search: AStarSearch = AStarSearch(),
        cost: SearchCost? = nil,
        config: Config = .default
    ) -> (result: Result, searchResult: SearchResult)? {
        let costModel = cost ?? TravelTimeCost()
        guard let searchResult = search.search(
            from: .coordinate(origin),
            to: .coordinate(destination),
            in: graph,
            cost: costModel
        ), !searchResult.edgePath.isEmpty else {
            return nil
        }

        let coords = geometry(of: searchResult, in: graph)
        let result = validate(
            coordinates: coords,
            origin: origin,
            destination: destination,
            timeSeconds: searchResult.totalCost,
            graphMaxSpeedMPS: Double(graph.graphMaxSpeedMPS),
            config: config
        )
        return (result, searchResult)
    }

    // MARK: - Reference shortest path (for differential validation)

    /// Brute-force Dijkstra over the CSR graph for the SAME endpoints, used as a
    /// reference the router's free-flow route is compared against in tests. Pure;
    /// no heuristic, so it's the ground-truth least-cost path under `cost`.
    /// Returns the total cost to the snapped destination node, or nil if
    /// unreachable. Endpoints snap exactly as the router does so the comparison is
    /// apples-to-apples.
    static func referenceShortestCost(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        in graph: RoadGraph,
        cost: SearchCost = TravelTimeCost(),
        snapMaxDistanceMeters: Double = 200
    ) -> Double? {
        guard let startSnap = graph.snap(origin, maxDistanceMeters: snapMaxDistanceMeters),
              let endSnap = graph.snap(destination, maxDistanceMeters: snapMaxDistanceMeters) else {
            return nil
        }
        let startEdge = graph.edges[Int(startSnap.edge)]
        let endEdge = graph.edges[Int(endSnap.edge)]
        let startNode = startEdge.to            // travel from snap to the edge's downstream node
        let goalNode = endEdge.from             // reach the upstream node of the goal edge

        let startFull = cost.edgeCost(startEdge, in: graph)
        guard startFull.isFinite else { return nil }
        let startPartial = startFull * (1 - startSnap.fraction)
        let endFull = cost.edgeCost(endEdge, in: graph)
        guard endFull.isFinite else { return nil }
        let endPartial = endFull * endSnap.fraction

        // Plain Dijkstra (no turn cost — matches TravelTimeCost; turn-aware
        // reference is unnecessary for the structural comparison this guards).
        let n = graph.nodes.count
        var dist = [Double](repeating: .infinity, count: n)
        var visited = [Bool](repeating: false, count: n)
        dist[Int(startNode)] = startPartial
        var heap = BinaryHeap<Double>(minimumCapacity: n)
        heap.push(Int(startNode), priority: startPartial)

        while let popped = heap.popMin() {
            let u = popped.id
            if visited[u] { continue }
            visited[u] = true
            if Int32(u) == goalNode { return dist[u] + endPartial }
            for e in graph.outEdgeRange(of: Int32(u)) {
                let edge = graph.edges[Int(e)]
                let w = cost.edgeCost(edge, in: graph)
                guard w.isFinite else { continue }
                let v = Int(edge.to)
                if dist[u] + w < dist[v] {
                    dist[v] = dist[u] + w
                    heap.push(v, priority: dist[v])
                }
            }
        }
        return nil
    }

    // MARK: - Geometry stitching

    /// Stitch an edge path's per-edge geometry into one polyline, deduping the
    /// shared junction vertex between consecutive edges. Mirrors how the step
    /// synthesizer assembles the route polyline, but standalone so the validator
    /// has no dependency on synthesis.
    static func geometry(of result: SearchResult, in graph: RoadGraph) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        for edgeIndex in result.edgePath {
            let coords = Array(graph.geometry(of: edgeIndex))
            guard !coords.isEmpty else { continue }
            if let last = out.last, let first = coords.first,
               RouteGeometry.haversineDistance(from: last, to: first) < 1 {
                out.append(contentsOf: coords.dropFirst())
            } else {
                out.append(contentsOf: coords)
            }
        }
        return out
    }
}
