import Testing
import Foundation
@testable import Steddi

// CommuteETAEntry lives in the SteddiWidget extension target; the file is also a
// member of this test target's compile sources so the staleness/liveness logic
// can be unit-tested directly (no `@testable import` of the extension).

// MARK: - Widget Staleness / Liveness

/// Guards the widget's defense against a phantom "Navigating" pill with a
/// finished/stale ETA after an OOM/watchdog kill mid-drive. When the app is
/// killed without running any teardown, the App Group keeps `isNavigating == true`
/// with a frozen near-arrival ETA until the next app launch reconciles it. The
/// widget must NOT present that dead session as live; it bounds liveness on the
/// recency of the last live ETA write rather than trusting the flag.
@Suite("CommuteETAEntry staleness / liveness")
struct CommuteETAWidgetStalenessTests {

    // Fixed reference instant so timestamp math is deterministic.
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    /// A navigating entry whose ETA was written moments ago is a real live drive.
    @Test("Fresh navigating entry is live and not stale")
    func freshNavigatingIsLive() {
        let entry = CommuteETAEntry(
            date: now,
            commuteName: "Work",
            etaMinutes: 12,
            destinationName: "Office",
            isNavigating: true,
            etaUpdatedAt: now.addingTimeInterval(-30)   // 30s ago — live cadence
        )
        #expect(entry.isLiveNavigating == true)
        #expect(entry.isStale == false)
    }

    /// THE BUG: navigating flag still set, but the last live ETA write is old —
    /// the session was killed mid-drive and never torn down. It must be treated
    /// as NOT live (no "Navigating" pill) without waiting for the next app launch.
    @Test("Stale navigating entry (old ETA write) is treated as not-live")
    func staleNavigatingIsNotLive() {
        let entry = CommuteETAEntry(
            date: now,
            commuteName: "Work",
            etaMinutes: 1,                              // frozen near-arrival ETA
            destinationName: "Office",
            isNavigating: true,
            etaUpdatedAt: now.addingTimeInterval(-10 * 60)   // 10 min ago — dead
        )
        #expect(entry.isLiveNavigating == false)
        // It also falls through to the normal staleness path rather than being
        // presented as a live current ETA.
        #expect(entry.isStale == true)
    }

    /// A navigating flag with NO timestamp at all can't be proven live, so it's
    /// not presented as a live drive either.
    @Test("Navigating entry with no ETA timestamp is not live")
    func navigatingNoTimestampIsNotLive() {
        let entry = CommuteETAEntry(
            date: now,
            commuteName: "Work",
            etaMinutes: 2,
            destinationName: "Office",
            isNavigating: true,
            etaUpdatedAt: nil
        )
        #expect(entry.isLiveNavigating == false)
        #expect(entry.isStale == true)
    }

    /// Exactly at the navigating-staleness boundary the session is still honored
    /// as live (the boundary is inclusive); just past it, it is not.
    @Test("Liveness boundary is inclusive at the threshold, dead just past it")
    func livenessBoundary() {
        let atBoundary = CommuteETAEntry(
            date: now, commuteName: "W", etaMinutes: 5, destinationName: "O",
            isNavigating: true, etaUpdatedAt: now.addingTimeInterval(-3 * 60)   // == window
        )
        #expect(atBoundary.isLiveNavigating == true)

        let pastBoundary = CommuteETAEntry(
            date: now, commuteName: "W", etaMinutes: 5, destinationName: "O",
            isNavigating: true, etaUpdatedAt: now.addingTimeInterval(-3 * 60 - 1)
        )
        #expect(pastBoundary.isLiveNavigating == false)
    }

    /// A fresh idle (not-navigating) ETA is never "live navigating" but is also
    /// not stale — it remains a valid pre-drive glance.
    @Test("Fresh idle entry is not live-navigating and not stale")
    func freshIdleIsNotStale() {
        let entry = CommuteETAEntry(
            date: now,
            commuteName: "Work",
            etaMinutes: 25,
            destinationName: "Office",
            isNavigating: false,
            etaUpdatedAt: now.addingTimeInterval(-60)
        )
        #expect(entry.isLiveNavigating == false)
        #expect(entry.isStale == false)
    }
}
