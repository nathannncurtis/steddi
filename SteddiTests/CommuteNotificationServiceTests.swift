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

        #expect(CommuteNotificationService.scheduledDepartureHours(
            commute: commute, direction: .originToDestination) == [6])
        #expect(CommuteNotificationService.scheduledDepartureHours(
            commute: commute, direction: .destinationToOrigin) == [17])
    }

    @Test("No schedule returns empty")
    func noScheduleEmpty() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let commute = Commute(name: "Unscheduled")
        context.insert(commute)

        #expect(CommuteNotificationService.scheduledDepartureHours(
            commute: commute, direction: .originToDestination).isEmpty)
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
