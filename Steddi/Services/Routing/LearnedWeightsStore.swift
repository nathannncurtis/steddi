import Foundation

/// Persistence for the per-driver weights `PrefLearner` produces (Phase 7).
///
/// Deliberately lightweight — JSON in `UserDefaults`, keyed per scope, no schema
/// and no migration (matching the spec's "UserDefaults/JSON is fine" note). A
/// learned set is small (one `CostWeights`), is refreshed after each drive, and
/// is cheap to read on the routing path, so a heavyweight store would be
/// over-engineering. If the format ever changes, a decode failure simply yields
/// `nil` and routing falls back to `CostWeights.default` — the same graceful
/// degradation the rest of the router uses.
///
/// Scope is a free-form string so weights can be stored **per commute/direction**
/// (`"commute-<uuid>-toWork"`) or **globally** (`LearnedWeightsStore.globalScope`).
/// The router reads the most specific scope available and falls back to global,
/// then to `.default`.
struct LearnedWeightsStore: Sendable {

    /// The scope used when no per-commute scope is supplied.
    static let globalScope = "global"

    private let defaults: UserDefaults
    private let keyPrefix: String

    /// - Parameters:
    ///   - defaults: injectable for tests (use a transient suite); `.standard` in
    ///     production.
    ///   - keyPrefix: namespacing prefix so learned weights don't collide with
    ///     other `UserDefaults` keys.
    init(defaults: UserDefaults = .standard, keyPrefix: String = "steddi.learnedWeights.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    private func key(for scope: String) -> String { keyPrefix + scope }

    /// Persist `weights` for `scope`. Overwrites any prior set for that scope.
    func save(_ weights: CostWeights, scope: String) {
        guard let data = try? JSONEncoder().encode(StoredWeights(weights)) else { return }
        defaults.set(data, forKey: key(for: scope))
    }

    /// Load the weights for `scope`, or `nil` if none are stored (or the stored
    /// blob can't be decoded — caller then uses `.default`).
    func load(scope: String) -> CostWeights? {
        guard let data = defaults.data(forKey: key(for: scope)),
              let stored = try? JSONDecoder().decode(StoredWeights.self, from: data) else {
            return nil
        }
        return stored.costWeights
    }

    /// Load the best available weights for a commute scope: the per-scope set if
    /// present, else the global set, else `nil`.
    func loadBest(scope: String?) -> CostWeights? {
        if let scope, let specific = load(scope: scope) { return specific }
        return load(scope: Self.globalScope)
    }

    /// Remove any stored weights for `scope` (e.g. on commute deletion).
    func clear(scope: String) {
        defaults.removeObject(forKey: key(for: scope))
    }
}

/// Codable shadow of `CostWeights`. Kept separate from `CostWeights` (which lives
/// in the Phase-4 cost model and stays a pure value with no persistence coupling)
/// so the on-disk shape is owned by the store, not the cost model. Field-by-field
/// so a future `CostWeights` addition is a deliberate, reviewed change here.
private struct StoredWeights: Codable {
    var straightPenalty: Double
    var rightTurnPenalty: Double
    var protectedLeftPenalty: Double
    var unprotectedLeftBase: Double
    var unprotectedLeftPerOncomingLane: Double
    var uTurnPenalty: Double
    var stopSignPenalty: Double
    var trafficSignalPenalty: Double
    var roadClassMultiplier: [Double]
    var avoidHighwayMultiplier: Double
    var tollPenalty: Double
    var rushHourMultiplier: Double
    var softZoneTimeMultiplier: Double

    init(_ w: CostWeights) {
        straightPenalty = w.straightPenalty
        rightTurnPenalty = w.rightTurnPenalty
        protectedLeftPenalty = w.protectedLeftPenalty
        unprotectedLeftBase = w.unprotectedLeftBase
        unprotectedLeftPerOncomingLane = w.unprotectedLeftPerOncomingLane
        uTurnPenalty = w.uTurnPenalty
        stopSignPenalty = w.stopSignPenalty
        trafficSignalPenalty = w.trafficSignalPenalty
        roadClassMultiplier = w.roadClassMultiplier
        avoidHighwayMultiplier = w.avoidHighwayMultiplier
        tollPenalty = w.tollPenalty
        rushHourMultiplier = w.rushHourMultiplier
        softZoneTimeMultiplier = w.softZoneTimeMultiplier
    }

    var costWeights: CostWeights {
        var w = CostWeights()
        w.straightPenalty = straightPenalty
        w.rightTurnPenalty = rightTurnPenalty
        w.protectedLeftPenalty = protectedLeftPenalty
        w.unprotectedLeftBase = unprotectedLeftBase
        w.unprotectedLeftPerOncomingLane = unprotectedLeftPerOncomingLane
        w.uTurnPenalty = uTurnPenalty
        w.stopSignPenalty = stopSignPenalty
        w.trafficSignalPenalty = trafficSignalPenalty
        w.roadClassMultiplier = roadClassMultiplier
        w.avoidHighwayMultiplier = avoidHighwayMultiplier
        w.tollPenalty = tollPenalty
        w.rushHourMultiplier = rushHourMultiplier
        w.softZoneTimeMultiplier = softZoneTimeMultiplier
        return w
    }
}
