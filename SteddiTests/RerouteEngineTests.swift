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
}
