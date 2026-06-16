import Foundation
import CoreLocation

/// Core reroute decision engine.
/// Evaluates whether a fallback route should be suggested based on
/// the user's threshold settings and current remaining ETA.
struct RerouteEngine {

    /// Absolute-savings floor for the percentage gate. `scaledThreshold` only
    /// raises the PERCENTAGE needed on short drives — but a percentage of a tiny
    /// remaining ETA collapses to seconds, so a ~15-30s alternate can clear the
    /// gate seconds before arrival and pop a "Save ~1 min" card (the overlay
    /// clamps the displayed savings up to a full minute) right when a reroute is
    /// least useful. Require a real saving — never suggest a reroute for less than
    /// this no matter how high the percentage — so a sub-minute delta can't surface
    /// a card. The long-drive `hardMinuteFloor` is a far larger, separate gate.
    static let minPercentageSavingsSeconds: TimeInterval = 90 // 1.5 min

    /// Near-arrival suppression floor. With less remaining than this you're on
    /// final approach; a reroute can't meaningfully help and only distracts, so
    /// suppress suggestions entirely regardless of percentage or absolute savings.
    static let minRemainingForRerouteSeconds: TimeInterval = 180 // 3 min

    /// Determines if a reroute should be suggested.
    ///
    /// The threshold is percentage-based with intelligent scaling:
    /// - Short drives need a higher percentage saved to trigger (you're almost there anyway)
    /// - Long drives use a lower percentage (small % = big absolute time)
    /// - The percentage is always evaluated against REMAINING ETA, not original trip duration
    /// - Hard minute floor is overridden if percentage threshold is met
    ///   (saving 50% of a 20-min remaining drive = 10 min, should always trigger)
    ///
    /// - Parameters:
    ///   - remainingETASeconds: Current ETA on the active route from current position
    ///   - fallbackETASeconds: ETA via the fallback route from current position
    ///   - basePercentage: User's configured sensitivity (e.g., 0.20 = 20%)
    ///   - hardMinuteFloor: Optional hard minute minimum for long drives (e.g., 10)
    /// - Returns: A `RerouteDecision` with the recommendation and reasoning
    static func evaluate(
        remainingETASeconds: TimeInterval,
        fallbackETASeconds: TimeInterval,
        basePercentage: Double,
        hardMinuteFloor: Int?
    ) -> RerouteDecision {
        let savingsSeconds = remainingETASeconds - fallbackETASeconds

        // No savings or fallback is slower — never suggest
        guard savingsSeconds > 0 else {
            return RerouteDecision(shouldReroute: false, savingsSeconds: savingsSeconds, reason: .noSavings)
        }

        // Near-arrival suppression: with only a few minutes left you're on final
        // approach; no reroute is worth the distraction, and a tiny absolute
        // saving here is exactly what pops a pointless "Save ~1 min" card right
        // before arrival. Gate it out before any percentage/floor evaluation.
        guard remainingETASeconds >= minRemainingForRerouteSeconds else {
            return RerouteDecision(
                shouldReroute: false,
                savingsSeconds: savingsSeconds,
                reason: .belowAbsoluteFloor(savingsSeconds: savingsSeconds)
            )
        }

        let remainingMinutes = remainingETASeconds / 60.0
        let savingsMinutes = savingsSeconds / 60.0

        // Scale the percentage threshold based on remaining drive duration.
        // Shorter remaining drives need higher % to trigger (you're almost there).
        // Longer remaining drives use lower % (small % = large absolute time).
        let scaledPercentage = scaledThreshold(
            basePercentage: basePercentage,
            remainingMinutes: remainingMinutes
        )

        // No division-by-zero guard needed: savingsSeconds > 0 above means
        // remainingETASeconds > fallbackETASeconds >= 0, so it's strictly positive.
        let actualPercentage = savingsSeconds / remainingETASeconds

        // Percentage threshold met AND the saving clears the absolute floor —
        // suggest, regardless of hard floor. The absolute floor stops a high
        // percentage of a small remaining ETA (e.g. 27% of a 1-min drive ≈ 16s)
        // from surfacing a card for a sub-minute delta.
        if actualPercentage >= scaledPercentage && savingsSeconds >= minPercentageSavingsSeconds {
            return RerouteDecision(
                shouldReroute: true,
                savingsSeconds: savingsSeconds,
                reason: .percentageThresholdMet(actual: actualPercentage, threshold: scaledPercentage)
            )
        }

        // Percentage met but the absolute saving is below the floor — don't pop a
        // low-value card. (Distinct from .belowThreshold so the reason is honest.)
        if actualPercentage >= scaledPercentage {
            return RerouteDecision(
                shouldReroute: false,
                savingsSeconds: savingsSeconds,
                reason: .belowAbsoluteFloor(savingsSeconds: savingsSeconds)
            )
        }

        // Percentage not met — check hard minute floor as secondary gate for long drives
        if let floor = hardMinuteFloor, savingsMinutes >= Double(floor) {
            return RerouteDecision(
                shouldReroute: true,
                savingsSeconds: savingsSeconds,
                reason: .hardFloorMet(savingsMinutes: savingsMinutes, floor: Double(floor))
            )
        }

        return RerouteDecision(
            shouldReroute: false,
            savingsSeconds: savingsSeconds,
            reason: .belowThreshold(actual: actualPercentage, threshold: scaledPercentage)
        )
    }

    /// Scales the base percentage threshold based on remaining drive time.
    ///
    /// The curve:
    /// - Very short drives (< 10 min): threshold increases up to 1.5x base
    ///   (you're almost there, don't bother rerouting unless huge savings)
    /// - Medium drives (10-30 min): threshold stays near base
    /// - Long drives (30-90 min): threshold decreases to ~0.7x base
    /// - Very long drives (90+ min): threshold floors at ~0.5x base
    ///
    /// Uses a smooth sigmoid-like curve so there are no hard breakpoints.
    static func scaledThreshold(basePercentage: Double, remainingMinutes: Double) -> Double {
        // Logistic scaling centered around 30 minutes
        // At 30 min, multiplier ≈ 1.0 (base percentage unchanged)
        // Below 30 min, multiplier increases (harder to trigger)
        // Above 30 min, multiplier decreases (easier to trigger)
        let midpoint: Double = 30.0
        let steepness: Double = 0.06

        // Sigmoid maps remaining time to a 0.5...1.5 multiplier range
        let sigmoid = 1.0 / (1.0 + exp(steepness * (remainingMinutes - midpoint)))
        let multiplier = 0.5 + sigmoid // Range: ~0.5 (long) to ~1.5 (short)

        return min(basePercentage * multiplier, 0.80) // Cap at 80% — always allow reroute if savings > 80%
    }
}

struct RerouteDecision {
    let shouldReroute: Bool
    let savingsSeconds: TimeInterval
    let reason: RerouteReason

    var savingsMinutes: Double { savingsSeconds / 60.0 }
}

enum RerouteReason {
    case noSavings
    case percentageThresholdMet(actual: Double, threshold: Double)
    case hardFloorMet(savingsMinutes: Double, floor: Double)
    case belowThreshold(actual: Double, threshold: Double)
    /// Savings cleared the percentage gate (or the drive is on final approach)
    /// but the absolute saving / remaining time is too small to be worth a card.
    case belowAbsoluteFloor(savingsSeconds: TimeInterval)
}
