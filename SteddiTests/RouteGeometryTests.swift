import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - RouteGeometry Tests

@Suite("RouteGeometry")
struct RouteGeometryTests {

    @Test("Haversine distance for 0.001 degree latitude is ~111m")
    func haversineKnownDistance() {
        let a = CLLocationCoordinate2D(latitude: 33.0, longitude: -117.0)
        let b = CLLocationCoordinate2D(latitude: 33.001, longitude: -117.0)
        let d = RouteGeometry.haversineDistance(from: a, to: b)
        #expect(abs(d - 111.19) < 0.5)
    }

    @Test("Bearing due east is 90")
    func bearingEast() {
        let a = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let b = CLLocationCoordinate2D(latitude: 0, longitude: 0.001)
        #expect(abs(RouteGeometry.bearing(from: a, to: b) - 90) < 0.01)
    }

    @Test("Bearing due north is 0")
    func bearingNorth() {
        let a = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let b = CLLocationCoordinate2D(latitude: 0.001, longitude: 0)
        let bearing = RouteGeometry.bearing(from: a, to: b)
        #expect(bearing < 0.01 || bearing > 359.99)
    }

    @Test("Normalize wraps negative angles into 0..<360")
    func normalizeNegative() {
        #expect(RouteGeometry.normalizeBearing(-90) == 270)
        #expect(RouteGeometry.normalizeBearing(450) == 90)
        #expect(RouteGeometry.normalizeBearing(0) == 0)
    }

    @Test("Smooth bearing takes the short arc across the 360/0 wrap")
    func smoothBearingWraparound() {
        // 350 -> 10 should pass through 357, not rotate backward through 180
        let result = RouteGeometry.smoothBearing(current: 350, target: 10, factor: 0.35)
        #expect(result > 350 || result < 10)
        #expect(abs(result - 357) < 0.01)
    }

    @Test("Smooth bearing converges on the target")
    func smoothBearingConvergence() {
        var bearing = 350.0
        for _ in 0..<25 {
            bearing = RouteGeometry.smoothBearing(current: bearing, target: 10, factor: 0.35)
        }
        var delta = abs(bearing - 10).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta = 360 - delta }
        #expect(delta < 1.0)
    }

    @Test("Offset coordinate round-trips through haversine distance")
    func offsetCoordinateRoundTrip() {
        let origin = CLLocationCoordinate2D(latitude: 33.0, longitude: -117.0)
        let moved = RouteGeometry.offsetCoordinate(origin, distanceMeters: 100, bearingDegrees: 45)
        #expect(abs(RouteGeometry.haversineDistance(from: origin, to: moved) - 100) < 0.5)
        #expect(abs(RouteGeometry.bearing(from: origin, to: moved) - 45) < 0.5)
    }

    @Test("Cumulative distances start at zero and end at the total")
    func cumulativeDistancesShape() {
        let polyline = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0.001, longitude: 0),
            CLLocationCoordinate2D(latitude: 0.001, longitude: 0.001),
        ]
        let cumulative = RouteGeometry.cumulativeDistances(polyline)
        #expect(cumulative.count == polyline.count)
        #expect(cumulative[0] == 0)
        let leg1 = RouteGeometry.haversineDistance(from: polyline[0], to: polyline[1])
        let leg2 = RouteGeometry.haversineDistance(from: polyline[1], to: polyline[2])
        #expect(abs(cumulative[2] - (leg1 + leg2)) < 0.01)
    }

    @Test("Arc-length midpoint of an L-shaped polyline lies on the second leg")
    func arcLengthMidpointOnPolyline() throws {
        // North 111m, then east 111m — the straight-line midpoint would cut the
        // corner; walking the polyline must stay on the line.
        let polyline = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0.001, longitude: 0),
            CLLocationCoordinate2D(latitude: 0.001, longitude: 0.001),
        ]
        let cumulative = RouteGeometry.cumulativeDistances(polyline)
        let total = try #require(cumulative.last)

        let mid = try #require(RouteGeometry.coordinate(atDistance: total / 2, polyline: polyline, cumulative: cumulative))
        // Half the total is exactly the corner vertex
        #expect(abs(mid.latitude - 0.001) < 1e-9)
        #expect(abs(mid.longitude - 0) < 1e-9)

        // Three quarters along is halfway down the east leg
        let threeQuarter = try #require(RouteGeometry.coordinate(atDistance: total * 0.75, polyline: polyline, cumulative: cumulative))
        #expect(abs(threeQuarter.latitude - 0.001) < 1e-7)
        #expect(abs(threeQuarter.longitude - 0.0005) < 1e-7)
    }

    @Test("Coordinate at distance clamps to the polyline ends")
    func coordinateAtDistanceClamps() throws {
        let polyline = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0.001, longitude: 0),
        ]
        let cumulative = RouteGeometry.cumulativeDistances(polyline)

        let before = try #require(RouteGeometry.coordinate(atDistance: -10, polyline: polyline, cumulative: cumulative))
        #expect(before.latitude == 0)

        let after = try #require(RouteGeometry.coordinate(atDistance: 99999, polyline: polyline, cumulative: cumulative))
        #expect(after.latitude == 0.001)
    }

    @Test("Bearing at distance is nil for a degenerate polyline")
    func bearingNilForDegeneratePolyline() {
        let point = CLLocationCoordinate2D(latitude: 33.0, longitude: -117.0)
        let polyline = [point, point]
        let cumulative = RouteGeometry.cumulativeDistances(polyline)
        #expect(RouteGeometry.bearing(atDistance: 0, polyline: polyline, cumulative: cumulative) == nil)
    }

    @Test("Bearing at distance stays valid approaching the route end")
    func bearingStableNearEnd() throws {
        let polyline = (0...10).map { CLLocationCoordinate2D(latitude: 33.0 + Double($0) * 0.001, longitude: -117.0) }
        let cumulative = RouteGeometry.cumulativeDistances(polyline)
        let total = try #require(cumulative.last)

        let nearEnd = try #require(RouteGeometry.bearing(atDistance: total - 1, polyline: polyline, cumulative: cumulative))
        let atEnd = try #require(RouteGeometry.bearing(atDistance: total, polyline: polyline, cumulative: cumulative))
        #expect(nearEnd < 0.5 || nearEnd > 359.5)
        #expect(atEnd < 0.5 || atEnd > 359.5)
    }
}

// MARK: - RouteProjector Tests

@Suite("RouteProjector")
struct RouteProjectorTests {

    /// Straight route running north, ~111m per segment.
    private func straightRoute(segments: Int) -> [CLLocationCoordinate2D] {
        (0...segments).map { CLLocationCoordinate2D(latitude: 33.0 + Double($0) * 0.001, longitude: -117.0) }
    }

    @Test("Projection snaps an offset point onto the line")
    func snapsOntoLine() throws {
        var projector = RouteProjector(polyline: straightRoute(segments: 10))
        // ~18m east of the route, halfway up the first segment
        let point = CLLocationCoordinate2D(latitude: 33.0005, longitude: -116.9998)
        let result = projector.project(point)
        let projection = try #require(result)

        #expect(abs(projection.snappedCoordinate.longitude - (-117.0)) < 1e-6)
        #expect(abs(projection.snappedCoordinate.latitude - 33.0005) < 1e-5)
        #expect(projection.segmentIndex == 0)
        #expect(projection.t > 0.4 && projection.t < 0.6)
        #expect(abs(projection.perpendicularDistance - 18.6) < 2)
        #expect(abs(projection.distanceAlongRoute - 55.6) < 2)
    }

    @Test("Jump beyond the window triggers a full rescan")
    func fullRescanBeyondWindow() throws {
        var projector = RouteProjector(polyline: straightRoute(segments: 100))
        // Anchor the window at the start
        _ = projector.project(CLLocationCoordinate2D(latitude: 33.0001, longitude: -117.0))
        // Then project a point ~80 segments ahead — far outside prev..+50
        let result = projector.project(CLLocationCoordinate2D(latitude: 33.0805, longitude: -117.0))
        let far = try #require(result)
        #expect(far.segmentIndex == 80)
        #expect(far.perpendicularDistance < 1)
    }

    @Test("GPS jitter one segment backward snaps backward within the window")
    func backwardJitterWithinWindow() throws {
        var projector = RouteProjector(polyline: straightRoute(segments: 10))
        // Anchor mid-segment-5 (~611m along)
        let firstResult = projector.project(CLLocationCoordinate2D(latitude: 33.0055, longitude: -117.0))
        let first = try #require(firstResult)
        #expect(first.segmentIndex == 5)

        // Jitter ~78m backward into segment 4 — windowBehind=1 must allow it
        let backResult = projector.project(CLLocationCoordinate2D(latitude: 33.0048, longitude: -117.0))
        let back = try #require(backResult)
        #expect(back.segmentIndex == 4)
        #expect(back.distanceAlongRoute < first.distanceAlongRoute)
        #expect(back.perpendicularDistance < 1)
    }

    @Test("Large backward jump beyond the window triggers a full rescan")
    func backwardFullRescan() throws {
        var projector = RouteProjector(polyline: straightRoute(segments: 100))
        // Anchor far up the route at segment 80
        let farResult = projector.project(CLLocationCoordinate2D(latitude: 33.0805, longitude: -117.0))
        let far = try #require(farResult)
        #expect(far.segmentIndex == 80)

        // A fix ~8km behind the window (position correction, e.g. tunnel exit):
        // the windowed snap is way off-route, so the full rescan must recover
        let recoveredResult = projector.project(CLLocationCoordinate2D(latitude: 33.0055, longitude: -117.0))
        let recovered = try #require(recoveredResult)
        #expect(recovered.segmentIndex == 5)
        #expect(recovered.perpendicularDistance < 1)
    }

    @Test("Single-point polyline yields no projection")
    func degeneratePolyline() {
        var projector = RouteProjector(polyline: [CLLocationCoordinate2D(latitude: 33, longitude: -117)])
        #expect(projector.project(CLLocationCoordinate2D(latitude: 33, longitude: -117)) == nil)
    }

    @Test("Reset window forces the next projection to rescan globally")
    func resetWindowRescans() throws {
        var projector = RouteProjector(polyline: straightRoute(segments: 100))
        _ = projector.project(CLLocationCoordinate2D(latitude: 33.09, longitude: -117.0))
        projector.resetWindow()
        let result = projector.project(CLLocationCoordinate2D(latitude: 33.0005, longitude: -117.0))
        let back = try #require(result)
        #expect(back.segmentIndex == 0)
    }
}

// MARK: - Spike Removal (legacy chained-leg spur cleanup)

@Suite("RouteGeometry.removeSpikes")
struct RemoveSpikesTests {

    private func c(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    @Test("Out-and-back spike apex is removed")
    func removesSimpleSpike() {
        // A -> B -> spur -> B -> C : the spur vertex must vanish
        let polyline = [
            c(33.0000, -117.0000),
            c(33.0010, -117.0000),
            c(33.0010, -117.0005),  // spur apex
            c(33.0010, -117.0000),  // retrace
            c(33.0020, -117.0000),
        ]
        let cleaned = RouteGeometry.removeSpikes(polyline)
        #expect(cleaned.count == 3)
        #expect(abs(cleaned[1].latitude - 33.0010) < 1e-9)
    }

    @Test("Multi-vertex spur unwinds fully")
    func unwindsDeepSpur() {
        let polyline = [
            c(33.0000, -117.0000),
            c(33.0010, -117.0000),
            c(33.0010, -117.0004),
            c(33.0010, -117.0008),  // deep apex
            c(33.0010, -117.0004),
            c(33.0010, -117.0000),
            c(33.0020, -117.0000),
        ]
        let cleaned = RouteGeometry.removeSpikes(polyline)
        #expect(cleaned.count == 3)
    }

    @Test("Clean geometry is untouched")
    func leavesCleanGeometryAlone() {
        let polyline = (0...10).map { c(33.0 + Double($0) * 0.001, -117.0) }
        #expect(RouteGeometry.removeSpikes(polyline).count == polyline.count)
    }

    @Test("Adjacent near-duplicates are deduped")
    func dedupesNearDuplicates() {
        let polyline = [
            c(33.0000, -117.0000),
            c(33.000001, -117.000001),  // ~0.15m away
            c(33.0010, -117.0000),
        ]
        #expect(RouteGeometry.removeSpikes(polyline).count == 2)
    }
}

// MARK: - Post-Reset Leg Disambiguation (regression)

@Suite("RouteProjector post-reset disambiguation")
struct PostResetDisambiguationTests {

    /// Out-and-back on identical geometry: north 33.000 -> 33.005, back south.
    /// ~1111m out, ~1111m back (vertices every ~55m).
    private var outAndBack: [CLLocationCoordinate2D] {
        let out = (0...20).map { CLLocationCoordinate2D(latitude: 33.0 + Double($0) * 0.0005, longitude: -117.0) }
        let back = (1...20).map { CLLocationCoordinate2D(latitude: 33.01 - Double($0) * 0.0005, longitude: -117.0) }
        return out + back
    }

    @Test("Return-leg pose survives a window reset on shared geometry")
    func returnLegSurvivesReset() throws {
        let polyline = outAndBack
        var projector = RouteProjector(polyline: polyline)
        let total = projector.totalDistance

        // Drive out and onto the return leg: project a point at ~75% of the
        // route (second pass over the shared line, heading south)
        for lat in stride(from: 33.000, through: 33.0095, by: 0.0005) {
            _ = projector.project(.init(latitude: lat, longitude: -117.0))
        }
        for lat in stride(from: 33.0095, through: 33.0075, by: -0.0005) {
            _ = projector.project(.init(latitude: lat, longitude: -117.0))
        }
        let beforeOptional = projector.project(.init(latitude: 33.007, longitude: -117.0))
        let before = try #require(beforeOptional)
        #expect(before.distanceAlongRoute > total / 2, "pose must be on the return leg before the reset")

        // Off-route confirmation resets the window mid-return-leg
        projector.resetWindow()

        // GPS recovers on the shared line slightly further south — the pose
        // must continue on the RETURN leg (along > half), never re-anchor to
        // the outbound leg and walk backward
        let afterOptional = projector.project(.init(latitude: 33.0065, longitude: -117.0))
        let after = try #require(afterOptional)
        #expect(after.distanceAlongRoute > total / 2, "post-reset rescan re-anchored to the outbound leg")
        #expect(after.distanceAlongRoute > before.distanceAlongRoute, "pose walked backward after reset")
    }
}
