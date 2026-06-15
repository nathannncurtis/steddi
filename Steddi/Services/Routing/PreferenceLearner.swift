import Foundation
import CoreLocation

/// Per-driver preference learning (Phase 7) — the "your route, your rules"
/// promise made *inferred* rather than configured.
///
/// `PrefLearner` is a **pure, offline, fully unit-testable** component (it mirrors
/// the codebase's pure-engine culture — `RerouteEngine`, `ZoneValidationEngine`).
/// It reads the driver's own `DriveRecord` GPS traces, map-matches each onto the
/// corridor `RoadGraph`, and asks a simple question: *what does this driver
/// actually favour or avoid that the `DefaultCostModel` would not pick on its
/// own?* The answer is a **tuned `CostWeights`** — road-class multipliers and turn
/// penalties nudged toward the driver's revealed preference.
///
/// ## Why a weights adjustment (not per-edge biases)
/// A weights-level tuning generalizes: learning "this driver loves tertiary
/// scenic roads" lowers the tertiary multiplier *everywhere in the corridor*, not
/// just on the exact edges they happened to drive. It is also tiny to persist
/// (one `CostWeights`), survives graph refetches (no edge-id coupling), and feeds
/// straight back into the existing `DefaultCostModel` with zero hot-path cost.
///
/// ## Conservative by construction (the invariants)
/// Learning can NEVER produce absurd or unsafe weights:
/// - It is a **blend**: `tuned = lerp(default, revealed, learningRate)` so a few
///   drives only nudge, never overwrite.
/// - Every output is **clamped** to a sane band, and the band itself respects the
///   admissibility invariant — all multipliers stay `>= 1`, all penalties `>= 0`
///   (see `CostWeights` doc). A road the driver loves can be made *no cheaper than
///   its free-flow time* (multiplier floored at 1), which keeps the A* heuristic a
///   valid lower bound. A road they avoid is bounded above so one bad inference
///   can't wall off the corridor.
/// - **No history ⇒ defaults.** Below `minimumDrives`, learning is inert.
enum PrefLearner {

    // MARK: - Configuration

    /// Tuning knobs for the learner. Injected data (like `CostWeights`) so the
    /// learning behaviour is configured and unit-pinned, never a magic literal.
    struct Config: Sendable, Equatable {
        /// Below this many usable drives the learner returns the seed weights
        /// unchanged — a single fluke drive must not reshape routing.
        var minimumDrives: Int = 3
        /// Blend factor toward the driver's revealed preference, in 0...1. 0 keeps
        /// the seed weights; 1 would jump fully to the revealed target (we never
        /// use 1 in production — conservative nudging is the point).
        var learningRate: Double = 0.5
        /// How far a road-class multiplier may move below its seed value when the
        /// driver favours that class (a discount toward, but never past, 1.0).
        var maxClassDiscount: Double = 0.5
        /// How far a road-class multiplier may move above its seed when the driver
        /// avoids that class. Bounded so a mis-inference can't make a class
        /// effectively impassable.
        var maxClassPenalty: Double = 1.0
        /// Fraction by which a turn penalty may move toward 0 (driver tolerates
        /// the maneuver) or grow (driver avoids it). e.g. 0.5 ⇒ at most halve or
        /// 1.5× a turn penalty.
        var maxTurnDelta: Double = 0.5
        /// Max distance (m) a trace point may be from an edge to count as on it.
        /// Beyond this the point is treated as off-graph and skipped (parking
        /// lots, GPS noise), so off-graph noise can't poison the tally.
        var snapMaxDistanceMeters: Double = 35
        /// GPS points closer together than this contribute no road-class distance
        /// (stationary jitter); avoids over-counting time spent idling.
        var minSegmentMeters: Double = 5

        static let `default` = Config()
    }

    // MARK: - Revealed usage (intermediate, also exposed for tests)

    /// What the driver's traces revealed, before it is turned into weights. Pure
    /// data so tests can assert the tally independently of the weight blend.
    struct RevealedUsage: Sendable, Equatable {
        /// Drives that contributed at least one matched segment.
        var usableDrives: Int = 0
        /// Metres travelled on each `RoadClass` (indexed by `rawValue`, 0...9;
        /// `unknown` is dropped). The driver's modal-share of road classes.
        var metersByClass: [RoadClass: Double] = [:]
        /// Count of each turn category the driver actually made at graph nodes.
        var turnCounts: [TurnDirection: Int] = [:]
        /// The distinct drivable classes the CORRIDOR offers (not just the ones the
        /// driver used). This is the reference set for affinity: a driver who pours
        /// all their distance into tertiary while primary is *available* reveals a
        /// preference, even though they touched only one class. Without this, a
        /// single-class driver would have zero affinity and learning would no-op.
        var availableClasses: Set<RoadClass> = []

        /// Total matched distance across all classes (denominator for shares).
        var totalMeters: Double { metersByClass.values.reduce(0, +) }
    }

    // MARK: - Entry point

    /// Derive a tuned `CostWeights` from the driver's history.
    ///
    /// - Parameters:
    ///   - records: the driver's `DriveRecord`s for one commute/direction. Each is
    ///     map-matched onto `graph` via `matchedPolyline` if present, else
    ///     `rawGPSPoints`.
    ///   - graph: the corridor graph the routes were driven on.
    ///   - seed: the weights to learn *from* (the shipping `CostWeights.default`,
    ///     or a previously learned set for incremental refinement).
    ///   - config: learning knobs.
    /// - Returns: bounded, admissibility-preserving weights. With `< minimumDrives`
    ///   usable drives, returns `seed` unchanged.
    static func learn(
        from records: [DriveRecord],
        graph: RoadGraph,
        seed: CostWeights = .default,
        config: Config = .default
    ) -> CostWeights {
        let usage = revealedUsage(from: records, graph: graph, config: config)
        return weights(from: usage, seed: seed, config: config)
    }

    // MARK: - Map-match traces → revealed usage (pure)

    /// Tally road-class distance and turn categories over the driver's traces by
    /// snapping each trace polyline onto the graph. A point that doesn't snap
    /// within `snapMaxDistanceMeters` is skipped; a drive with no matched segment
    /// doesn't count toward `usableDrives`.
    static func revealedUsage(
        from records: [DriveRecord],
        graph: RoadGraph,
        config: Config = .default
    ) -> RevealedUsage {
        var usage = RevealedUsage()
        guard !graph.edges.isEmpty else { return usage }

        // Reference set: every drivable class the corridor offers.
        for edge in graph.edges where edge.roadClass != .unknown {
            usage.availableClasses.insert(edge.roadClass)
        }

        for record in records {
            let trace = traceCoordinates(of: record)
            guard trace.count >= 2 else { continue }
            let matched = matchedEdgeSequence(trace, graph: graph, config: config)
            guard !matched.isEmpty else { continue }
            usage.usableDrives += 1

            // Road-class distance: attribute each matched segment's length to its
            // edge's class. Use the matched segment span (not the whole edge) so a
            // partial pass-through is counted proportionally.
            for seg in matched {
                let cls = graph.edges[Int(seg.edge)].roadClass
                guard cls != .unknown, seg.meters >= config.minSegmentMeters else { continue }
                usage.metersByClass[cls, default: 0] += seg.meters
            }

            // Turn categories: classify each consecutive distinct-edge pair the
            // driver traversed (their actual maneuver mix at junctions).
            var lastEdge: EdgeIndex?
            for seg in matched {
                if let prev = lastEdge, prev != seg.edge {
                    let incoming = graph.edges[Int(prev)]
                    let outgoing = graph.edges[Int(seg.edge)]
                    // Only count a real maneuver: the edges must meet at a node.
                    if incoming.to == outgoing.from {
                        let turn = DefaultCostModel.classifyTurn(from: incoming, to: outgoing, in: graph)
                        usage.turnCounts[turn, default: 0] += 1
                    }
                }
                lastEdge = seg.edge
            }
        }
        return usage
    }

    /// One matched segment of a trace: an edge and the metres of the trace that
    /// lay on it.
    struct MatchedSegment: Sendable, Equatable {
        let edge: EdgeIndex
        let meters: Double
    }

    /// Snap each trace point to the nearest edge and collapse consecutive points
    /// on the same edge into one segment carrying the trace distance walked on it.
    /// This is a deliberately simple greedy map-match — exact enough for a
    /// road-class/turn tally and pure (no OSRM, testable on canned graphs).
    static func matchedEdgeSequence(
        _ trace: [CLLocationCoordinate2D],
        graph: RoadGraph,
        config: Config
    ) -> [MatchedSegment] {
        var segments: [MatchedSegment] = []
        var current: EdgeIndex?
        var accumulated: Double = 0
        // Index of the most recent point that successfully snapped. A step's
        // distance may be attributed to an edge ONLY when it connects two
        // CONSECUTIVELY-snapped points (no unsnapped/skipped point between them);
        // otherwise we'd credit an edge for ground the driver covered off-graph.
        var lastSnappedIndex: Int?

        for i in 0..<trace.count {
            guard let snap = graph.snap(trace[i], maxDistanceMeters: config.snapMaxDistanceMeters) else {
                continue   // unsnapped point: breaks the consecutive-snap chain
            }
            // Step distance counts only when the previous trace point also snapped
            // and is immediately adjacent (i - 1). A gap (skip) contributes 0.
            let step = (lastSnappedIndex == i - 1)
                ? RouteGeometry.haversineDistance(from: trace[i - 1], to: trace[i])
                : 0
            lastSnappedIndex = i

            if let cur = current, cur == snap.edge {
                accumulated += step
            } else {
                if let cur = current {
                    segments.append(MatchedSegment(edge: cur, meters: accumulated))
                }
                current = snap.edge
                // Credit the transition step (last point on the prior edge → first
                // point on this one) to the edge being ENTERED. Starting the new
                // accumulator at 0 would zero out any edge a trace crosses with a
                // single snapped point, dropping it before the minSegmentMeters
                // filter and biasing the road-class tally toward long edges. `step`
                // is already 0 when the chain broke (unsnapped/skipped point), so
                // this never credits ground covered off-graph.
                accumulated = step
            }
        }
        if let cur = current {
            segments.append(MatchedSegment(edge: cur, meters: accumulated))
        }
        return segments
    }

    /// The trace to match: the road-snapped `matchedPolyline` when present (best),
    /// else the raw GPS fix coordinates.
    static func traceCoordinates(of record: DriveRecord) -> [CLLocationCoordinate2D] {
        if let encoded = record.matchedPolyline {
            let coords = PolylineEncoder.decode(encoded, precision: 6)
            if coords.count >= 2 { return coords }
        }
        return record.rawGPSPoints.map(\.coordinate)
    }

    // MARK: - Revealed usage → tuned weights (pure, bounded)

    /// Blend the seed weights toward the driver's revealed preference, clamped so
    /// the result can never violate the admissibility invariant (multipliers
    /// `>= 1`, penalties `>= 0`) nor stray into absurd territory.
    static func weights(
        from usage: RevealedUsage,
        seed: CostWeights = .default,
        config: Config = .default
    ) -> CostWeights {
        guard usage.usableDrives >= config.minimumDrives, usage.totalMeters > 0 else {
            return seed   // no-history ⇒ defaults
        }

        var tuned = seed

        // --- Road-class multipliers ---
        // A class the driver uses MORE than its "expected" even share gets a
        // discount (toward, never below, 1.0); a class they use LESS gets a small
        // penalty. The reference is an even share across the classes the CORRIDOR
        // offers (`availableClasses`), not just the ones touched — so a driver who
        // pours all their distance into tertiary while primary is *available*
        // reveals a real preference and tertiary shifts down within the clamp,
        // even though only one class was driven.
        let touched = usage.metersByClass.filter { $0.value > 0 }
        // Reference size: the corridor's drivable classes, falling back to the
        // touched set if the graph carried none (defensive — shouldn't happen).
        let referenceCount = max(usage.availableClasses.count, touched.count)
        if !touched.isEmpty, referenceCount > 0 {
            let evenShare = 1.0 / Double(referenceCount)
            for (cls, meters) in touched {
                let idx = Int(cls.rawValue)
                guard idx >= 0, idx < tuned.roadClassMultiplier.count else { continue }
                let share = meters / usage.totalMeters
                // affinity in [-1, 1]: positive ⇒ over-used (favoured).
                let affinity = max(-1, min(1, (share - evenShare) / evenShare))
                let seedMult = seed.roadClassMultiplier[idx]
                let target: Double
                if affinity >= 0 {
                    // Favoured: discount toward 1.0.
                    let floor = max(1.0, seedMult - config.maxClassDiscount)
                    target = seedMult - affinity * (seedMult - floor)
                } else {
                    // Avoided: small penalty above seed.
                    let ceil = seedMult + config.maxClassPenalty
                    target = seedMult + (-affinity) * (ceil - seedMult)
                }
                let blended = seedMult + config.learningRate * (target - seedMult)
                tuned.roadClassMultiplier[idx] = max(1.0, blended)   // invariant: >= 1
            }
        }

        // --- Turn penalties ---
        // A driver who makes a maneuver often relative to its "cost rank" reveals
        // tolerance for it ⇒ lower its penalty (toward 0); one they shun ⇒ raise
        // it. We compare each maneuver's observed share against an even share over
        // the maneuver types the driver actually made.
        let turnTotal = usage.turnCounts.values.reduce(0, +)
        if turnTotal > 0 {
            let usedKinds = usage.turnCounts.filter { $0.value > 0 }.count
            let evenTurnShare = usedKinds > 0 ? 1.0 / Double(usedKinds) : 0
            tuned.rightTurnPenalty = adjustedTurnPenalty(
                seed.rightTurnPenalty, kind: .right, usage: usage,
                turnTotal: turnTotal, evenShare: evenTurnShare, config: config)
            tuned.protectedLeftPenalty = adjustedTurnPenalty(
                seed.protectedLeftPenalty, kind: .left, usage: usage,
                turnTotal: turnTotal, evenShare: evenTurnShare, config: config)
            tuned.unprotectedLeftBase = adjustedTurnPenalty(
                seed.unprotectedLeftBase, kind: .left, usage: usage,
                turnTotal: turnTotal, evenShare: evenTurnShare, config: config)
        }

        return tuned
    }

    /// Move one turn penalty toward 0 (if the driver tolerates the maneuver) or up
    /// (if they avoid it), bounded by `maxTurnDelta` and floored at 0.
    private static func adjustedTurnPenalty(
        _ seedPenalty: Double,
        kind: TurnDirection,
        usage: RevealedUsage,
        turnTotal: Int,
        evenShare: Double,
        config: Config
    ) -> Double {
        // Aggregate left/right into the broad maneuver buckets the penalties model.
        let count: Int
        switch kind {
        case .right, .slightRight:
            count = (usage.turnCounts[.right] ?? 0) + (usage.turnCounts[.slightRight] ?? 0)
        case .left, .slightLeft:
            count = (usage.turnCounts[.left] ?? 0) + (usage.turnCounts[.slightLeft] ?? 0)
        default:
            count = usage.turnCounts[kind] ?? 0
        }
        guard turnTotal > 0 else { return seedPenalty }
        let share = Double(count) / Double(turnTotal)
        // affinity in [-1, 1]: positive ⇒ driver makes this maneuver more than an
        // even share ⇒ tolerates it ⇒ lower the penalty.
        let affinity = evenShare > 0 ? max(-1, min(1, (share - evenShare) / evenShare)) : 0
        let target: Double
        if affinity >= 0 {
            target = seedPenalty * (1 - config.maxTurnDelta * affinity)       // toward 0
        } else {
            target = seedPenalty * (1 + config.maxTurnDelta * (-affinity))    // grow
        }
        let blended = seedPenalty + config.learningRate * (target - seedPenalty)
        return max(0, blended)   // invariant: penalties >= 0
    }
}
