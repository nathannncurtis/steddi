import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - Remaining Polyline (active-route remaining geometry)

/// The high-severity regression was that the active route's remaining ETA and a
/// candidate's ETA were computed as the SAME point-to-point estimate, so savings
/// was always ~0 and no reroute could ever fire. The fix makes both ETAs follow
/// their own geometry; `remainingPolyline` extracts the part of the active route
/// still ahead of the driver so its ETA reflects the roads they're committed to.
@Suite("DirectionsService.remainingPolyline")
struct RemainingPolylineTests {

    /// A straight north-bound route; the driver is partway up it.
    private let route: [CLLocationCoordinate2D] = (0...10).map {
        CLLocationCoordinate2D(latitude: 33.0 + Double($0) * 0.001, longitude: -117.0)
    }

    @Test("Starts at the snapped position, ends at the destination")
    func startsSnappedEndsAtDestination() {
        // ~halfway up the route, slightly off-line to the east.
        let position = CLLocationCoordinate2D(latitude: 33.0052, longitude: -116.9999)
        let remaining = DirectionsService.remainingPolyline(of: route, from: position)

        #expect(remaining.count >= 2)
        // Snapped start sits near the driver's latitude, not back at the origin.
        #expect(abs(remaining.first!.latitude - position.latitude) < 0.0005)
        #expect(remaining.first!.latitude > route.first!.latitude)
        // Ends at the route's real destination.
        let dest = route.last!
        #expect(abs(remaining.last!.latitude - dest.latitude) < 1e-9)
        #expect(abs(remaining.last!.longitude - dest.longitude) < 1e-9)
    }

    @Test("Remaining geometry is strictly shorter than the full route once underway")
    func remainingShorterThanFull() {
        let position = CLLocationCoordinate2D(latitude: 33.007, longitude: -117.0)
        let remaining = DirectionsService.remainingPolyline(of: route, from: position)

        let fullLen = RouteGeometry.cumulativeDistances(route).last ?? 0
        let remainingLen = RouteGeometry.cumulativeDistances(remaining).last ?? 0
        #expect(remainingLen > 0)
        #expect(remainingLen < fullLen)
    }

    @Test("Near the start, remaining is essentially the whole route")
    func nearStartKeepsWholeRoute() {
        let position = route.first!
        let remaining = DirectionsService.remainingPolyline(of: route, from: position)
        let fullLen = RouteGeometry.cumulativeDistances(route).last ?? 0
        let remainingLen = RouteGeometry.cumulativeDistances(remaining).last ?? 0
        #expect(abs(remainingLen - fullLen) < 5) // within a few meters
    }

    @Test("Degenerate polyline (< 2 points) is returned unchanged")
    func degeneratePolyline() {
        let single = [CLLocationCoordinate2D(latitude: 33.0, longitude: -117.0)]
        let result = DirectionsService.remainingPolyline(of: single, from: single[0])
        #expect(result.count == 1)
        #expect(DirectionsService.remainingPolyline(of: [], from: single[0]).isEmpty)
    }
}

// MARK: - "Stay" Cooldown Suppression (low-severity nag fix)

@Suite("NavigationStateManager reroute suppression")
@MainActor
struct RerouteSuppressionTests {

    private func route(_ name: String = "Fallback") -> Route {
        Route(rank: 1, encodedPolyline: "", name: name, direction: .originToDestination)
    }

    @Test("Declining a route suppresses re-suggesting it at the same savings")
    func declineSuppressesSameSavings() {
        let manager = NavigationStateManager()
        let r = route()
        manager.rerouteSuggestion = (route: r, savingsMinutes: 6, savingsPercentage: 0.2)

        manager.dismissRerouteSuggestion()
        #expect(manager.rerouteSuggestion == nil)

        // Same route, same ~6 min (360s) savings, one cycle later — suppressed.
        #expect(manager.isRerouteSuppressed(
            routeID: r.id, savingsSeconds: 360,
            now: Date().addingTimeInterval(300)
        ))
    }

    @Test("A different route is never suppressed by a prior decline")
    func differentRouteNotSuppressed() {
        let manager = NavigationStateManager()
        let declined = route("A")
        let other = route("B")
        manager.rerouteSuggestion = (route: declined, savingsMinutes: 6, savingsPercentage: 0.2)
        manager.dismissRerouteSuggestion()

        #expect(!manager.isRerouteSuppressed(
            routeID: other.id, savingsSeconds: 360, now: Date()
        ))
    }

    @Test("Suppression lapses after the cooldown window")
    func suppressionLapsesAfterCooldown() {
        let manager = NavigationStateManager()
        let r = route()
        manager.rerouteSuggestion = (route: r, savingsMinutes: 6, savingsPercentage: 0.2)
        manager.dismissRerouteSuggestion()

        // 11 minutes later (> 10 min cooldown) — no longer suppressed.
        #expect(!manager.isRerouteSuppressed(
            routeID: r.id, savingsSeconds: 360,
            now: Date().addingTimeInterval(660)
        ))
    }

    @Test("A materially better savings re-surfaces even within cooldown")
    func materiallyBetterReSurfaces() {
        let manager = NavigationStateManager()
        let r = route()
        manager.rerouteSuggestion = (route: r, savingsMinutes: 6, savingsPercentage: 0.2)
        manager.dismissRerouteSuggestion()

        // Rejected 360s; now saving 360 + 180 = 540s (> 2 min margin) — allowed.
        #expect(!manager.isRerouteSuppressed(
            routeID: r.id, savingsSeconds: 540,
            now: Date().addingTimeInterval(120)
        ))
        // A trivial 30s improvement is still within the margin — suppressed.
        #expect(manager.isRerouteSuppressed(
            routeID: r.id, savingsSeconds: 390,
            now: Date().addingTimeInterval(120)
        ))
    }

    @Test("With nothing declined, nothing is suppressed")
    func nothingDeclinedNothingSuppressed() {
        let manager = NavigationStateManager()
        let r = route()
        #expect(!manager.isRerouteSuppressed(routeID: r.id, savingsSeconds: 999, now: Date()))
    }

    @Test("stopObserving clears the declined-route memory")
    func stopObservingClearsDecline() {
        let manager = NavigationStateManager()
        let r = route()
        manager.rerouteSuggestion = (route: r, savingsMinutes: 6, savingsPercentage: 0.2)
        manager.dismissRerouteSuggestion()
        #expect(manager.isRerouteSuppressed(routeID: r.id, savingsSeconds: 360, now: Date()))

        manager.stopObserving()
        // New session must not inherit a stale decline.
        #expect(!manager.isRerouteSuppressed(routeID: r.id, savingsSeconds: 360, now: Date()))
    }
}
