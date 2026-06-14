import Foundation

// MARK: - Weather Model (decoupled from WeatherKit)

/// A weather severity bucket the decision engine reasons over. Decoupled from
/// WeatherKit so the engine stays pure and testable — `CommuteWeatherService`
/// maps live WeatherKit data into this.
enum WeatherSeverity: Int, Comparable, Codable {
    case clear = 0       // nothing notable
    case minimal = 1     // light rain, breezy
    case moderate = 2    // steady rain, gusty wind, reduced visibility
    case harsh = 3       // heavy precip, snow, extreme temps, low visibility, high wind

    static func < (lhs: WeatherSeverity, rhs: WeatherSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A snapshot of weather conditions relevant to a commute. Produced by
/// `CommuteWeatherService` from WeatherKit and consumed by the decision engine.
struct WeatherCondition: Equatable {
    /// Overall severity bucket for the worst expected condition along the window.
    var severity: WeatherSeverity
    /// Short human phrase, e.g. "Snow expected" or "Heavy rain". Empty when clear.
    var summary: String
    /// Whether weather data was actually available. False means WeatherKit was
    /// unavailable / over budget / errored — the engine then ignores weather.
    var available: Bool

    static let unavailable = WeatherCondition(severity: .clear, summary: "", available: false)
    static let clear = WeatherCondition(severity: .clear, summary: "", available: true)
}

/// The user's chosen weather sensitivity (mirrors the Settings picker). The
/// engine notifies on weather only when the condition meets or exceeds this.
enum WeatherSensitivity: String, CaseIterable, Codable {
    case minimal
    case moderate
    case harsh

    var threshold: WeatherSeverity {
        switch self {
        case .minimal: return .minimal
        case .moderate: return .moderate
        case .harsh: return .harsh
        }
    }

    var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .moderate: return "Moderate"
        case .harsh: return "Harsh"
        }
    }
}

// MARK: - Decision Types

/// What kind of notification we'd send — drives copy and lead time.
enum NotificationActionType: Equatable {
    case leaveEarly      // traffic / ETA delay only
    case harshWeather    // weather only
    case combinedDelay   // both traffic + weather
}

/// The decision engine's verdict for a single commute evaluation.
enum NotificationDecision: Equatable {
    case skip(reason: String)
    case notify(message: String, actionType: NotificationActionType, leadMinutes: Int)
}

// MARK: - Decision Engine

/// Pure, deterministic logic for deciding whether to alert the user to leave
/// early. No WeatherKit, no MKDirections, no UNUserNotificationCenter, no
/// SwiftData fetches — every input is passed in. This keeps the matrix
/// (traffic / weather / quiet hours / cooldown / zero-history) fully unit
/// testable and reusable from a widget or background task alike.
struct CommuteNotificationDecisionEngine {

    // MARK: Tuning Constants

    /// Minimum ETA delay (as a fraction of typical) before traffic alone notifies.
    /// 0.20 == 20% slower than usual. Conservative to avoid crying wolf.
    static let trafficDelayThreshold: Double = 0.20

    /// Absolute minute floor — a 20% delay on a 5-minute hop isn't worth a ping.
    static let trafficDelayHardFloorMinutes: Int = 6

    /// Weather notifies when the trip is also at least this much slower than usual.
    /// Lower than the traffic-only floor because harsh weather is itself the signal.
    static let weatherDelayThreshold: Double = 0.15

    /// How close to the expected departure we must be to bother notifying.
    /// Outside this window the alert is either too early to act on or too late.
    static let departureWindowMinutes: Int = 30

    /// Cooldown — never re-notify the same commute within this span.
    static let cooldownSeconds: TimeInterval = 2 * 60 * 60  // 2 hours

    /// Extra lead minutes layered on when traffic and weather both fire.
    static let combinedExtraLeadMinutes: Int = 10

    // MARK: Inputs

    struct Input {
        /// Whether notifications are enabled for this commute (per-commute toggle).
        var notificationsEnabled: Bool
        /// Whether notifications are enabled globally (Settings toggle).
        var globallyEnabled: Bool
        /// How early to alert, in minutes (per-commute, 15–120).
        var leadMinutes: Int
        /// Quiet-hours start hour 0–23, nil if no quiet hours.
        var quietHoursStart: Int?
        /// Quiet-hours end hour 0–23, nil if no quiet hours.
        var quietHoursEnd: Int?

        /// Expected departure hours for today (learned from CommuteTrip history,
        /// else schedule-rule start hour). Empty => zero-history & no schedule.
        var expectedDepartureHours: [Int]
        /// True when `expectedDepartureHours` came from learned trips (>=5),
        /// false when from schedule rules only. Affects confidence copy.
        var fromLearnedHistory: Bool

        /// Current ETA from origin to destination, seconds. nil if unavailable
        /// (no location, MKDirections failed).
        var currentETA: TimeInterval?
        /// Typical/baseline duration for the trip, seconds. nil if unknown.
        var typicalDuration: TimeInterval?

        /// Weather snapshot for the destination. `.unavailable` to ignore weather.
        var weather: WeatherCondition
        /// User's weather sensitivity threshold.
        var weatherSensitivity: WeatherSensitivity

        /// When this commute last sent a notification, nil if never.
        var lastNotificationTime: Date?

        /// Now.
        var now: Date

        /// A short noun for the destination used in copy, e.g. "Work".
        var destinationName: String
    }

    // MARK: Evaluate

    /// The single entry point. Returns `.skip` with a human reason or `.notify`
    /// with ready-to-render copy, the action type, and the lead minutes.
    static func evaluate(_ input: Input) -> NotificationDecision {
        // 1. Master switches
        guard input.globallyEnabled else { return .skip(reason: "notifications disabled globally") }
        guard input.notificationsEnabled else { return .skip(reason: "notifications disabled for this commute") }

        let cal = Calendar.current
        let hour = cal.component(.hour, from: input.now)

        // 2. Quiet hours
        if isWithinQuietHours(hour: hour, start: input.quietHoursStart, end: input.quietHoursEnd) {
            return .skip(reason: "within quiet hours")
        }

        // 3. Cooldown — never double-notify a window. Resets at midnight so a
        //    morning ping never suppresses an evening one.
        if let last = input.lastNotificationTime {
            let sameDay = cal.isDate(last, inSameDayAs: input.now)
            if sameDay && input.now.timeIntervalSince(last) < cooldownSeconds {
                return .skip(reason: "within cooldown window")
            }
        }

        // 4. Expected departure — learned, else schedule, else nothing.
        guard !input.expectedDepartureHours.isEmpty else {
            return .skip(reason: "no learned pattern or schedule for today")
        }

        // 5. Departure-timing window — only alert when we're approaching a
        //    departure. We notify `leadMinutes` early, so we're "in window" when
        //    now is within [departure - lead - slack, departure].
        guard isApproachingDeparture(
            hour: hour,
            now: input.now,
            departureHours: input.expectedDepartureHours,
            leadMinutes: input.leadMinutes,
            calendar: cal
        ) else {
            return .skip(reason: "not approaching an expected departure")
        }

        // 6. Compute delay fraction (nil when we can't compare).
        let delayFraction = Self.delayFraction(eta: input.currentETA, typical: input.typicalDuration)
        let delayMinutes = Self.delayMinutes(eta: input.currentETA, typical: input.typicalDuration)

        // Traffic trigger: delay over threshold AND over the absolute floor.
        let trafficTriggered: Bool = {
            guard let frac = delayFraction, let mins = delayMinutes else { return false }
            return frac >= trafficDelayThreshold && mins >= trafficDelayHardFloorMinutes
        }()

        // Weather trigger: available, meets sensitivity, and either there's no
        // ETA to check OR the ETA confirms a >=15% slowdown.
        let weatherSevere = input.weather.available
            && input.weather.severity >= input.weatherSensitivity.threshold
        let weatherETAConfirms: Bool = {
            guard let frac = delayFraction else { return true } // no ETA => weather stands alone
            return frac >= weatherDelayThreshold
        }()
        let weatherTriggered = weatherSevere && weatherETAConfirms

        // 7. Combine
        switch (trafficTriggered, weatherTriggered) {
        case (true, true):
            let lead = clampLead(input.leadMinutes + combinedExtraLeadMinutes)
            let weatherPhrase = input.weather.summary.isEmpty ? "rough weather" : input.weather.summary.lowercased()
            let mins = delayMinutes ?? 0
            return .notify(
                message: "\(weatherPhrase.capitalizingFirstLetter()) and \(mins) min of extra traffic to \(input.destinationName).",
                actionType: .combinedDelay,
                leadMinutes: lead
            )
        case (true, false):
            let mins = delayMinutes ?? 0
            return .notify(
                message: "Heavier traffic than usual — about \(mins) extra min to \(input.destinationName).",
                actionType: .leaveEarly,
                leadMinutes: clampLead(input.leadMinutes)
            )
        case (false, true):
            let weatherPhrase = input.weather.summary.isEmpty ? "Rough weather expected" : input.weather.summary
            return .notify(
                message: "\(weatherPhrase) on your way to \(input.destinationName).",
                actionType: .harshWeather,
                leadMinutes: clampLead(input.leadMinutes)
            )
        case (false, false):
            return .skip(reason: "no traffic delay or harsh weather")
        }
    }

    // MARK: - Helpers (internal for testing)

    /// True if `hour` falls inside the quiet-hours band. Handles wraparound
    /// (e.g. 22 → 7 spans midnight). Inclusive of start, exclusive of end.
    static func isWithinQuietHours(hour: Int, start: Int?, end: Int?) -> Bool {
        guard let start, let end else { return false }
        if start == end { return false }            // empty band
        if start < end {
            return hour >= start && hour < end       // same-day band, e.g. 1..5
        }
        // Wraps midnight, e.g. 22..7 => [22,23] ∪ [0,7)
        return hour >= start || hour < end
    }

    /// Whether `now` is close enough before one of today's expected departures
    /// that an "leave early" ping is actionable. We allow a small slack before
    /// the lead window so iOS's imprecise background timing still lands inside.
    static func isApproachingDeparture(
        hour: Int,
        now: Date,
        departureHours: [Int],
        leadMinutes: Int,
        calendar: Calendar = .current
    ) -> Bool {
        for depHour in departureHours {
            guard let departure = calendar.date(
                bySettingHour: depHour, minute: 0, second: 0, of: now
            ) else { continue }
            // Window opens lead + slack before departure, closes at departure.
            let windowOpen = departure.addingTimeInterval(
                TimeInterval(-(leadMinutes + departureWindowMinutes) * 60)
            )
            if now >= windowOpen && now <= departure {
                return true
            }
        }
        return false
    }

    /// ETA delay as a fraction of typical. nil when either is missing/invalid.
    static func delayFraction(eta: TimeInterval?, typical: TimeInterval?) -> Double? {
        guard let eta, let typical, typical > 0 else { return nil }
        return (eta - typical) / typical
    }

    /// ETA delay in whole minutes. nil when either is missing/invalid.
    static func delayMinutes(eta: TimeInterval?, typical: TimeInterval?) -> Int? {
        guard let eta, let typical, typical > 0 else { return nil }
        return Int((eta - typical) / 60.0)
    }

    /// Clamp lead minutes to the supported 15–120 range.
    static func clampLead(_ minutes: Int) -> Int {
        min(120, max(15, minutes))
    }
}

// MARK: - String Helper

private extension String {
    func capitalizingFirstLetter() -> String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
