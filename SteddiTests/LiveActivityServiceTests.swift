import Testing
import Foundation
@testable import Steddi

// MARK: - Finding 2: Live Activity lifecycle serialization (end-then-late-update race)

/// An in-flight `updateActivity` Task could previously land AFTER `endActivity`
/// and resurrect a just-ended activity (lost-update race). The fix serializes all
/// activity mutations through one ordered chain (`enqueueLifecycle`) plus a
/// `sessionEnded` latch, so an update can never apply after an end.
///
/// ActivityKit can't vend a real `Activity` in a unit test, so these drive the
/// exact serialization + latch logic the production paths use via the service's
/// test seam, recording the order operations actually apply in.
@Suite("LiveActivityService lifecycle serialization")
@MainActor
struct LiveActivityServiceTests {

    @Test("An update applies in a live session (before any end)")
    func updateAppliesWhileLive() async {
        let service = LiveActivityService.shared
        service.resetForTesting()
        let sink = LifecycleRecorder()

        // No end pending — the update applies, then drains.
        service.enqueueSimulatedUpdateForTesting("update", into: sink)
        await service.drainLifecycleForTesting()

        let applied = await sink.applied
        #expect(applied == ["update"], "A live-session update must apply")

        // Then end the session — it applies after the update.
        service.enqueueSimulatedEndForTesting("end", into: sink)
        await service.drainLifecycleForTesting()
        #expect(await sink.applied == ["update", "end"])
    }

    @Test("An update submitted AFTER an end is dropped — never resurrects the activity")
    func lateUpdateAfterEndIsDropped() async {
        let service = LiveActivityService.shared
        service.resetForTesting()
        let sink = LifecycleRecorder()

        // End first (latches sessionEnded synchronously)...
        service.enqueueSimulatedEndForTesting("end", into: sink)
        // ...then a late update tick fires. It must be dropped, not applied after.
        service.enqueueSimulatedUpdateForTesting("late-update", into: sink)
        await service.drainLifecycleForTesting()

        let applied = await sink.applied
        #expect(applied == ["end"], "A late update after end must be dropped, never resurrecting the activity")
        #expect(service.sessionEnded, "The end latch stays set until a new session starts")
    }

    // The actual safety invariant: once an end is issued, NO update applies after
    // it. The end latches `sessionEnded` synchronously, so any update whose chained
    // op runs after the end (whether submitted before or after) is dropped — the
    // resurrection window is closed. Strict pre-end ordering is not promised (and
    // not needed); "nothing applies after the end" is.
    @Test("No update ever lands after the end")
    func noUpdateLandsAfterEnd() async {
        let service = LiveActivityService.shared
        service.resetForTesting()
        let sink = LifecycleRecorder()

        service.enqueueSimulatedUpdateForTesting("u1", into: sink)
        service.enqueueSimulatedUpdateForTesting("u2", into: sink)
        service.enqueueSimulatedEndForTesting("end", into: sink)
        // These arrive after the end — all must be dropped.
        service.enqueueSimulatedUpdateForTesting("u3", into: sink)
        service.enqueueSimulatedUpdateForTesting("u4", into: sink)
        await service.drainLifecycleForTesting()

        let applied = await sink.applied
        // The end is applied, and is the LAST applied operation — nothing after it.
        #expect(applied.contains("end"), "The end must apply")
        #expect(applied.last == "end", "Nothing may apply after the end")
        // Post-end updates are always dropped (resurrection window closed).
        #expect(!applied.contains("u3"))
        #expect(!applied.contains("u4"))
    }
}
