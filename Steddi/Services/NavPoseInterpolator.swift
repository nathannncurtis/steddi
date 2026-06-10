import Foundation
import CoreLocation

/// Interpolates between consecutive engine poses so the puck and camera can be
/// driven per display frame from one continuous arc-length position, instead of
/// stepping (or re-animating) once per GPS fix on competing clocks.
struct NavPoseInterpolator {

    private(set) var previousPose: NavPose?
    private(set) var currentPose: NavPose?
    /// Monotonic time at which currentPose was pushed.
    private(set) var currentPushTime: TimeInterval = 0
    /// Smoothed interval between fixes, seconds.
    private(set) var fixInterval: TimeInterval = 1.0
    /// Smoothed ground speed used to extrapolate when a fix arrives late.
    private(set) var smoothedSpeedMPS: Double = 0

    /// Extrapolation never runs past this multiple of the fix interval.
    static let maxExtrapolationFactor: Double = 1.5

    mutating func reset() {
        previousPose = nil
        currentPose = nil
        currentPushTime = 0
        fixInterval = 1.0
        smoothedSpeedMPS = 0
    }

    /// Feed a new engine pose. `now` is a monotonic clock — typically the
    /// display link timestamp.
    mutating func push(_ pose: NavPose, at now: TimeInterval) {
        if let current = currentPose {
            let interval = now - currentPushTime
            if interval > 0.05, interval < 10 {
                fixInterval += (interval - fixInterval) * 0.3
            }
            previousPose = current
        }
        currentPose = pose
        currentPushTime = now
        smoothedSpeedMPS += (pose.speedMPS - smoothedSpeedMPS) * 0.3
    }

    /// Interpolated distance along the route at display time `now`.
    /// `maxDistance` caps forward extrapolation (e.g. never past the next
    /// maneuver or the route end). nil until a pose has been pushed.
    func distanceAlongRoute(at now: TimeInterval, maxDistance: Double? = nil) -> Double? {
        guard let current = currentPose else { return nil }
        let raw = Self.interpolatedDistance(
            previousDistance: previousPose?.distanceAlongRoute,
            currentDistance: current.distanceAlongRoute,
            elapsedSinceFix: max(0, now - currentPushTime),
            fixInterval: fixInterval,
            speedMPS: smoothedSpeedMPS
        )
        guard let maxDistance else { return raw }
        // Clamp the extrapolated part only — never pull the pose behind the fix
        return min(raw, max(maxDistance, current.distanceAlongRoute))
    }

    /// Pure interpolation core. Inside the expected fix interval the position
    /// slides from the previous fix toward the current one (rendering one fix
    /// behind, like the system puck). When the next fix is late, the position
    /// extrapolates forward at the smoothed speed, clamped so it never runs
    /// more than maxExtrapolationFactor fix intervals past the last fix.
    static func interpolatedDistance(
        previousDistance: Double?,
        currentDistance: Double,
        elapsedSinceFix: TimeInterval,
        fixInterval: TimeInterval,
        speedMPS: Double
    ) -> Double {
        let interval = max(0.1, fixInterval)
        let speed = max(0, speedMPS)

        if let previousDistance, previousDistance <= currentDistance, elapsedSinceFix <= interval {
            let t = elapsedSinceFix / interval
            return previousDistance + (currentDistance - previousDistance) * t
        }

        // Late fix, first fix, or a projection that jumped backward (reroute):
        // extrapolate from the current fix at the smoothed speed, clamped.
        let overshoot = max(0, min(elapsedSinceFix, interval * maxExtrapolationFactor) - interval)
        return currentDistance + speed * overshoot
    }
}
