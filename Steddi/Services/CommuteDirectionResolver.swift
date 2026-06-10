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
        trips: [CommuteTrip] = [],
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
            if days.contains(currentDay) && currentHour >= startHour && currentHour < endHour {
                return .originToDestination
            }
        }

        // Check "go to origin" schedule
        if let daysStr = commute.scheduleToOriginDays,
           let startHour = commute.scheduleToOriginStartHour,
           let endHour = commute.scheduleToOriginEndHour {
            let days = Set(daysStr.split(separator: ",").compactMap { Int($0) })
            if days.contains(currentDay) && currentHour >= startHour && currentHour < endHour {
                return .destinationToOrigin
            }
        }

        return nil
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

    // MARK: - Learned Patterns

    /// Check if we have enough trip history to predict the direction.
    /// Requires at least 5 trips on the same day-of-week within ±2 hours.
    private static func learnedDirection(
        commute: Commute,
        trips: [CommuteTrip],
        now: Date
    ) -> CommuteDirection? {
        let cal = Calendar.current
        let currentDay = cal.component(.weekday, from: now)
        let currentHour = cal.component(.hour, from: now)

        // Filter to trips for this commute, same day of week, within ±2 hours
        let relevant = trips.filter { trip in
            trip.commute?.id == commute.id &&
            trip.dayOfWeek == currentDay &&
            abs(trip.hourOfDay - currentHour) <= 2
        }

        guard relevant.count >= 5 else { return nil }

        // Majority vote
        let toDestCount = relevant.filter { $0.direction == .originToDestination }.count
        let toOriginCount = relevant.filter { $0.direction == .destinationToOrigin }.count

        // Need at least 70% agreement to be confident
        let total = Double(relevant.count)
        if Double(toDestCount) / total >= 0.7 { return .originToDestination }
        if Double(toOriginCount) / total >= 0.7 { return .destinationToOrigin }

        return nil
    }

    // MARK: - Smart Defaults

    /// Weekday heuristic: before noon → going to destination (work), after noon → going to origin (home).
    /// Weekends → nil (ambiguous).
    private static func smartDefault(now: Date) -> CommuteDirection? {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: now)
        let hour = cal.component(.hour, from: now)

        // Weekend (Sunday=1, Saturday=7)
        if weekday == 1 || weekday == 7 { return nil }

        // Weekday
        if hour >= 5 && hour < 12 {
            return .originToDestination  // morning → going to work
        } else if hour >= 12 && hour < 22 {
            return .destinationToOrigin  // afternoon/evening → going home
        }

        return nil // late night → ambiguous
    }
}
