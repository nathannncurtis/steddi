import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - NavPoseInterpolator Tests

@Suite("NavPoseInterpolator")
struct NavPoseInterpolatorTests {

    private func pose(distance: Double, speed: Double = 10, t: TimeInterval = 0) -> NavPose {
        NavPose(
            snappedCoordinate: CLLocationCoordinate2D(latitude: 33, longitude: -117),
            segmentIndex: 0,
            t: 0,
            distanceAlongRoute: distance,
            segmentBearingDegrees: 0,
            speedMPS: speed,
            fixTimestamp: Date(timeIntervalSince1970: 1_750_000_000 + t)
        )
    }

    @Test("Distance is nil before any pose is pushed")
    func nilBeforeFirstPush() {
        let interpolator = NavPoseInterpolator()
        #expect(interpolator.distanceAlongRoute(at: 100) == nil)
    }

    @Test("First pose holds at the fix distance")
    func firstPoseHolds() throws {
        var interpolator = NavPoseInterpolator()
        interpolator.push(pose(distance: 100), at: 50.0)
        let d = try #require(interpolator.distanceAlongRoute(at: 50.2))
        #expect(d == 100)
    }

    @Test("Midpoint of the fix interval is halfway between fixes")
    func midpointBetweenFixes() throws {
        var interpolator = NavPoseInterpolator()
        interpolator.push(pose(distance: 0, t: 0), at: 100.0)
        interpolator.push(pose(distance: 10, t: 1), at: 101.0)
        let d = try #require(interpolator.distanceAlongRoute(at: 101.5))
        #expect(abs(d - 5) < 1e-9)
    }

    @Test("Full interval lands exactly on the current fix")
    func fullIntervalReachesCurrentFix() throws {
        var interpolator = NavPoseInterpolator()
        interpolator.push(pose(distance: 0, t: 0), at: 100.0)
        interpolator.push(pose(distance: 10, t: 1), at: 101.0)
        let d = try #require(interpolator.distanceAlongRoute(at: 102.0))
        #expect(abs(d - 10) < 1e-9)
    }

    @Test("Late fix extrapolates at speed, clamped to 1.5x the interval")
    func extrapolationClamp() {
        // 0.2s past the 1s interval: extrapolate 0.2s at 10 m/s
        let slightlyLate = NavPoseInterpolator.interpolatedDistance(
            previousDistance: 0, currentDistance: 10,
            elapsedSinceFix: 1.2, fixInterval: 1.0, speedMPS: 10
        )
        #expect(abs(slightlyLate - 12) < 1e-9)

        // Way late: the extrapolation budget caps at 0.5x the interval
        let veryLate = NavPoseInterpolator.interpolatedDistance(
            previousDistance: 0, currentDistance: 10,
            elapsedSinceFix: 8.0, fixInterval: 1.0, speedMPS: 10
        )
        #expect(abs(veryLate - 15) < 1e-9)
    }

    @Test("Backward projection jump holds at the current fix")
    func backwardJumpHolds() {
        // A reroute can move distance-along backward — never interpolate across it
        let d = NavPoseInterpolator.interpolatedDistance(
            previousDistance: 50, currentDistance: 10,
            elapsedSinceFix: 0.5, fixInterval: 1.0, speedMPS: 10
        )
        #expect(d == 10)
    }

    @Test("Extrapolation never passes the max distance")
    func maxDistanceClamp() throws {
        var interpolator = NavPoseInterpolator()
        interpolator.push(pose(distance: 0, speed: 20, t: 0), at: 100.0)
        interpolator.push(pose(distance: 20, speed: 20, t: 1), at: 101.0)
        // Late frame would extrapolate past 22 — the next-maneuver clamp stops it
        let d = try #require(interpolator.distanceAlongRoute(at: 102.4, maxDistance: 22))
        #expect(d == 22)
    }

    @Test("Max distance clamp never pulls the pose behind the current fix")
    func maxDistanceClampNeverGoesBackward() throws {
        var interpolator = NavPoseInterpolator()
        interpolator.push(pose(distance: 0, speed: 20, t: 0), at: 100.0)
        interpolator.push(pose(distance: 20, speed: 20, t: 1), at: 101.0)
        // A max distance behind the fix must not drag the pose backward
        let d = try #require(interpolator.distanceAlongRoute(at: 102.4, maxDistance: 5))
        #expect(d == 20)
    }

    @Test("Reset clears all pose state")
    func resetClearsState() {
        var interpolator = NavPoseInterpolator()
        interpolator.push(pose(distance: 10), at: 100.0)
        interpolator.reset()
        #expect(interpolator.currentPose == nil)
        #expect(interpolator.previousPose == nil)
        #expect(interpolator.distanceAlongRoute(at: 101) == nil)
    }

    @Test("Fix interval adapts toward the observed cadence")
    func fixIntervalAdapts() {
        var interpolator = NavPoseInterpolator()
        interpolator.push(pose(distance: 0, t: 0), at: 100.0)
        for i in 1...20 {
            interpolator.push(pose(distance: Double(i) * 20, t: Double(i) * 2), at: 100.0 + Double(i) * 2)
        }
        #expect(abs(interpolator.fixInterval - 2.0) < 0.1)
    }
}
