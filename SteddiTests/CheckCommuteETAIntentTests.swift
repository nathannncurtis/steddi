import Testing
import Foundation
import CoreLocation
import SwiftData
@testable import Steddi

/// Tests for `CheckCommuteETAIntent`'s `Sendable` snapshot + value-only direction
/// resolution. Snapshots are built synchronously on the `ModelContext`'s executor
/// (no `@Model` access after the intent's `await`s); these tests exercise that
/// seam directly so the post-`await` selection logic is verified without a live
/// Siri/location stack.
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

    // Preferred routes per direction with distinct typical durations.
    let toWork = Route(rank: 0, encodedPolyline: "", typicalDurationSeconds: 1200, direction: .originToDestination)  // 20 min
    let toHome = Route(rank: 0, encodedPolyline: "", typicalDurationSeconds: 1800, direction: .destinationToOrigin)  // 30 min
    commute.routes = [toWork, toHome]

    context.insert(commute)
    return (container, commute)
}

private func date(year: Int = 2026, month: Int = 6, day: Int, hour: Int) throws -> Date {
    let comps = DateComponents(year: year, month: month, day: day, hour: hour)
    return try #require(Calendar.current.date(from: comps))
}

@Suite("CommuteETASnapshot")
struct CommuteETASnapshotTests {

    @Test("Captures both endpoints, names, and per-direction typical durations")
    func capturesEndpointsAndDurations() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let snapshot = try #require(CommuteETASnapshot(commute: commute))

        #expect(snapshot.originName == "Home")
        #expect(snapshot.destinationName == "Work")
        #expect(snapshot.originCoordinate.latitude == 34.05)
        #expect(snapshot.destinationCoordinate.latitude == 34.10)
        #expect(snapshot.toDestinationTypicalSeconds == 1200)
        #expect(snapshot.toOriginTypicalSeconds == 1800)
    }

    @Test("Returns nil when the commute has no endpoints")
    func nilWithoutEndpoints() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ModelStoreLocator.schema, configurations: [config])
        let context = ModelContext(container)
        let commute = Commute(name: "Incomplete")
        context.insert(commute)
        _ = container

        #expect(CommuteETASnapshot(commute: commute) == nil)
    }

    @Test("Endpoints for to-destination use the destination + its typical duration")
    func endpointsToDestination() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let snapshot = try #require(CommuteETASnapshot(commute: commute))
        let ep = snapshot.endpoints(for: .originToDestination)

        #expect(ep.destinationName == "Work")
        #expect(ep.startCoordinate.latitude == 34.05)
        #expect(ep.destinationCoordinate.latitude == 34.10)
        #expect(ep.typicalDurationSeconds == 1200)
    }

    @Test("Endpoints for to-origin flip start/destination and use the to-home duration")
    func endpointsToOrigin() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let snapshot = try #require(CommuteETASnapshot(commute: commute))
        let ep = snapshot.endpoints(for: .destinationToOrigin)

        #expect(ep.destinationName == "Home")
        #expect(ep.startCoordinate.latitude == 34.10)
        #expect(ep.destinationCoordinate.latitude == 34.05)
        #expect(ep.typicalDurationSeconds == 1800)
    }
}

@Suite("CheckCommuteETAIntent.resolveDirection")
struct ETAResolveDirectionTests {

    @Test("Location at origin resolves to-destination regardless of schedule")
    func proximityAtOrigin() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let snapshot = try #require(CommuteETASnapshot(commute: commute))
        let atHome = CLLocation(latitude: 34.05, longitude: -118.25)
        // Noon: no active window, so only proximity drives this.
        let mondayNoon = try date(day: 8, hour: 12)

        let direction = CheckCommuteETAIntent.resolveDirection(
            snapshot: snapshot, currentLocation: atHome, now: mondayNoon
        )
        #expect(direction == .originToDestination)
    }

    @Test("No location, active morning window resolves to-destination")
    func scheduleMorning() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let snapshot = try #require(CommuteETASnapshot(commute: commute))
        let monday8am = try date(day: 8, hour: 8)

        let direction = CheckCommuteETAIntent.resolveDirection(
            snapshot: snapshot, currentLocation: nil, now: monday8am
        )
        #expect(direction == .originToDestination)
    }

    @Test("No location, active afternoon window resolves to-origin")
    func scheduleAfternoon() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let snapshot = try #require(CommuteETASnapshot(commute: commute))
        let monday4pm = try date(day: 8, hour: 16)

        let direction = CheckCommuteETAIntent.resolveDirection(
            snapshot: snapshot, currentLocation: nil, now: monday4pm
        )
        #expect(direction == .destinationToOrigin)
    }

    @Test("No location, midday between windows falls back to next window (afternoon)")
    func middayNextWindow() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let snapshot = try #require(CommuteETASnapshot(commute: commute))
        let mondayNoon = try date(day: 8, hour: 12)

        let direction = CheckCommuteETAIntent.resolveDirection(
            snapshot: snapshot, currentLocation: nil, now: mondayNoon
        )
        #expect(direction == .destinationToOrigin)
    }

    @Test("Location away from endpoints with no active window uses the schedule")
    func awayFromEndpointsUsesSchedule() throws {
        let (container, commute) = try makeScheduledCommute()
        _ = container
        let snapshot = try #require(CommuteETASnapshot(commute: commute))
        let elsewhere = CLLocation(latitude: 33.90, longitude: -118.00)
        let monday8am = try date(day: 8, hour: 8)

        let direction = CheckCommuteETAIntent.resolveDirection(
            snapshot: snapshot, currentLocation: elsewhere, now: monday8am
        )
        #expect(direction == .originToDestination)
    }
}

// MARK: - Overnight / midnight-wrapping schedule windows

/// The intent's snapshot used to keep its OWN window-test (`hourInWindow`) that
/// gated BOTH portions of a wrapping window on `days.contains(today)`, diverging
/// from the canonical `CommuteDirectionResolver.windowActive` (which attributes
/// the post-midnight morning portion to the PREVIOUS weekday). That mis-resolved
/// the direction for any commute with an overnight window. These exercise a
/// night-shift commute whose to-destination window wraps past midnight.
@Suite("CheckCommuteETAIntent overnight schedule windows")
struct ETAOvernightWindowTests {

    /// Monday-only night-shift outbound: 22:00 → 06:00 to-destination. A Tuesday
    /// daytime to-origin window (09:00–17:00) exists so a wrong post-midnight
    /// resolution would be observable (it would fall through to the Tuesday
    /// to-origin window and speak the wrong direction).
    private func makeNightShiftCommute() throws -> (ModelContainer, Commute) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ModelStoreLocator.schema, configurations: [config])
        let context = ModelContext(container)

        let home = PinnedLocation(name: "Home", latitude: 34.05, longitude: -118.25)
        let work = PinnedLocation(name: "Work", latitude: 34.10, longitude: -118.40)
        let commute = Commute(name: "Night Shift", origin: home, destination: work)
        // To-destination wraps midnight: Monday (weekday 2) 22:00 → 06:00.
        commute.scheduleToDestDays = "2"
        commute.scheduleToDestStartHour = 22
        commute.scheduleToDestEndHour = 6
        // Tuesday (weekday 3) daytime return: 09:00 → 17:00.
        commute.scheduleToOriginDays = "3"
        commute.scheduleToOriginStartHour = 9
        commute.scheduleToOriginEndHour = 17

        let toWork = Route(rank: 0, encodedPolyline: "", typicalDurationSeconds: 1200, direction: .originToDestination)
        let toHome = Route(rank: 0, encodedPolyline: "", typicalDurationSeconds: 1800, direction: .destinationToOrigin)
        commute.routes = [toWork, toHome]
        context.insert(commute)
        return (container, commute)
    }

    @Test("Before midnight inside the wrapping window resolves to-destination")
    func beforeMidnightInWindow() throws {
        let (container, commute) = try makeNightShiftCommute()
        _ = container
        let snapshot = try #require(CommuteETASnapshot(commute: commute))
        // Monday (June 8) 23:00 — evening portion, day matches Monday.
        let mondayNight = try date(day: 8, hour: 23)

        let direction = CheckCommuteETAIntent.resolveDirection(
            snapshot: snapshot, currentLocation: nil, now: mondayNight
        )
        #expect(direction == .originToDestination)
    }

    @Test("After midnight inside the wrapping window still resolves to-destination (prev-day attribution)")
    func afterMidnightInWindow() throws {
        let (container, commute) = try makeNightShiftCommute()
        _ = container
        let snapshot = try #require(CommuteETASnapshot(commute: commute))
        // Tuesday (June 9) 02:00 — morning portion of Monday's 22→6 window.
        // The buggy copy checked days.contains(Tuesday)=false and fell through to
        // the Tuesday to-origin window, speaking the WRONG direction.
        let tuesdayEarly = try date(day: 9, hour: 2)

        let direction = CheckCommuteETAIntent.resolveDirection(
            snapshot: snapshot, currentLocation: nil, now: tuesdayEarly
        )
        #expect(direction == .originToDestination)
    }

    @Test("Outside the wrapping window falls through to the next scheduled direction")
    func outsideWindow() throws {
        let (container, commute) = try makeNightShiftCommute()
        _ = container
        let snapshot = try #require(CommuteETASnapshot(commute: commute))
        // Tuesday (June 9) 07:00 — past the 06:00 end, before the 09:00 to-origin
        // window. No active window, so the next scheduled (Tuesday to-origin) wins.
        let tuesdayMorning = try date(day: 9, hour: 7)

        let direction = CheckCommuteETAIntent.resolveDirection(
            snapshot: snapshot, currentLocation: nil, now: tuesdayMorning
        )
        #expect(direction == .destinationToOrigin)
    }

    @Test("Wrapping window is NOT active the night before its scheduled day")
    func notActiveWrongNight() throws {
        let (container, commute) = try makeNightShiftCommute()
        _ = container
        let snapshot = try #require(CommuteETASnapshot(commute: commute))
        // Monday (June 8) 02:00 — morning portion belongs to SUNDAY, not Monday,
        // so the Monday-only window must NOT be active here.
        let mondayEarly = try date(day: 8, hour: 2)

        let scheduled = snapshot.schedule.scheduledDirection(now: mondayEarly)
        #expect(scheduled == nil, "Monday-only 22→6 must not be active Monday 02:00")
    }
}
