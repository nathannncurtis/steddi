import Testing
import Foundation
import SwiftData
@testable import Steddi

/// Forward-compat hardening for persisted enum properties. `Route.source` /
/// `.direction`, `Trip.flowMode`, and `CommuteTrip.direction` are stored as raw
/// String columns with computed typed accessors (mirroring `RoadCondition.kind`)
/// so a future build that renames or drops an enum case can't brick existing
/// rows: an unknown stored raw value degrades to a safe default instead of
/// failing the whole row's decode. These tests pin that behavior.
@Suite("Persisted enum raw-value fallback")
struct PersistedEnumFallbackTests {

    // MARK: Route.source

    @Test("Unknown RouteSource raw degrades to .recorded, not a decode failure")
    func routeSourceUnknownDegrades() {
        let route = Route(rank: 0, encodedPolyline: "abc")
        route.sourceRaw = "suggestedV2FromANewerBuild"
        #expect(route.source == .recorded)
    }

    @Test("Route.source setter round-trips through the raw column")
    func routeSourceRoundTrips() {
        let route = Route(rank: 0, encodedPolyline: "abc")
        route.source = .planned
        #expect(route.sourceRaw == "planned")
        #expect(route.source == .planned)
    }

    // MARK: Route.direction

    @Test("Unknown Route direction raw degrades to .originToDestination")
    func routeDirectionUnknownDegrades() {
        let route = Route(rank: 0, encodedPolyline: "abc")
        route.directionRaw = "diagonalFromANewerBuild"
        #expect(route.direction == .originToDestination)
    }

    @Test("Route.direction setter round-trips through the raw column")
    func routeDirectionRoundTrips() {
        let route = Route(rank: 0, encodedPolyline: "abc")
        route.direction = .destinationToOrigin
        #expect(route.directionRaw == "destinationToOrigin")
        #expect(route.direction == .destinationToOrigin)
    }

    // MARK: Trip.flowMode

    @Test("Unknown TripFlowMode raw degrades to .continuous")
    func tripFlowModeUnknownDegrades() {
        let trip = Trip(name: "Errands")
        trip.flowModeRaw = "semiAutoFromANewerBuild"
        #expect(trip.flowMode == .continuous)
    }

    @Test("Trip.flowMode setter round-trips through the raw column")
    func tripFlowModeRoundTrips() {
        let trip = Trip(name: "Errands")
        trip.flowMode = .manual
        #expect(trip.flowModeRaw == "manual")
        #expect(trip.flowMode == .manual)
    }

    // MARK: CommuteTrip.direction

    @Test("Unknown CommuteTrip direction raw degrades to .originToDestination")
    func commuteTripDirectionUnknownDegrades() {
        let commute = Commute(name: "Work")
        let log = CommuteTrip(commute: commute, direction: .destinationToOrigin)
        log.directionRaw = "loopFromANewerBuild"
        #expect(log.direction == .originToDestination)
    }

    @Test("CommuteTrip.direction setter round-trips through the raw column")
    func commuteTripDirectionRoundTrips() {
        let commute = Commute(name: "Work")
        let log = CommuteTrip(commute: commute, direction: .originToDestination)
        log.direction = .destinationToOrigin
        #expect(log.directionRaw == "destinationToOrigin")
        #expect(log.direction == .destinationToOrigin)
    }

    // MARK: Persistence round-trip through SwiftData

    @Test("Raw enum columns survive a SwiftData store round-trip")
    func storeRoundTrip() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ModelStoreLocator.schema, configurations: config)
        let context = ModelContext(container)

        let route = Route(rank: 1, encodedPolyline: "xyz", source: .planned, direction: .destinationToOrigin)
        context.insert(route)
        try context.save()

        let fetched = try #require(
            try context.fetch(FetchDescriptor<Route>()).first
        )
        #expect(fetched.source == .planned)
        #expect(fetched.direction == .destinationToOrigin)
    }
}
