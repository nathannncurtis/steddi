import Foundation
import SwiftData
import CoreLocation
import Observation
import os

private let roadConditionLog = Logger(subsystem: "to.nathancurtis.steddi", category: "RoadCondition")

/// Local-only store and query engine for remembered road conditions.
///
/// Owns the lifecycle (create / confirm / expire / sweep) and the spatial
/// queries used during navigation. Follows the codebase's singleton
/// `@Observable @MainActor` service pattern (`HapticService`,
/// `OSMSpeedLimitService`) and shares the app's `ModelContainer` so it reads
/// and writes the same SwiftData store as the rest of the app.
///
/// Spatial lookups go through a lazily-built grid index (~200m cells), the same
/// shape as `OSMSpeedLimitService`'s speed-limit grid: O(1) cell lookup plus an
/// O(n) scan of the matched cell and its 8 neighbors. The index is invalidated
/// on any mutation so it never serves a stale or deleted condition.
@Observable
@MainActor
final class RoadConditionService {
    static let shared = RoadConditionService()

    /// The store. nil until `configure(container:)` runs at launch; CRUD is a
    /// no-op while unconfigured so previews and early callers don't crash.
    private var modelContainer: ModelContainer?

    /// Wall clock, injectable for deterministic decay tests.
    private let now: () -> Date

    /// The grid currently indexed, keyed by the route id it was built for.
    /// Rebuilt lazily on the first query for a route and cleared on mutation.
    private var index: RoadConditionGridIndex?
    private var indexedRouteID: UUID?

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    /// Wire up the shared container at launch. Idempotent.
    func configure(container: ModelContainer) {
        self.modelContainer = container
    }

    private var context: ModelContext? {
        guard let modelContainer else { return nil }
        return ModelContext(modelContainer)
    }

    // MARK: - Lifecycle (CRUD)

    /// Persist a new active condition tied to a route. Returns the inserted model
    /// (nil if the store is unavailable). Invalidates the spatial index.
    @discardableResult
    func createCondition(
        kind: RoadConditionKind,
        coordinate: CLLocationCoordinate2D,
        route: Route?,
        note: String? = nil
    ) -> RoadCondition? {
        guard let context else { return nil }
        let condition = RoadCondition(
            kind: kind,
            coordinate: coordinate,
            note: note,
            route: route,
            createdAt: now()
        )
        context.insert(condition)
        if let route {
            if route.roadConditions == nil { route.roadConditions = [] }
            route.roadConditions?.append(condition)
        }
        save(context)
        invalidateIndex()
        return condition
    }

    /// User confirmed "still there?" — reset the decay timer. Keeps the
    /// condition active and restarts both the reconfirm and expiry windows.
    func updateConfirmation(_ condition: RoadCondition) {
        condition.lastConfirmedAt = now()
        condition.status = .active
        persistMutation(of: condition)
    }

    /// User reported the condition gone — soft-delete to `.expired`. It leaves
    /// the map and alerts immediately but survives until the 90-day sweep.
    func expireCondition(_ condition: RoadCondition) {
        condition.status = .expired
        persistMutation(of: condition)
    }

    /// Hard-delete every condition whose last confirmation is older than the
    /// 90-day window, plus any already-expired/archived condition past it.
    /// Run at app launch. Returns the number deleted.
    @discardableResult
    func sweepExpiredConditions() -> Int {
        guard let context else { return 0 }
        let cutoff = now().addingTimeInterval(-RoadConditionDecay.expiryWindowDays * 86_400)
        let descriptor = FetchDescriptor<RoadCondition>(
            predicate: #Predicate { $0.lastConfirmedAt < cutoff }
        )
        guard let stale = try? context.fetch(descriptor), !stale.isEmpty else { return 0 }
        for condition in stale { context.delete(condition) }
        save(context)
        invalidateIndex()
        roadConditionLog.info("Swept \(stale.count) expired road conditions")
        return stale.count
    }

    // MARK: - Route-scoped queries

    /// All active conditions tagged to this specific route, ordered by kind
    /// priority then recency. Pulls from the route relationship directly.
    func fetchConditionsOnRoute(_ route: Route) -> [RoadCondition] {
        (route.roadConditions ?? [])
            .filter { $0.status == .active }
            .sorted { lhs, rhs in
                if lhs.kind.priority != rhs.kind.priority {
                    return lhs.kind.priority > rhs.kind.priority
                }
                return lhs.createdAt > rhs.createdAt
            }
    }

    /// Active conditions on this route past the 14-day reconfirm window — the
    /// candidates for the post-arrival "still there?" prompt, oldest first so
    /// the most stale is offered before fresher ones.
    func staleConditionsOnRoute(_ route: Route) -> [RoadCondition] {
        let reference = now()
        return (route.roadConditions ?? [])
            .filter { $0.needsReconfirmation(now: reference) }
            .sorted { $0.lastConfirmedAt < $1.lastConfirmedAt }
    }

    // MARK: - Spatial queries

    /// All active conditions within `radiusMeters` of a coordinate, searched via
    /// the grid index built for `route`. Builds the index lazily on first query.
    func fetchNearbyConditions(
        _ coordinate: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance,
        on route: Route
    ) -> [RoadCondition] {
        let index = indexFor(route)
        return index.candidates(near: coordinate)
            .filter { RouteGeometry.haversineDistance(from: coordinate, to: $0.coordinate) <= radiusMeters }
            .sorted { lhs, rhs in
                RouteGeometry.haversineDistance(from: coordinate, to: lhs.coordinate)
                    < RouteGeometry.haversineDistance(from: coordinate, to: rhs.coordinate)
            }
    }

    /// Highest-priority active condition within `proximityThresholdMeters` of the
    /// current position, for firing nav-time alerts. Returns nil when nothing is
    /// in range. Pure helper over an explicit list so navigation code and tests
    /// can call it without an indexed route.
    nonisolated static func checkProximityToConditions(
        currentCoord: CLLocationCoordinate2D,
        routeConditions: [RoadCondition],
        proximityThresholdMeters: CLLocationDistance
    ) -> RoadCondition? {
        routeConditions
            .filter {
                $0.status == .active
                    && RouteGeometry.haversineDistance(from: currentCoord, to: $0.coordinate) < proximityThresholdMeters
            }
            // Closest of the highest-priority kind wins, so passing a pothole and
            // a cone at once announces the pothole.
            .min { lhs, rhs in
                if lhs.kind.priority != rhs.kind.priority {
                    return lhs.kind.priority > rhs.kind.priority
                }
                return RouteGeometry.haversineDistance(from: currentCoord, to: lhs.coordinate)
                    < RouteGeometry.haversineDistance(from: currentCoord, to: rhs.coordinate)
            }
    }

    /// Grid-indexed proximity check for the route currently being navigated.
    func checkProximity(
        currentCoord: CLLocationCoordinate2D,
        on route: Route,
        proximityThresholdMeters: CLLocationDistance
    ) -> RoadCondition? {
        let index = indexFor(route)
        let nearby = index.candidates(near: currentCoord)
        return Self.checkProximityToConditions(
            currentCoord: currentCoord,
            routeConditions: nearby,
            proximityThresholdMeters: proximityThresholdMeters
        )
    }

    // MARK: - Index management

    /// The index for `route`, rebuilt if stale or for a different route.
    private func indexFor(_ route: Route) -> RoadConditionGridIndex {
        if let index, indexedRouteID == route.id {
            return index
        }
        let active = (route.roadConditions ?? []).filter { $0.status == .active }
        let built = RoadConditionGridIndex(conditions: active)
        index = built
        indexedRouteID = route.id
        return built
    }

    /// Drop the cached index so the next query rebuilds it. Called after any
    /// create/confirm/expire/delete so the grid never serves a stale row.
    private func invalidateIndex() {
        index = nil
        indexedRouteID = nil
    }

    // MARK: - Persistence helpers

    private func persistMutation(of condition: RoadCondition) {
        if let ctx = condition.modelContext {
            save(ctx)
        } else {
            save(context)
        }
        invalidateIndex()
    }

    private func save(_ context: ModelContext?) {
        guard let context else { return }
        do {
            try context.save()
        } catch {
            roadConditionLog.error("Failed to save road condition change: \(error.localizedDescription)")
        }
    }
}

// MARK: - Grid Index

/// A ~200m spatial hash grid over a set of road conditions. Each condition is
/// registered in the single cell containing its point; a query gathers the
/// center cell plus its 8 neighbors so a condition near a cell boundary is still
/// found within the proximity radius. Immutable once built — the service throws
/// it away and rebuilds on mutation rather than mutating in place.
struct RoadConditionGridIndex {
    /// Degrees per cell. ~0.002° ≈ 222m N/S, which comfortably exceeds the 100m
    /// proximity threshold so the center-plus-neighbors search can't miss a hit.
    static let cellSizeDegrees = 0.002

    private let conditions: [RoadCondition]
    private let grid: [GridKey: [Int]]

    init(conditions: [RoadCondition]) {
        self.conditions = conditions
        var grid: [GridKey: [Int]] = [:]
        for (i, condition) in conditions.enumerated() {
            let key = Self.key(for: condition.coordinate)
            grid[key, default: []].append(i)
        }
        self.grid = grid
    }

    /// Conditions in the cell containing `coordinate` and its 8 neighbors.
    func candidates(near coordinate: CLLocationCoordinate2D) -> [RoadCondition] {
        let centerLat = Self.cellIndex(coordinate.latitude)
        let centerLon = Self.cellIndex(coordinate.longitude)
        var result: [RoadCondition] = []
        for dLat in -1...1 {
            for dLon in -1...1 {
                if let indices = grid[GridKey(lat: centerLat + dLat, lon: centerLon + dLon)] {
                    for i in indices { result.append(conditions[i]) }
                }
            }
        }
        return result
    }

    /// Number of occupied cells — exposed for tests asserting index shape.
    var occupiedCellCount: Int { grid.count }

    static func cellIndex(_ degrees: Double) -> Int {
        Int(floor(degrees / cellSizeDegrees))
    }

    private static func key(for coordinate: CLLocationCoordinate2D) -> GridKey {
        GridKey(lat: cellIndex(coordinate.latitude), lon: cellIndex(coordinate.longitude))
    }

    struct GridKey: Hashable {
        let lat: Int
        let lon: Int
    }
}
