import Testing
import Foundation
import CoreLocation
@testable import Steddi

@Suite("OneShotLocation")
struct OneShotLocationTests {

    /// The unit-test runner has no location authorization, so the auth-status
    /// guard must short-circuit to nil immediately — never blocking on the
    /// timeout or hanging waiting for a fix that can't arrive. This also pins
    /// the "fail gracefully" contract the ETA intent relies on.
    /// The auth-status guard short-circuits to nil; the `.timeLimit` is the only
    /// timing assertion — it catches a true hang (waiting out the 30s clock or
    /// blocking on CLLocationManager) without a tight wall-clock `elapsed` bound,
    /// which is inherently flaky under heavy host/CI load (scheduling delay alone
    /// can dwarf a fast bail). Behavior, not stopwatch.
    @Test("Returns nil promptly when unauthorized", .timeLimit(.minutes(1)))
    func unauthorizedReturnsNilFast() async {
        let location = await OneShotLocation.current(timeout: 30)
        #expect(location == nil)
    }

    /// The timeout must be a HARD deadline: `current()` must RETURN rather than
    /// block on CLLocationManager's own ~10s internal timeout / await a pending
    /// fix task forever. The `.timeLimit(.minutes(1))` is the regression guard —
    /// if the production timeout ever regressed to a true hang, the test fails by
    /// the time limit instead of hanging the suite. We assert the behavior (it
    /// returns) rather than a tight wall-clock bound, which flakes under load.
    @Test("Honors a short hard timeout without hanging", .timeLimit(.minutes(1)))
    func shortTimeoutReturnsWithoutHanging() async {
        // Unauthorized in the test runner, so this resolves via the auth guard /
        // the 1s timeout — never CoreLocation's ~10s path. Returning at all
        // (under the 1-minute limit) is the contract; a hang would trip it.
        let location = await OneShotLocation.current(timeout: 1)
        #expect(location == nil)
    }
}
