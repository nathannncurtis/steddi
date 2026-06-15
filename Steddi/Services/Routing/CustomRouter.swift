import Foundation
import CoreLocation

/// Steddi's custom road-graph router as a `RouteProvider` — the Phase-5 facade
/// that wires the whole keystone together: corridor graph (Phase 2) → snap →
/// A* (Phase 3) with the `DefaultCostModel` (Phase 4) → `StepSynthesizer`
/// (Phase 5) → a `GeneratedRoute` byte-compatible with what `NavigationEngine`
/// consumes.
///
/// This is where "your route, your rules" becomes a route: `RoutePreferences`,
/// the departure time, and the active `NoGoZone`s are translated into a
/// `RoutingContext` and `RoutedZone`s, the cost model shapes the search, and the
/// resulting edge path is turned into a polyline + `NavStep`s.
///
/// **Graceful failure is the contract.** If the corridor graph can't load
/// (network down, cache miss), if A* finds no path, or if step synthesis
/// degrades to nothing, `generateRoute` returns `nil` so the selector falls back
/// to MapKit. The custom router never throws and never strands a drive.
@MainActor
final class CustomRouter: RouteProvider {

    private let graphSource: RoadGraphSource
    private let search: AStarSearch
    private let weights: CostWeights
    /// Corridor `around` buffer half-width used to seed the loader's corridor
    /// polyline density. The loader applies its own 1500 m buffer; this only
    /// affects how many waypoints we densify the centerline with.
    private let corridorSampleSpacingMeters: Double
    /// Per-driver learned weights store (Phase 7). When present, the router reads
    /// the most specific learned `CostWeights` for the request's scope and uses it
    /// in place of the injected `weights`; absent (or no stored set) it falls back
    /// to `weights` (which defaults to `CostWeights.default`). Learning is purely
    /// additive — it never strands a route.
    private let learnedWeightsStore: LearnedWeightsStore?
    /// Maps a `RouteRequest` to a learned-weights scope (e.g. a commute id +
    /// direction). Returns nil to use only the global learned set. Injected so the
    /// router stays decoupled from how scopes are derived.
    private let scope: @Sendable (RouteRequest) -> String?

    init(
        graphSource: RoadGraphSource,
        search: AStarSearch = AStarSearch(),
        weights: CostWeights = .default,
        corridorSampleSpacingMeters: Double = 1000,
        learnedWeightsStore: LearnedWeightsStore? = nil,
        scope: @escaping @Sendable (RouteRequest) -> String? = { _ in nil }
    ) {
        self.graphSource = graphSource
        self.search = search
        self.weights = weights
        self.corridorSampleSpacingMeters = corridorSampleSpacingMeters
        self.learnedWeightsStore = learnedWeightsStore
        self.scope = scope
    }

    /// The weights to route with for a request: the most specific learned set
    /// available (per-scope, then global), else the injected base `weights`
    /// (`CostWeights.default` by default). Pure given the store's contents; the
    /// Phase-7 hook and tests read it directly.
    func resolvedWeights(for request: RouteRequest) -> CostWeights {
        guard let store = learnedWeightsStore else { return weights }
        return store.loadBest(scope: scope(request)) ?? weights
    }

    // MARK: - RouteProvider

    func generateRoute(_ request: RouteRequest) async -> GeneratedRoute? {
        // 1. Corridor: the ordered endpoints define the ribbon to fetch a graph
        //    for. Densify so the loader's `around` clauses cover the whole line.
        let corridor = Self.corridor(
            origin: request.origin,
            waypoints: request.waypoints,
            destination: request.destination,
            spacingMeters: corridorSampleSpacingMeters
        )
        guard corridor.count >= 2 else { return nil }
        let corridorKey = RoadGraphSource.cacheKey(for: corridor)

        // 2. Load the corridor graph (cache-first, off-main inside the source).
        //    A nil graph (network failure + no cache, or an empty graph) means
        //    fall back — never crash the drive.
        guard let graph = await graphSource.load(corridor: corridor, corridorKey: corridorKey),
              !graph.nodes.isEmpty, !graph.edges.isEmpty else {
            return nil
        }

        // 3. Build the routing context from preferences + departure + zones, and
        //    resolve the cost weights — the driver's learned set when one exists
        //    for this scope (Phase 7), else the injected base weights.
        let context = Self.routingContext(for: request)
        let cost = DefaultCostModel(weights: resolvedWeights(for: request), context: context)

        // 4. Search the corridor leg-by-leg so waypoints are honored as
        //    pass-throughs (one A* per leg, stitched). The search + synthesis are
        //    CPU-bound; run them off the main actor.
        let stops = [request.origin] + request.waypoints + [request.destination]
        let search = self.search
        guard let synthesis = await Task.detached(priority: .userInitiated, operation: {
            Self.searchAndSynthesize(stops: stops, graph: graph, search: search, cost: cost)
        }).value else {
            return nil
        }

        guard synthesis.coordinates.count >= 2, synthesis.steps.count >= 1 else { return nil }

        // 5. ETA from the cost model's accumulated edge time would mix penalties
        //    into the displayed duration; instead report pure free-flow travel
        //    time built from each edge's real speed (honest, traffic-free — §6),
        //    so a motorway route reads ~highway-fast and a residential one
        //    ~residential-slow rather than a single flat urban baseline. The flat
        //    baseline only kicks in when no edge carried a usable speed. The
        //    distance is the stitched polyline length.
        let distance = RouteGeometry.cumulativeDistances(synthesis.coordinates).last ?? 0
        let duration = Self.freeFlowDuration(
            edgeFreeFlowSeconds: synthesis.freeFlowSeconds,
            fallbackCoords: synthesis.coordinates,
            fallbackDistance: distance
        )

        return GeneratedRoute(
            coordinates: synthesis.coordinates,
            steps: synthesis.steps,
            distanceMeters: distance,
            expectedTravelTime: duration,
            source: .custom
        )
    }

    // MARK: - Search + synthesize (pure, off-main)

    /// Run one A* per leg between consecutive stops and stitch the legs into a
    /// single synthesis. Any leg with no path aborts the whole route (nil) so the
    /// caller falls back. Pure over its inputs — unit-testable on in-memory graphs.
    nonisolated static func searchAndSynthesize(
        stops: [CLLocationCoordinate2D],
        graph: RoadGraph,
        search: AStarSearch,
        cost: SearchCost
    ) -> StepSynthesizer.Synthesis? {
        guard stops.count >= 2 else { return nil }

        var stitchedCoords: [CLLocationCoordinate2D] = []
        var stitchedSteps: [NavStep] = []
        var freeFlowSeconds: TimeInterval = 0
        // Distance carried over from a stripped departure (and any earlier leg that
        // contributed no surviving step) waiting to be folded onto the next real
        // step. Persists across legs so a TURN-LESS leg — whose whole distance lives
        // on a departure step that is then stripped, with its arrival stripped too,
        // leaving no surviving step in that leg — does not silently drop its length.
        var carriedDistance: Double = 0

        for i in 0..<(stops.count - 1) {
            let result = search.search(
                from: .coordinate(stops[i]),
                to: .coordinate(stops[i + 1]),
                in: graph,
                cost: cost
            )
            guard let result, !result.edgePath.isEmpty,
                  let synthesis = StepSynthesizer.synthesize(result, in: graph) else {
                return nil
            }
            freeFlowSeconds += synthesis.freeFlowSeconds

            // Stitch geometry, deduping the shared junction vertex between legs.
            if let last = stitchedCoords.last, let first = synthesis.coordinates.first,
               RouteGeometry.haversineDistance(from: last, to: first) < 5 {
                stitchedCoords.append(contentsOf: synthesis.coordinates.dropFirst())
            } else {
                stitchedCoords.append(contentsOf: synthesis.coordinates)
            }

            // Drop the intermediate leg's trailing arrival and the next leg's
            // leading departure: waypoints are pass-throughs, not stops (mirrors
            // DirectionsService.stitchTrimmedLegs / viaSteps).
            var legSteps = synthesis.steps
            // Strip the TRAILING arrival BEFORE folding the stripped departure's
            // carried distance. Order matters: a turn-less leg synthesizes exactly
            // [departure(distance = whole leg length), arrival(distance = 0)], so the
            // only surviving step after stripping the departure is the arrival — fold
            // first and the arrival-strip would then carry that distance away with it.
            // Stripping the arrival first leaves no step to mis-fold onto, so the
            // leg's distance survives in `carriedDistance` and lands on the next
            // real step (or, for the final leg, its kept arrival) below.
            if i < stops.count - 2 {
                while let last = legSteps.last, isArrival(last) { legSteps.removeLast() }
            }
            if i > 0 {
                // The departure "Head …" step carries the leg's LEAD-IN distance
                // (waypoint → first maneuver; StepSynthesizer writes that onto the
                // departure step). Removing it would drop that distance, so carry it
                // forward — preserving the per-step distance totals and the
                // distance-to-next-maneuver shown right after the stop.
                while let first = legSteps.first, isDeparture(first) {
                    carriedDistance += first.distance
                    legSteps.removeFirst()
                }
            }
            // Fold any carried distance onto this leg's first surviving step. A
            // turn-less leg leaves `legSteps` empty here, so the carry simply rolls
            // forward to the next leg (or, for the final leg, onto its kept arrival).
            if carriedDistance > 0, let first = legSteps.first {
                legSteps[0] = withDistance(first, first.distance + carriedDistance)
                carriedDistance = 0
            }
            stitchedSteps.append(contentsOf: legSteps)
        }

        // Any distance still pending (a turn-less final leg, or a trailing run of
        // turn-less legs that produced no surviving step) lands on the last step so
        // the route's per-step distances still sum to the full driven length.
        if carriedDistance > 0, let last = stitchedSteps.last {
            stitchedSteps[stitchedSteps.count - 1] = withDistance(last, last.distance + carriedDistance)
            carriedDistance = 0
        }

        guard stitchedCoords.count >= 2 else { return nil }
        return StepSynthesizer.Synthesis(
            coordinates: stitchedCoords,
            steps: stitchedSteps,
            freeFlowSeconds: freeFlowSeconds
        )
    }

    private nonisolated static func isArrival(_ step: NavStep) -> Bool {
        step.maneuverSymbol == "flag.fill"
            || step.instruction.lowercased().contains("arrive")
    }

    private nonisolated static func isDeparture(_ step: NavStep) -> Bool {
        step.maneuverSymbol == "location.fill"
            || step.instruction.lowercased().hasPrefix("head ")
    }

    /// A copy of `step` with its distance replaced — used to fold a stripped
    /// departure step's lead-in distance onto the first surviving step.
    private nonisolated static func withDistance(_ step: NavStep, _ distance: Double) -> NavStep {
        NavStep(
            instruction: step.instruction,
            distance: distance,
            coordinate: step.coordinate,
            maneuverSymbol: step.maneuverSymbol
        )
    }

    // MARK: - Context mapping

    /// Map a `RouteRequest` onto the cost model's `RoutingContext`: preferences
    /// drive toll/highway avoidance, the departure hour drives rush weighting, and
    /// active no-go zones are resolved to `RoutedZone`s and split into hard
    /// exclusions vs soft "rather avoid" penalties.
    nonisolated static func routingContext(for request: RouteRequest) -> RoutingContext {
        var context = RoutingContext()
        context.avoidsTolls = request.preferences.avoidsTolls
        context.avoidsHighways = request.preferences.avoidsHighways
        context.departureHour = Calendar.current.component(.hour, from: request.departureDate)

        let active = request.noGoZones.filter { $0.isActive(now: request.departureDate) }
        // Today's product semantics are hard exclusion (§5.3); soft zones are a
        // future toggle, so every active zone resolves to a hard exclusion here.
        context.hardZones = active.compactMap { Self.routedZone(from: $0) }
        return context
    }

    /// Convert a `NoGoZone` (SwiftData model) into a pure `RoutedZone` the cost
    /// model can test geometry against — decoding its polyline/circle once so the
    /// hot cost path does pure geometry, never JSON (§5.3).
    nonisolated static func routedZone(from zone: NoGoZone) -> RoutedZone? {
        switch zone.geometry {
        case let .circle(center, radiusMeters):
            return RoutedZone(shape: .circle(center: center, radiusMeters: radiusMeters))
        case let .corridor(encodedPolyline, bufferMeters):
            let coords = PolylineEncoder.decode(encodedPolyline, precision: 6)
            guard coords.count >= 2 else { return nil }
            return RoutedZone(shape: .corridor(polyline: coords, widthMeters: bufferMeters))
        case let .polygon(encodedPolyline):
            let coords = PolylineEncoder.decode(encodedPolyline, precision: 6)
            guard coords.count >= 3 else { return nil }
            return RoutedZone(shape: .polygon(vertices: coords))
        }
    }

    // MARK: - Corridor + duration

    /// Densify the endpoint chain into a corridor centerline so the loader's
    /// `around` clauses cover the whole ribbon (long legs get intermediate
    /// vertices at ~`spacingMeters` so a 70-mile straight line still fetches a
    /// continuous corridor, not two end discs).
    nonisolated static func corridor(
        origin: CLLocationCoordinate2D,
        waypoints: [CLLocationCoordinate2D],
        destination: CLLocationCoordinate2D,
        spacingMeters: Double
    ) -> [CLLocationCoordinate2D] {
        let stops = [origin] + waypoints + [destination]
        guard stops.count >= 2 else { return stops }
        var out: [CLLocationCoordinate2D] = [stops[0]]
        for i in 0..<(stops.count - 1) {
            let a = stops[i], b = stops[i + 1]
            let segLen = RouteGeometry.haversineDistance(from: a, to: b)
            if segLen > spacingMeters {
                let steps = Int((segLen / spacingMeters).rounded(.up))
                for s in 1..<steps {
                    let t = Double(s) / Double(steps)
                    out.append(CLLocationCoordinate2D(
                        latitude: a.latitude + t * (b.latitude - a.latitude),
                        longitude: a.longitude + t * (b.longitude - a.longitude)
                    ))
                }
            }
            out.append(b)
        }
        return out
    }

    /// Honest, traffic-free route duration. The custom router does NOT own traffic
    /// (§6); the displayed/reroute ETA stays on MKDirections, so this is a baseline
    /// travel time. It prefers the edge-speed sum the search produced
    /// (`StepSynthesizer.freeFlowSeconds`, accumulated per leg) — that respects
    /// each road's real free-flow speed, so a 70-mile freeway leg reads ~70 min,
    /// not ~2h17m at a flat urban speed. The flat-baseline path is the last resort
    /// for a degenerate graph where no edge carried a usable speed.
    nonisolated static func freeFlowDuration(
        edgeFreeFlowSeconds: TimeInterval,
        fallbackCoords: [CLLocationCoordinate2D],
        fallbackDistance: Double
    ) -> TimeInterval {
        if edgeFreeFlowSeconds > 0 { return edgeFreeFlowSeconds }
        return freeFlowDuration(of: fallbackCoords, fallbackDistance: fallbackDistance)
    }

    /// Last-resort flat free-flow estimate over a polyline at a default urban
    /// speed, used only when the edge-speed sum is unavailable (no edge carried a
    /// usable `freeFlowSpeedMPS`).
    private static let defaultFreeFlowMPS: Double = 13.4   // ~30 mph mixed urban

    nonisolated static func freeFlowDuration(of coords: [CLLocationCoordinate2D], fallbackDistance: Double) -> TimeInterval {
        let distance = fallbackDistance > 0 ? fallbackDistance : (RouteGeometry.cumulativeDistances(coords).last ?? 0)
        guard distance > 0 else { return 0 }
        return distance / defaultFreeFlowMPS
    }
}
