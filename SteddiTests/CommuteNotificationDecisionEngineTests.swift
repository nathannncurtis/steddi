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
        let input = baseInput(leadMinutes: 20, currentETA: 40 * 60, weather: weather, now: try at(hour: 6, minute: 40))
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
        let input = baseInput(leadMinutes: 120, currentETA: 60 * 60, weather: weather, now: try at(hour: 4, minute: 30))
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

    @Test("Negative delay (faster than typical) yields negative fraction and minutes")
    func fasterThanTypical() throws {
        // ETA 8 min vs 10 min typical => -20% / -2 min. Used to prove a faster
        // trip can never satisfy the >=20% traffic threshold.
        let frac = try #require(CommuteNotificationDecisionEngine.delayFraction(eta: 480, typical: 600))
        #expect(abs(frac - (-0.2)) < 0.0001)
        #expect(CommuteNotificationDecisionEngine.delayMinutes(eta: 480, typical: 600) == -2)
    }
}

// MARK: - Adversarial Edge Cases

@Suite("DecisionEngine adversarial edges")
struct DecisionEngineAdversarialTests {

    @Test("ETA faster than typical never triggers traffic — skips")
    func fasterTripSkips() throws {
        // 20 min typical, 12 min ETA (-40%). No weather. Must skip, never notify
        // and certainly never produce a negative-minute message.
        let input = baseInput(currentETA: 12 * 60, now: try at(hour: 6, minute: 50))
        guard case .skip(let reason) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip on a faster-than-typical trip"); return
        }
        #expect(reason.contains("no traffic delay"))
    }

    @Test("Harsh weather but faster trip suppresses weather (ETA fails 15% gate)")
    func harshWeatherFasterTripSkips() throws {
        // Snow but the ETA shows a -40% (faster) trip => weatherETAConfirms false.
        let weather = WeatherCondition(severity: .harsh, summary: "Snow expected", available: true)
        let input = baseInput(currentETA: 12 * 60, weather: weather, now: try at(hour: 6, minute: 50))
        guard case .skip = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip — faster ETA should gate harsh weather"); return
        }
    }

    @Test("Cooldown at exactly 2h boundary is NOT suppressed")
    func cooldownExactBoundary() throws {
        // 7am departure; place 'now' late enough that the 2h-ago timestamp still
        // falls inside the approaching-departure window.
        let now = try at(hour: 7, minute: 0)
        let exactly2hAgo = now.addingTimeInterval(-CommuteNotificationDecisionEngine.cooldownSeconds)
        let input = baseInput(currentETA: 40 * 60, lastNotificationTime: exactly2hAgo, now: now)
        // Strict `<` cooldown means exactly 2h elapsed is allowed through.
        guard case .notify = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected notify at the exact 2h cooldown boundary"); return
        }
    }

    @Test("Cooldown one second under 2h IS suppressed")
    func cooldownJustUnderBoundary() throws {
        let now = try at(hour: 7, minute: 0)
        let justUnder = now.addingTimeInterval(-(CommuteNotificationDecisionEngine.cooldownSeconds - 1))
        let input = baseInput(currentETA: 40 * 60, lastNotificationTime: justUnder, now: now)
        guard case .skip(let reason) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip just under the cooldown boundary"); return
        }
        #expect(reason.contains("cooldown"))
    }

    @Test("Future-dated lastNotification (clock skew) treated as within cooldown")
    func futureLastNotificationSuppresses() throws {
        let now = try at(hour: 6, minute: 50)
        let future = try at(hour: 6, minute: 55)  // same day, ahead of now
        let input = baseInput(currentETA: 40 * 60, lastNotificationTime: future, now: now)
        guard case .skip(let reason) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip for a future-dated last notification"); return
        }
        #expect(reason.contains("cooldown"))
    }

    @Test("isApproachingDeparture is inclusive at the exact departure instant")
    func approachingInclusiveAtDeparture() throws {
        let cal = Calendar.current
        #expect(CommuteNotificationDecisionEngine.isApproachingDeparture(
            hour: 7, now: try at(hour: 7, minute: 0), departureHours: [7], leadMinutes: 15, calendar: cal))
    }

    @Test("isApproachingDeparture excludes one minute past departure")
    func approachingExcludesPastDeparture() throws {
        let cal = Calendar.current
        #expect(!CommuteNotificationDecisionEngine.isApproachingDeparture(
            hour: 7, now: try at(hour: 7, minute: 1), departureHours: [7], leadMinutes: 15, calendar: cal))
    }

    @Test("Second of multiple departure hours can put us in window")
    func multipleDepartureHoursSecondMatches() throws {
        // Departures at 7 and 17. now 16:40 is in the 17:00 window (15 lead + 30 slack opens 16:15).
        let input = baseInput(
            expectedDepartureHours: [7, 17], currentETA: 40 * 60, now: try at(hour: 16, minute: 40))
        guard case .notify = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected notify inside the second departure window"); return
        }
    }

    @Test("None of multiple departure hours in window skips")
    func multipleDepartureHoursNoneMatch() throws {
        // Departures at 7 and 17; now 12:00 is in neither window.
        let input = baseInput(
            expectedDepartureHours: [7, 17], currentETA: 40 * 60, now: try at(hour: 12, minute: 0))
        guard case .skip(let reason) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip outside all departure windows"); return
        }
        #expect(reason.contains("approaching"))
    }

    @Test("Combined message carries both the delay minutes and destination")
    func combinedMessageContents() throws {
        let weather = WeatherCondition(severity: .harsh, summary: "Heavy snow", available: true)
        // 20 min typical, 38 min ETA => 18 min over.
        let input = baseInput(
            leadMinutes: 20, currentETA: 38 * 60, weather: weather,
            now: try at(hour: 6, minute: 40), destinationName: "Downtown")
        guard case .notify(let msg, let action, _) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected combined notify"); return
        }
        #expect(action == .combinedDelay)
        #expect(msg.contains("18"))           // delay minutes
        #expect(msg.contains("Downtown"))     // destination
        #expect(msg.lowercased().contains("snow"))
        #expect(!msg.contains("-"))           // never a negative minute
    }

    @Test("Combined with empty weather summary falls back to 'rough weather'")
    func combinedEmptySummaryFallback() throws {
        // Harsh severity but blank summary (defensive: shouldn't happen, but copy must not break).
        let weather = WeatherCondition(severity: .harsh, summary: "", available: true)
        let input = baseInput(leadMinutes: 15, currentETA: 40 * 60, weather: weather, now: try at(hour: 6, minute: 50))
        guard case .notify(let msg, let action, _) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected combined notify"); return
        }
        #expect(action == .combinedDelay)
        #expect(msg.lowercased().contains("rough weather"))
    }

    @Test("Traffic exactly at the 20% threshold and 6-min floor notifies")
    func trafficExactlyAtThreshold() throws {
        // 30 min typical, 36 min ETA => exactly 20% and exactly 6 min over.
        let input = baseInput(currentETA: 36 * 60, typicalDuration: 30 * 60, now: try at(hour: 6, minute: 50))
        guard case .notify(_, let action, _) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected notify at the exact traffic threshold"); return
        }
        #expect(action == .leaveEarly)
    }

    @Test("Traffic at 20% but exactly one minute under the floor skips")
    func trafficAtPercentButUnderFloor() throws {
        // 25 min typical, 30 min ETA => 20% but only 5 min over (< 6 floor).
        let input = baseInput(currentETA: 30 * 60, typicalDuration: 25 * 60, now: try at(hour: 6, minute: 50))
        guard case .skip = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected skip — 5 min is under the 6-min floor"); return
        }
    }

    @Test("Quiet hours hour equal to start is suppressed (inclusive start)")
    func quietHoursInclusiveStart() {
        #expect(CommuteNotificationDecisionEngine.isWithinQuietHours(hour: 22, start: 22, end: 7))
    }

    @Test("Quiet hours hour equal to end is allowed (exclusive end)")
    func quietHoursExclusiveEnd() {
        #expect(!CommuteNotificationDecisionEngine.isWithinQuietHours(hour: 7, start: 22, end: 7))
    }

    @Test("Lead below 15 is clamped up even on a weather-only notify")
    func weatherNotifyClampsLowLead() throws {
        let weather = WeatherCondition(severity: .harsh, summary: "Snow expected", available: true)
        let input = baseInput(leadMinutes: 5, currentETA: nil, weather: weather, now: try at(hour: 6, minute: 50))
        guard case .notify(_, _, let lead) = CommuteNotificationDecisionEngine.evaluate(input) else {
            Issue.record("expected weather notify"); return
        }
        #expect(lead == 15)
    }
}
