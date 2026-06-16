import Testing
import Foundation
@testable import Steddi

@Suite("PendingCommuteStartStore")
@MainActor
struct PendingCommuteStartStoreTests {

    @Test("Empty store consumes to nil")
    func emptyConsumesNil() {
        let store = PendingCommuteStartStore()
        #expect(store.pending == nil)
        #expect(store.consume() == nil)
    }

    @Test("Request then consume returns the queued action and clears it")
    func requestThenConsume() {
        let store = PendingCommuteStartStore()
        store.request(.firstActive)
        #expect(store.pending == .firstActive)

        let consumed = store.consume()
        #expect(consumed == .firstActive)
        // Drained — a second consume is empty.
        #expect(store.pending == nil)
        #expect(store.consume() == nil)
    }

    @Test("Specific request round-trips commute id and direction")
    func specificRoundTrip() {
        let store = PendingCommuteStartStore()
        let id = UUID()
        store.request(.specific(commuteId: id, direction: .destinationToOrigin))
        #expect(store.consume() == .specific(commuteId: id, direction: .destinationToOrigin))
    }

    @Test("Specific request preserves a nil direction")
    func specificNilDirection() {
        let store = PendingCommuteStartStore()
        let id = UUID()
        store.request(.specific(commuteId: id, direction: nil))
        #expect(store.consume() == .specific(commuteId: id, direction: nil))
    }

    @Test("Latest request wins when not yet consumed")
    func latestWins() {
        let store = PendingCommuteStartStore()
        let first = UUID()
        let second = UUID()
        store.request(.specific(commuteId: first, direction: nil))
        store.request(.specific(commuteId: second, direction: .originToDestination))
        #expect(store.consume() == .specific(commuteId: second, direction: .originToDestination))
    }

    @Test("Version bumps on every request, including identical payloads")
    func versionBumps() {
        let store = PendingCommuteStartStore()
        let start = store.version
        store.request(.firstActive)
        #expect(store.version == start + 1)
        // Same payload again — version must still advance so an Observation
        // consumer re-runs.
        store.request(.firstActive)
        #expect(store.version == start + 2)
    }

    @Test("Version is unaffected by consume")
    func versionStableAcrossConsume() {
        let store = PendingCommuteStartStore()
        store.request(.firstActive)
        let v = store.version
        _ = store.consume()
        #expect(store.version == v)
    }
}

@Suite("PendingUIRouteStore")
@MainActor
struct PendingUIRouteStoreTests {

    @Test("Empty store consumes to nil")
    func emptyConsumesNil() {
        let store = PendingUIRouteStore()
        #expect(store.pending == nil)
        #expect(store.consume() == nil)
    }

    @Test("Show-places request round-trips and clears")
    func showPlacesRoundTrip() {
        let store = PendingUIRouteStore()
        store.request(.showPlaces)
        #expect(store.pending == .showPlaces)
        #expect(store.consume() == .showPlaces)
        #expect(store.consume() == nil)
    }

    /// Wires the `steddi://search?q=` deep link end-to-end at the store seam:
    /// the query the URL carries must survive the durable hand-off so HomeView's
    /// `consumePendingUIRoute` can open search pre-seeded with it (previously the
    /// route posted a NotificationCenter notification nothing observed).
    @Test("Search request round-trips the query and clears")
    func searchRoundTrip() {
        let store = PendingUIRouteStore()
        store.request(.search(query: "Coffee"))
        #expect(store.pending == .search(query: "Coffee"))
        #expect(store.consume() == .search(query: "Coffee"))
        #expect(store.consume() == nil)
    }

    @Test("Search equality is query-sensitive")
    func searchEquality() {
        #expect(PendingUIRoute.search(query: "A") == PendingUIRoute.search(query: "A"))
        #expect(PendingUIRoute.search(query: "A") != PendingUIRoute.search(query: "B"))
        #expect(PendingUIRoute.search(query: "A") != .showPlaces)
    }

    @Test("Latest route wins when not yet consumed")
    func latestWins() {
        let store = PendingUIRouteStore()
        store.request(.showPlaces)
        store.request(.search(query: "Gym"))
        #expect(store.consume() == .search(query: "Gym"))
    }

    @Test("Version bumps on every request, including identical payloads")
    func versionBumps() {
        let store = PendingUIRouteStore()
        let start = store.version
        store.request(.search(query: "X"))
        #expect(store.version == start + 1)
        store.request(.search(query: "X"))
        #expect(store.version == start + 2)
    }
}
