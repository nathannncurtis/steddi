import Testing
@testable import Steddi

@Suite("RerouteEngine")
struct RerouteEngineTests {

    // MARK: - Scaled Threshold

    @Test("Short drive increases threshold ~1.3x")
    func shortDriveIncreasesThreshold() {
        let threshold = RerouteEngine.scaledThreshold(basePercentage: 0.20, remainingMinutes: 5)
        #expect(threshold > 0.25)
        #expect(threshold < 0.32)
    }

    @Test("Medium drive keeps threshold near base")
    func mediumDriveUnchanged() {
        let threshold = RerouteEngine.scaledThreshold(basePercentage: 0.20, remainingMinutes: 30)
        #expect(abs(threshold - 0.20) < 0.02)
    }

    @Test("Long drive decreases threshold")
    func longDriveDecreasesThreshold() {
        let threshold = RerouteEngine.scaledThreshold(basePercentage: 0.20, remainingMinutes: 60)
        #expect(threshold < 0.18)
        #expect(threshold > 0.10)
    }

    @Test("Very long drive floors at ~0.5x")
    func veryLongDriveFloorsAtHalf() {
        let threshold = RerouteEngine.scaledThreshold(basePercentage: 0.20, remainingMinutes: 120)
        #expect(abs(threshold - 0.10) < 0.02)
    }

    @Test("Threshold capped at 80%")
    func thresholdCappedAt80() {
        let threshold = RerouteEngine.scaledThreshold(basePercentage: 0.70, remainingMinutes: 5)
        #expect(threshold <= 0.80)
    }

    @Test("Multiplier is monotonically decreasing with time")
    func multiplierMonotonicallyDecreasing() {
        var previous = RerouteEngine.scaledThreshold(basePercentage: 0.20, remainingMinutes: 1)
        for minutes in stride(from: 5.0, through: 120.0, by: 5.0) {
            let current = RerouteEngine.scaledThreshold(basePercentage: 0.20, remainingMinutes: minutes)
            #expect(current <= previous, "Threshold should decrease as remaining time increases")
            previous = current
        }
    }

    // MARK: - Basic Decisions

    @Test("Fallback slower returns noSavings")
    func fallbackSlower() {
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 1800, fallbackETASeconds: 2000,
            basePercentage: 0.20, hardMinuteFloor: 10
        )
        #expect(!decision.shouldReroute)
        if case .noSavings = decision.reason {} else {
            Issue.record("Expected noSavings reason")
        }
    }

    @Test("Fallback equal returns noSavings")
    func fallbackEqual() {
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 1800, fallbackETASeconds: 1800,
            basePercentage: 0.20, hardMinuteFloor: 10
        )
        #expect(!decision.shouldReroute)
    }

    @Test("Huge savings always reroutes")
    func hugeSavings() {
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 3600, fallbackETASeconds: 1200,
            basePercentage: 0.20, hardMinuteFloor: 10
        )
        #expect(decision.shouldReroute)
    }

    @Test("Tiny savings no reroute")
    func tinySavings() {
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 1800, fallbackETASeconds: 1790,
            basePercentage: 0.20, hardMinuteFloor: 10
        )
        #expect(!decision.shouldReroute)
    }

    // MARK: - Percentage Scaling

    @Test("Short drive 15% savings does not reroute")
    func shortDrive15Pct() {
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 600, fallbackETASeconds: 510,
            basePercentage: 0.20, hardMinuteFloor: nil
        )
        #expect(!decision.shouldReroute)
    }

    @Test("Short drive 40% savings reroutes")
    func shortDrive40Pct() {
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 600, fallbackETASeconds: 360,
            basePercentage: 0.20, hardMinuteFloor: nil
        )
        #expect(decision.shouldReroute)
    }

    @Test("Long drive 11% savings reroutes")
    func longDrive11Pct() {
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 5400, fallbackETASeconds: 4800,
            basePercentage: 0.20, hardMinuteFloor: nil
        )
        #expect(decision.shouldReroute)
    }

    // MARK: - Percentage Overrides Hard Floor

    @Test("Percentage met overrides hard floor")
    func percentageOverridesFloor() {
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 1200, fallbackETASeconds: 600,
            basePercentage: 0.20, hardMinuteFloor: 15
        )
        #expect(decision.shouldReroute)
        if case .percentageThresholdMet = decision.reason {} else {
            Issue.record("Expected percentageThresholdMet reason")
        }
    }

    // MARK: - Hard Floor

    @Test("Hard floor triggers when percentage not met")
    func hardFloorTriggers() {
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 7200, fallbackETASeconds: 6540,
            basePercentage: 0.20, hardMinuteFloor: 10
        )
        #expect(decision.shouldReroute)
        if case .hardFloorMet = decision.reason {} else {
            Issue.record("Expected hardFloorMet reason")
        }
    }

    @Test("No hard floor set, below percentage, no reroute")
    func noHardFloor() {
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 7200, fallbackETASeconds: 6540,
            basePercentage: 0.20, hardMinuteFloor: nil
        )
        #expect(!decision.shouldReroute)
    }

    // MARK: - Edge Cases

    @Test("Zero remaining ETA returns belowThreshold")
    func zeroRemainingETA() {
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 0, fallbackETASeconds: 0,
            basePercentage: 0.20, hardMinuteFloor: 10
        )
        #expect(!decision.shouldReroute)
    }

    @Test("Negative savings returns noSavings")
    func negativeSavings() {
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 600, fallbackETASeconds: 900,
            basePercentage: 0.20, hardMinuteFloor: nil
        )
        #expect(!decision.shouldReroute)
        if case .noSavings = decision.reason {} else {
            Issue.record("Expected noSavings reason")
        }
    }

    @Test("savingsMinutes computed correctly")
    func savingsMinutesComputed() {
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 3600, fallbackETASeconds: 3000,
            basePercentage: 0.20, hardMinuteFloor: nil
        )
        #expect(abs(decision.savingsMinutes - 10.0) < 0.01)
    }

    // MARK: - Absolute-savings / near-arrival floor

    /// THE BUG: on a ~1-min remaining drive, scaledThreshold raises the PERCENTAGE
    /// gate (~0.27) but a percentage of a tiny ETA is only seconds — a ~16s
    /// alternate (well over 27%) cleared the gate and popped a "Save ~1 min" card
    /// seconds before arrival. With less than the near-arrival floor remaining, no
    /// suggestion should surface at all.
    @Test("Tiny saving on a sub-minute remaining drive does not surface a suggestion")
    func tinySavingNearArrivalSuppressed() {
        // 60s remaining, fallback 44s -> 16s saved = ~27% (above scaled 0.27).
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 60, fallbackETASeconds: 44,
            basePercentage: 0.20, hardMinuteFloor: nil
        )
        #expect(!decision.shouldReroute, "no card for a ~16s save right before arrival")
    }

    /// A ~1-min saving (60s) is exactly the misleading-card case the overlay
    /// clamps to "Save ~1 min". On a short remaining drive it must NOT surface,
    /// whether suppressed by the near-arrival floor or the absolute-savings floor.
    @Test("A ~1-min saving on a short remaining drive does not surface a suggestion")
    func oneMinuteSavingOnShortDriveSuppressed() {
        // 150s remaining (2.5 min, below the 3-min near-arrival floor), 60s saved
        // (40% — easily clears the scaled percentage). Must be suppressed.
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 150, fallbackETASeconds: 90,
            basePercentage: 0.20, hardMinuteFloor: nil
        )
        #expect(!decision.shouldReroute, "a ~1-min save just before arrival must not pop a card")
    }

    /// Above the near-arrival floor but still a sub-floor absolute saving: a high
    /// percentage alone must not trigger. 180s remaining (at the near-arrival
    /// floor, so not suppressed by it), 80s saved = ~44% — well over the scaled
    /// percentage gate — but below the 90s absolute floor, so no card.
    @Test("High percentage but sub-floor absolute saving does not reroute")
    func highPctSubFloorAbsoluteSuppressed() {
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 180, fallbackETASeconds: 100,
            basePercentage: 0.20, hardMinuteFloor: nil
        )
        #expect(!decision.shouldReroute, "80s saved is below the absolute floor even at ~44%")
        if case .belowAbsoluteFloor = decision.reason {} else {
            Issue.record("Expected belowAbsoluteFloor reason")
        }
    }

    /// The floor must not over-suppress a genuinely worthwhile reroute: a saving
    /// well above the absolute floor on a drive past the near-arrival window still
    /// triggers. 660s remaining, 480s fallback -> 180s saved = ~27% on an 11-min
    /// drive (clears the scaled gate) and 180s >= the 90s absolute floor.
    @Test("A clearly-good saving past the near-arrival window still reroutes")
    func savingAboveFloorStillReroutes() {
        let decision = RerouteEngine.evaluate(
            remainingETASeconds: 660, fallbackETASeconds: 480,
            basePercentage: 0.20, hardMinuteFloor: nil
        )
        #expect(decision.shouldReroute, "a 3-min, ~27% saving past the near-arrival window must still reroute")
        if case .percentageThresholdMet = decision.reason {} else {
            Issue.record("Expected percentageThresholdMet reason")
        }
    }
}
