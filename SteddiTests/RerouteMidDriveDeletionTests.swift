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
}
