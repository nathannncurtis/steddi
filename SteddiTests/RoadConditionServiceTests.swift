import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import Steddi

// MARK: - Helpers

private func inMemoryContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: ModelStoreLocator.schema, configurations: [config])
}

/// A coordinate offset roughly `meters` north of a base point. ~111,320 m per
/// degree of latitude, so the conversion is good enough for proximity tests.
private func north(of base: CLLocationCoordinate2D, meters: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: base.latitude + meters / 111_320.0, longitude: base.longitude)
}

/// A coordinate offset roughly `meters` east of a base point, accounting for the
/// `cos(lat)` shrink of longitudinal spacing toward the poles.
private func east(of base: CLLocationCoordinate2D, meters: Double) -> CLLocationCoordinate2D {
    let metersPerDegLon = 111_320.0 * cos(base.latitude * .pi / 180)
    return CLLocationCoordinate2D(latitude: base.latitude, longitude: base.longitude + meters / metersPerDegLon)
}

private let downtown = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)

private func makeCondition(
    kind: RoadConditionKind = .pothole,
    at coordinate: CLLocationCoordinate2D = downtown,
    status: RoadConditionStatus = .active,
    createdAt: Date = Date()
) -> RoadCondition {
    RoadCondition(kind: kind, coordinate: coordinate, route: nil, status: status, createdAt: createdAt)
}

private let day: TimeInterval = 86_400

// MARK: - Spatial grid index

@Suite("RoadConditionGridIndex spatial lookup")
struct RoadConditionGridIndexTests {

    @Test("A condition is found from its own cell")
    func findsInOwnCell() {
        let condition = makeCondition(at: downtown)
        let index = RoadConditionGridIndex(conditions: [condition])
        let found = index.candidates(near: downtown)
        #expect(found.contains { $0.id == condition.id })
    }

    @Test("A condition one cell over is still a candidate via neighbor search")
    func findsAcrossCellBoundary() {
        // ~150m north lands in (or adjacent to) the next ~222m cell; the
        // center-plus-8-neighbors query must still surface it.
        let near = north(of: downtown, meters: 150)
        let condition = makeCondition(at: near)
        let index = RoadConditionGridIndex(conditions: [condition])
        let found = index.candidates(near: downtown)
        #expect(found.contains { $0.id == condition.id })
    }

    @Test("A far-away condition is not returned as a candidate")
    func excludesFarCondition() {
        // ~5km north is many cells away — outside the 3x3 neighbor window.
        let far = north(of: downtown, meters: 5_000)
        let condition = makeCondition(at: far)
        let index = RoadConditionGridIndex(conditions: [condition])
        let found = index.candidates(near: downtown)
        #expect(found.isEmpty)
    }

    @Test("Co-located conditions share one occupied cell")
    func coLocatedShareCell() {
        let a = makeCondition(at: downtown)
        let b = makeCondition(at: north(of: downtown, meters: 10))
        let index = RoadConditionGridIndex(conditions: [a, b])
        #expect(index.occupiedCellCount == 1)
        #expect(index.candidates(near: downtown).count == 2)
    }

    @Test("Distant conditions occupy distinct cells")
    func distantConditionsDistinctCells() {
        let a = makeCondition(at: downtown)
        let b = makeCondition(at: north(of: downtown, meters: 1_000))
        let index = RoadConditionGridIndex(conditions: [a, b])
        #expect(index.occupiedCellCount == 2)
    }

    @Test("cellIndex floors negative coordinates correctly")
    func cellIndexFloorsNegatives() {
        // -118.2437 / 0.002 ≈ -59121.85 → floor → -59122 (not truncation -59121).
        #expect(RoadConditionGridIndex.cellIndex(-118.2437) == -59122)
        #expect(RoadConditionGridIndex.cellIndex(0.0) == 0)
        #expect(RoadConditionGridIndex.cellIndex(0.0021) == 1)
    }

    @Test("A condition within the radius due east is found at a high latitude")
    func findsHighLatitudeEastCondition() {
        // Anchorage (~61°N): a 0.002° cell is only ~108m wide E/W, so a fixed 3×3
        // scan guarantees coverage to just ~108m — under the 100m radius once the
        // query point sits near the cell's east edge. A condition ~90m due east
        // must still surface via the latitude-robust ring.
        let anchorage = CLLocationCoordinate2D(latitude: 61.2181, longitude: -149.9003)
        let cond = makeCondition(at: east(of: anchorage, meters: 90))
        // Sanity: it really is inside the 100m radius.
        #expect(RouteGeometry.haversineDistance(from: anchorage, to: cond.coordinate) <= 100)
        let index = RoadConditionGridIndex(conditions: [cond])
        let found = index.candidates(near: anchorage, radiusMeters: 100)
        #expect(found.contains { $0.id == cond.id })
    }

    @Test("High-latitude condition near a cell boundary surfaces from the worst-case offset")
    func findsHighLatitudeBoundaryCondition() {
        // Pin the query point hard against the eastern edge of its cell — the
        // worst case for the ring — then a condition ~95m further east must still
        // be reachable.
        let baseLat = 61.0
        let cellWidthLon = RoadConditionGridIndex.cellSizeDegrees
        let cellLon = floor(-150.0 / cellWidthLon)
        let query = CLLocationCoordinate2D(
            latitude: baseLat,
            longitude: (cellLon + 1) * cellWidthLon - 0.0000001
        )
        let cond = makeCondition(at: east(of: query, meters: 95))
        #expect(RouteGeometry.haversineDistance(from: query, to: cond.coordinate) <= 100)
        let index = RoadConditionGridIndex(conditions: [cond])
        #expect(index.candidates(near: query, radiusMeters: 100).contains { $0.id == cond.id })
    }

    @Test("cellSearchRadius grows with latitude to keep the radius covered")
    func cellSearchRadiusLatitudeRobust() {
        let r = 100.0
        let socal = RoadConditionGridIndex.cellSearchRadius(forMaxDistanceMeters: r, atLatitude: 34.0)
        let anchorage = RoadConditionGridIndex.cellSearchRadius(forMaxDistanceMeters: r, atLatitude: 61.0)
        // Always at least the original 3×3 behavior, and never shrinking as the
        // cell narrows toward the pole.
        #expect(socal >= 1)
        #expect(anchorage >= socal)
        // The guaranteed-covered distance (ring cells × E/W meters-per-cell) must
        // reach the radius at the high latitude.
        let metersPerCellAnchorage = RoadConditionGridIndex.cellSizeDegrees * 111_320.0 * cos(61.0 * .pi / 180)
        #expect(Double(anchorage) * metersPerCellAnchorage >= r)
    }

    @Test("A far-away high-latitude condition is still excluded by the ring")
    func excludesFarHighLatitudeCondition() {
        // The radius-aware ring must not over-collect: a condition ~5km east is
        // far outside a 100m radius and must not be a candidate.
        let anchorage = CLLocationCoordinate2D(latitude: 61.2181, longitude: -149.9003)
        let far = makeCondition(at: east(of: anchorage, meters: 5_000))
        let index = RoadConditionGridIndex(conditions: [far])
        #expect(index.candidates(near: anchorage, radiusMeters: 100).isEmpty)
    }
}

// MARK: - Drive-past proximity detection

@Suite("RoadConditionService.checkProximityToConditions")
struct RoadConditionProximityTests {

    @Test("Returns the condition when inside the threshold")
    func firesWithinThreshold() {
        let condition = makeCondition(at: north(of: downtown, meters: 50))
        let hit = RoadConditionService.checkProximityToConditions(
            currentCoord: downtown,
            routeConditions: [condition],
            proximityThresholdMeters: 100
        )
        #expect(hit?.id == condition.id)
    }

    @Test("Returns nil when outside the threshold")
    func silentBeyondThreshold() {
        let condition = makeCondition(at: north(of: downtown, meters: 250))
        let hit = RoadConditionService.checkProximityToConditions(
            currentCoord: downtown,
            routeConditions: [condition],
            proximityThresholdMeters: 100
        )
        #expect(hit == nil)
    }

    @Test("Skips expired conditions even when in range")
    func ignoresExpiredInRange() {
        let condition = makeCondition(at: north(of: downtown, meters: 20), status: .expired)
        let hit = RoadConditionService.checkProximityToConditions(
            currentCoord: downtown,
            routeConditions: [condition],
            proximityThresholdMeters: 100
        )
        #expect(hit == nil)
    }

    @Test("Higher-priority kind wins when two are in range")
    func priorityWinsOverDistance() {
        // Construction is closer, but a pothole in range must announce first.
        let construction = makeCondition(kind: .construction, at: north(of: downtown, meters: 20))
        let pothole = makeCondition(kind: .pothole, at: north(of: downtown, meters: 80))
        let hit = RoadConditionService.checkProximityToConditions(
            currentCoord: downtown,
            routeConditions: [construction, pothole],
            proximityThresholdMeters: 100
        )
        #expect(hit?.kind == .pothole)
    }

    @Test("Among same-priority kinds, the closer one wins")
    func closerWinsAtEqualPriority() {
        let nearPothole = makeCondition(kind: .pothole, at: north(of: downtown, meters: 30))
        let farPothole = makeCondition(kind: .pothole, at: north(of: downtown, meters: 90))
        let hit = RoadConditionService.checkProximityToConditions(
            currentCoord: downtown,
            routeConditions: [farPothole, nearPothole],
            proximityThresholdMeters: 100
        )
        #expect(hit?.id == nearPothole.id)
    }

    @Test("Empty condition list returns nil")
    func emptyListReturnsNil() {
        let hit = RoadConditionService.checkProximityToConditions(
            currentCoord: downtown,
            routeConditions: [],
            proximityThresholdMeters: 100
        )
        #expect(hit == nil)
    }
}

// MARK: - Decay state machine (model-level)

@Suite("RoadCondition decay state machine")
struct RoadConditionDecayModelTests {

    @Test("A fresh condition does not need reconfirmation")
    func freshIsFine() {
        let condition = makeCondition(createdAt: Date())
        #expect(condition.needsReconfirmation(now: Date()) == false)
    }

    @Test("Just under 14 days does not yet prompt")
    func justUnderWindow() {
        let now = Date()
        let condition = makeCondition(createdAt: now.addingTimeInterval(-13.5 * day))
        #expect(condition.needsReconfirmation(now: now) == false)
    }

    @Test("Just over 14 days prompts for reconfirmation")
    func justOverWindow() {
        let now = Date()
        let condition = makeCondition(createdAt: now.addingTimeInterval(-15 * day))
        #expect(condition.needsReconfirmation(now: now) == true)
    }

    @Test("An expired condition never prompts, however old")
    func expiredNeverPrompts() {
        let now = Date()
        let condition = makeCondition(status: .expired, createdAt: now.addingTimeInterval(-30 * day))
        #expect(condition.needsReconfirmation(now: now) == false)
    }

    @Test("daysSinceConfirmed counts whole days from last confirmation")
    func daysSinceConfirmedCounts() {
        let now = Date()
        let condition = makeCondition(createdAt: now.addingTimeInterval(-20 * day))
        #expect(condition.daysSinceConfirmed(now: now) == 20)
    }
}

// MARK: - Decay state machine (service + store)

@MainActor
@Suite("RoadConditionService lifecycle")
struct RoadConditionServiceLifecycleTests {

    /// Build a service over a fresh in-memory store and hand back the service's
    /// own context so tests insert routes where the service reads them.
    private func makeService(now: @escaping () -> Date) throws -> (RoadConditionService, ModelContext) {
        let container = try inMemoryContainer()
        let service = RoadConditionService(now: now)
        service.configure(container: container)
        let context = try #require(service.testContext)
        return (service, context)
    }

    @Test("createCondition persists an active condition tied to the route")
    func createPersists() throws {
        var clock = Date()
        let (service, context) = try makeService(now: { clock })
        let route = Route(rank: 0, encodedPolyline: "abc")
        context.insert(route)

        let created = service.createCondition(kind: .pothole, coordinate: downtown, route: route)
        #expect(created != nil)
        #expect(created?.status == .active)

        clock = clock.addingTimeInterval(1)
        let onRoute = service.fetchConditionsOnRoute(route)
        #expect(onRoute.count == 1)
        #expect(onRoute.first?.kind == .pothole)
    }

    @Test("updateConfirmation resets the decay timer and reactivates")
    func confirmResetsTimer() throws {
        let start = Date()
        var clock = start
        let (service, context) = try makeService(now: { clock })
        let route = Route(rank: 0, encodedPolyline: "abc")
        context.insert(route)

        let condition = try #require(service.createCondition(kind: .pothole, coordinate: downtown, route: route))
        // Backdate so it's well into the reconfirm window.
        condition.lastConfirmedAt = start.addingTimeInterval(-20 * day)
        #expect(condition.needsReconfirmation(now: clock) == true)

        clock = start.addingTimeInterval(100)
        service.updateConfirmation(condition)
        #expect(condition.lastConfirmedAt == clock)
        #expect(condition.status == .active)
        #expect(condition.needsReconfirmation(now: clock) == false)
    }

    @Test("expireCondition soft-deletes and drops it from the active route set")
    func expireHides() throws {
        var clock = Date()
        let (service, context) = try makeService(now: { clock })
        let route = Route(rank: 0, encodedPolyline: "abc")
        context.insert(route)

        let condition = try #require(service.createCondition(kind: .debris, coordinate: downtown, route: route))
        clock = clock.addingTimeInterval(1)
        service.expireCondition(condition)
        #expect(condition.status == .expired)
        #expect(service.fetchConditionsOnRoute(route).isEmpty)
    }

    @Test("staleConditionsOnRoute returns only conditions past the 14-day window, oldest first")
    func staleOrdering() throws {
        let now = Date()
        var clock = now
        let (service, context) = try makeService(now: { clock })
        let route = Route(rank: 0, encodedPolyline: "abc")
        context.insert(route)

        let fresh = try #require(service.createCondition(kind: .pothole, coordinate: downtown, route: route))
        let stale = try #require(service.createCondition(kind: .construction, coordinate: downtown, route: route))
        let stalest = try #require(service.createCondition(kind: .debris, coordinate: downtown, route: route))
        fresh.lastConfirmedAt = now.addingTimeInterval(-1 * day)
        stale.lastConfirmedAt = now.addingTimeInterval(-15 * day)
        stalest.lastConfirmedAt = now.addingTimeInterval(-40 * day)

        clock = now
        let result = service.staleConditionsOnRoute(route)
        #expect(result.map(\.id) == [stalest.id, stale.id])
    }

    @Test("sweep deletes conditions older than 90 days, keeps younger ones")
    func sweepBoundary() throws {
        let now = Date()
        var clock = now
        let (service, context) = try makeService(now: { clock })
        let route = Route(rank: 0, encodedPolyline: "abc")
        context.insert(route)

        let young = try #require(service.createCondition(kind: .pothole, coordinate: downtown, route: route))
        let old = try #require(service.createCondition(kind: .debris, coordinate: downtown, route: route))
        let expiredOld = try #require(service.createCondition(kind: .other, coordinate: downtown, route: route))
        young.lastConfirmedAt = now.addingTimeInterval(-30 * day)
        old.lastConfirmedAt = now.addingTimeInterval(-91 * day)
        expiredOld.status = .expired
        expiredOld.lastConfirmedAt = now.addingTimeInterval(-120 * day)
        // Persist the backdated timestamps so the sweep's fresh-context fetch
        // sees them (the sweep queries the store, not these in-memory objects).
        try context.save()

        clock = now
        let deleted = service.sweepExpiredConditions()
        #expect(deleted == 2)

        let remaining = try context.fetch(FetchDescriptor<RoadCondition>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == young.id)
    }

    @Test("sweep just under 90 days keeps the condition")
    func sweepJustUnderKeeps() throws {
        let now = Date()
        let (service, context) = try makeService(now: { now })
        let route = Route(rank: 0, encodedPolyline: "abc")
        context.insert(route)

        let condition = try #require(service.createCondition(kind: .pothole, coordinate: downtown, route: route))
        condition.lastConfirmedAt = now.addingTimeInterval(-89 * day)
        try context.save()

        #expect(service.sweepExpiredConditions() == 0)
        #expect(try context.fetch(FetchDescriptor<RoadCondition>()).count == 1)
    }

    @Test("Grid-indexed checkProximity finds an active condition on the route")
    func indexedProximityOnRoute() throws {
        let (service, context) = try makeService(now: { Date() })
        let route = Route(rank: 0, encodedPolyline: "abc")
        context.insert(route)

        let condition = try #require(service.createCondition(
            kind: .pothole,
            coordinate: north(of: downtown, meters: 40),
            route: route
        ))
        let hit = service.checkProximity(currentCoord: downtown, on: route, proximityThresholdMeters: 100)
        #expect(hit?.id == condition.id)

        let miss = service.checkProximity(currentCoord: downtown, on: route, proximityThresholdMeters: 25)
        #expect(miss == nil)
    }
}

// MARK: - Adversarial edge cases

/// Boundary and degradation cases the happy-path suites don't cover: exclusive
/// proximity threshold, raw-value forward-compat, clock skew, exact-window
/// reconfirm, priority ties at equal distance, and grid-index status filtering.
@Suite("RoadCondition adversarial edges")
struct RoadConditionAdversarialTests {

    // MARK: Raw-value forward compatibility

    @Test("Unknown kind raw value degrades to .other, not a decode failure")
    func unknownKindDegrades() {
        let condition = makeCondition()
        condition.kindRaw = "futureKindFromANewerBuild"
        #expect(condition.kind == .other)
    }

    @Test("Unknown status raw value stays visible by degrading to .active")
    func unknownStatusDegrades() {
        let condition = makeCondition()
        condition.statusRaw = "quarantined"
        #expect(condition.status == .active)
    }

    @Test("kind setter round-trips through the raw column")
    func kindSetterRoundTrips() {
        let condition = makeCondition()
        condition.kind = .construction
        #expect(condition.kindRaw == "construction")
        #expect(condition.kind == .construction)
    }

    // MARK: Proximity threshold is exclusive

    @Test("A condition exactly at the threshold distance does NOT fire (exclusive <)")
    func exactThresholdIsExclusive() {
        // Place the condition exactly 100m north and query with a 100m threshold.
        // The check uses strict `<`, so the boundary point must not fire.
        let condition = makeCondition(at: north(of: downtown, meters: 100))
        let hit = RoadConditionService.checkProximityToConditions(
            currentCoord: downtown,
            routeConditions: [condition],
            proximityThresholdMeters: RouteGeometry.haversineDistance(from: downtown, to: condition.coordinate)
        )
        #expect(hit == nil)
    }

    @Test("A condition fractionally inside the threshold fires")
    func justInsideThresholdFires() {
        let condition = makeCondition(at: north(of: downtown, meters: 99))
        let exact = RouteGeometry.haversineDistance(from: downtown, to: condition.coordinate)
        let hit = RoadConditionService.checkProximityToConditions(
            currentCoord: downtown,
            routeConditions: [condition],
            proximityThresholdMeters: exact + 0.5
        )
        #expect(hit?.id == condition.id)
    }

    @Test("All-expired list in range still returns nil")
    func allExpiredInRangeReturnsNil() {
        let a = makeCondition(kind: .pothole, at: north(of: downtown, meters: 10), status: .expired)
        let b = makeCondition(kind: .construction, at: north(of: downtown, meters: 20), status: .archived)
        let hit = RoadConditionService.checkProximityToConditions(
            currentCoord: downtown,
            routeConditions: [a, b],
            proximityThresholdMeters: 100
        )
        #expect(hit == nil)
    }

    @Test("Equal priority and equal distance resolves deterministically without trapping")
    func equalPriorityEqualDistanceIsStable() {
        // Two potholes at the identical coordinate: the comparator must form a
        // valid ordering (no precondition trap) and return one of them.
        let coord = north(of: downtown, meters: 40)
        let a = makeCondition(kind: .pothole, at: coord)
        let b = makeCondition(kind: .pothole, at: coord)
        let hit = RoadConditionService.checkProximityToConditions(
            currentCoord: downtown,
            routeConditions: [a, b],
            proximityThresholdMeters: 100
        )
        #expect(hit != nil)
        #expect(hit?.id == a.id || hit?.id == b.id)
    }

    // MARK: Decay window boundaries

    @Test("Exactly 14 days does not yet prompt (window is strictly greater-than)")
    func exactlyFourteenDaysDoesNotPrompt() {
        let now = Date()
        let condition = makeCondition(createdAt: now.addingTimeInterval(-14 * day))
        #expect(condition.needsReconfirmation(now: now) == false)
    }

    @Test("A hair past 14 days prompts")
    func hairPastFourteenPrompts() {
        let now = Date()
        let condition = makeCondition(createdAt: now.addingTimeInterval(-14 * day - 1))
        #expect(condition.needsReconfirmation(now: now) == true)
    }

    @Test("daysSinceConfirmed never reports a positive count for a future confirmation")
    func futureConfirmationDoesNotReportPositiveAge() {
        // Clock skew: lastConfirmedAt is in the future relative to `now`.
        let now = Date()
        let condition = makeCondition(createdAt: now.addingTimeInterval(2 * day))
        #expect(condition.daysSinceConfirmed(now: now) <= 0)
        // And a future-confirmed condition is never offered for reconfirmation.
        #expect(condition.needsReconfirmation(now: now) == false)
    }

    @Test("An archived condition never prompts for reconfirmation")
    func archivedNeverPrompts() {
        let now = Date()
        let condition = makeCondition(status: .archived, createdAt: now.addingTimeInterval(-60 * day))
        #expect(condition.needsReconfirmation(now: now) == false)
    }

    // MARK: Grid index status filtering

    @MainActor
    @Test("Grid-indexed proximity ignores an expired condition sitting on the route")
    func gridProximityIgnoresExpired() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ModelStoreLocator.schema, configurations: [config])
        let service = RoadConditionService(now: { Date() })
        service.configure(container: container)
        let context = try #require(service.testContext)
        let route = Route(rank: 0, encodedPolyline: "abc")
        context.insert(route)

        let condition = try #require(service.createCondition(
            kind: .pothole,
            coordinate: north(of: downtown, meters: 30),
            route: route
        ))
        // Expire it; the index must be invalidated and the next query must miss.
        service.expireCondition(condition)
        let hit = service.checkProximity(currentCoord: downtown, on: route, proximityThresholdMeters: 100)
        #expect(hit == nil)
    }

    @Test("Co-located conditions across a kind mix still cluster into one cell")
    func coLocatedMixedKindsOneCell() {
        let coord = downtown
        let index = RoadConditionGridIndex(conditions: [
            makeCondition(kind: .pothole, at: coord),
            makeCondition(kind: .debris, at: coord),
            makeCondition(kind: .construction, at: coord)
        ])
        #expect(index.occupiedCellCount == 1)
        #expect(index.candidates(near: coord).count == 3)
    }
}
