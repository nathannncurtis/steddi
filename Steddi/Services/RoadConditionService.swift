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

    /// One long-lived context for all operations, created at `configure`. A
    /// single context keeps route relationships and fetches consistent (a
    /// per-call context would put a created condition and its route in different
    /// contexts, and the launch sweep wouldn't see in-flight edits).
    private var sharedContext: ModelContext?

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    /// Wire up the shared container at launch. Idempotent.
    func configure(container: ModelContainer) {
        self.modelContainer = container
        self.sharedContext = ModelContext(container)
    }

    private var context: ModelContext? { sharedContext }

    /// The context the service reads and writes. Exposed for tests so they can
    /// insert routes into the same context the service uses, keeping
    /// relationship-backed queries consistent.
    var testContext: ModelContext? { sharedContext }

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
        // Pass the query radius so the ring scan covers it at any latitude — a
        // fixed 3×3 block would silently truncate any radius beyond one cell width.
        return index.candidates(near: coordinate, radiusMeters: radiusMeters)
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
    ///
    /// NOTE: this `@Model`-typed overload is for synchronous, same-turn callers
    /// (the grid-indexed `checkProximity`, route/map queries, and tests) that hold
    /// the models live. The long-lived navigation provider must NOT use it — a
    /// closure retained for the whole drive can read a `RoadCondition` deleted
    /// mid-drive and trap. That path goes through the `Sendable`
    /// `RoadConditionSnapshot` overload below.
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

    /// Snapshot-based proximity check, mirroring the `@Model` overload but over
    /// plain `Sendable` value snapshots. This is the form the navigation engine's
    /// long-lived `roadConditionProvider` closure uses: the conditions are
    /// captured into `RoadConditionSnapshot`s at wire time (while the models are
    /// valid) so a per-fix lookup for the whole drive never dereferences a
    /// `@Model` that a mid-drive delete (Settings "delete all data", route/commute
    /// deletion) may have invalidated. Only `.active` snapshots are produced at
    /// capture time, so no status re-check is needed here.
    nonisolated static func checkProximityToConditions(
        currentCoord: CLLocationCoordinate2D,
        routeConditions: [RoadConditionSnapshot],
        proximityThresholdMeters: CLLocationDistance
    ) -> RoadConditionSnapshot? {
        routeConditions
            .filter {
                RouteGeometry.haversineDistance(from: currentCoord, to: $0.coordinate) < proximityThresholdMeters
            }
            .min { lhs, rhs in
                if lhs.kind.priority != rhs.kind.priority {
                    return lhs.kind.priority > rhs.kind.priority
                }
                return RouteGeometry.haversineDistance(from: currentCoord, to: lhs.coordinate)
                    < RouteGeometry.haversineDistance(from: currentCoord, to: rhs.coordinate)
            }
    }

    /// Build `Sendable` snapshots of the active conditions on a route, for wiring
    /// into the navigation engine's long-lived `roadConditionProvider`. Captured
    /// ONCE at session start, while the `@Model` graph is valid, so the per-fix
    /// nav lookup (and the first-approach heads-up) operate on detached value
    /// types — a mid-drive delete of the route/conditions can never be observed by
    /// the closure. Mirrors `NavigationStateManager.rerouteSnapshot`. MainActor-
    /// isolated because it reads the `@Model` graph (the @Model itself is
    /// main-actor); the resulting snapshots are `Sendable` and safe to retain.
    @MainActor
    static func conditionSnapshots(on route: Route) -> [RoadConditionSnapshot] {
        (route.roadConditions ?? [])
            .filter { $0.status == .active && !$0.isDeleted && $0.modelContext != nil }
            .map { RoadConditionSnapshot(condition: $0) }
    }

    /// Grid-indexed proximity check for the route currently being navigated.
    func checkProximity(
        currentCoord: CLLocationCoordinate2D,
        on route: Route,
        proximityThresholdMeters: CLLocationDistance
    ) -> RoadCondition? {
        let index = indexFor(route)
        // Size the ring to the proximity threshold so a hit near a longitudinal
        // cell boundary at high latitude isn't dropped before the distance filter.
        let nearby = index.candidates(near: currentCoord, radiusMeters: proximityThresholdMeters)
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

// MARK: - Sendable Snapshot

/// A plain, `Sendable` snapshot of a road condition the navigation alert path
/// needs — id (for the engine's one-shot debounce), kind (priority + spoken
/// name + the heads-up text), coordinate (proximity test), and the owning
/// route's name (the "… on Main St" suffix). Decoupled from the `@Model
/// RoadCondition` so the long-lived `roadConditionProvider` closure — retained
/// by the engine for the whole drive — never re-touches a model that a
/// concurrent mid-drive delete (Settings "delete all data", route/commute
/// deletion) may have invalidated. Mirrors `NavigationStateManager.RerouteSnapshot`.
struct RoadConditionSnapshot: Sendable, Identifiable {
    let id: UUID
    let kind: RoadConditionKind
    let coordinate: CLLocationCoordinate2D
    /// Name of the owning route, captured at snapshot time for the spoken
    /// "… on <route>" suffix. nil when the condition has no route or it is
    /// unnamed — so the alert wiring never dereferences `condition.route` live.
    let routeName: String?

    /// Capture from a live `@Model` on the main actor at wire time. The caller
    /// must have already gated on liveness (`!isDeleted && modelContext != nil`).
    @MainActor
    init(condition: RoadCondition) {
        self.id = condition.id
        self.kind = condition.kind
        self.coordinate = condition.coordinate
        self.routeName = condition.route?.name
    }

    /// Direct initializer for tests and synthetic snapshots.
    init(id: UUID = UUID(), kind: RoadConditionKind, coordinate: CLLocationCoordinate2D, routeName: String? = nil) {
        self.id = id
        self.kind = kind
        self.coordinate = coordinate
        self.routeName = routeName
    }
}

// MARK: - Grid Index

/// A ~200m spatial hash grid over a set of road conditions. Each condition is
/// registered in the single cell containing its point; a query gathers the
/// center cell plus its 8 neighbors so a condition near a cell boundary is still
/// found within the proximity radius. Immutable once built — the service throws
/// it away and rebuilds on mutation rather than mutating in place.
struct RoadConditionGridIndex {
    /// Degrees per cell. ~0.002° ≈ 222m N/S. Cells are narrowest in longitude
    /// (`cos(lat)` shrinks east-west spacing), so a fixed 3×3 block can miss an
    /// in-radius condition at high latitude — `candidates(near:radiusMeters:)`
    /// sizes its ring against the radius instead.
    static let cellSizeDegrees = 0.002

    /// Default query radius when a caller doesn't specify one. Matches the 100m
    /// nav-time proximity threshold used by `checkProximityToConditions`.
    static let defaultRadiusMeters: CLLocationDistance = 100

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

    /// Conditions in the cell containing `coordinate` plus a square ring of
    /// neighbors sized to cover `radiusMeters`. A query point can sit anywhere in
    /// its cell, so a fixed 3×3 block only guarantees coverage to ONE cell width —
    /// and the cell is narrowest in longitude (`cos(lat)` shrinks east-west
    /// spacing), so a condition within the proximity radius could be dropped at
    /// high latitude. The ring radius is therefore derived from `radiusMeters`
    /// against the conservative longitude axis (mirrors `SpeedCameraGridIndex` and
    /// `GraphSpatialIndex.cellSearchRadius`).
    func candidates(
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance = RoadConditionGridIndex.defaultRadiusMeters
    ) -> [RoadCondition] {
        let centerLat = Self.cellIndex(coordinate.latitude)
        let centerLon = Self.cellIndex(coordinate.longitude)
        let ring = Self.cellSearchRadius(forMaxDistanceMeters: radiusMeters, atLatitude: coordinate.latitude)
        var result: [RoadCondition] = []
        for dLat in -ring...ring {
            for dLon in -ring...ring {
                if let indices = grid[GridKey(lat: centerLat + dLat, lon: centerLon + dLon)] {
                    for i in indices { result.append(conditions[i]) }
                }
            }
        }
        return result
    }

    /// The neighbor-cell ring radius needed for `candidates` to cover
    /// `maxDistanceMeters` at `latitude`. A query point can sit anywhere in its
    /// cell, so the guaranteed distance from the point to the outer edge of a
    /// radius-`r` ring is `r` whole cells (worst case: the point sits on the near
    /// boundary). The ring must therefore span at least
    /// `ceil(maxDistanceMeters / metersPerCell)` cells. Cells are narrowest in
    /// longitude (`cos(lat)`), so size against that conservative axis. Always ≥ 1
    /// to preserve the original 3×3 behavior.
    static func cellSearchRadius(forMaxDistanceMeters maxDistanceMeters: Double, atLatitude latitude: Double) -> Int {
        guard maxDistanceMeters > 0 else { return 1 }
        let metersPerDegreeLat = 111_320.0
        // Clamp the cosine to a small floor so an extreme/garbage latitude can't
        // blow the radius up.
        let cosLat = max(0.1, cos(latitude * .pi / 180))
        let metersPerCell = cellSizeDegrees * metersPerDegreeLat * cosLat
        guard metersPerCell > 0 else { return 1 }
        return max(1, Int(ceil(maxDistanceMeters / metersPerCell)))
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
