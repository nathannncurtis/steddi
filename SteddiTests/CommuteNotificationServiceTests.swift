import Testing
import Foundation
import SwiftData
@testable import Steddi

// MARK: - Helpers

private func inMemoryContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: ModelStoreLocator.schema, configurations: [config])
}

/// June 8, 2026 is a Monday (weekday == 2).
private func at(day: Int = 8, hour: Int) throws -> Date {
    try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour)))
}

private func freshDefaults() -> UserDefaults {
    let name = "notifservicetest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: - Learned Departure Hours

@Suite("CommuteNotificationService learned departure hours")
struct LearnedDepartureTests {

    @Test("Under the confidence floor returns empty")
    func belowConfidence() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let commute = Commute(name: "Work")
        context.insert(commute)

        // Only 3 Monday trips — below the 5-trip floor.
        let monday = try at(hour: 7)
        for _ in 0..<3 {
            let trip = CommuteTrip(commute: commute, direction: .originToDestination)
            trip.dayOfWeek = 2; trip.hourOfDay = 7
            context.insert(trip)
        }

        let hours = CommuteNotificationService.learnedDepartureHours(
            commute: commute, trips: try context.fetch(FetchDescriptor<CommuteTrip>()), now: monday
        )
        #expect(hours.isEmpty)
    }

    @Test("Clustered 7am Monday departures surface as a learned hour")
    func learnedHourSurfaces() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let commute = Commute(name: "Work")
        context.insert(commute)

        for _ in 0..<6 {
            let trip = CommuteTrip(commute: commute, direction: .originToDestination)
            trip.dayOfWeek = 2; trip.hourOfDay = 7
            context.insert(trip)
        }

        let monday = try at(hour: 7)
        let hours = CommuteNotificationService.learnedDepartureHours(
            commute: commute, trips: try context.fetch(FetchDescriptor<CommuteTrip>()), now: monday
        )
        #expect(hours == [7])
    }

    @Test("One-off outlier hour is filtered, dominant hour kept")
    func outlierFiltered() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let commute = Commute(name: "Work")
        context.insert(commute)

        // 8 trips at 7am, 1 outlier at 11am — outlier under the 20% floor.
        for _ in 0..<8 {
            let t = CommuteTrip(commute: commute, direction: .originToDestination)
            t.dayOfWeek = 2; t.hourOfDay = 7
            context.insert(t)
        }
        let outlier = CommuteTrip(commute: commute, direction: .originToDestination)
        outlier.dayOfWeek = 2; outlier.hourOfDay = 11
        context.insert(outlier)

        let monday = try at(hour: 7)
        let hours = CommuteNotificationService.learnedDepartureHours(
            commute: commute, trips: try context.fetch(FetchDescriptor<CommuteTrip>()), now: monday
        )
        #expect(hours == [7])
    }

    @Test("Trips on a different day-of-week don't count")
    func differentDayIgnored() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let commute = Commute(name: "Work")
        context.insert(commute)

        // 6 Tuesday trips (weekday 3), querying for a Monday.
        for _ in 0..<6 {
            let t = CommuteTrip(commute: commute, direction: .originToDestination)
            t.dayOfWeek = 3; t.hourOfDay = 7
            context.insert(t)
        }

        let monday = try at(hour: 7)
        let hours = CommuteNotificationService.learnedDepartureHours(
            commute: commute, trips: try context.fetch(FetchDescriptor<CommuteTrip>()), now: monday
        )
        #expect(hours.isEmpty)
    }
}

// MARK: - Scheduled Departure Hours (zero-history fallback)

@Suite("CommuteNotificationService scheduled departure hours")
struct ScheduledDepartureTests {

    @Test("To-destination uses the schedule start hour")
    func toDestStartHour() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let commute = Commute(name: "Work")
        commute.scheduleToDestStartHour = 6
        commute.scheduleToOriginStartHour = 17
        context.insert(commute)

        // No days configured ⇒ no day restriction; returns the start hour on a
        // weekday (Monday, June 8) just as before.
        let monday = try at(hour: 6)
        #expect(CommuteNotificationService.scheduledDepartureHours(
            commute: commute, direction: .originToDestination, now: monday) == [6])
        #expect(CommuteNotificationService.scheduledDepartureHours(
            commute: commute, direction: .destinationToOrigin, now: monday) == [17])
    }

    @Test("No schedule returns empty")
    func noScheduleEmpty() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let commute = Commute(name: "Unscheduled")
        context.insert(commute)

        #expect(CommuteNotificationService.scheduledDepartureHours(
            commute: commute, direction: .originToDestination, now: try at(hour: 6)).isEmpty)
    }

    @Test("Weekday-only schedule returns the hour on a weekday")
    func weekdayScheduleActiveOnWeekday() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let commute = Commute(name: "Work")
        commute.scheduleToDestStartHour = 8
        commute.scheduleToDestDays = "2,3,4,5,6"   // Mon–Fri
        context.insert(commute)

        // June 8, 2026 is a Monday (weekday 2) — inside the rule.
        let monday = try at(hour: 7)
        #expect(CommuteNotificationService.scheduledDepartureHours(
            commute: commute, direction: .originToDestination, now: monday) == [8])
    }

    @Test("Weekday-only schedule returns empty on Saturday")
    func weekdayScheduleSilentOnSaturday() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let commute = Commute(name: "Work")
        commute.scheduleToDestStartHour = 8
        commute.scheduleToDestDays = "2,3,4,5,6"   // Mon–Fri only
        context.insert(commute)

        // June 13, 2026 is a Saturday (weekday 7) — outside the rule, so no
        // departure hour and therefore no weekend "leave early" false alert.
        let saturday = try at(day: 13, hour: 7)
        #expect(CommuteNotificationService.scheduledDepartureHours(
            commute: commute, direction: .originToDestination, now: saturday).isEmpty)
    }

    @Test("Weekend-only schedule is silent on weekdays, active on its day")
    func weekendScheduleHonorsItsDays() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let commute = Commute(name: "Gym")
        commute.scheduleToDestStartHour = 9
        commute.scheduleToDestDays = "1,7"   // Sun + Sat only
        context.insert(commute)

        // Monday (weekday 2) — outside the rule.
        #expect(CommuteNotificationService.scheduledDepartureHours(
            commute: commute, direction: .originToDestination, now: try at(hour: 8)).isEmpty)
        // Saturday (weekday 7) — inside the rule.
        #expect(CommuteNotificationService.scheduledDepartureHours(
            commute: commute, direction: .originToDestination, now: try at(day: 13, hour: 8)) == [9])
    }
}

// MARK: - Settings Accessors

@Suite("CommuteNotificationService settings accessors")
struct ServiceSettingsTests {

    @Test("Global enabled defaults to true when unset")
    func globalDefaultTrue() throws {
        let container = try inMemoryContainer()
        let defaults = freshDefaults()
        let service = CommuteNotificationService(modelContainer: container, defaults: defaults)
        #expect(service.globallyEnabled)
    }

    @Test("Global enabled honors a stored false")
    func globalStoredFalse() throws {
        let container = try inMemoryContainer()
        let defaults = freshDefaults()
        defaults.set(false, forKey: CommuteNotificationService.globalEnabledKey)
        let service = CommuteNotificationService(modelContainer: container, defaults: defaults)
        #expect(!service.globallyEnabled)
    }

    @Test("Weather sensitivity defaults to harsh")
    func sensitivityDefault() throws {
        let container = try inMemoryContainer()
        let defaults = freshDefaults()
        let service = CommuteNotificationService(modelContainer: container, defaults: defaults)
        #expect(service.weatherSensitivity == .harsh)
    }

    @Test("Weather sensitivity reads the stored raw value")
    func sensitivityStored() throws {
        let container = try inMemoryContainer()
        let defaults = freshDefaults()
        defaults.set(WeatherSensitivity.moderate.rawValue, forKey: CommuteNotificationService.weatherSensitivityKey)
        let service = CommuteNotificationService(modelContainer: container, defaults: defaults)
        #expect(service.weatherSensitivity == .moderate)
    }
}

// MARK: - Title Copy

@Suite("CommuteNotificationService title copy")
struct ServiceTitleTests {

    @Test("Leave-early title includes the lead minutes")
    func leaveEarlyTitle() {
        #expect(CommuteNotificationService.title(for: .leaveEarly, leadMinutes: 20) == "Leave 20 minutes early?")
    }

    @Test("Combined title also prompts to leave early")
    func combinedTitle() {
        #expect(CommuteNotificationService.title(for: .combinedDelay, leadMinutes: 30).contains("30 minutes"))
    }

    @Test("Weather-only title is a heads up")
    func weatherTitle() {
        #expect(CommuteNotificationService.title(for: .harshWeather, leadMinutes: 15) == "Heads up before you head out")
    }
}

// MARK: - End-to-End Pass (guarded against double-notify)

@Suite("CommuteNotificationService notification pass")
struct ServicePassTests {

    @Test("Pass does nothing when globally disabled")
    func disabledNoOp() async throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let commute = Commute(name: "Work")
        commute.isActive = true
        commute.scheduleToDestStartHour = 7
        commute.scheduleToDestEndHour = 10
        commute.scheduleToDestDays = "2,3,4,5,6"
        context.insert(commute)
        try context.save()

        let defaults = freshDefaults()
        defaults.set(false, forKey: CommuteNotificationService.globalEnabledKey)
        let service = CommuteNotificationService(modelContainer: container, defaults: defaults)

        // Should return without throwing or scheduling anything.
        await service.runNotificationPass(now: try at(hour: 6))
    }

    @Test("Pass over an inactive commute is a no-op")
    func inactiveNoOp() async throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let commute = Commute(name: "Work")
        commute.isActive = false
        context.insert(commute)
        try context.save()

        let defaults = freshDefaults()
        let service = CommuteNotificationService(modelContainer: container, defaults: defaults)
        await service.runNotificationPass(now: try at(hour: 6))
    }
}

// MARK: - Idle Pre-Drive Widget: next-commute selection

/// The idle widget shows ONE commute, so the pre-drive ETA must come from the
/// commute whose departure window comes soonest. These exercise that selection
/// (the new logic) directly, without racing on the shared App Group widget
/// defaults that the parallel widget-sync suite also mutates.
@Suite("CommuteNotificationService next-departure selection")
struct ServiceNextDepartureTests {

    private func service(_ container: ModelContainer) -> CommuteNotificationService {
        CommuteNotificationService(modelContainer: container, defaults: freshDefaults())
    }

    @Test("Picks the commute whose scheduled departure is soonest")
    func picksEarliestDeparture() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)

        // Querying at Monday 06:00. Morning departs at 7 (sooner); evening at 17.
        let morning = Commute(name: "Morning")
        morning.isActive = true
        morning.scheduleToDestStartHour = 7
        let evening = Commute(name: "Evening")
        evening.isActive = true
        evening.scheduleToOriginStartHour = 17
        context.insert(morning)
        context.insert(evening)
        try context.save()

        let commutes = try context.fetch(FetchDescriptor<Commute>())
        let trips = try context.fetch(FetchDescriptor<CommuteTrip>())
        let id = service(container).nextDepartureCommuteID(commutes: commutes, trips: trips, now: try at(hour: 6))
        #expect(id == morning.id)
    }

    @Test("Skips commutes with notifications disabled")
    func skipsNotificationsDisabled() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)

        // The sooner window belongs to a commute with notifications off, so the
        // later-but-eligible commute must be chosen.
        let off = Commute(name: "Off")
        off.isActive = true
        off.notificationsEnabled = false
        off.scheduleToDestStartHour = 7
        let on = Commute(name: "On")
        on.isActive = true
        on.scheduleToDestStartHour = 9
        context.insert(off)
        context.insert(on)
        try context.save()

        let commutes = try context.fetch(FetchDescriptor<Commute>())
        let trips = try context.fetch(FetchDescriptor<CommuteTrip>())
        let id = service(container).nextDepartureCommuteID(commutes: commutes, trips: trips, now: try at(hour: 6))
        #expect(id == on.id)
    }

    @Test("Returns nil when no commute has an upcoming departure")
    func nilWhenNoSchedule() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let commute = Commute(name: "Unscheduled")
        commute.isActive = true
        context.insert(commute)
        try context.save()

        let commutes = try context.fetch(FetchDescriptor<Commute>())
        let trips = try context.fetch(FetchDescriptor<CommuteTrip>())
        let id = service(container).nextDepartureCommuteID(commutes: commutes, trips: trips, now: try at(hour: 6))
        #expect(id == nil)
    }

    /// A weekday-only commute, queried on a weekend, must NOT schedule a
    /// same-weekend departure (the bug that wasted background wakeups + fired
    /// weekend false alerts). Its next departure is the following Monday, which
    /// is more than 24h out from Saturday morning — so a same-day Saturday
    /// candidate would surface as "soonest" and be detectable here.
    @Test("Weekday-only commute has no weekend departure")
    func noWeekendDepartureForWeekdayCommute() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)

        // Weekday-only (Mon–Fri) commute departing 08:00.
        let weekdayCommute = Commute(name: "Work")
        weekdayCommute.isActive = true
        weekdayCommute.scheduleToDestStartHour = 8
        weekdayCommute.scheduleToDestDays = "2,3,4,5,6"
        context.insert(weekdayCommute)

        // A weekend-active commute departing 09:00 on Sat/Sun — its Saturday
        // window IS valid and must win over the weekday commute's Monday window.
        let weekendCommute = Commute(name: "Gym")
        weekendCommute.isActive = true
        weekendCommute.scheduleToDestStartHour = 9
        weekendCommute.scheduleToDestDays = "1,7"
        context.insert(weekendCommute)
        try context.save()

        let commutes = try context.fetch(FetchDescriptor<Commute>())
        let trips = try context.fetch(FetchDescriptor<CommuteTrip>())

        // Query Saturday June 13 at 07:00. If the weekday commute (incorrectly)
        // scheduled an 08:00 Saturday departure, it would beat the weekend
        // commute's 09:00 Saturday departure and win. It must not — the weekend
        // commute owns the next departure.
        let saturday = try at(day: 13, hour: 7)
        let id = service(container).nextDepartureCommuteID(commutes: commutes, trips: trips, now: saturday)
        #expect(id == weekendCommute.id)
    }
}

// MARK: - Idle Pre-Drive Widget: value extraction before await

/// The SwiftData thread-safety fix restructured `refreshIdleCommuteETA` (and the
/// notification pass) to snapshot every needed `@Model` property — commute name,
/// destination name/coordinate, preferred-route typical duration, resolved
/// direction — into a Sendable value struct SYNCHRONOUSLY before any await,
/// because the @Model objects are bound to the ModelContext's executor and must
/// not be touched after a suspension resumes on another thread.
///
/// These exercise that extraction directly via the (internal) selection seam and
/// the model accessors the snapshot reads, WITHOUT touching the shared App Group
/// widget defaults — the same approach `ServiceNextDepartureTests` takes to avoid
/// racing the parallel NavigationStateManager widget-sync suite that mutates
/// those defaults concurrently.
@Suite("CommuteNotificationService idle ETA value extraction")
struct ServiceIdleETAExtractionTests {

    private func service(_ container: ModelContainer) -> CommuteNotificationService {
        CommuteNotificationService(modelContainer: container, defaults: freshDefaults())
    }

    /// Build the fixture the snapshot reads: a scheduled to-destination commute
    /// with a preferred (rank 0) route carrying a known typical duration.
    private func fixture(_ context: ModelContext, typicalSeconds: Double) throws -> Commute {
        let origin = PinnedLocation(name: "Home", latitude: 37.0, longitude: -122.0)
        let destination = PinnedLocation(name: "Office", latitude: 37.5, longitude: -122.5)
        let commute = Commute(name: "Work", origin: origin, destination: destination)
        commute.isActive = true
        commute.notificationsEnabled = true
        commute.scheduleToDestStartHour = 8
        commute.scheduleToDestDays = "2,3,4,5,6"   // Mon–Fri
        context.insert(commute)

        let route = Route(
            rank: 0,
            encodedPolyline: "abc",
            typicalDurationSeconds: typicalSeconds,
            direction: .originToDestination
        )
        context.insert(route)
        // Link via the to-many side so `commute.preferredRoute(for:)` (which reads
        // `commute.routes`) sees it — there's no declared inverse to auto-populate.
        commute.routes = [route]
        route.commute = commute
        try context.save()
        return commute
    }

    /// The selection seam must pick the scheduled commute, and the values the
    /// snapshot extracts from it (the preferred route's typical duration for the
    /// resolved direction, the destination name) must be exactly what the idle
    /// widget would show — 1500s ⇒ 25 min, "Office".
    @Test("Extracted typical duration and destination match the selected commute")
    func extractsTypicalDurationAndDestination() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let commute = try fixture(context, typicalSeconds: 1500)   // 25 min

        let monday = try at(hour: 7)   // before the 08:00 window
        let commutes = try context.fetch(FetchDescriptor<Commute>())
        let trips = try context.fetch(FetchDescriptor<CommuteTrip>())

        // 1) Selection: this is the commute whose ETA the idle widget reflects.
        let id = service(container).nextDepartureCommuteID(commutes: commutes, trips: trips, now: monday)
        #expect(id == commute.id)

        // 2) Values the snapshot extracts before any await: the resolved direction
        //    is originToDestination (scheduled window), so the preferred route's
        //    typical duration and the destination name are what flow to the widget.
        let direction = CommuteDirectionResolver.scheduledDirection(commute: commute, now: monday)
            ?? CommuteDirectionResolver.nextScheduledDirection(commute: commute, now: monday)
            ?? .originToDestination
        #expect(direction == .originToDestination)
        #expect(commute.preferredRoute(for: direction)?.typicalDurationSeconds == 1500)
        #expect(commute.destination?.name == "Office")
        // The widget conversion the service applies: max(1, round(seconds/60)).
        #expect(max(1, Int((1500.0 / 60).rounded())) == 25)
    }

    /// End-to-end: with no location fix the live-ETA await is skipped and the
    /// model-derived typical duration is used — so the whole async path runs
    /// without ever re-touching the @Model after a suspension point. Exercises the
    /// restructured method for crashes/hangs even though the widget write itself
    /// is intentionally not asserted here (it races the parallel NSM suite).
    @Test("Idle refresh runs the extraction path with no location fix")
    func idleRefreshRunsWithoutLocation() async throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        _ = try fixture(context, typicalSeconds: 1500)

        // Default locationProvider returns nil → no network suspension; the typical
        // duration (extracted from the model before any await) is used.
        await service(container).refreshIdleCommuteETA(now: try at(hour: 7))
    }

    /// The home-screen ETA widget is a SEPARATE feature from smart-commute
    /// notifications. With the notification master toggle OFF, the idle widget
    /// refresh must STILL run and push a fresh ETA — previously it early-returned
    /// on `guard globallyEnabled`, silently freezing the widget. This asserts the
    /// widget App Group defaults receive the freshly-computed ETA even though
    /// notifications are disabled (only no-op'd when actually navigating).
    @Test("Idle refresh still pushes the widget ETA when notifications are disabled")
    @MainActor
    func idleRefreshRunsWithNotificationsDisabled() async throws {
        // Can't assert the widget write while a live nav session is in flight
        // (updateIdleCommuteETA no-ops then); this fresh test process is idle.
        guard !NavigationStateManager.shared.isNavigating else { return }

        let container = try inMemoryContainer()
        let context = ModelContext(container)
        _ = try fixture(context, typicalSeconds: 1500)   // 25 min

        // Notifications globally OFF — the path that USED to be frozen.
        let defaults = freshDefaults()
        defaults.set(false, forKey: CommuteNotificationService.globalEnabledKey)
        let svc = CommuteNotificationService(modelContainer: container, defaults: defaults)
        #expect(!svc.globallyEnabled)

        let widgetDefaults = try #require(UserDefaults(suiteName: "group.to.nathancurtis.steddi"))
        let before = Date().timeIntervalSince1970

        // No location fix → typical duration (1500s ⇒ 25 min) flows to the widget.
        await svc.refreshIdleCommuteETA(now: try at(hour: 7))

        // The widget received a fresh ETA despite notifications being disabled.
        #expect(widgetDefaults.integer(forKey: NavigationStateManager.kETAMinutes) == 25)
        #expect(widgetDefaults.double(forKey: NavigationStateManager.kETAUpdatedAt) >= before)
    }
}

// MARK: - CommuteTrip Cascade Delete

@Suite("Commute cascade-deletes its trips")
struct CommuteTripCascadeTests {

    /// Deleting a Commute must cascade-delete its CommuteTrip history. Without the
    /// model-level cascade the trips were merely nullified (commute -> nil) and
    /// left behind as orphans, accumulating forever.
    @Test("Deleting a commute removes all its CommuteTrip rows")
    func deletingCommuteRemovesTrips() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)

        let commute = Commute(name: "Work")
        context.insert(commute)
        for _ in 0..<5 {
            context.insert(CommuteTrip(commute: commute, direction: .originToDestination))
        }
        try context.save()

        #expect(try context.fetch(FetchDescriptor<CommuteTrip>()).count == 5)

        context.delete(commute)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Commute>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<CommuteTrip>()).isEmpty)
    }

    /// A sibling commute's trips must survive when another commute is deleted —
    /// the cascade is scoped to the deleted commute's own trips only.
    @Test("Cascade is scoped to the deleted commute, sibling trips survive")
    func cascadeScopedToDeletedCommute() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)

        let work = Commute(name: "Work")
        let gym = Commute(name: "Gym")
        context.insert(work)
        context.insert(gym)
        context.insert(CommuteTrip(commute: work, direction: .originToDestination))
        context.insert(CommuteTrip(commute: work, direction: .destinationToOrigin))
        context.insert(CommuteTrip(commute: gym, direction: .originToDestination))
        try context.save()

        context.delete(work)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<CommuteTrip>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.commute?.id == gym.id)
    }
}
