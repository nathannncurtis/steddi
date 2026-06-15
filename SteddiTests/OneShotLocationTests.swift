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
}
