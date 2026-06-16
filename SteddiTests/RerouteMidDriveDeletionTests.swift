import Testing
import Foundation
import CoreLocation
import SwiftData
@testable import Steddi

// MARK: - Finding 1: mid-drive commute/route deletion must not crash the reroute loop

/// The long-lived reroute Task in `startObserving` used to capture the @Model
/// `Commute`/`Route` and dereference them every 5 minutes for the whole drive,
/// across `await` points. If the user deletes the commute/route mid-drive (and
/// the session never tore down — e.g. a CarPlay-only drive), the next cycle read
/// an invalidated SwiftData model and trapped.
///
/// The fix captures a `Sendable` snapshot of the reroute inputs at session start
/// (while the @Model graph is valid) and iterates THAT in the loop — never the
/// live relationship. The winning route is re-resolved by a predicate fetch that
/// safely returns nil if deleted. These tests exercise that contract over an
/// in-memory store, simulating the deletion.
@Suite("Reroute mid-drive deletion safety")
@MainActor
struct RerouteMidDriveDeletionTests {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ModelStoreLocator.schema, configurations: config)
        return ModelContext(container)
    }

    private func straightPolyline() -> String {
        let coords = (0..<10).map { CLLocationCoordinate2D(latitude: 33.0 + Double($0) * 0.001, longitude: -117.0) }
        return PolylineEncoder.encode(coords, precision: 6)
    }

    /// Build a persisted commute with two routes in `originToDestination`.
    private func makeCommute(in context: ModelContext) throws -> (Commute, active: Route, candidate: Route) {
        let commute = Commute(name: "Test", thresholdPercentage: 0.20, hardMinuteFloor: 10)
        let active = Route(rank: 0, encodedPolyline: straightPolyline(), name: "Active", direction: .originToDestination)
        let candidate = Route(rank: 1, encodedPolyline: straightPolyline(), name: "Candidate", direction: .originToDestination)
        commute.routes = [active, candidate]
        active.commute = commute
        candidate.commute = commute
        context.insert(commute)
        try context.save()
        return (commute, active, candidate)
    }

    @Test("Snapshot of a live commute captures candidates excluding the active route")
    func snapshotLiveCommute() throws {
        let context = try makeContext()
        let (commute, active, candidate) = try makeCommute(in: context)

        let snapshot = NavigationStateManager.rerouteSnapshot(
            commute: commute,
            direction: .originToDestination,
            excludingRouteID: active.id
        )

        let snap = try #require(snapshot)
        #expect(snap.thresholdPercentage == 0.20)
        #expect(snap.hardMinuteFloor == 10)
        // Only the non-active route is a candidate, excluded by identity.
        #expect(snap.candidates.map(\.id) == [candidate.id])
        #expect(snap.candidates.first?.encodedPolyline == candidate.encodedPolyline)
    }

    @Test("Snapshot is a Sendable value detached from the models — safe to read AFTER deletion")
    func snapshotSurvivesDeletion() throws {
        let context = try makeContext()
        let (commute, active, candidate) = try makeCommute(in: context)

        // Capture the snapshot while live (as startObserving does).
        let snapshot = try #require(NavigationStateManager.rerouteSnapshot(
            commute: commute,
            direction: .originToDestination,
            excludingRouteID: active.id
        ))

        // Now the models are deleted out from under the drive...
        context.delete(commute)
        try context.save()

        // ...but the already-captured value snapshot is still safe to read — it
        // holds plain UUID/String/Double, not the invalidated @Model. The loop
        // iterates exactly this, so a mid-drive deletion can't trap it.
        #expect(snapshot.candidates.map(\.id) == [candidate.id])
        #expect(snapshot.candidates.first?.encodedPolyline.isEmpty == false)
    }

    @Test("fetchLiveRoute resolves a live route by id")
    func fetchLiveRouteResolvesLive() throws {
        let context = try makeContext()
        let (_, _, candidate) = try makeCommute(in: context)

        let fetched = NavigationStateManager.fetchLiveRoute(id: candidate.id, in: context)
        #expect(fetched?.id == candidate.id)
    }

    @Test("fetchLiveRoute returns nil after the route is deleted mid-drive — no crash, suggestion skipped")
    func fetchLiveRouteNilAfterDeletion() throws {
        let context = try makeContext()
        let (commute, _, candidate) = try makeCommute(in: context)
        let candidateID = candidate.id

        // Delete the candidate route mid-drive (CommuteDetailView route delete).
        context.delete(candidate)
        try context.save()

        // The winning-route resolution uses a predicate fetch — it must return nil
        // (not trap on a stale handle), so the loop simply skips the suggestion.
        let fetched = NavigationStateManager.fetchLiveRoute(id: candidateID, in: context)
        #expect(fetched == nil, "A deleted route must resolve to nil, so no suggestion points at an invalidated model")
        _ = commute // keep alive for the duration of the test
    }

    @Test("fetchLiveRoute returns nil for the whole commute deleted (delete-all-data)")
    func fetchLiveRouteNilAfterCommuteDeleted() throws {
        let context = try makeContext()
        let (commute, _, candidate) = try makeCommute(in: context)
        let candidateID = candidate.id

        // Delete the entire commute (cascade-deletes routes) — Settings
        // "delete all data" mid-drive.
        context.delete(commute)
        try context.save()

        let fetched = NavigationStateManager.fetchLiveRoute(id: candidateID, in: context)
        #expect(fetched == nil)
    }

    @Test("fetchLiveRoute tolerates a nil context")
    func fetchLiveRouteNilContext() {
        #expect(NavigationStateManager.fetchLiveRoute(id: UUID(), in: nil) == nil)
    }

    // MARK: - switchToRoute liveness gate (suggestion's route deleted before tap)

    /// The reroute card holds a cached @Model Route and can display for up to 30s.
    /// The loop validated liveness only at set-time; nothing re-checks while the
    /// card shows. If the commute/route is deleted in that window (CommuteDetailView
    /// delete, Settings "delete all data"), tapping "Switch" used to dereference the
    /// invalidated @Model in navigateWithSavedRoute (encodedPolyline/name/…) and
    /// trap. switchToRoute now re-validates with HomeView.isSwitchableRoute and
    /// re-resolves a fresh live handle by id (fetchLiveRoute) before decoding,
    /// dismissing the suggestion gracefully if the route is gone.

    @Test("isSwitchableRoute is true for a live route")
    func isSwitchableLive() throws {
        let context = try makeContext()
        let (_, _, candidate) = try makeCommute(in: context)
        #expect(HomeView.isSwitchableRoute(candidate) == true)
    }

    @Test("isSwitchableRoute is false after the route is deleted mid-window — switch dismisses, no crash")
    func isSwitchableFalseAfterRouteDeleted() throws {
        let context = try makeContext()
        let (commute, _, candidate) = try makeCommute(in: context)

        // The suggestion was surfaced; THEN the route is deleted before "Switch".
        context.delete(candidate)
        try context.save()

        // The switch-time liveness gate must reject the invalidated handle — so
        // switchToRoute returns/dismisses instead of decoding it and trapping.
        #expect(HomeView.isSwitchableRoute(candidate) == false,
                "A deleted route must fail the switch gate so switchToRoute dismisses gracefully")
        _ = commute
    }

    @Test("isSwitchableRoute is false after the whole commute is deleted (delete-all-data)")
    func isSwitchableFalseAfterCommuteDeleted() throws {
        let context = try makeContext()
        let (commute, _, candidate) = try makeCommute(in: context)

        // Cascade-delete via the commute — Settings "delete all data" mid-drive.
        context.delete(commute)
        try context.save()

        #expect(HomeView.isSwitchableRoute(candidate) == false)
    }

    @Test("Switch path: deleted suggestion route resolves to nil via fetchLiveRoute — graceful dismissal")
    func switchPathDeletedRouteResolvesNil() throws {
        // End-to-end mirror of switchToRoute's guard: re-validate liveness, then
        // re-resolve by id. With the route deleted, BOTH the liveness gate fails
        // AND the id re-fetch returns nil, so the function bails (clears the
        // suggestion) without ever reaching the navigateWithSavedRoute decode.
        let context = try makeContext()
        let (commute, _, candidate) = try makeCommute(in: context)
        let candidateID = candidate.id

        context.delete(candidate)
        try context.save()

        let switchable = HomeView.isSwitchableRoute(candidate)
        let liveHandle = NavigationStateManager.fetchLiveRoute(id: candidateID, in: context)

        #expect(switchable == false)
        #expect(liveHandle == nil, "switchToRoute would dismiss the suggestion and skip navigation — no @Model deref, no crash")
        _ = commute
    }

    @Test("Switch path: a still-live suggestion route re-resolves to a usable live handle")
    func switchPathLiveRouteResolvesHandle() throws {
        // The happy path: nothing was deleted, so the gate passes and the id
        // re-fetch returns a live handle switchToRoute decodes safely.
        let context = try makeContext()
        let (_, _, candidate) = try makeCommute(in: context)
        let candidateID = candidate.id

        #expect(HomeView.isSwitchableRoute(candidate) == true)
        let liveHandle = NavigationStateManager.fetchLiveRoute(id: candidateID, in: context)
        #expect(liveHandle?.id == candidateID)
        // The decode switchToRoute would run on the resolved handle succeeds.
        #expect(liveHandle.map { PolylineEncoder.decode($0.encodedPolyline, precision: 6).count >= 2 } == true)
    }
}
