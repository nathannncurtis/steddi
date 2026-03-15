import Foundation
import CoreLocation

/// Core reroute decision engine.
/// Evaluates whether a fallback route should be suggested based on
/// the user's threshold settings and current remaining ETA.
struct RerouteEngine {

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

        let remainingMinutes = remainingETASeconds / 60.0
        let savingsMinutes = savingsSeconds / 60.0

        // Scale the percentage threshold based on remaining drive duration.
        // Shorter remaining drives need higher % to trigger (you're almost there).
        // Longer remaining drives use lower % (small % = large absolute time).
        let scaledPercentage = scaledThreshold(
            basePercentage: basePercentage,
            remainingMinutes: remainingMinutes
        )

        let actualPercentage = savingsSeconds / remainingETASeconds

        // Percentage threshold met — always suggest, regardless of hard floor
        if actualPercentage >= scaledPercentage {
            return RerouteDecision(
                shouldReroute: true,
                savingsSeconds: savingsSeconds,
                reason: .percentageThresholdMet(actual: actualPercentage, threshold: scaledPercentage)
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
}
