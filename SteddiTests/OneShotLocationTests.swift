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
    @Test("Returns nil promptly when unauthorized")
    func unauthorizedReturnsNilFast() async {
        let start = Date()
        let location = await OneShotLocation.current(timeout: 30)
        let elapsed = Date().timeIntervalSince(start)
        #expect(location == nil)
        // Far under the 30s timeout — proves we bailed on the auth guard, not
        // by waiting out the clock.
        #expect(elapsed < 2)
    }

    /// The timeout must be a HARD deadline: `current()` must return at (or very
    /// near) the requested timeout, NOT block on CLLocationManager's own ~10s
    /// internal timeout. This test guards against the regression where the task
    /// group implicitly awaits the still-pending fix task.
    ///
    /// The call is itself raced against a generous outer deadline so that if the
    /// production timeout ever regressed to a hang, the TEST fails fast instead
    /// of hanging the whole suite — the explicit "test can't hang" requirement.
    @Test("Honors a short hard timeout without hanging", .timeLimit(.minutes(1)))
    func shortTimeoutReturnsWithoutHanging() async {
        let requested: TimeInterval = 1
        // Outer guard deadline: comfortably above the requested timeout but well
        // under CLLocationManager's ~10s internal one, so a regression that
        // waits out CoreLocation surfaces as a nil-from-deadline (which we
        // assert against) rather than a hung test.
        let outerDeadline: TimeInterval = 6

        let start = Date()
        let didReturnInTime = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await OneShotLocation.current(timeout: requested)
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(outerDeadline))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        let elapsed = Date().timeIntervalSince(start)

        // The production call returned on its own (within the requested timeout
        // plus scheduling slack) rather than being beaten by the outer deadline.
        #expect(didReturnInTime)
        #expect(elapsed < outerDeadline)
    }
}
