import Testing
import Foundation
import CoreLocation
import SwiftData
@testable import Steddi

// MARK: - Helpers

/// Build an in-memory container with a weekday commute:
/// origin "Home" → destination "Work", to-work 6–10, to-home 15–19, Mon–Fri.
private func makeScheduledCommute() throws -> (ModelContainer, Commute) {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: ModelStoreLocator.schema, configurations: [config])
    let context = ModelContext(container)

    let home = PinnedLocation(name: "Home", latitude: 34.05, longitude: -118.25)
    let work = PinnedLocation(name: "Work", latitude: 34.10, longitude: -118.40)
    let commute = Commute(name: "Work Commute", origin: home, destination: work)
    commute.scheduleToDestDays = "2,3,4,5,6"
    commute.scheduleToDestStartHour = 6
    commute.scheduleToDestEndHour = 10
    commute.scheduleToOriginDays = "2,3,4,5,6"
    commute.scheduleToOriginStartHour = 15
    commute.scheduleToOriginEndHour = 19

    context.insert(commute)
    return (container, commute)
}

/// Build a date from components. June 8, 2026 is a Monday.
private func date(year: Int = 2026, month: Int = 6, day: Int, hour: Int) throws -> Date {
    let comps = DateComponents(year: year, month: month, day: day, hour: hour)
    return try #require(Calendar.current.date(from: comps))
}

// MARK: - Scheduled Direction Tests

@Suite("CommuteDirectionResolver.scheduledDirection")
struct ScheduledDirectionTests {

    @Test("Weekday morning inside the to-work window")
    func weekdayMorning() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let monday8am = try date(day: 8, hour: 8)
        #expect(CommuteDirectionResolver.scheduledDirection(commute: commute, now: monday8am) == .originToDestination)
    }

    @Test("Weekday afternoon inside the to-home window")
    func weekdayAfternoon() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let monday4pm = try date(day: 8, hour: 16)
        #expect(CommuteDirectionResolver.scheduledDirection(commute: commute, now: monday4pm) == .destinationToOrigin)
    }

    @Test("Weekday midday between windows returns nil")
    func weekdayMidday() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let mondayNoon = try date(day: 8, hour: 12)
        #expect(CommuteDirectionResolver.scheduledDirection(commute: commute, now: mondayNoon) == nil)
    }

    @Test("Weekend morning returns nil for weekday-only schedule")
    func weekendMorning() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let saturday8am = try date(day: 13, hour: 8)
        #expect(CommuteDirectionResolver.scheduledDirection(commute: commute, now: saturday8am) == nil)
    }

    @Test("Window end hour is exclusive")
    func endHourExclusive() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let monday10am = try date(day: 8, hour: 10)
        #expect(CommuteDirectionResolver.scheduledDirection(commute: commute, now: monday10am) == nil)
    }
}

// MARK: - Next Scheduled Direction Tests

@Suite("CommuteDirectionResolver.nextScheduledDirection")
struct NextScheduledDirectionTests {

    @Test("Weekday midday: next window is the afternoon drive home")
    func middayPicksAfternoon() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let mondayNoon = try date(day: 8, hour: 12)
        #expect(CommuteDirectionResolver.nextScheduledDirection(commute: commute, now: mondayNoon) == .destinationToOrigin)
    }

    @Test("Weekday evening after both windows: next is tomorrow's drive to work")
    func eveningPicksNextMorning() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let monday8pm = try date(day: 8, hour: 20)
        #expect(CommuteDirectionResolver.nextScheduledDirection(commute: commute, now: monday8pm) == .originToDestination)
    }

    @Test("Saturday: next window is Monday's drive to work")
    func weekendPicksMondayMorning() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let saturdayNoon = try date(day: 13, hour: 12)
        #expect(CommuteDirectionResolver.nextScheduledDirection(commute: commute, now: saturdayNoon) == .originToDestination)
    }

    @Test("No schedule configured returns nil")
    func noScheduleReturnsNil() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ModelStoreLocator.schema, configurations: [config])
        let context = ModelContext(container)
        let commute = Commute(name: "Unscheduled")
        context.insert(commute)

        #expect(CommuteDirectionResolver.nextScheduledDirection(commute: commute, now: Date()) == nil)
    }
}

// MARK: - Proximity Resolution Tests

@Suite("CommuteDirectionResolver.resolve")
struct ResolveProximityTests {

    @Test("At the origin resolves confidently toward the destination")
    func atOriginGoesToDestination() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let atHome = CLLocation(latitude: 34.05, longitude: -118.25)
        let mondayNoon = try date(day: 8, hour: 12)

        let result = CommuteDirectionResolver.resolve(commute: commute, currentLocation: atHome, now: mondayNoon)
        guard case .confident(let direction, let destinationName) = result else {
            Issue.record("Expected confident resolution, got \(result)")
            return
        }
        #expect(direction == .originToDestination)
        #expect(destinationName == "Work")
    }

    @Test("Away from both endpoints with no active window is ambiguous")
    func awayFromEndpointsAmbiguous() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let elsewhere = CLLocation(latitude: 33.90, longitude: -118.00)
        let mondayNoon = try date(day: 8, hour: 12)

        let result = CommuteDirectionResolver.resolve(commute: commute, currentLocation: elsewhere, now: mondayNoon)
        guard case .ambiguous(let originName, let destinationName) = result else {
            Issue.record("Expected ambiguous resolution, got \(result)")
            return
        }
        #expect(originName == "Home")
        #expect(destinationName == "Work")
    }
}

// MARK: - Midnight-Crossing Window Tests

@Suite("CommuteDirectionResolver.scheduledDirection midnight wrap")
struct MidnightWindowTests {

    /// Night-shift commute: drive to work 22:00→02:00, drive home 04:00→08:00,
    /// every day. Both to-dest windows wrap past midnight (start > end).
    private func makeNightShiftCommute() throws -> (ModelContainer, Commute) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ModelStoreLocator.schema, configurations: [config])
        let context = ModelContext(container)

        let home = PinnedLocation(name: "Home", latitude: 34.05, longitude: -118.25)
        let work = PinnedLocation(name: "Work", latitude: 34.10, longitude: -118.40)
        let commute = Commute(name: "Night Shift", origin: home, destination: work)
        commute.scheduleToDestDays = "1,2,3,4,5,6,7"
        commute.scheduleToDestStartHour = 22
        commute.scheduleToDestEndHour = 2
        commute.scheduleToOriginDays = "1,2,3,4,5,6,7"
        commute.scheduleToOriginStartHour = 4
        commute.scheduleToOriginEndHour = 8

        context.insert(commute)
        return (container, commute)
    }

    @Test("Late-evening hour inside the wrapping to-dest window matches")
    func lateEveningMatchesToDest() throws {
        let (container, commute) = try makeNightShiftCommute()
        _ = container
        let monday11pm = try date(day: 8, hour: 23)
        #expect(CommuteDirectionResolver.scheduledDirection(commute: commute, now: monday11pm) == .originToDestination)
    }

    @Test("After-midnight hour still inside the wrapping to-dest window matches")
    func afterMidnightMatchesToDest() throws {
        let (container, commute) = try makeNightShiftCommute()
        _ = container
        let tuesday1am = try date(day: 9, hour: 1)
        #expect(CommuteDirectionResolver.scheduledDirection(commute: commute, now: tuesday1am) == .originToDestination)
    }

    @Test("End hour of a wrapping window is exclusive")
    func wrappingEndHourExclusive() throws {
        let (container, commute) = try makeNightShiftCommute()
        _ = container
        let tuesday2am = try date(day: 9, hour: 2)
        // 02:00 is the exclusive end of the to-dest window and below the 04:00
        // start of the to-origin window — neither matches.
        #expect(CommuteDirectionResolver.scheduledDirection(commute: commute, now: tuesday2am) == nil)
    }

    @Test("Hour inside the non-wrapping to-origin window matches")
    func morningMatchesToOrigin() throws {
        let (container, commute) = try makeNightShiftCommute()
        _ = container
        let tuesday6am = try date(day: 9, hour: 6)
        #expect(CommuteDirectionResolver.scheduledDirection(commute: commute, now: tuesday6am) == .destinationToOrigin)
    }
}

// MARK: - Midnight-Wrap Day Attribution (mirrors NoGoZone.TimeWindow.isActive)

/// A wrapping window's post-midnight portion belongs to the PREVIOUS weekday, so
/// a sparse-day schedule (not all 7 days) must attribute it exactly the way
/// `NoGoZone.TimeWindow.isActive` does. These cases distinguish the correct
/// previous-day attribution from the old "today only" semantics, which the
/// all-days fixtures above cannot detect.
@Suite("CommuteDirectionResolver midnight-wrap day attribution")
struct MidnightWrapDayAttributionTests {

    /// Monday-ONLY night shift: drive to work 22:00→06:00. The morning portion
    /// (00:00–06:00) belongs to Monday's window and so falls on TUESDAY morning.
    private func makeMondayOnlyNightShift() throws -> (ModelContainer, Commute) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ModelStoreLocator.schema, configurations: [config])
        let context = ModelContext(container)

        let home = PinnedLocation(name: "Home", latitude: 34.05, longitude: -118.25)
        let work = PinnedLocation(name: "Work", latitude: 34.10, longitude: -118.40)
        let commute = Commute(name: "Monday Night Shift", origin: home, destination: work)
        commute.scheduleToDestDays = "2"   // Monday only (Sun=1 .. Sat=7)
        commute.scheduleToDestStartHour = 22
        commute.scheduleToDestEndHour = 6
        context.insert(commute)
        return (container, commute)
    }

    @Test("Tuesday 02:00 IS active — the morning portion belongs to Monday's window")
    func tuesdayMorningBelongsToMonday() throws {
        let (container, commute) = try makeMondayOnlyNightShift()
        _ = container
        let tuesday2am = try date(day: 9, hour: 2)   // June 9 2026 is Tuesday
        #expect(CommuteDirectionResolver.scheduledDirection(commute: commute, now: tuesday2am) == .originToDestination)
    }

    @Test("Monday 02:00 is NOT active — that morning belongs to Sunday's window")
    func mondayMorningBelongsToSunday() throws {
        let (container, commute) = try makeMondayOnlyNightShift()
        _ = container
        let monday2am = try date(day: 8, hour: 2)   // June 8 2026 is Monday
        #expect(CommuteDirectionResolver.scheduledDirection(commute: commute, now: monday2am) == nil)
    }

    @Test("Monday 23:00 IS active — the evening portion belongs to the scheduled day")
    func mondayEveningActive() throws {
        let (container, commute) = try makeMondayOnlyNightShift()
        _ = container
        let monday11pm = try date(day: 8, hour: 23)
        #expect(CommuteDirectionResolver.scheduledDirection(commute: commute, now: monday11pm) == .originToDestination)
    }

    @Test("Tuesday 23:00 is NOT active — Tuesday evening is not scheduled")
    func tuesdayEveningInactive() throws {
        let (container, commute) = try makeMondayOnlyNightShift()
        _ = container
        let tuesday11pm = try date(day: 9, hour: 23)
        #expect(CommuteDirectionResolver.scheduledDirection(commute: commute, now: tuesday11pm) == nil)
    }

    /// `windowActive` must agree with `NoGoZone.TimeWindow.isActive` for every
    /// (day, hour) over a full week, across same-day, wrapping, and zero-length
    /// windows on a sparse day set — the two implementations the resolver claims
    /// to share must be identical.
    @Test("windowActive matches TimeWindow.isActive for all weekday/hour combinations")
    func parityWithTimeWindowIsActive() throws {
        let cal = Calendar.current
        let windows: [(start: Int, end: Int)] = [
            (6, 10),    // same-day
            (22, 6),    // wrapping
            (0, 0),     // zero-length (never active)
            (23, 1),    // narrow wrap
            (0, 23),    // nearly full day
        ]
        let daySets: [Set<Int>] = [[2], [1, 3], [6, 7], [1, 2, 3, 4, 5, 6, 7]]

        for win in windows {
            for days in daySets {
                let window = TimeWindow(daysOfWeek: days, startHour: win.start, endHour: win.end)
                // June 7 2026 is a Sunday → 7 consecutive days cover all weekdays.
                for dayOffset in 0..<7 {
                    for hour in 0..<24 {
                        let when = try #require(cal.date(from: DateComponents(
                            year: 2026, month: 6, day: 7 + dayOffset, hour: hour
                        )))
                        let weekday = cal.component(.weekday, from: when)
                        let expected = window.isActive(now: when, calendar: cal)
                        let actual = CommuteDirectionResolver.windowActive(
                            day: weekday, hour: hour, days: days, start: win.start, end: win.end
                        )
                        #expect(actual == expected, "mismatch win=\(win) days=\(days) day=\(weekday) hour=\(hour)")
                    }
                }
            }
        }
    }
}
