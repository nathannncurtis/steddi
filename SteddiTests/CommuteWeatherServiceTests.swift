import Testing
import Foundation
import CoreLocation
#if canImport(WeatherKit)
import WeatherKit
#endif
@testable import Steddi

// MARK: - Helpers

/// Isolated UserDefaults suite per test so budget bookkeeping never collides.
private func freshDefaults() -> UserDefaults {
    let name = "weathertest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func date(year: Int, month: Int, day: Int = 1) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
}

// MARK: - Budget Guard

@Suite("CommuteWeatherService budget guard")
struct WeatherBudgetTests {

    @Test("Fresh install starts with full monthly budget")
    func freshBudget() {
        let defaults = freshDefaults()
        let service = CommuteWeatherService(defaults: defaults, now: { date(year: 2026, month: 6) })
        #expect(service.budgetRemaining == CommuteWeatherService.monthlyBudget)
        #expect(service.hasBudget)
    }

    @Test("Budget resets on a new month")
    func budgetResetsNewMonth() {
        let defaults = freshDefaults()
        // Simulate a depleted budget recorded in May.
        defaults.set("2026-5", forKey: CommuteWeatherService.budgetMonthKey)
        defaults.set(0, forKey: CommuteWeatherService.budgetRemainingKey)

        // Init in June — rollover restores full budget.
        let service = CommuteWeatherService(defaults: defaults, now: { date(year: 2026, month: 6) })
        #expect(service.budgetRemaining == CommuteWeatherService.monthlyBudget)
    }

    @Test("Same-month depleted budget is preserved")
    func sameMonthDepletedPreserved() {
        let defaults = freshDefaults()
        defaults.set("2026-6", forKey: CommuteWeatherService.budgetMonthKey)
        defaults.set(5, forKey: CommuteWeatherService.budgetRemainingKey)

        let service = CommuteWeatherService(defaults: defaults, now: { date(year: 2026, month: 6) })
        #expect(service.budgetRemaining == 5)
        #expect(service.hasBudget)
    }

    @Test("Exhausted budget degrades to unavailable without a WeatherKit call")
    func exhaustedDegrades() async {
        let defaults = freshDefaults()
        defaults.set("2026-6", forKey: CommuteWeatherService.budgetMonthKey)
        defaults.set(0, forKey: CommuteWeatherService.budgetRemainingKey)

        let service = CommuteWeatherService(defaults: defaults, now: { date(year: 2026, month: 6) })
        #expect(!service.hasBudget)
        let condition = await service.condition(for: CLLocationCoordinate2D(latitude: 34, longitude: -118))
        #expect(condition == .unavailable)
        // Budget never goes negative.
        #expect(service.budgetRemaining == 0)
    }

    @Test("budgetUsedFraction reflects remaining")
    func usedFraction() {
        let defaults = freshDefaults()
        defaults.set("2026-6", forKey: CommuteWeatherService.budgetMonthKey)
        defaults.set(CommuteWeatherService.monthlyBudget / 2, forKey: CommuteWeatherService.budgetRemainingKey)
        let service = CommuteWeatherService(defaults: defaults, now: { date(year: 2026, month: 6) })
        #expect(abs(service.budgetUsedFraction - 0.5) < 0.001)
    }
}

// MARK: - Cache Key

@Suite("CommuteWeatherService cache key")
struct WeatherCacheKeyTests {

    @Test("Nearby coordinates share a cache key")
    func nearbyShareKey() {
        let a = CommuteWeatherService.cacheKey(CLLocationCoordinate2D(latitude: 34.0512, longitude: -118.2491))
        let b = CommuteWeatherService.cacheKey(CLLocationCoordinate2D(latitude: 34.0498, longitude: -118.2503))
        #expect(a == b)
    }

    @Test("Distant coordinates use distinct keys")
    func distantDistinctKeys() {
        let a = CommuteWeatherService.cacheKey(CLLocationCoordinate2D(latitude: 34.05, longitude: -118.25))
        let b = CommuteWeatherService.cacheKey(CLLocationCoordinate2D(latitude: 40.71, longitude: -74.00))
        #expect(a != b)
    }
}

// MARK: - Severity Mapping (WeatherKit-gated)

#if canImport(WeatherKit)
@Suite("CommuteWeatherService severity mapping")
struct WeatherSeverityTests {

    @Test("Snow is always harsh")
    func snowHarsh() {
        let result = CommuteWeatherService.severity(
            precipMmPerHour: 0, temperatureC: 0, visibilityMeters: 10_000,
            windKmh: 0, condition: .snow
        )
        #expect(result.severity == .harsh)
        #expect(result.summary == "Snow expected")
    }

    @Test("Heavy rain over 25mm/hr is harsh")
    func heavyRainHarsh() {
        let result = CommuteWeatherService.severity(
            precipMmPerHour: 30, temperatureC: 15, visibilityMeters: 10_000,
            windKmh: 10, condition: .rain
        )
        #expect(result.severity == .harsh)
    }

    @Test("Extreme cold and heat are harsh")
    func extremeTemps() {
        let cold = CommuteWeatherService.severity(
            precipMmPerHour: 0, temperatureC: -15, visibilityMeters: 10_000, windKmh: 0, condition: .clear)
        let hot = CommuteWeatherService.severity(
            precipMmPerHour: 0, temperatureC: 42, visibilityMeters: 10_000, windKmh: 0, condition: .clear)
        #expect(cold.severity == .harsh)
        #expect(hot.severity == .harsh)
    }

    @Test("Low visibility and high wind are harsh")
    func visibilityWind() {
        let fog = CommuteWeatherService.severity(
            precipMmPerHour: 0, temperatureC: 15, visibilityMeters: 500, windKmh: 0, condition: .foggy)
        let gale = CommuteWeatherService.severity(
            precipMmPerHour: 0, temperatureC: 15, visibilityMeters: 10_000, windKmh: 60, condition: .windy)
        #expect(fog.severity == .harsh)
        #expect(gale.severity == .harsh)
    }

    @Test("Steady rain is moderate")
    func steadyRainModerate() {
        let result = CommuteWeatherService.severity(
            precipMmPerHour: 10, temperatureC: 15, visibilityMeters: 10_000, windKmh: 10, condition: .rain)
        #expect(result.severity == .moderate)
    }

    @Test("Clear calm conditions are clear")
    func clearConditions() {
        let result = CommuteWeatherService.severity(
            precipMmPerHour: 0, temperatureC: 20, visibilityMeters: 12_000, windKmh: 5, condition: .clear)
        #expect(result.severity == .clear)
        #expect(result.summary.isEmpty)
    }
}
#endif
