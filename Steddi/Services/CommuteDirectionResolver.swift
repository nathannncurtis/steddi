import Foundation
import CoreLocation
import SwiftData

/// Resolves which direction a user is likely going when they tap a commute.
/// Only uses proximity — if you're at one endpoint, go to the other. Otherwise, ask.
struct CommuteDirectionResolver {

    enum Result {
        case confident(CommuteDirection, destinationName: String)
        case ambiguous(originName: String, destinationName: String)
    }

    /// The radius (meters) within which we're confident the user is "at" an endpoint (~500 feet).
    private static let proximityRadius: Double = 152

    /// Resolve the likely direction for a commute from the user's current location.
    /// Only auto-resolves if the user is physically at one of the endpoints.
    static func resolve(
        commute: Commute,
        currentLocation: CLLocation,
        now: Date = Date()
    ) -> Result {
        guard let origin = commute.origin, let destination = commute.destination else {
            return .ambiguous(
                originName: commute.origin?.name ?? "Origin",
                destinationName: commute.destination?.name ?? "Destination"
            )
        }

        let originLoc = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let destLoc = CLLocation(latitude: destination.latitude, longitude: destination.longitude)

        let distToOrigin = currentLocation.distance(from: originLoc)
        let distToDest = currentLocation.distance(from: destLoc)

        // Only auto-resolve if physically at one endpoint
        if distToOrigin < proximityRadius && distToDest >= proximityRadius {
            return .confident(.originToDestination, destinationName: destination.name)
        }
        if distToDest < proximityRadius && distToOrigin >= proximityRadius {
            return .confident(.destinationToOrigin, destinationName: origin.name)
        }

        // 2. Schedule-based direction — user-configured time rules
        if let scheduleDir = scheduledDirection(commute: commute, now: now) {
            let name = scheduleDir == .originToDestination ? destination.name : origin.name
            return .confident(scheduleDir, destinationName: name)
        }

        // 3. Not at either endpoint and no schedule match — ask
        return .ambiguous(originName: origin.name, destinationName: destination.name)
    }

    // MARK: - Schedule Rules

    /// Check if the current day-of-week and hour match the user's configured schedule.
    /// Internal so location-less callers (Siri intents) can resolve by schedule alone.
    static func scheduledDirection(
        commute: Commute,
        now: Date = Date()
    ) -> CommuteDirection? {
        let cal = Calendar.current
        let currentDay = cal.component(.weekday, from: now)  // Sun=1 .. Sat=7
        let currentHour = cal.component(.hour, from: now)

        // Check "go to destination" schedule
        if let daysStr = commute.scheduleToDestDays,
           let startHour = commute.scheduleToDestStartHour,
           let endHour = commute.scheduleToDestEndHour {
            let days = Set(daysStr.split(separator: ",").compactMap { Int($0) })
            if windowActive(day: currentDay, hour: currentHour, days: days, start: startHour, end: endHour) {
                return .originToDestination
            }
        }

        // Check "go to origin" schedule
        if let daysStr = commute.scheduleToOriginDays,
           let startHour = commute.scheduleToOriginStartHour,
           let endHour = commute.scheduleToOriginEndHour {
            let days = Set(daysStr.split(separator: ",").compactMap { Int($0) })
            if windowActive(day: currentDay, hour: currentHour, days: days, start: startHour, end: endHour) {
                return .destinationToOrigin
            }
        }

        return nil
    }

    /// Whether the schedule (its set of weekdays + [start, end) hour window) is
    /// active at `(day, hour)`. Mirrors `NoGoZone.TimeWindow.isActive` EXACTLY,
    /// including its midnight-wrap day attribution: for a wrapping window
    /// (start > end, e.g. 22→6) the evening portion (hour >= start) belongs to the
    /// scheduled day, but the morning portion (hour < end) belongs to the PREVIOUS
    /// weekday's window — so a Monday-only 22→6 schedule is active Tue 02:00, not
    /// Mon 02:00. `day` is `Calendar.weekday` (Sun=1 .. Sat=7); the end hour is
    /// exclusive. Previously this only checked `days.contains(today)` for both
    /// portions, diverging from the zone semantics it claims to share.
    static func windowActive(day: Int, hour: Int, days: Set<Int>, start: Int, end: Int) -> Bool {
        if start < end {
            // Same-day window: day must match and hour within [start, end).
            return days.contains(day) && hour >= start && hour < end
        } else if start > end {
            // Wrapping window: evening portion is the scheduled day; morning
            // portion belongs to the previous weekday.
            if hour >= start {
                return days.contains(day)
            }
            if hour < end {
                let prevDay = day == 1 ? 7 : day - 1
                return days.contains(prevDay)
            }
            return false
        } else {
            // start == end: zero-length window, never active.
            return false
        }
    }

    /// The direction of the next upcoming schedule window after `now`.
    /// Used when no schedule window is currently active and there's no
    /// location fix — "which way is this person going next?"
    static func nextScheduledDirection(
        commute: Commute,
        now: Date = Date()
    ) -> CommuteDirection? {
        let cal = Calendar.current

        let rules: [(days: String?, startHour: Int?, direction: CommuteDirection)] = [
            (commute.scheduleToDestDays, commute.scheduleToDestStartHour, .originToDestination),
            (commute.scheduleToOriginDays, commute.scheduleToOriginStartHour, .destinationToOrigin)
        ]

        var best: (start: Date, direction: CommuteDirection)?

        for rule in rules {
            guard let daysStr = rule.days, let startHour = rule.startHour else { continue }
            let days = Set(daysStr.split(separator: ",").compactMap { Int($0) })
            guard !days.isEmpty else { continue }

            // Find this rule's next window start within the coming week.
            for dayOffset in 0...7 {
                guard let day = cal.date(byAdding: .day, value: dayOffset, to: now),
                      days.contains(cal.component(.weekday, from: day)),
                      let start = cal.date(bySettingHour: startHour, minute: 0, second: 0, of: day),
                      start > now else { continue }
                if let current = best {
                    if start < current.start {
                        best = (start, rule.direction)
                    }
                } else {
                    best = (start, rule.direction)
                }
                break
            }
        }

        return best?.direction
    }
}
