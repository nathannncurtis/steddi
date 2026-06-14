import Testing
import Foundation
import CoreLocation
@testable import Steddi

// Hardening tests for PrefLearner's admissibility invariant (multipliers >= 1,
// penalties >= 0) and clamping under ADVERSARIAL inputs — extreme configs, hostile
// seeds, and degenerate usages that try to push the learner out of bounds. These
// complement PreferenceLearnerTests by attacking the bound logic directly rather
// than via realistic traces.

// MARK: - Helpers

private func usage(
    metersByClass: [RoadClass: Double],
    turns: [TurnDirection: Int] = [:],
    available: Set<RoadClass> = [],
    drives: Int = 50
) -> PrefLearner.RevealedUsage {
    var u = PrefLearner.RevealedUsage()
    u.usableDrives = drives
    u.metersByClass = metersByClass
    u.turnCounts = turns
    u.availableClasses = available
    return u
}

private func assertAdmissible(_ w: CostWeights, _ comment: Comment) {
    for (i, m) in w.roadClassMultiplier.enumerated() {
        #expect(m >= 1.0, "roadClassMultiplier[\(i)] = \(m) violated >= 1; \(comment)")
        #expect(m.isFinite, "roadClassMultiplier[\(i)] = \(m) not finite; \(comment)")
    }
    #expect(w.rightTurnPenalty >= 0, comment)
    #expect(w.protectedLeftPenalty >= 0, comment)
    #expect(w.unprotectedLeftBase >= 0, comment)
    #expect(w.unprotectedLeftPerOncomingLane >= 0, comment)
    #expect(w.uTurnPenalty >= 0, comment)
    #expect(w.stopSignPenalty >= 0, comment)
    #expect(w.trafficSignalPenalty >= 0, comment)
    #expect(w.straightPenalty >= 0, comment)
    #expect(w.rightTurnPenalty.isFinite, comment)
    #expect(w.unprotectedLeftBase.isFinite, comment)
}

@Suite("PrefLearner admissibility holds under adversarial inputs")
struct PrefLearnerInvariantHardeningTests {

    // MARK: - Extreme configs cannot break the invariant

    @Test("Absurdly large maxClassDiscount can't push any multiplier below 1")
    func hugeDiscountStillFlooredAtOne() {
        // A driver who lives on service roads + a config that "wants" a -50 discount.
        let u = usage(metersByClass: [.service: 100000, .motorway: 1],
                      available: [.service, .motorway, .primary, .residential])
        let cfg = PrefLearner.Config(
            minimumDrives: 1, learningRate: 1.0,
            maxClassDiscount: 50, maxClassPenalty: 50, maxTurnDelta: 50)
        let w = PrefLearner.weights(from: u, seed: .default, config: cfg)
        assertAdmissible(w, "huge discount config")
        // The heavily favoured class is floored at exactly 1.0 (can't go lower).
        #expect(w.roadClassMultiplier[Int(RoadClass.service.rawValue)] == 1.0)
    }

    @Test("Absurd maxTurnDelta with learningRate 1 keeps penalties >= 0 and finite")
    func extremeTurnDeltaBounded() {
        let u = usage(metersByClass: [.primary: 1000],
                      turns: [.left: 1000, .right: 1, .uTurn: 1])
        let cfg = PrefLearner.Config(
            minimumDrives: 1, learningRate: 1.0,
            maxTurnDelta: 100)   // would try to slash penalties far past 0
        let w = PrefLearner.weights(from: u, seed: .default, config: cfg)
        assertAdmissible(w, "extreme turn delta")
    }

    @Test("learningRate 0 returns the seed exactly (no movement)")
    func zeroLearningRateNoOp() {
        let u = usage(metersByClass: [.tertiary: 9000, .primary: 1000],
                      turns: [.right: 10, .left: 1],
                      available: [.tertiary, .primary])
        let cfg = PrefLearner.Config(minimumDrives: 1, learningRate: 0)
        let w = PrefLearner.weights(from: u, seed: .default, config: cfg)
        #expect(w == CostWeights.default)
    }

    // MARK: - Hostile seeds are sanitised, never amplified

    @Test("A seed that itself violates the invariant is repaired to >= 1, never worsened")
    func hostileSeedMultiplierRepaired() {
        // Construct an inadmissible seed (a multiplier < 1) — the learner must NEVER
        // emit a multiplier < 1 even if the seed it learns from is broken.
        var badSeed = CostWeights.default
        badSeed.roadClassMultiplier[Int(RoadClass.tertiary.rawValue)] = 0.3   // illegal
        // Driver favours tertiary, which (favoured branch) would discount further.
        let u = usage(metersByClass: [.tertiary: 9000, .primary: 1000],
                      available: [.tertiary, .primary])
        let cfg = PrefLearner.Config(minimumDrives: 1, learningRate: 1.0, maxClassDiscount: 5)
        let w = PrefLearner.weights(from: u, seed: badSeed, config: cfg)
        // Output is floored at 1.0 regardless of the broken seed.
        #expect(w.roadClassMultiplier[Int(RoadClass.tertiary.rawValue)] >= 1.0)
        for m in w.roadClassMultiplier { #expect(m >= 1.0) }
    }

    @Test("A seed with a negative turn penalty is repaired to >= 0")
    func hostileSeedPenaltyRepaired() {
        var badSeed = CostWeights.default
        badSeed.rightTurnPenalty = -100   // illegal
        let u = usage(metersByClass: [.primary: 1000],
                      turns: [.right: 100, .left: 1])
        let cfg = PrefLearner.Config(minimumDrives: 1, learningRate: 1.0, maxTurnDelta: 2)
        let w = PrefLearner.weights(from: u, seed: badSeed, config: cfg)
        #expect(w.rightTurnPenalty >= 0)
    }

    // MARK: - Degenerate / single-class usages

    @Test("Single available class, single driven class => still admissible, no NaN")
    func singleClassNoNaN() {
        let u = usage(metersByClass: [.tertiary: 5000], available: [.tertiary])
        let w = PrefLearner.weights(from: u, seed: .default)
        assertAdmissible(w, "single class")
    }

    @Test("Zero total meters with >= minimumDrives => seed unchanged (guard holds)")
    func zeroMetersGuard() {
        // usableDrives high but no class distance recorded (all sub-minSegment).
        let u = usage(metersByClass: [:], turns: [:], drives: 99)
        let w = PrefLearner.weights(from: u, seed: .default)
        #expect(w == CostWeights.default)
    }

    @Test("A class index beyond the multiplier array is ignored, not a crash/OOB")
    func outOfRangeClassIgnored() {
        // unknown (255) must never index into the 10-slot multiplier array.
        var u = usage(metersByClass: [.tertiary: 1000], available: [.tertiary])
        u.metersByClass[.unknown] = 9_000_000   // adversarial: huge unknown distance
        let w = PrefLearner.weights(from: u, seed: .default)
        assertAdmissible(w, "unknown class present")
        #expect(w.roadClassMultiplier.count == CostWeights.default.roadClassMultiplier.count)
    }

    // MARK: - Stability: learning is idempotent-ish under re-feeding

    @Test("Re-learning from an already-learned seed stays bounded (no runaway)")
    func incrementalRefinementStaysBounded() {
        let u = usage(metersByClass: [.tertiary: 9000, .primary: 1000],
                      turns: [.right: 20, .left: 2],
                      available: [.tertiary, .primary, .secondary])
        var w = CostWeights.default
        // Feed the learner its own output 10 times — a misbehaving learner would
        // drift the multiplier below 1 or blow penalties up; this must converge in band.
        for _ in 0..<10 {
            w = PrefLearner.weights(from: u, seed: w)
            assertAdmissible(w, "incremental round")
        }
        let tertiary = w.roadClassMultiplier[Int(RoadClass.tertiary.rawValue)]
        #expect(tertiary >= 1.0)
    }
}
