import Foundation
import CoreLocation
import os
#if canImport(WeatherKit)
import WeatherKit
#endif

private let weatherLog = Logger(subsystem: "to.nathancurtis.steddi", category: "CommuteWeather")

/// Fetches WeatherKit conditions for a commute destination and maps them into
/// the engine's `WeatherCondition`. Owns three concerns the spec calls out:
///
/// 1. Budget guard — WeatherKit's free tier is 500k calls/mo. We track a
///    monthly remaining counter in UserDefaults and stop calling when it's
///    exhausted, degrading to `.unavailable` so the engine falls back to
///    traffic-only.
/// 2. Caching — a short TTL keyed by rounded coordinate so a background pass
///    that checks several commutes near the same place doesn't burn the budget.
/// 3. Graceful degradation — when WeatherKit can't link (no entitlement) or
///    throws (region unsupported, network), we return `.unavailable` and never
///    crash the notification pass.
@Observable
final class CommuteWeatherService {

    // MARK: UserDefaults Keys

    static let budgetRemainingKey = "steddi.weatherKitBudgetRemaining"
    static let budgetMonthKey = "steddi.weatherKitBudgetMonth"

    /// WeatherKit free tier: 500k calls/month.
    static let monthlyBudget = 500_000

    /// Cache TTL — 8 minutes, inside the spec's 5–10 min guidance.
    static let cacheTTL: TimeInterval = 8 * 60

    /// How long to suppress further WeatherKit calls after a hard/entitlement
    /// failure (no entitlement, unsupported region). Mirrors WeatherKitService's
    /// 6h availability retry so a build without the entitlement doesn't re-hit
    /// WeatherKit for every commute on every background pass.
    static let entitlementBackoff: TimeInterval = 6 * 60 * 60
    /// Shorter cooldown after a transient failure (network) so genuine weather
    /// comes back quickly once connectivity returns, without re-calling for
    /// every nearby commute in the same constrained background window.
    static let transientBackoff: TimeInterval = 5 * 60

    // MARK: Harsh-Condition Thresholds (insurance-grade, from spec)

    static let heavyPrecipMmPerHour: Double = 25.0
    static let extremeColdC: Double = -10.0
    static let extremeHotC: Double = 40.0
    static let lowVisibilityMeters: Double = 1_000.0
    static let highWindKmh: Double = 50.0

    // MARK: State

    /// Exposed for the Settings budget display.
    private(set) var budgetRemaining: Int

    private struct CacheEntry {
        let condition: WeatherCondition
        let fetchedAt: Date
    }
    private var cache: [String: CacheEntry] = [:]

    /// When set, WeatherKit recently failed and we short-circuit to
    /// `.unavailable` (skipping the framework call entirely) until this instant.
    /// Cleared on the first successful fetch. Prevents re-hitting WeatherKit for
    /// every commute on every background pass when the entitlement is missing or
    /// the network is down.
    private var unavailableUntil: Date?

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        self.budgetRemaining = Self.loadBudget(defaults: defaults, now: now())
    }

    // MARK: - Public API

    /// Current weather condition for a destination coordinate. Returns
    /// `.unavailable` (engine ignores weather) when cached-miss + budget-out,
    /// WeatherKit unlinkable, or any error. Never throws.
    func condition(for coordinate: CLLocationCoordinate2D) async -> WeatherCondition {
        let key = Self.cacheKey(coordinate)

        // Cache hit within TTL.
        if let entry = cache[key], now().timeIntervalSince(entry.fetchedAt) < Self.cacheTTL {
            return entry.condition
        }

        // Unavailability cooldown — a recent missing-entitlement / network
        // failure suppresses further WeatherKit calls (across every commute in
        // this pass and subsequent background passes) until the backoff lapses,
        // so a no-entitlement build doesn't pay the failed-call latency on every
        // commute on every wake.
        if let until = unavailableUntil {
            if now() < until { return .unavailable }
            unavailableUntil = nil
        }

        // Budget guard — refresh the month rollover first.
        refreshBudgetMonth()
        guard budgetRemaining > 0 else {
            weatherLog.notice("WeatherKit budget exhausted; degrading to unavailable")
            return .unavailable
        }

        let result = await fetchCondition(for: coordinate)
        switch result {
        case .success(let condition):
            unavailableUntil = nil
            decrementBudget()
            cache[key] = CacheEntry(condition: condition, fetchedAt: now())
            return condition
        case .entitlementFailure:
            // Hard failure (no entitlement, unsupported region) — long backoff.
            unavailableUntil = now().addingTimeInterval(Self.entitlementBackoff)
            return .unavailable
        case .transientFailure:
            // Network/etc. — short backoff so genuine weather returns soon.
            unavailableUntil = now().addingTimeInterval(Self.transientBackoff)
            return .unavailable
        }
    }

    /// Whether weather features are usable at all right now (budget remaining).
    var hasBudget: Bool { budgetRemaining > 0 }

    /// Percentage of the monthly budget consumed, 0...1, for the Settings bar.
    var budgetUsedFraction: Double {
        1.0 - (Double(budgetRemaining) / Double(Self.monthlyBudget))
    }

    // MARK: - Fetch + Mapping

    /// Outcome of a single WeatherKit fetch, distinguishing a hard/entitlement
    /// failure (long backoff) from a transient one (short backoff) so the caller
    /// can pick the right cooldown.
    private enum FetchResult {
        case success(WeatherCondition)
        case entitlementFailure
        case transientFailure
    }

    private func fetchCondition(for coordinate: CLLocationCoordinate2D) async -> FetchResult {
        #if canImport(WeatherKit)
        do {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let weather = try await WeatherService.shared.weather(for: location)
            return .success(Self.map(current: weather.currentWeather, hourly: weather.hourlyForecast, now: now()))
        } catch {
            // No entitlement, unsupported region, or network — degrade silently.
            weatherLog.error("WeatherKit fetch failed: \(error.localizedDescription, privacy: .public)")
            return WeatherKitService.isEntitlementFailure(error)
                ? .entitlementFailure
                : .transientFailure
        }
        #else
        // WeatherKit can't even link in this build — treat as a hard failure so
        // we back off rather than retrying a framework that will never resolve.
        return .entitlementFailure
        #endif
    }

    #if canImport(WeatherKit)
    /// Map current conditions + the next 12h forecast to a `WeatherCondition`,
    /// keeping the worst severity seen across the window. `now` is the injected
    /// clock so the scan is deterministic and testable.
    static func map(
        current: CurrentWeather,
        hourly: Forecast<HourWeather>,
        now: Date
    ) -> WeatherCondition {
        let currentSeverity = severity(
            precipMmPerHour: Self.precipMmPerHour(current.precipitationIntensity),
            temperatureC: current.temperature.converted(to: .celsius).value,
            visibilityMeters: current.visibility.converted(to: .meters).value,
            windKmh: current.wind.speed.converted(to: .kilometersPerHour).value,
            condition: current.condition
        )
        // Project each forecast hour to (date, severity) so the time-bounding +
        // worst-severity reduction lives in a pure, WeatherKit-free helper that
        // the suite can exercise with synthetic past/future hours.
        let hourlySeverities = hourly.forecast.map { hour in
            (date: hour.date, severity: severity(
                // Hourly precipitationAmount is the mm of precip over the hour ==
                // mm/hr for our threshold purposes.
                precipMmPerHour: hour.precipitationAmount.converted(to: .millimeters).value,
                temperatureC: hour.temperature.converted(to: .celsius).value,
                visibilityMeters: hour.visibility.converted(to: .meters).value,
                windKmh: hour.wind.speed.converted(to: .kilometersPerHour).value,
                condition: hour.condition
            ))
        }
        return worstCondition(current: currentSeverity, hourly: hourlySeverities, now: now)
    }
    #endif

    /// Reduce the current condition plus the time-stamped hourly severities to a
    /// single worst-case `WeatherCondition`, scanning ONLY the [now, now + 12h]
    /// window. The lower bound matters: WeatherKit's `hourlyForecast` routinely
    /// begins before `now` (it starts ~10pm the prior local day), so without it an
    /// already-elapsed burst of heavy rain that has since cleared would still
    /// inflate the commute's severity and fire a false pre-drive alert. Pure and
    /// WeatherKit-free so it is deterministically testable.
    static func worstCondition(
        current: (severity: WeatherSeverity, summary: String),
        hourly: [(date: Date, severity: (severity: WeatherSeverity, summary: String))],
        now: Date
    ) -> WeatherCondition {
        var worst = current
        var worstSummary = worst.severity > WeatherSeverity.clear ? worst.summary : ""

        let horizon = now.addingTimeInterval(12 * 3600)
        for hour in hourly where hour.date >= now && hour.date <= horizon {
            if hour.severity.severity > worst.severity {
                worst = hour.severity
                worstSummary = hour.severity.summary
            }
        }

        return WeatherCondition(severity: worst.severity, summary: worstSummary, available: true)
    }

    #if canImport(WeatherKit)

    /// WeatherKit's `precipitationIntensity` is a `Measurement<UnitSpeed>`
    /// whose base unit is m/s. Convert to mm/hr: m/s × 1000 mm/m × 3600 s/hr.
    private static func precipMmPerHour(_ intensity: Measurement<UnitSpeed>) -> Double {
        intensity.converted(to: .metersPerSecond).value * 1000.0 * 3600.0
    }

    /// Map a single WeatherKit condition into our severity bucket. Static so it
    /// can be exercised without a live WeatherKit fetch.
    static func severity(
        precipMmPerHour: Double,
        temperatureC: Double,
        visibilityMeters: Double,
        windKmh: Double,
        condition: WeatherCondition.WeatherKitCondition
    ) -> (severity: WeatherSeverity, summary: String) {
        // Hard harsh triggers.
        if condition.isSnow { return (.harsh, "Snow expected") }
        if precipMmPerHour >= heavyPrecipMmPerHour { return (.harsh, "Heavy rain") }
        if temperatureC <= extremeColdC { return (.harsh, "Extreme cold") }
        if temperatureC >= extremeHotC { return (.harsh, "Extreme heat") }
        if visibilityMeters < lowVisibilityMeters { return (.harsh, "Low visibility") }
        if windKmh >= highWindKmh { return (.harsh, "High winds") }

        // Moderate.
        if precipMmPerHour >= 7.5 { return (.moderate, "Steady rain") }
        if visibilityMeters < 4_000 { return (.moderate, "Reduced visibility") }
        if windKmh >= 30 { return (.moderate, "Gusty wind") }

        // Minimal.
        if precipMmPerHour > 0 { return (.minimal, "Light rain") }
        if windKmh >= 20 { return (.minimal, "Breezy") }

        return (.clear, "")
    }
    #endif

    // MARK: - Budget Bookkeeping

    private func refreshBudgetMonth() {
        let currentMonth = Self.monthStamp(now())
        let storedMonth = defaults.string(forKey: Self.budgetMonthKey)
        if storedMonth != currentMonth {
            // New month — reset.
            defaults.set(currentMonth, forKey: Self.budgetMonthKey)
            defaults.set(Self.monthlyBudget, forKey: Self.budgetRemainingKey)
            budgetRemaining = Self.monthlyBudget
        }
    }

    private func decrementBudget() {
        budgetRemaining = max(0, budgetRemaining - 1)
        defaults.set(budgetRemaining, forKey: Self.budgetRemainingKey)
    }

    private static func loadBudget(defaults: UserDefaults, now: Date) -> Int {
        let currentMonth = monthStamp(now)
        let storedMonth = defaults.string(forKey: budgetMonthKey)
        if storedMonth != currentMonth {
            defaults.set(currentMonth, forKey: budgetMonthKey)
            defaults.set(monthlyBudget, forKey: budgetRemainingKey)
            return monthlyBudget
        }
        // object(forKey:) is nil on a fresh install with the right month stamp
        // never set — treat nil as full budget.
        if defaults.object(forKey: budgetRemainingKey) == nil {
            return monthlyBudget
        }
        return defaults.integer(forKey: budgetRemainingKey)
    }

    private static func monthStamp(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)"
    }

    /// Round to ~1km grid so nearby commutes share a cache entry.
    static func cacheKey(_ c: CLLocationCoordinate2D) -> String {
        let lat = (c.latitude * 100).rounded() / 100
        let lng = (c.longitude * 100).rounded() / 100
        return "\(lat),\(lng)"
    }
}

#if canImport(WeatherKit)
extension WeatherCondition {
    /// Thin alias so `severity(...)` can take a WeatherKit condition without
    /// leaking the import into the engine file.
    typealias WeatherKitCondition = WeatherKit.WeatherCondition
}

extension WeatherKit.WeatherCondition {
    /// Whether this condition is snow / wintry mix — always harsh for driving.
    var isSnow: Bool {
        switch self {
        case .blizzard, .blowingSnow, .flurries, .heavySnow, .snow,
             .sleet, .freezingRain, .freezingDrizzle, .wintryMix, .hail:
            return true
        default:
            return false
        }
    }
}
#endif
