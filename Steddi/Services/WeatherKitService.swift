import Foundation
import CoreLocation
import Observation
import WeatherKit
import os

private let weatherLog = Logger(subsystem: "to.nathancurtis.steddi", category: "Weather")

/// Fetches and caches current weather for the theming pipeline.
///
/// Degrades gracefully on every axis: missing WeatherKit entitlement flips
/// `isAvailable` and the service serves time-of-day heuristics instead; no
/// network serves the 10-minute cache; nothing here ever surfaces an error to
/// the UI. A budget guard caps WeatherKit calls (min spacing + daily ceiling)
/// so theming can never burn quota.
@Observable
@MainActor
final class WeatherKitService {
    static let shared = WeatherKitService()

    typealias Provider = @Sendable (CLLocation) async throws -> WeatherConditionSnapshot

    private(set) var currentCondition: WeatherConditionSnapshot?
    private(set) var isAvailable = true
    private(set) var lastFetchTime: Date?
    private(set) var lastError: Error?

    private let provider: Provider
    private let now: () -> Date
    /// Where refreshed conditions land — ThemeEngine in production, a probe in tests.
    private let apply: (WeatherConditionSnapshot, WeatherThemeCoefficients) -> Void

    private var isRefreshing = false
    private var unavailableSince: Date?
    private var fetchDay: Date?
    private var fetchCountToday = 0

    init(
        provider: Provider? = nil,
        now: @escaping () -> Date = { Date() },
        apply: ((WeatherConditionSnapshot, WeatherThemeCoefficients) -> Void)? = nil
    ) {
        self.provider = provider ?? Self.weatherKitProvider
        self.now = now
        self.apply = apply ?? { condition, coefficients in
            ThemeEngine.shared.setWeather(condition: condition, coefficients: coefficients)
        }
    }

    // MARK: - Refresh

    /// Fetch current weather, respecting the budget guard. Always leaves the
    /// engine with *some* condition — fetched, cached, or heuristic.
    func refresh(at location: CLLocation) async {
        guard !isRefreshing else { return }

        // Entitlement failures aren't permanent verdicts (provisioning can
        // change) — retry availability every 6 hours.
        if !isAvailable, let since = unavailableSince,
           now().timeIntervalSince(since) > Tuning.availabilityRetryInterval {
            isAvailable = true
            unavailableSince = nil
        }

        guard isAvailable, budgetAllowsFetch() else {
            publishBestEffort()
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }
        recordFetchAttempt()

        do {
            let condition = try await provider(location)
            currentCondition = condition
            lastFetchTime = now()
            lastError = nil
            apply(condition, Self.coefficients(for: condition.kind))
        } catch {
            // Auth/entitlement failures disable WeatherKit; transient network
            // errors keep it available and fall through to cache/heuristics.
            lastError = error
            if Self.isEntitlementFailure(error) {
                weatherLog.info("WeatherKit unavailable (entitlement); using heuristics")
                isAvailable = false
                unavailableSince = now()
            } else {
                weatherLog.debug("Weather fetch failed: \(error.localizedDescription)")
            }
            publishBestEffort()
        }
    }

    /// Cached condition if it is still fresh enough to trust.
    func getCachedCondition() -> WeatherConditionSnapshot? {
        guard let currentCondition, let fetchedAt = currentCondition.fetchedAt,
              now().timeIntervalSince(fetchedAt) < Tuning.cacheTTL else { return nil }
        return currentCondition
    }

    private func publishBestEffort() {
        if let cached = getCachedCondition() {
            apply(cached, Self.coefficients(for: cached.kind))
        } else {
            let heuristic = Self.heuristicCondition(at: now())
            apply(heuristic, Self.coefficients(for: heuristic.kind))
        }
    }

    // MARK: - Budget guard

    private func budgetAllowsFetch() -> Bool {
        if let lastFetchTime, now().timeIntervalSince(lastFetchTime) < Tuning.minFetchInterval {
            return false
        }
        let today = Calendar.current.startOfDay(for: now())
        if fetchDay != today {
            fetchDay = today
            fetchCountToday = 0
        }
        return fetchCountToday < Tuning.maxFetchesPerDay
    }

    private func recordFetchAttempt() {
        let today = Calendar.current.startOfDay(for: now())
        if fetchDay != today {
            fetchDay = today
            fetchCountToday = 0
        }
        fetchCountToday += 1
    }

    // MARK: - Condition → theme mapping

    /// How each condition bends the theme. Overcast and fog are the strong
    /// grey pulls; storms darken; snow brightens (white-sky glare).
    nonisolated static func coefficients(for kind: WeatherConditionSnapshot.Kind) -> WeatherThemeCoefficients {
        switch kind {
        case .clear:
            return .neutral
        case .partlyCloudy:
            return WeatherThemeCoefficients(greyPull: 0.15, brightnessShift: 0)
        case .overcast:
            return WeatherThemeCoefficients(greyPull: 0.55, brightnessShift: -0.05)
        case .fog:
            return WeatherThemeCoefficients(greyPull: 0.70, brightnessShift: -0.05)
        case .rain:
            return WeatherThemeCoefficients(greyPull: 0.45, brightnessShift: -0.12)
        case .snow:
            return WeatherThemeCoefficients(greyPull: 0.25, brightnessShift: 0.10)
        case .storm:
            return WeatherThemeCoefficients(greyPull: 0.50, brightnessShift: -0.25)
        case .unknown:
            return .neutral
        }
    }

    /// No-entitlement / no-network fallback: assume clear skies and let the
    /// solar layer carry the look. Time still flows through `fetchedAt: nil`
    /// so it is never mistaken for a real observation.
    nonisolated static func heuristicCondition(at date: Date) -> WeatherConditionSnapshot {
        WeatherConditionSnapshot(kind: .clear, temperatureF: nil, fetchedAt: nil)
    }

    // MARK: - WeatherKit integration

    private static let weatherKitProvider: Provider = { location in
        let weather = try await WeatherService.shared.weather(for: location, including: .current)
        return WeatherConditionSnapshot(
            kind: WeatherKitService.kind(for: weather.condition),
            temperatureF: weather.temperature.converted(to: .fahrenheit).value,
            fetchedAt: Date()
        )
    }

    nonisolated static func kind(for condition: WeatherCondition) -> WeatherConditionSnapshot.Kind {
        switch condition {
        case .clear, .mostlyClear, .hot:
            return .clear
        case .partlyCloudy, .mostlyCloudy:
            return .partlyCloudy
        case .cloudy:
            return .overcast
        case .foggy, .haze, .smoky, .blowingDust:
            // All reduced-visibility, particulate-in-air conditions read as fog
            // for theming (grey pull, no precipitation tint).
            return .fog
        case .drizzle, .rain, .heavyRain, .freezingDrizzle, .freezingRain, .sunShowers:
            return .rain
        case .snow, .flurries, .heavySnow, .sleet, .wintryMix, .blizzard, .blowingSnow, .frigid, .sunFlurries:
            return .snow
        case .thunderstorms, .strongStorms, .isolatedThunderstorms, .scatteredThunderstorms,
             .hurricane, .tropicalStorm, .hail, .windy, .breezy:
            return condition == .windy || condition == .breezy ? .clear : .storm
        @unknown default:
            // Intentional forward-compat catch-all: WeatherCondition is a
            // framework enum Apple can extend in future OSes. Every case known
            // at compile time is handled explicitly above (the compiler enforces
            // that — see the `.blowingDust` addition), so this only ever fires
            // for cases that did not exist when this built. Mapping the truly
            // unknown to `.unknown` lets the solar layer carry the look rather
            // than guessing a weather mood.
            return .unknown
        }
    }

    /// Entitlement/auth failures present as WeatherKit errors or as JWT/auth
    /// URLErrors; treat anything that is clearly not transient as unavailable.
    nonisolated static func isEntitlementFailure(_ error: Error) -> Bool {
        if error is WeatherError { return true }
        let nsError = error as NSError
        if nsError.domain == "WeatherDaemon.WDSJWTAuthenticatorServiceListener.Errors" { return true }
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorUserAuthenticationRequired
        }
        return false
    }

    private enum Tuning {
        static let minFetchInterval: TimeInterval = 10 * 60
        static let maxFetchesPerDay = 60
        static let cacheTTL: TimeInterval = 60 * 60
        static let availabilityRetryInterval: TimeInterval = 6 * 60 * 60
    }
}
