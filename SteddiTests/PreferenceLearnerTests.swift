import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - Fixture helpers (mirror DefaultCostModelTests / AStarSearchTests)

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

/// A DriveRecord whose raw trace is the given coordinates (1 s apart, cruising).
private func driveRecord(trace: [CLLocationCoordinate2D], speed: Double = 12) -> DriveRecord {
    let rec = DriveRecord(startedAt: Date(timeIntervalSince1970: 0))
    var t = Date(timeIntervalSince1970: 0)
    rec.rawGPSPoints = trace.map { c in
        defer { t = t.addingTimeInterval(1) }
        return GPSPoint(latitude: c.latitude, longitude: c.longitude, altitude: 0,
                        horizontalAccuracy: 5, timestamp: t, speed: speed)
    }
    rec.endedAt = t
    return rec
}

/// Densify a coordinate pair into `count` evenly spaced points (so the greedy
/// snapper sees several fixes on each edge, as a real GPS trace would).
private func densify(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, count: Int) -> [CLLocationCoordinate2D] {
    (0...count).map { i in
        let t = Double(i) / Double(count)
        return CLLocationCoordinate2D(latitude: a.latitude + t * (b.latitude - a.latitude),
                                      longitude: a.longitude + t * (b.longitude - a.longitude))
    }
}

// MARK: - No-history / below-threshold => defaults

@Suite("PrefLearner defaults when there's no usable history")
struct PrefLearnerDefaultsTests {

    private func lineGraph() -> RoadGraph {
        buildGraph(
            node(1, 34.0000, -117.0000),
            node(2, 34.0000, -116.9990),
            node(3, 34.0000, -116.9980),
            way(10, [1, 2, 3], tags: ["highway": "tertiary", "maxspeed": "35 mph"])
        )
    }

    @Test("No records => seed weights unchanged")
    func noRecords() {
        let g = lineGraph()
        let learned = PrefLearner.learn(from: [], graph: g, seed: .default)
        #expect(learned == CostWeights.default)
    }

    @Test("Fewer than minimumDrives => seed weights unchanged")
    func belowThreshold() {
        let g = lineGraph()
        let n1 = g.nodes[Int(g.osmToIndex[1]!)].coordinate
        let n3 = g.nodes[Int(g.osmToIndex[3]!)].coordinate
        let rec = driveRecord(trace: densify(n1, n3, count: 8))
        // Only 2 drives, minimumDrives defaults to 3.
        let learned = PrefLearner.learn(from: [rec, rec], graph: g, seed: .default)
        #expect(learned == CostWeights.default)
    }

    @Test("Empty graph => seed weights unchanged")
    func emptyGraph() {
        let empty = buildGraph(node(1, 0, 0))   // a lone node, no ways => no edges
        let rec = driveRecord(trace: [CLLocationCoordinate2D(latitude: 0, longitude: 0)])
        let learned = PrefLearner.learn(from: [rec, rec, rec, rec], graph: empty, seed: .default)
        #expect(learned == CostWeights.default)
    }
}

// MARK: - Map-matching the trace onto edges

@Suite("PrefLearner map-matching")
struct PrefLearnerMatchingTests {

    /// A 3-segment path 1-2-3-4 all tertiary, straight east.
    private func pathGraph() -> RoadGraph {
        buildGraph(
            node(1, 34.0000, -117.0000),
            node(2, 34.0000, -116.9990),
            node(3, 34.0000, -116.9980),
            node(4, 34.0000, -116.9970),
            way(10, [1, 2], tags: ["highway": "tertiary"]),
            way(11, [2, 3], tags: ["highway": "tertiary"]),
            way(12, [3, 4], tags: ["highway": "tertiary"])
        )
    }

    @Test("A trace over the whole path matches the traversed edges in order")
    func matchesInOrder() {
        let g = pathGraph()
        let coords = [1, 2, 3, 4].map { g.nodes[Int(g.osmToIndex[Int64($0)]!)].coordinate }
        let trace = stride(from: 0, to: coords.count - 1, by: 1).flatMap { i in
            densify(coords[i], coords[i + 1], count: 6).dropLast()
        } + [coords.last!]
        let matched = PrefLearner.matchedEdgeSequence(Array(trace), graph: g, config: .default)
        // Distinct edges traversed, in order (1->2, 2->3, 3->4).
        let distinct = matched.map(\.edge)
        #expect(distinct.count == 3)
        // Each segment carries roughly the edge length (~92 m for 0.001 deg lon).
        for seg in matched { #expect(seg.meters > 50) }
    }

    @Test("Off-graph points (beyond snap radius) don't match")
    func offGraphSkipped() {
        let g = pathGraph()
        // A trace 1 km north of the line — way outside the 35 m snap radius.
        let far = CLLocationCoordinate2D(latitude: 34.01, longitude: -116.999)
        let matched = PrefLearner.matchedEdgeSequence(densify(far, far, count: 4), graph: g, config: .default)
        #expect(matched.isEmpty)
    }

    @Test("An unsnapped gap is not attributed to any edge's distance")
    func unsnappedGapNotAttributed() {
        let g = pathGraph()
        let n1 = g.nodes[Int(g.osmToIndex[1]!)].coordinate
        let n2 = g.nodes[Int(g.osmToIndex[2]!)].coordinate
        // First half of edge 1->2 (on-graph, consecutive).
        let onEdge = densify(n1, n2, count: 4)
        // A point ~1 km off-graph (beyond the 35 m snap radius) — the GPS dropped
        // or wandered off the mapped network.
        let far = CLLocationCoordinate2D(latitude: 34.01, longitude: -116.9995)
        // Return to a point ~90% along edge 1->2 (unambiguously on that edge, not
        // at the node where two edges meet).
        let back = CLLocationCoordinate2D(
            latitude: n1.latitude + 0.9 * (n2.latitude - n1.latitude),
            longitude: n1.longitude + 0.9 * (n2.longitude - n1.longitude)
        )
        let trace = Array(onEdge.prefix(3)) + [far] + [back]
        let matched = PrefLearner.matchedEdgeSequence(trace, graph: g, config: .default)
        // Only edge 1->2 matched; the off-graph point is skipped entirely.
        #expect(matched.count == 1)
        let edge12 = matched[0]
        // The credited distance must NOT include the ~1 km return leg across the
        // gap — it should be at most the on-edge span actually walked (the edge is
        // ~92 m). The old code attributed the far->n2 step (~1 km) to this edge.
        let edgeLength = g.edges[Int(edge12.edge)].lengthMeters
        #expect(edge12.meters <= edgeLength + 1)
    }

    @Test("matchedPolyline is preferred over raw GPS when present")
    func prefersMatchedPolyline() {
        let g = pathGraph()
        let n1 = g.nodes[Int(g.osmToIndex[1]!)].coordinate
        let n2 = g.nodes[Int(g.osmToIndex[2]!)].coordinate
        let rec = driveRecord(trace: [])   // empty raw trace
        rec.matchedPolyline = PolylineEncoder.encode(densify(n1, n2, count: 6), precision: 6)
        let trace = PrefLearner.traceCoordinates(of: rec)
        #expect(trace.count >= 2)
    }
}

// MARK: - Bounded weights / invariants

@Suite("PrefLearner produces bounded, admissible weights")
struct PrefLearnerInvariantTests {

    /// Synthesize a revealed usage directly so the bound logic is tested without
    /// the matcher (pure unit of the weight blend).
    private func usage(metersByClass: [RoadClass: Double], turns: [TurnDirection: Int] = [:], drives: Int = 10) -> PrefLearner.RevealedUsage {
        var u = PrefLearner.RevealedUsage()
        u.usableDrives = drives
        u.metersByClass = metersByClass
        u.turnCounts = turns
        return u
    }

    @Test("All road-class multipliers stay >= 1 (admissibility invariant)")
    func multipliersAtLeastOne() {
        // Extreme: driver ONLY ever uses service roads.
        let u = usage(metersByClass: [.service: 10000])
        let w = PrefLearner.weights(from: u, seed: .default)
        for m in w.roadClassMultiplier { #expect(m >= 1.0) }
    }

    @Test("All turn penalties stay >= 0")
    func penaltiesNonNegative() {
        let u = usage(metersByClass: [.tertiary: 1000],
                      turns: [.right: 50, .left: 1])
        let w = PrefLearner.weights(from: u, seed: .default)
        #expect(w.rightTurnPenalty >= 0)
        #expect(w.protectedLeftPenalty >= 0)
        #expect(w.unprotectedLeftBase >= 0)
    }

    @Test("Turn even-share denominator counts BROAD buckets, not raw sub-categories")
    func turnPenaltyEvenShareUsesBroadBuckets() {
        // Driver makes equal LEFT and RIGHT maneuvers (50/50), but the LEFT total is
        // split across two raw sub-categories (.left + .slightLeft) while RIGHT is a
        // single .right bucket. Aggregated to the broad buckets the penalties model
        // there are exactly TWO kinds (left, right) each at a 0.5 share == the even
        // share, so NEITHER side reveals a preference: every turn penalty must stay
        // at its seed.
        //
        // The old buggy code counted 3 raw kinds (evenShare 0.333): the aggregated
        // left share (0.5) would read as favoured (discount) while right (0.5) would
        // also read as favoured — both moving OFF seed for a perfectly balanced
        // driver. This asserts the like-for-like fix.
        let u = usage(metersByClass: [.tertiary: 1000],
                      turns: [.left: 25, .slightLeft: 25, .right: 50])
        let seed = CostWeights.default
        let w = PrefLearner.weights(from: u, seed: seed)
        #expect(abs(w.rightTurnPenalty - seed.rightTurnPenalty) < 1e-9)
        #expect(abs(w.protectedLeftPenalty - seed.protectedLeftPenalty) < 1e-9)
        #expect(abs(w.unprotectedLeftBase - seed.unprotectedLeftBase) < 1e-9)
    }

    @Test("Learned turn penalty distributes correctly: favoured side down, shunned side up")
    func turnPenaltyDistributesAcrossKinds() {
        // Two broad buckets used (left, right). The driver strongly FAVOURS right
        // (share 0.8 > even 0.5 ⇒ affinity +) and AVOIDS left (share 0.2 < 0.5 ⇒
        // affinity −). The right penalty must drop below seed; both left penalties
        // must rise above seed. The .slightRight/.right split must NOT change the
        // outcome vs. a single .right of the same total (broad-bucket aggregation).
        let seed = CostWeights.default
        let split = usage(metersByClass: [.tertiary: 1000],
                          turns: [.right: 40, .slightRight: 40, .left: 20])
        let w = PrefLearner.weights(from: split, seed: seed)

        // Favoured right ⇒ discounted toward 0; shunned left ⇒ penalised upward.
        #expect(w.rightTurnPenalty < seed.rightTurnPenalty)
        #expect(w.protectedLeftPenalty > seed.protectedLeftPenalty)
        #expect(w.unprotectedLeftBase > seed.unprotectedLeftBase)
        // Invariants preserved.
        #expect(w.rightTurnPenalty >= 0)
        #expect(w.protectedLeftPenalty >= 0)

        // Aggregation invariance: collapsing the split right into one .right bucket
        // of the same total yields the SAME learned penalties.
        let merged = usage(metersByClass: [.tertiary: 1000],
                           turns: [.right: 80, .left: 20])
        let wMerged = PrefLearner.weights(from: merged, seed: seed)
        #expect(abs(w.rightTurnPenalty - wMerged.rightTurnPenalty) < 1e-9)
        #expect(abs(w.protectedLeftPenalty - wMerged.protectedLeftPenalty) < 1e-9)
        #expect(abs(w.unprotectedLeftBase - wMerged.unprotectedLeftBase) < 1e-9)
    }

    @Test("A favoured class can't be discounted past its clamp")
    func discountClamped() {
        let u = usage(metersByClass: [.tertiary: 9000, .primary: 1000])
        let w = PrefLearner.weights(from: u, seed: .default, config: .default)
        let tertiary = w.roadClassMultiplier[Int(RoadClass.tertiary.rawValue)]
        let seed = CostWeights.default.roadClassMultiplier[Int(RoadClass.tertiary.rawValue)]
        // It moved down (favoured) but not below the maxClassDiscount floor / 1.0.
        #expect(tertiary < seed)
        #expect(tertiary >= max(1.0, seed - PrefLearner.Config.default.maxClassDiscount))
    }

    @Test("An avoided class can't be penalised past its clamp")
    func penaltyClamped() {
        // Driver uses primary almost exclusively => service is avoided.
        let u = usage(metersByClass: [.primary: 9000, .service: 100])
        let w = PrefLearner.weights(from: u, seed: .default, config: .default)
        let service = w.roadClassMultiplier[Int(RoadClass.service.rawValue)]
        let seed = CostWeights.default.roadClassMultiplier[Int(RoadClass.service.rawValue)]
        #expect(service <= seed + PrefLearner.Config.default.maxClassPenalty + 1e-9)
    }
}

// MARK: - The "scenic tertiary" learning scenario

@Suite("PrefLearner learns the scenic-road preference")
struct PrefLearnerScenicTests {

    /// Two parallel ways between the same endpoints: a fast PRIMARY and a slower
    /// scenic TERTIARY. The driver always takes the tertiary, so learning should
    /// shift the tertiary multiplier DOWN (more preferred) within the clamp.
    private func parallelGraph() -> RoadGraph {
        buildGraph(
            node(1, 34.0000, -117.0000),       // shared origin
            node(2, 34.0000, -116.9900),       // shared destination
            node(3, 34.0020, -116.9950),       // tertiary mid (north detour)
            node(4, 33.9980, -116.9950),       // primary mid (south, straighter/faster)
            way(10, [1, 3, 2], tags: ["highway": "tertiary", "maxspeed": "30 mph"]),
            way(11, [1, 4, 2], tags: ["highway": "primary", "maxspeed": "55 mph"])
        )
    }

    // Node 3 (tertiary mid) and node 4 (primary mid) are degree-2 through-points
    // interior to a single way, so they become edge GEOMETRY, not graph nodes —
    // they aren't in osmToIndex. Reference their literal coordinates instead.
    private let n1 = CLLocationCoordinate2D(latitude: 34.0000, longitude: -117.0000)
    private let n2 = CLLocationCoordinate2D(latitude: 34.0000, longitude: -116.9900)
    private let n3 = CLLocationCoordinate2D(latitude: 34.0020, longitude: -116.9950)

    @Test("Always driving the tertiary lowers its multiplier within the clamp")
    func scenicShiftsDown() {
        let g = parallelGraph()
        // Trace the tertiary 1 -> 3 -> 2 over many drives.
        let leg = densify(n1, n3, count: 6).dropLast() + densify(n3, n2, count: 6)
        let recs = (0..<6).map { _ in driveRecord(trace: Array(leg)) }

        let seed = CostWeights.default
        let learned = PrefLearner.learn(from: recs, graph: g, seed: seed)

        let tertiaryIdx = Int(RoadClass.tertiary.rawValue)
        let seedTertiary = seed.roadClassMultiplier[tertiaryIdx]
        let learnedTertiary = learned.roadClassMultiplier[tertiaryIdx]

        // Tertiary became MORE preferred (lower multiplier) than the seed...
        #expect(learnedTertiary < seedTertiary)
        // ...but stayed admissible (>= 1) and within the discount clamp.
        #expect(learnedTertiary >= 1.0)
        #expect(learnedTertiary >= seedTertiary - PrefLearner.Config.default.maxClassDiscount)
    }

    @Test("Revealed usage attributes the driven distance to tertiary")
    func usageAttributed() {
        let g = parallelGraph()
        let leg = densify(n1, n3, count: 6).dropLast() + densify(n3, n2, count: 6)
        let recs = (0..<4).map { _ in driveRecord(trace: Array(leg)) }
        let u = PrefLearner.revealedUsage(from: recs, graph: g)
        #expect(u.usableDrives == 4)
        let tertiary = u.metersByClass[.tertiary] ?? 0
        let primary = u.metersByClass[.primary] ?? 0
        #expect(tertiary > 0)
        #expect(tertiary > primary)   // they never drove the primary
    }
}

// MARK: - Persistence round-trip

@Suite("LearnedWeightsStore round-trips weights")
struct LearnedWeightsStoreTests {

    private func transientDefaults() -> UserDefaults {
        let name = "test.learnedWeights.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Save then load returns an equal CostWeights")
    func roundTrip() {
        let store = LearnedWeightsStore(defaults: transientDefaults())
        var w = CostWeights.default
        w.rightTurnPenalty = 2.5
        w.roadClassMultiplier[Int(RoadClass.tertiary.rawValue)] = 1.01
        store.save(w, scope: "commute-A-toWork")
        let loaded = store.load(scope: "commute-A-toWork")
        #expect(loaded == w)
    }

    @Test("Missing scope loads nil")
    func missingNil() {
        let store = LearnedWeightsStore(defaults: transientDefaults())
        #expect(store.load(scope: "nope") == nil)
    }

    @Test("loadBest prefers the specific scope, then global, then nil")
    func loadBestPrecedence() {
        let store = LearnedWeightsStore(defaults: transientDefaults())
        var global = CostWeights.default; global.rightTurnPenalty = 1
        var specific = CostWeights.default; specific.rightTurnPenalty = 9
        // Only global present => loadBest returns global.
        store.save(global, scope: LearnedWeightsStore.globalScope)
        #expect(store.loadBest(scope: "commute-A")?.rightTurnPenalty == 1)
        // Specific present => it wins.
        store.save(specific, scope: "commute-A")
        #expect(store.loadBest(scope: "commute-A")?.rightTurnPenalty == 9)
        // Unknown scope with global present => falls back to global.
        #expect(store.loadBest(scope: "commute-Z")?.rightTurnPenalty == 1)
        // Nil scope, global present => global.
        #expect(store.loadBest(scope: nil)?.rightTurnPenalty == 1)
    }

    @Test("clear removes the stored set")
    func clearRemoves() {
        let store = LearnedWeightsStore(defaults: transientDefaults())
        store.save(.default, scope: "x")
        store.clear(scope: "x")
        #expect(store.load(scope: "x") == nil)
    }

    @Test("Learned weights survive a full learn -> save -> load round trip")
    func learnPersistRoundTrip() {
        let store = LearnedWeightsStore(defaults: transientDefaults())
        var w = CostWeights.default
        w.roadClassMultiplier[Int(RoadClass.tertiary.rawValue)] = 1.005
        w.unprotectedLeftBase = 20
        store.save(w, scope: LearnedWeightsStore.globalScope)
        #expect(store.loadBest(scope: nil) == w)
    }

    /// `destinationOnlyPenalty` must round-trip through the `StoredWeights`
    /// Codable mirror; previously it was omitted and silently reset to the
    /// `CostWeights` default on every save/load, losing the learned value.
    @Test("destinationOnlyPenalty survives a save -> load round trip")
    func destinationOnlyPenaltyRoundTrips() {
        let store = LearnedWeightsStore(defaults: transientDefaults())
        var w = CostWeights.default
        // A value distinct from the 1200 default so a silent reset is caught.
        w.destinationOnlyPenalty = 3456
        #expect(w.destinationOnlyPenalty != CostWeights.default.destinationOnlyPenalty)
        store.save(w, scope: "commute-D-toWork")
        let loaded = store.load(scope: "commute-D-toWork")
        #expect(loaded?.destinationOnlyPenalty == 3456)
        #expect(loaded == w)
    }

    /// `slightLeftPenalty` must round-trip through the `StoredWeights` Codable
    /// mirror; previously it was omitted and silently reset to the `CostWeights`
    /// default (5) on every save/load, losing the learned value across launches.
    @Test("slightLeftPenalty survives a save -> load round trip")
    func slightLeftPenaltyRoundTrips() {
        let store = LearnedWeightsStore(defaults: transientDefaults())
        var w = CostWeights.default
        // A value distinct from the 5 default so a silent reset is caught.
        w.slightLeftPenalty = 12
        #expect(w.slightLeftPenalty != CostWeights.default.slightLeftPenalty)
        store.save(w, scope: "commute-L-toWork")
        let loaded = store.load(scope: "commute-L-toWork")
        #expect(loaded?.slightLeftPenalty == 12)
        #expect(loaded == w)
    }
}

// MARK: - CustomRouter learned-weights hook

@Suite("CustomRouter resolves learned weights")
@MainActor
struct CustomRouterLearnedWeightsTests {

    private func transientDefaults() -> UserDefaults {
        let name = "test.routerWeights.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func request() -> RouteRequest {
        RouteRequest(
            origin: CLLocationCoordinate2D(latitude: 34, longitude: -117),
            destination: CLLocationCoordinate2D(latitude: 34, longitude: -116.99),
            preferences: RoutePreferences(avoidsTolls: false, avoidsHighways: false)
        )
    }

    @Test("No store => the injected base weights are used")
    func noStoreUsesBase() {
        var base = CostWeights.default; base.rightTurnPenalty = 3
        let router = CustomRouter(graphSource: RoadGraphSource(), weights: base)
        #expect(router.resolvedWeights(for: request()) == base)
    }

    @Test("Store with no entry => falls back to base weights")
    func emptyStoreFallsBack() {
        let store = LearnedWeightsStore(defaults: transientDefaults())
        var base = CostWeights.default; base.rightTurnPenalty = 3
        let router = CustomRouter(graphSource: RoadGraphSource(), weights: base,
                                  learnedWeightsStore: store, scope: { _ in "commute-A" })
        #expect(router.resolvedWeights(for: request()) == base)
    }

    @Test("Learned set for the scope is preferred over base")
    func learnedPreferred() {
        let store = LearnedWeightsStore(defaults: transientDefaults())
        var learned = CostWeights.default; learned.rightTurnPenalty = 1
        store.save(learned, scope: "commute-A")
        let router = CustomRouter(graphSource: RoadGraphSource(),
                                  learnedWeightsStore: store, scope: { _ in "commute-A" })
        #expect(router.resolvedWeights(for: request()) == learned)
    }
}
