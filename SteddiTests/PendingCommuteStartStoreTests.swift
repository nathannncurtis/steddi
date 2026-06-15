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
