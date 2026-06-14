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
