import Testing
import Foundation
@testable import Steddi

// MARK: - Helpers

/// June 8, 2026 is a Monday. Build a date at a given hour/minute.
private func at(day: Int = 8, hour: Int, minute: Int = 0) throws -> Date {
    let comps = DateComponents(year: 2026, month: 6, day: day, hour: hour, minute: minute)
    return try #require(Calendar.current.date(from: comps))
}

/// A baseline input: notifications on, 15 min lead, no quiet hours, a learned
/// 7am departure, 20-min typical drive, clear weather, never notified, "now"
/// inside the departure window (6:50am). Override fields per test.
private func baseInput(
    notificationsEnabled: Bool = true,
    globallyEnabled: Bool = true,
    leadMinutes: Int = 15,
    quietHoursStart: Int? = nil,
    quietHoursEnd: Int? = nil,
    expectedDepartureHours: [Int] = [7],
    fromLearnedHistory: Bool = true,
    currentETA: TimeInterval? = nil,
    typicalDuration: TimeInterval? = 20 * 60,
    weather: WeatherCondition = .clear,
    weatherSensitivity: WeatherSensitivity = .harsh,
    lastNotificationTime: Date? = nil,
    now: Date,
    destinationName: String = "Work"
) -> CommuteNotificationDecisionEngine.Input {
    CommuteNotificationDecisionEngine.Input(
        notificationsEnabled: notificationsEnabled,
        globallyEnabled: globallyEnabled,
        leadMinutes: leadMinutes,
        quietHoursStart: quietHoursStart,
        quietHoursEnd: quietHoursEnd,
        expectedDepartureHours: expectedDepartureHours,
        fromLearnedHistory: fromLearnedHistory,
        currentETA: currentETA,
        typicalDuration: typicalDuration,
        weather: weather,
        weatherSensitivity: weatherSensitivity,
        lastNotificationTime: lastNotificationTime,
        now: now,
        destinationName: destinationName
    )
}

// MARK: - Master Switches

@Suite("DecisionEngine master switches")
struct DecisionEngineSwitchTests {

    @Test("Globally disabled skips")
    func globallyDisabled() throws {
        let input = baseInput(globallyEnabled: false, currentETA: 40 * 60, now: try at(hour: 6, minute: 50))
        guard case .skip = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip"); return
        }
    }

    @Test("Per-commute disabled skips")
    func commuteDisabled() throws {
        let input = baseInput(notificationsEnabled: false, currentETA: 40 * 60, now: try at(hour: 6, minute: 50))
        guard case .skip = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip"); return
        }
    }
}

// MARK: - Quiet Hours

@Suite("DecisionEngine quiet hours")
struct DecisionEngineQuietHoursTests {

    @Test("Same-day quiet band suppresses")
    func sameDayBand() {
        #expect(CommuteNotificationDecisionEngine.isWithinQuietHours(hour: 3, start: 1, end: 5))
        #expect(!CommuteNotificationDecisionEngine.isWithinQuietHours(hour: 6, start: 1, end: 5))
    }

    @Test("Wraparound band spans midnight")
    func wraparoundBand() {
        // 22..7 covers 23 and 2, not 9
        #expect(CommuteNotificationDecisionEngine.isWithinQuietHours(hour: 23, start: 22, end: 7))
        #expect(CommuteNotificationDecisionEngine.isWithinQuietHours(hour: 2, start: 22, end: 7))
        #expect(!CommuteNotificationDecisionEngine.isWithinQuietHours(hour: 9, start: 22, end: 7))
    }

    @Test("Start equal to end is an empty band")
    func emptyBand() {
        #expect(!CommuteNotificationDecisionEngine.isWithinQuietHours(hour: 5, start: 5, end: 5))
    }

    @Test("nil bounds never quiet")
    func nilBounds() {
        #expect(!CommuteNotificationDecisionEngine.isWithinQuietHours(hour: 3, start: nil, end: nil))
        #expect(!CommuteNotificationDecisionEngine.isWithinQuietHours(hour: 3, start: 1, end: nil))
    }

    @Test("Departure inside quiet hours skips even with heavy traffic")
    func departureInQuietHours() throws {
        // 7am departure, quiet hours 6..8, heavy traffic — still skip.
        let input = baseInput(
            quietHoursStart: 6, quietHoursEnd: 8,
            currentETA: 40 * 60, now: try at(hour: 6, minute: 50)
        )
        guard case .skip(let reason) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip"); return
        }
        #expect(reason.contains("quiet"))
    }
}

// MARK: - Cooldown

@Suite("DecisionEngine cooldown")
struct DecisionEngineCooldownTests {

    @Test("Within 2h cooldown skips")
    func withinCooldown() throws {
        let now = try at(hour: 6, minute: 50)
        let lastHour = try at(hour: 5, minute: 30)  // 80 min ago, same day
        let input = baseInput(currentETA: 40 * 60, lastNotificationTime: lastHour, now: now)
        guard case .skip(let reason) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip"); return
        }
        #expect(reason.contains("cooldown"))
    }

    @Test("Past 2h cooldown allows notify")
    func pastCooldown() throws {
        let now = try at(hour: 6, minute: 50)
        let longAgo = try at(hour: 3, minute: 0)  // >2h ago, same day
        let input = baseInput(currentETA: 40 * 60, lastNotificationTime: longAgo, now: now)
        guard case .notify = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected notify"); return
        }
    }

    @Test("Cooldown resets across midnight — yesterday's late ping doesn't suppress today")
    func cooldownResetsAtMidnight() throws {
        let now = try at(day: 9, hour: 6, minute: 50)            // Tuesday morning
        let lastNight = try at(day: 8, hour: 23, minute: 30)     // Monday night, <2h clock gap but different day
        let input = baseInput(currentETA: 40 * 60, lastNotificationTime: lastNight, now: now)
        guard case .notify = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected notify across day boundary"); return
        }
    }
}

// MARK: - Zero History / Departure Window

@Suite("DecisionEngine departure window & zero history")
struct DecisionEngineDepartureTests {

    @Test("No pattern and no schedule skips")
    func zeroHistory() throws {
        let input = baseInput(expectedDepartureHours: [], currentETA: 40 * 60, now: try at(hour: 6, minute: 50))
        guard case .skip(let reason) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip"); return
        }
        #expect(reason.contains("no learned pattern"))
    }

    @Test("Schedule-only fallback still evaluates when in window")
    func scheduleFallback() throws {
        let input = baseInput(
            expectedDepartureHours: [7], fromLearnedHistory: false,
            currentETA: 40 * 60, now: try at(hour: 6, minute: 50)
        )
        guard case .notify = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected notify on schedule fallback"); return
        }
    }

    @Test("Too early for departure skips")
    func tooEarly() throws {
        // 7am departure, 15 lead + 30 slack => window opens 6:15. 5:00 is too early.
        let input = baseInput(currentETA: 40 * 60, now: try at(hour: 5, minute: 0))
        guard case .skip(let reason) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip"); return
        }
        #expect(reason.contains("approaching"))
    }

    @Test("After departure skips")
    func afterDeparture() throws {
        let input = baseInput(currentETA: 40 * 60, now: try at(hour: 7, minute: 30))
        guard case .skip = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip"); return
        }
    }

    @Test("isApproachingDeparture honors lead + slack window")
    func approachingWindow() throws {
        let cal = Calendar.current
        // 7am departure, 15 lead => window opens 6:15.
        #expect(CommuteNotificationDecisionEngine.isApproachingDeparture(
            hour: 6, now: try at(hour: 6, minute: 20), departureHours: [7], leadMinutes: 15, calendar: cal))
        #expect(!CommuteNotificationDecisionEngine.isApproachingDeparture(
            hour: 6, now: try at(hour: 6, minute: 0), departureHours: [7], leadMinutes: 15, calendar: cal))
    }
}

// MARK: - Traffic Trigger

@Suite("DecisionEngine traffic trigger")
struct DecisionEngineTrafficTests {

    @Test("Delay over threshold and floor notifies leaveEarly")
    func heavyTrafficNotifies() throws {
        // 20 min typical, 40 min ETA => 100% delay, 20 min over floor.
        let input = baseInput(currentETA: 40 * 60, now: try at(hour: 6, minute: 50))
        guard case .notify(_, let action, let lead) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected notify"); return
        }
        #expect(action == .leaveEarly)
        #expect(lead == 15)
    }

    @Test("Delay below percentage threshold skips")
    func belowPercentSkips() throws {
        // 20 min typical, 22 min ETA => 10% delay (< 20%).
        let input = baseInput(currentETA: 22 * 60, now: try at(hour: 6, minute: 50))
        guard case .skip(let reason) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip"); return
        }
        #expect(reason.contains("no traffic delay"))
    }

    @Test("Big percentage but below minute floor skips")
    func belowFloorSkips() throws {
        // 5 min typical, 7 min ETA => 40% delay but only 2 min over (< 6 floor).
        let input = baseInput(currentETA: 7 * 60, typicalDuration: 5 * 60, now: try at(hour: 6, minute: 50))
        guard case .skip = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip"); return
        }
    }

    @Test("No ETA and clear weather skips (nothing to act on)")
    func noETANoWeather() throws {
        let input = baseInput(currentETA: nil, now: try at(hour: 6, minute: 50))
        guard case .skip = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip"); return
        }
    }
}

// MARK: - Weather Trigger & Gating

@Suite("DecisionEngine weather gating")
struct DecisionEngineWeatherTests {

    @Test("Harsh weather, no ETA — weather stands alone and notifies")
    func harshWeatherNoETA() throws {
        let weather = WeatherCondition(severity: .harsh, summary: "Snow expected", available: true)
        let input = baseInput(currentETA: nil, weather: weather, now: try at(hour: 6, minute: 50))
        guard case .notify(let msg, let action, _) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected notify"); return
        }
        #expect(action == .harshWeather)
        #expect(msg.contains("Snow"))
    }

    @Test("Harsh weather but ETA shows no slowdown skips")
    func harshWeatherETAClears() throws {
        // Harsh weather but ETA == typical => weatherETAConfirms false.
        let weather = WeatherCondition(severity: .harsh, summary: "Snow expected", available: true)
        let input = baseInput(currentETA: 20 * 60, weather: weather, now: try at(hour: 6, minute: 50))
        guard case .skip = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip when ETA unaffected"); return
        }
    }

    @Test("Moderate weather below harsh sensitivity skips")
    func belowSensitivitySkips() throws {
        let weather = WeatherCondition(severity: .moderate, summary: "Rain", available: true)
        let input = baseInput(
            currentETA: nil, weather: weather, weatherSensitivity: .harsh,
            now: try at(hour: 6, minute: 50)
        )
        guard case .skip = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip below sensitivity"); return
        }
    }

    @Test("Moderate weather meets moderate sensitivity, notifies")
    func meetsSensitivity() throws {
        let weather = WeatherCondition(severity: .moderate, summary: "Rain", available: true)
        let input = baseInput(
            currentETA: nil, weather: weather, weatherSensitivity: .moderate,
            now: try at(hour: 6, minute: 50)
        )
        guard case .notify(_, let action, _) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected notify"); return
        }
        #expect(action == .harshWeather)
    }

    @Test("Unavailable weather ignored — no traffic means skip")
    func unavailableWeatherIgnored() throws {
        let input = baseInput(currentETA: nil, weather: .unavailable, now: try at(hour: 6, minute: 50))
        guard case .skip = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip"); return
        }
    }

    @Test("Unavailable weather still allows traffic-only notify")
    func unavailableWeatherTrafficStillWorks() throws {
        let input = baseInput(currentETA: 40 * 60, weather: .unavailable, now: try at(hour: 6, minute: 50))
        guard case .notify(_, let action, _) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected traffic notify"); return
        }
        #expect(action == .leaveEarly)
    }
}

// MARK: - Combined Trigger

@Suite("DecisionEngine combined trigger")
struct DecisionEngineCombinedTests {

    @Test("Traffic + harsh weather uses combinedDelay and higher lead")
    func combined() throws {
        let weather = WeatherCondition(severity: .harsh, summary: "Heavy snow", available: true)
        let input = baseInput(currentETA: 40 * 60, weather: weather, leadMinutes: 20, now: try at(hour: 6, minute: 40))
        guard case .notify(let msg, let action, let lead) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected notify"); return
        }
        #expect(action == .combinedDelay)
        // 20 lead + 10 combined extra = 30.
        #expect(lead == 30)
        #expect(msg.lowercased().contains("snow"))
    }

    @Test("Combined lead clamps to 120 max")
    func combinedLeadClamps() throws {
        let weather = WeatherCondition(severity: .harsh, summary: "Snow", available: true)
        let input = baseInput(currentETA: 60 * 60, weather: weather, leadMinutes: 120, now: try at(hour: 4, minute: 30))
        guard case .notify(_, _, let lead) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected notify"); return
        }
        #expect(lead == 120)
    }
}

// MARK: - Lead Clamp

@Suite("DecisionEngine lead clamp")
struct DecisionEngineLeadClampTests {
    @Test("Clamp enforces 15..120")
    func clamp() {
        #expect(CommuteNotificationDecisionEngine.clampLead(5) == 15)
        #expect(CommuteNotificationDecisionEngine.clampLead(45) == 45)
        #expect(CommuteNotificationDecisionEngine.clampLead(500) == 120)
    }
}

// MARK: - Delay Math

@Suite("DecisionEngine delay math")
struct DecisionEngineDelayMathTests {
    @Test("delayFraction nil when inputs missing or typical zero")
    func fractionNil() {
        #expect(CommuteNotificationDecisionEngine.delayFraction(eta: nil, typical: 100) == nil)
        #expect(CommuteNotificationDecisionEngine.delayFraction(eta: 100, typical: nil) == nil)
        #expect(CommuteNotificationDecisionEngine.delayFraction(eta: 100, typical: 0) == nil)
    }

    @Test("delayFraction computes correctly")
    func fractionValue() throws {
        let frac = try #require(CommuteNotificationDecisionEngine.delayFraction(eta: 1200, typical: 1000))
        #expect(abs(frac - 0.2) < 0.0001)
    }

    @Test("delayMinutes truncates to whole minutes")
    func minutesValue() {
        #expect(CommuteNotificationDecisionEngine.delayMinutes(eta: 1200, typical: 600) == 10)
    }
}
