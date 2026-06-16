import Testing
import Foundation
import SwiftData
@testable import Steddi

// MARK: - TripProgression State Machine

@Suite("TripProgression")
struct TripProgressionTests {

    private func ids(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    // MARK: Position Resolution

    @Test("Unstarted trip resolves to index 0")
    func unstartedResolvesToZero() {
        let stops = ids(3)
        let progression = TripProgression(stopIds: stops, currentStopId: nil)
        #expect(progression.currentIndex == 0)
    }

    @Test("Dangling current id resolves to index 0")
    func danglingIdResolvesToZero() {
        let progression = TripProgression(stopIds: ids(3), currentStopId: UUID())
        #expect(progression.currentIndex == 0)
    }

    @Test("Current index follows the stop's ordinal")
    func currentIndexFollowsOrdinal() {
        let stops = ids(4)
        let progression = TripProgression(stopIds: stops, currentStopId: stops[2])
        #expect(progression.currentIndex == 2)
        #expect(progression.remainingStopIds == [stops[3]])
        #expect(!progression.isOnFinalLeg)
    }

    @Test("Final leg detection")
    func finalLegDetection() {
        let stops = ids(3)
        let progression = TripProgression(stopIds: stops, currentStopId: stops[2])
        #expect(progression.isOnFinalLeg)
        #expect(progression.remainingStopIds.isEmpty)
    }

    @Test("Empty trip is never on a final leg")
    func emptyTripNoFinalLeg() {
        let progression = TripProgression(stopIds: [], currentStopId: nil)
        #expect(!progression.isOnFinalLeg)
        #expect(progression.remainingStopIds.isEmpty)
    }

    // MARK: Advancement

    @Test("Advance steps through every leg then completes")
    func advanceWalksAllLegs() {
        let stops = ids(3)
        var progression = TripProgression(stopIds: stops, currentStopId: stops[0])

        #expect(progression.advance() == .nextLeg(stops[1]))
        #expect(progression.currentStopId == stops[1])

        #expect(progression.advance() == .nextLeg(stops[2]))
        #expect(progression.currentStopId == stops[2])

        #expect(progression.advance() == .completed)
        // Completion leaves position unchanged — callers record completion.
        #expect(progression.currentStopId == stops[2])
    }

    @Test("Advance on a single-stop trip completes immediately")
    func singleStopCompletes() {
        let stops = ids(1)
        var progression = TripProgression(stopIds: stops, currentStopId: stops[0])
        #expect(progression.advance() == .completed)
    }

    @Test("Advance from an unstarted trip moves to the second stop")
    func advanceFromUnstarted() {
        let stops = ids(2)
        var progression = TripProgression(stopIds: stops, currentStopId: nil)
        #expect(progression.advance() == .nextLeg(stops[1]))
    }

    // MARK: Stop Deletion

    @Test("Deleting a stop after the current one leaves position alone")
    func deleteAfterCurrentNoChange() {
        let stops = ids(4)
        var progression = TripProgression(stopIds: stops, currentStopId: stops[1])
        progression.removeStop(id: stops[3])
        #expect(progression.currentStopId == stops[1])
        #expect(progression.currentIndex == 1)
        #expect(progression.stopIds == [stops[0], stops[1], stops[2]])
    }

    @Test("Deleting a stop before the current one keeps identity, shifts ordinal")
    func deleteBeforeCurrentShiftsOrdinal() {
        let stops = ids(4)
        var progression = TripProgression(stopIds: stops, currentStopId: stops[2])
        progression.removeStop(id: stops[0])
        #expect(progression.currentStopId == stops[2])
        #expect(progression.currentIndex == 1)
    }

    @Test("Deleting the current stop rolls back to the previous stop")
    func deleteCurrentRollsBack() {
        let stops = ids(4)
        var progression = TripProgression(stopIds: stops, currentStopId: stops[2])
        progression.removeStop(id: stops[2])
        #expect(progression.currentStopId == stops[1])
        #expect(progression.currentIndex == 1)
    }

    @Test("Deleting the current first stop clamps to the new first stop")
    func deleteCurrentFirstClamps() {
        let stops = ids(3)
        var progression = TripProgression(stopIds: stops, currentStopId: stops[0])
        progression.removeStop(id: stops[0])
        #expect(progression.currentStopId == stops[1])
        #expect(progression.currentIndex == 0)
    }

    @Test("Deleting the only stop clears the position")
    func deleteOnlyStopClears() {
        let stops = ids(1)
        var progression = TripProgression(stopIds: stops, currentStopId: stops[0])
        progression.removeStop(id: stops[0])
        #expect(progression.currentStopId == nil)
        #expect(progression.stopIds.isEmpty)
    }

    @Test("Deleting an unknown id is a no-op")
    func deleteUnknownIdNoOp() {
        let stops = ids(2)
        var progression = TripProgression(stopIds: stops, currentStopId: stops[1])
        progression.removeStop(id: UUID())
        #expect(progression.stopIds == stops)
        #expect(progression.currentStopId == stops[1])
    }

    // MARK: Reordering

    @Test("Reorder keeps the current stop pinned by identity")
    func reorderKeepsIdentity() {
        let stops = ids(4)
        var progression = TripProgression(stopIds: stops, currentStopId: stops[2])

        // Drag stop[0] to the end: ordinals shift but identity holds.
        let newOrder = [stops[1], stops[2], stops[3], stops[0]]
        progression.reorder(to: newOrder)

        #expect(progression.currentStopId == stops[2])
        #expect(progression.currentIndex == 1)
        #expect(progression.remainingStopIds == [stops[3], stops[0]])
    }

    @Test("Reorder after partial completion advances correctly from the new order")
    func reorderThenAdvance() {
        let stops = ids(3)
        var progression = TripProgression(stopIds: stops, currentStopId: stops[1])

        progression.reorder(to: [stops[1], stops[0], stops[2]])
        #expect(progression.currentIndex == 0)

        // Next arrival goes to the stop now AFTER the current one.
        #expect(progression.advance() == .nextLeg(stops[0]))
        #expect(progression.advance() == .nextLeg(stops[2]))
        #expect(progression.advance() == .completed)
    }
}

// MARK: - Trip-Aware ETA Summation

@Suite("TripProgression ETA")
struct TripProgressionETATests {

    @Test("Saved duration wins over distance fallback")
    func savedDurationWins() {
        let leg = TripProgression.LegEstimate(savedDurationSeconds: 600, straightLineMeters: 100_000)
        #expect(TripProgression.estimatedSeconds(for: leg) == 600)
    }

    @Test("Missing saved duration falls back to road-inflated distance estimate")
    func distanceFallback() {
        let leg = TripProgression.LegEstimate(savedDurationSeconds: nil, straightLineMeters: 13_400)
        let expected = 13_400 * TripProgression.roadFactor / TripProgression.fallbackSpeedMPS
        #expect(abs(TripProgression.estimatedSeconds(for: leg) - expected) < 0.001)
    }

    @Test("Zero saved duration is treated as missing")
    func zeroSavedDurationFallsBack() {
        let leg = TripProgression.LegEstimate(savedDurationSeconds: 0, straightLineMeters: 1340)
        let expected = 1340 * TripProgression.roadFactor / TripProgression.fallbackSpeedMPS
        #expect(abs(TripProgression.estimatedSeconds(for: leg) - expected) < 0.001)
    }

    @Test("Remaining trip seconds sums current leg plus all remaining legs")
    func remainingTripSums() {
        let legs = [
            TripProgression.LegEstimate(savedDurationSeconds: 300, straightLineMeters: 0),
            TripProgression.LegEstimate(savedDurationSeconds: nil, straightLineMeters: 13_400)
        ]
        let fallback = 13_400 * TripProgression.roadFactor / TripProgression.fallbackSpeedMPS
        let total = TripProgression.remainingTripSeconds(currentLegSeconds: 120, remainingLegs: legs)
        #expect(abs(total - (120 + 300 + fallback)) < 0.001)
    }

    @Test("No remaining legs returns just the current leg ETA")
    func finalLegOnlyCurrentETA() {
        let total = TripProgression.remainingTripSeconds(currentLegSeconds: 480, remainingLegs: [])
        #expect(total == 480)
    }

    @Test("Negative current leg ETA clamps to zero")
    func negativeCurrentClamps() {
        let legs = [TripProgression.LegEstimate(savedDurationSeconds: 60, straightLineMeters: 0)]
        let total = TripProgression.remainingTripSeconds(currentLegSeconds: -10, remainingLegs: legs)
        #expect(total == 60)
    }
}

// MARK: - Trip Model Lifecycle (SwiftData)

@MainActor
@Suite("Trip model lifecycle")
struct TripModelLifecycleTests {

    /// In-memory container with a trip of `count` stops, inserted and saved.
    /// The context is returned so callers keep mutating the same registration.
    private func makeTrip(
        stopCount: Int,
        flowMode: TripFlowMode = .continuous
    ) throws -> (container: ModelContainer, context: ModelContext, trip: Trip) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ModelStoreLocator.schema, configurations: [config])
        let context = ModelContext(container)

        let trip = Trip(name: "Coast Run", flowMode: flowMode)
        context.insert(trip)
        for i in 0..<stopCount {
            let stop = TripStop(
                order: i,
                name: "Stop \(i)",
                latitude: 34.0 + Double(i) * 0.1,
                longitude: -118.0 - Double(i) * 0.1
            )
            context.insert(stop)
            stop.trip = trip
        }
        try context.save()
        return (container, context, trip)
    }

    @Test("Ordered stops sort by order regardless of insertion")
    func orderedStopsSorted() throws {
        let (_, context, trip) = try makeTrip(stopCount: 0)
        for order in [2, 0, 1] {
            let stop = TripStop(order: order, name: "Stop \(order)", latitude: 34, longitude: -118)
            context.insert(stop)
            stop.trip = trip
        }
        try context.save()
        #expect(trip.orderedStops.map(\.order) == [0, 1, 2])
        #expect(trip.orderedStops.map(\.name) == ["Stop 0", "Stop 1", "Stop 2"])
    }

    @Test("Start pins position to the first stop")
    func startPinsFirstStop() throws {
        let (_, _, trip) = try makeTrip(stopCount: 3)
        #expect(!trip.isInProgress)
        trip.start()
        #expect(trip.isInProgress)
        #expect(trip.currentStopIndex == 0)
        #expect(trip.currentStop?.name == "Stop 0")
        #expect(trip.remainingStops.count == 2)
    }

    @Test("Arrival advances position and completion archives the trip")
    func arrivalAdvancesAndCompletes() throws {
        let (_, _, trip) = try makeTrip(stopCount: 2)
        trip.start()

        let first = trip.advanceAfterArrival()
        #expect(first == .nextLeg(trip.orderedStops[1].id))
        #expect(trip.currentStopIndex == 1)
        #expect(trip.completedAt == nil)

        let second = trip.advanceAfterArrival()
        #expect(second == .completed)
        #expect(trip.completedAt != nil)
        #expect(trip.isArchived)
        #expect(trip.currentStopId == nil)
        #expect(!trip.isInProgress)
    }

    @Test("Deleting the current stop mid-trip rolls position back and renumbers")
    func deleteCurrentStopRollsBack() throws {
        let (_, _, trip) = try makeTrip(stopCount: 4)
        trip.start()
        trip.advanceAfterArrival()
        trip.advanceAfterArrival()
        #expect(trip.currentStop?.name == "Stop 2")

        let current = try #require(trip.currentStop)
        trip.removeStop(current)

        // Rolled back to the previous stop; orders stay contiguous.
        #expect(trip.currentStop?.name == "Stop 1")
        #expect(trip.currentStopIndex == 1)
        #expect(trip.orderedStops.map(\.order) == [0, 1, 2])
        #expect(trip.orderedStops.map(\.name) == ["Stop 0", "Stop 1", "Stop 3"])
    }

    @Test("Deleting a non-current stop keeps the navigation position")
    func deleteOtherStopKeepsPosition() throws {
        let (_, _, trip) = try makeTrip(stopCount: 3)
        trip.start()
        trip.advanceAfterArrival()
        let current = try #require(trip.currentStop)

        trip.removeStop(trip.orderedStops[2])
        #expect(trip.currentStop?.id == current.id)

        trip.removeStop(trip.orderedStops[0])
        #expect(trip.currentStop?.id == current.id)
        #expect(trip.currentStopIndex == 0)
        #expect(trip.orderedStops.map(\.order) == [0])
    }

    @Test("Reorder after partial completion keeps the current stop by identity")
    func reorderKeepsCurrentStop() throws {
        let (_, _, trip) = try makeTrip(stopCount: 4)
        trip.start()
        trip.advanceAfterArrival()
        trip.advanceAfterArrival()
        let current = try #require(trip.currentStop)
        #expect(current.name == "Stop 2")

        // Drag the current stop to the front.
        var newOrder = trip.orderedStops
        newOrder.removeAll { $0.id == current.id }
        newOrder.insert(current, at: 0)
        trip.reorderStops(newOrder)

        #expect(trip.currentStop?.id == current.id)
        #expect(trip.currentStopIndex == 0)
        #expect(trip.remainingStops.count == 3)
    }

    @Test("Resume after relaunch resolves the persisted stop id")
    func resumeResolvesPersistedId() throws {
        let (container, context, trip) = try makeTrip(stopCount: 3)
        trip.start()
        trip.advanceAfterArrival()
        let savedId = try #require(trip.currentStopId)
        try context.save()

        // Fresh context = relaunch. Position survives by UUID.
        let fetched = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        let revived = try #require(fetched.first)
        #expect(revived.currentStopId == savedId)
        #expect(revived.currentStopIndex == 1)
        #expect(revived.isInProgress)
        #expect(revived.currentStop?.name == "Stop 1")
    }

    @Test("Reset progress clears position, completion, and arrival times")
    func resetProgressClears() throws {
        let (_, _, trip) = try makeTrip(stopCount: 2)
        trip.start()
        trip.orderedStops[0].arrivalTime = Date()
        trip.advanceAfterArrival()
        trip.advanceAfterArrival()
        #expect(trip.isArchived)

        trip.resetProgress()
        #expect(trip.currentStopId == nil)
        #expect(trip.completedAt == nil)
        #expect(!trip.isArchived)
        #expect(trip.orderedStops.allSatisfy { $0.arrivalTime == nil })
    }

    @Test("Current stop survives a stop deleted outside removeStop")
    func currentStopSurvivesExternalDeletion() throws {
        let (_, context, trip) = try makeTrip(stopCount: 4)
        trip.start()
        trip.advanceAfterArrival()
        trip.advanceAfterArrival()
        let current = try #require(trip.currentStop)
        #expect(current.name == "Stop 2")

        // Delete a stop AFTER the current one straight through the context,
        // bypassing Trip.removeStop entirely (the external-mutation path).
        context.delete(trip.orderedStops[3])
        try context.save()

        // Position resolves by id, unaffected by the desynced ordinals.
        #expect(trip.currentStop?.id == current.id)
        #expect(trip.currentStopIndex == 2)
        #expect(trip.remainingStops.isEmpty)
    }

    @Test("Orphaned current id clamps instead of pointing past the end")
    func orphanedCurrentIdClampsSafely() throws {
        let (_, context, trip) = try makeTrip(stopCount: 3)
        trip.start()
        trip.advanceAfterArrival()
        trip.advanceAfterArrival()
        #expect(trip.currentStopIndex == 2)
        #expect(trip.currentStop?.name == "Stop 2")

        // Externally delete the stop the position actually names — currentStopId
        // is now orphaned (points at a stop that no longer exists) without ever
        // going through removeStop. The position must resolve safely: index in
        // bounds, currentStop a real existing stop, no crash, never past the end.
        context.delete(trip.orderedStops[2])
        try context.save()

        #expect(trip.orderedStops.count == 2)
        // In bounds — never negative, never past the end.
        #expect(trip.currentStopIndex >= 0)
        #expect(trip.currentStopIndex < trip.orderedStops.count)
        // Resolves to a stop that actually exists in the trip.
        let resolved = try #require(trip.currentStop)
        #expect(trip.orderedStops.contains { $0.id == resolved.id })
        // remainingStops never reaches past the end regardless of the orphan.
        #expect(trip.remainingStops.count == trip.orderedStops.count - 1 - trip.currentStopIndex)
    }

    @Test("Deleting a trip cascades to its stops")
    func deleteCascadesToStops() throws {
        let (_, context, trip) = try makeTrip(stopCount: 3)
        context.delete(trip)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Trip>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TripStop>()).isEmpty)
    }

    @Test("Saved route on a stop persists duration for ETA summation")
    func savedRoutePersistsDuration() throws {
        let (container, context, trip) = try makeTrip(stopCount: 2)
        let route = Route(rank: 0, encodedPolyline: "abc", typicalDurationSeconds: 540, source: .recorded)
        context.insert(route)
        trip.orderedStops[1].savedRoute = route
        try context.save()

        let fetched = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        let revived = try #require(fetched.first)
        #expect(revived.orderedStops[1].savedRoute?.typicalDurationSeconds == 540)
        #expect(revived.orderedStops[0].savedRoute == nil)
    }

    @Test("Per-stop preferences override trip, trip overrides defaults")
    func routePreferenceLayering() throws {
        let (_, _, trip) = try makeTrip(stopCount: 2)
        UserDefaults.standard.removeObject(forKey: "steddi.defaultAvoidsTolls")
        UserDefaults.standard.removeObject(forKey: "steddi.defaultAvoidsHighways")

        // Global defaults (false) when nothing is set.
        #expect(trip.routePreferences(for: trip.orderedStops[0]).avoidsTolls == false)

        // Trip-level override.
        trip.avoidsTolls = true
        #expect(trip.routePreferences(for: trip.orderedStops[0]).avoidsTolls == true)

        // Stop-level override beats the trip.
        trip.orderedStops[0].avoidsTolls = false
        #expect(trip.routePreferences(for: trip.orderedStops[0]).avoidsTolls == false)
        // Other stops still inherit the trip override.
        #expect(trip.routePreferences(for: trip.orderedStops[1]).avoidsTolls == true)
    }
}

// MARK: - Continuous-Trip Leg Handoff vs. External Teardown
//
// HomeView observes `navStateManager.isNavigating` to detect when the session
// was ended OUT FROM UNDER it (the active trip deleted externally) and tear the
// local view down to match. A continuous-trip auto-advance, however, also drives
// manager.isNavigating false transiently: advanceTripLeg stops the finished
// leg's session and only re-observes the next leg AFTER its route fetch resolves
// (multi-second for a live-routed stop). During that window manager.isNavigating
// is false while the view still thinks it's navigating — which, before the fix,
// tripped the teardown observer and silently force-ended the whole trip
// mid-advance. `HomeView.shouldHandleExternalTeardown` distinguishes the two via
// the `isAdvancingLeg` flag set across the handoff.

@Suite("Continuous-trip leg handoff teardown guard")
struct ContinuousTripTeardownGuardTests {

    @Test("Leg auto-advance does NOT force-end nav (the high-severity bug)")
    func legAdvanceDoesNotTearDown() {
        // Mid-advance: the finished leg's session was stopped (manager idle) and
        // the next leg's route is still being fetched, so the view still thinks
        // it's navigating and the handoff flag is set. Teardown MUST NOT fire —
        // the trip must re-target to the next leg, not silently end.
        #expect(HomeView.shouldHandleExternalTeardown(
            managerNavigating: false,
            viewNavigating: true,
            isAdvancingLeg: true
        ) == false)
    }

    @Test("Genuine external teardown still fires when not advancing a leg")
    func externalTeardownStillFires() {
        // Active trip deleted externally: endActiveTripSession() stopped the
        // manager, no leg handoff is in flight. Teardown MUST fire so the view
        // dismisses the overlay and leaves navigation mode.
        #expect(HomeView.shouldHandleExternalTeardown(
            managerNavigating: false,
            viewNavigating: true,
            isAdvancingLeg: false
        ) == true)
    }

    @Test("A full multi-leg advance never tears down across any leg boundary")
    func multiLegAdvanceNeverTearsDown() {
        // Walk a 3-stop continuous trip leg-by-leg. Each arrival triggers an
        // auto-advance; throughout each handoff the view stays navigating and
        // isAdvancingLeg is set, so the teardown observer must stay silent on
        // every leg boundary (not just the first).
        let stops = (0..<3).map { _ in UUID() }
        var progression = TripProgression(stopIds: stops, currentStopId: stops[0])

        var advanceResult = progression.advance()
        while case .nextLeg = advanceResult {
            // Handoff window for this leg: manager momentarily idle while the
            // next leg's route fetch is in flight. Teardown must NOT fire.
            #expect(HomeView.shouldHandleExternalTeardown(
                managerNavigating: false,
                viewNavigating: true,
                isAdvancingLeg: true
            ) == false)

            // Next leg observed: manager navigating again, handoff window closed.
            // No teardown (and the manager-true edge wouldn't trigger it anyway).
            #expect(HomeView.shouldHandleExternalTeardown(
                managerNavigating: true,
                viewNavigating: true,
                isAdvancingLeg: false
            ) == false)

            advanceResult = progression.advance()
        }
        // The trip ran to completion through every leg without a force-end.
        #expect(advanceResult == .completed)
    }

    @Test("Manager staying navigating never triggers teardown")
    func managerNavigatingNeverTearsDown() {
        #expect(HomeView.shouldHandleExternalTeardown(
            managerNavigating: true,
            viewNavigating: true,
            isAdvancingLeg: false
        ) == false)
    }

    @Test("View already idle never triggers teardown")
    func viewIdleNeverTearsDown() {
        // The in-view End/pause/endTrip paths flip local isNavigating false in the
        // same turn they stop the manager, so the observer must no-op for them.
        #expect(HomeView.shouldHandleExternalTeardown(
            managerNavigating: false,
            viewNavigating: false,
            isAdvancingLeg: false
        ) == false)
    }
}
