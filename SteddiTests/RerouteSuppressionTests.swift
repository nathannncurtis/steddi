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

// MARK: - Symmetric Reroute ETA Comparison

/// Both sides of the reroute decision must be "time from where I am NOW to the
/// destination via route X." The active route's baseline is its REMAINING ETA
/// (geometry ahead of the driver only); each candidate must be measured the same
/// way — its polyline trimmed to the portion ahead of the current position. The
/// regression was that the candidate used its FULL saved polyline (starting at
/// the commute origin), so mid-drive every candidate ETA was inflated by the
/// backtrack to the origin and a genuinely faster route never surfaced.
///
/// These tests inject a `fetchETA` that returns a duration proportional to the
/// geometric length of the polyline it is HANDED — faithfully mimicking OSRM's
/// path-aware duration. So if `bestReroute` passes a candidate's full (un-trimmed)
/// polyline, the injected ETA balloons exactly as the real backtrack would, and
/// the asymmetry is caught.
@Suite("NavigationStateManager symmetric reroute ETA")
@MainActor
struct SymmetricRerouteETATests {

    /// Speed used to turn a polyline's length into a duration (m/s).
    private static let metersPerSecond: Double = 20.0

    /// ETA proportional to the trimmed-ahead length of the polyline actually
    /// handed to the fetch — the same way OSRM's via-route duration tracks the
    /// geometry it's given. Faster routes (shorter ahead-geometry) -> lower ETA.
    /// Tagged path-aware, mimicking a successful via-route fetch.
    private static func lengthProportionalETA(
        _ coord: CLLocationCoordinate2D, _ encoded: String
    ) async throws -> RouteETA {
        let coords = PolylineEncoder.decode(encoded, precision: 6)
        let length = RouteGeometry.cumulativeDistances(coords).last ?? 0
        return RouteETA(duration: length / Self.metersPerSecond, isPathAware: true)
    }

    /// Wrap a duration as a path-aware baseline, the basis a successful
    /// via-route fetch of the active route's remaining geometry produces.
    private static func pathAwareBaseline(_ duration: TimeInterval) -> RouteETA {
        RouteETA(duration: duration, isPathAware: true)
    }

    /// A straight east-west route. `lat`/`lon` span chosen so two parallel
    /// routes between the same endpoints can differ only in path length.
    private func straightRoute(latOffset: Double, points: Int = 21) -> [CLLocationCoordinate2D] {
        (0..<points).map { i in
            let frac = Double(i) / Double(points - 1)
            return CLLocationCoordinate2D(latitude: 33.0 + latOffset, longitude: -117.0 + frac * 0.2)
        }
    }

    private func route(_ rank: Int, _ coords: [CLLocationCoordinate2D], name: String) -> Route {
        Route(
            rank: rank,
            encodedPolyline: PolylineEncoder.encode(coords, precision: 6),
            name: name,
            direction: .originToDestination
        )
    }

    /// `bestReroute` now consumes `Sendable` value snapshots, not `@Model`s.
    private func candidate(_ route: Route) -> NavigationStateManager.RerouteCandidate {
        NavigationStateManager.RerouteCandidate(id: route.id, encodedPolyline: route.encodedPolyline)
    }

    /// A genuinely faster alternative (shorter ahead-geometry) yields positive
    /// savings — and crucially, the savings reflect only the geometry AHEAD of
    /// the driver, computed symmetrically for both sides.
    @Test("A genuinely faster alternative yields real savings")
    func fasterAlternativeShowsSavings() async throws {
        let manager = NavigationStateManager()

        // Active route: a long detour that bulges far north before reaching the
        // shared destination. Candidate: a short straight shot. Both share the
        // same first and last coordinate (same origin/destination).
        let origin = CLLocationCoordinate2D(latitude: 33.0, longitude: -117.0)
        let destination = CLLocationCoordinate2D(latitude: 33.0, longitude: -116.8)

        // Long active route: detours up to lat 33.1 in the middle.
        var activeCoords: [CLLocationCoordinate2D] = [origin]
        activeCoords += (1..<10).map { CLLocationCoordinate2D(latitude: 33.1, longitude: -117.0 + Double($0) * 0.02) }
        activeCoords.append(destination)

        // Short candidate: straight line origin -> destination.
        let candidateCoords = [origin, destination]

        // Driver is at the origin (start of the drive) so "remaining" is the
        // whole route for both — comparison is over the full shared trip.
        let currentCoord = origin

        let remainingActive = DirectionsService.remainingPolyline(of: activeCoords, from: currentCoord)
        let remainingETA = try await Self.lengthProportionalETA(
            currentCoord, PolylineEncoder.encode(remainingActive, precision: 6)
        ).duration

        let candidateRoute = route(1, candidateCoords, name: "Straight shot")
        let best = await NavigationStateManager.bestReroute(
            candidates: [candidate(candidateRoute)],
            currentCoord: currentCoord,
            baseline: Self.pathAwareBaseline(remainingETA),
            basePercentage: 0.20,
            hardMinuteFloor: 10,
            isSuppressed: { _, _ in false },
            fetchETA: Self.lengthProportionalETA
        )

        let suggestion = try #require(best, "A clearly faster alternative should be suggested")
        #expect(suggestion.routeID == candidateRoute.id)
        #expect(suggestion.savingsMinutes > 0)
        _ = manager // keep the @MainActor harness honest
    }

    /// Comparing a route against ITSELF must show ~0 savings (no spurious card to
    /// "switch" to the route already being driven). This is the symmetry proof:
    /// both sides trim from the same current position, so identical geometry ->
    /// identical ETA -> zero savings -> no suggestion.
    @Test("The same route yields ~0 savings and no suggestion")
    func sameRouteYieldsNoSavings() async throws {
        let coords = straightRoute(latOffset: 0)
        let currentCoord = coords[7] // partway along

        let remainingActive = DirectionsService.remainingPolyline(of: coords, from: currentCoord)
        let remainingETA = try await Self.lengthProportionalETA(
            currentCoord, PolylineEncoder.encode(remainingActive, precision: 6)
        ).duration

        // The candidate IS the same geometry as the active route.
        let candidateRoute = route(1, coords, name: "Same path")
        let best = await NavigationStateManager.bestReroute(
            candidates: [candidate(candidateRoute)],
            currentCoord: currentCoord,
            baseline: Self.pathAwareBaseline(remainingETA),
            basePercentage: 0.20,
            hardMinuteFloor: 10,
            isSuppressed: { _, _ in false },
            fetchETA: Self.lengthProportionalETA
        )

        #expect(best == nil, "An identical route must not be surfaced as a faster reroute")
    }

    /// Direct regression guard: mid-drive, a candidate identical to the active
    /// route must NOT look faster. If the candidate were measured along its FULL
    /// polyline (the old bug) its ETA would include backtracking to the origin,
    /// which — depending on sign — corrupts the comparison. With both sides
    /// trimmed-from-current-position the self-comparison is provably ~0.
    @Test("Mid-drive, an identical candidate is never spuriously faster")
    func midDriveSelfComparisonIsZero() async throws {
        let coords = straightRoute(latOffset: 0, points: 41)
        // Well into the drive — the bug's backtrack-to-origin inflation would be
        // largest here.
        let currentCoord = coords[30]

        let remainingActive = DirectionsService.remainingPolyline(of: coords, from: currentCoord)
        let remainingETA = try await Self.lengthProportionalETA(
            currentCoord, PolylineEncoder.encode(remainingActive, precision: 6)
        ).duration

        // Recreate the candidate ETA the way bestReroute does (trim then fetch)
        // to prove it equals the active remaining ETA.
        let candidateRemaining = DirectionsService.remainingPolyline(of: coords, from: currentCoord)
        let candidateETA = try await Self.lengthProportionalETA(
            currentCoord, PolylineEncoder.encode(candidateRemaining, precision: 6)
        ).duration
        #expect(abs(candidateETA - remainingETA) < 1.0)

        let candidateRoute = route(1, coords, name: "Same path mid-drive")
        let best = await NavigationStateManager.bestReroute(
            candidates: [candidate(candidateRoute)],
            currentCoord: currentCoord,
            baseline: Self.pathAwareBaseline(remainingETA),
            basePercentage: 0.20,
            hardMinuteFloor: 10,
            isSuppressed: { _, _ in false },
            fetchETA: Self.lengthProportionalETA
        )
        #expect(best == nil)
    }

    /// Candidate exclusion is by IDENTITY, not rank (Finding 2). After switching
    /// onto a fallback, the caller passes only the OTHER routes as candidates; the
    /// just-switched fallback must not be re-suggested, and the faster preferred
    /// (rank 0) route CAN be offered back.
    @Test("After switching to an alt, the alt is not re-suggested and the preferred route can be re-offered")
    func preferredRouteCanBeReOffered() async throws {
        let origin = CLLocationCoordinate2D(latitude: 33.0, longitude: -117.0)
        let destination = CLLocationCoordinate2D(latitude: 33.0, longitude: -116.8)

        // Preferred (rank 0): now the SHORT straight shot (became faster again).
        let preferredCoords = [origin, destination]
        // Fallback (rank 1): the LONG detour the driver switched onto earlier.
        var altCoords: [CLLocationCoordinate2D] = [origin]
        altCoords += (1..<10).map { CLLocationCoordinate2D(latitude: 33.1, longitude: -117.0 + Double($0) * 0.02) }
        altCoords.append(destination)

        let preferred = route(0, preferredCoords, name: "Preferred")
        let alt = route(1, altCoords, name: "Alt (currently driving)")

        // Driver is on the alt; remaining baseline measured along the alt.
        let currentCoord = origin
        let remainingAlt = DirectionsService.remainingPolyline(of: altCoords, from: currentCoord)
        let remainingETA = try await Self.lengthProportionalETA(
            currentCoord, PolylineEncoder.encode(remainingAlt, precision: 6)
        ).duration

        // Caller excludes the active route (alt) by identity — only the preferred
        // route is a candidate. (The OLD rank>0 filter would have excluded the
        // preferred route and kept the alt — exactly backwards.)
        let candidates = [preferred, alt].filter { $0.id != alt.id }
        #expect(candidates.map(\.id) == [preferred.id])

        let best = await NavigationStateManager.bestReroute(
            candidates: candidates.map { candidate($0) },
            currentCoord: currentCoord,
            baseline: Self.pathAwareBaseline(remainingETA),
            basePercentage: 0.20,
            hardMinuteFloor: 10,
            isSuppressed: { _, _ in false },
            fetchETA: Self.lengthProportionalETA
        )

        let suggestion = try #require(best, "The faster preferred route should be re-offered")
        #expect(suggestion.routeID == preferred.id)
        #expect(suggestion.routeID != alt.id, "The route being driven must never be re-suggested")
    }

    /// FALLBACK-PATH asymmetry guard. When a candidate's via-route fetch
    /// transiently FAILS, `fetchPathAwareETA` degrades to a direct (open-road,
    /// generally shorter) estimate tagged `isPathAware: false`. If `bestReroute`
    /// compared that direct number against the path-aware baseline, the shorter
    /// direct estimate would manufacture a phantom "faster route" card for a
    /// route that is actually SLOWER along its real geometry. The comparability
    /// gate must skip any candidate whose basis disagrees with the baseline, so
    /// no suggestion surfaces this cycle.
    @Test("A candidate that falls back to a direct estimate is never spuriously faster")
    func fallbackBasisMismatchYieldsNoSavings() async throws {
        let origin = CLLocationCoordinate2D(latitude: 33.0, longitude: -117.0)
        let destination = CLLocationCoordinate2D(latitude: 33.0, longitude: -116.8)

        // Active route: the committed path the driver is on — measured PATH-AWARE.
        // It bulges north before the shared destination, so its path-aware length
        // (and thus baseline ETA) is genuinely LONGER than a straight-line
        // origin->destination estimate.
        var activeCoords: [CLLocationCoordinate2D] = [origin]
        activeCoords += (1..<10).map { CLLocationCoordinate2D(latitude: 33.1, longitude: -117.0 + Double($0) * 0.02) }
        activeCoords.append(destination)

        // Candidate: an equally-long detour. Its REAL path-aware ETA would be
        // about the same as the baseline (no genuine savings), but its via-route
        // fetch transiently FAILS, so its ETA degrades to the much-shorter
        // straight-line direct estimate — which would manufacture phantom savings
        // if compared against the path-aware baseline.
        let candidateCoords = activeCoords

        let currentCoord = origin

        // Baseline: path-aware ETA along the (detouring) active route.
        let remainingActive = DirectionsService.remainingPolyline(of: activeCoords, from: currentCoord)
        let baselineDuration = try await Self.lengthProportionalETA(
            currentCoord, PolylineEncoder.encode(remainingActive, precision: 6)
        ).duration
        let baseline = Self.pathAwareBaseline(baselineDuration)

        // The straight-line endpoint distance, used as the DIRECT fallback
        // estimate — much shorter than the committed detour path, so it WOULD
        // look faster than the baseline if compared.
        let directEstimate = RouteGeometry.haversineDistance(from: origin, to: destination) / Self.metersPerSecond
        #expect(directEstimate < baselineDuration,
                "Setup: the direct fallback estimate must look faster than the path-aware baseline")

        // Simulate the candidate's via-route transiently failing: its fetch
        // degrades to the direct estimate, tagged NOT path-aware.
        let candidateRoute = route(1, candidateCoords, name: "Detour (via-route failed)")
        let best = await NavigationStateManager.bestReroute(
            candidates: [candidate(candidateRoute)],
            currentCoord: currentCoord,
            baseline: baseline,
            basePercentage: 0.20,
            hardMinuteFloor: 10,
            isSuppressed: { _, _ in false },
            fetchETA: { _, _ in RouteETA(duration: directEstimate, isPathAware: false) }
        )

        #expect(best == nil,
                "A direct-fallback candidate must not be compared against a path-aware baseline — no phantom savings")
    }

    /// Symmetry sanity: when BOTH sides fall back to the same (direct) basis,
    /// the comparison IS valid again and a genuinely faster route still
    /// surfaces. The gate only blocks MIXED-basis comparisons, not a fully
    /// degraded cycle where both numbers share the same footing.
    @Test("When both sides fall back to a direct estimate, a faster route still surfaces")
    func bothSidesDirectStillCompares() async throws {
        let origin = CLLocationCoordinate2D(latitude: 33.0, longitude: -117.0)
        let destination = CLLocationCoordinate2D(latitude: 33.0, longitude: -116.8)
        let candidateCoords = [origin, destination]
        let currentCoord = origin

        // Both baseline and candidate are on the DIRECT basis. Baseline is a
        // long direct estimate; candidate's direct estimate is shorter.
        let baseline = RouteETA(duration: 1200, isPathAware: false)
        let candidateRoute = route(1, candidateCoords, name: "Faster (both direct)")

        let best = await NavigationStateManager.bestReroute(
            candidates: [candidate(candidateRoute)],
            currentCoord: currentCoord,
            baseline: baseline,
            basePercentage: 0.20,
            hardMinuteFloor: 10,
            isSuppressed: { _, _ in false },
            fetchETA: { _, _ in RouteETA(duration: 600, isPathAware: false) }
        )

        let suggestion = try #require(best, "Same-basis comparison must still surface a faster route")
        #expect(suggestion.routeID == candidateRoute.id)
        #expect(suggestion.savingsMinutes > 0)
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
