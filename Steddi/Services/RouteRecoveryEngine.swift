import Foundation
import CoreLocation

/// A contiguous stretch of the saved route that carries the route's intent —
/// a freeway leg, a long arterial run — as opposed to micro waypoints (a
/// specific drawn turn) that matter less when recovering from a deviation.
struct MacroLeg {
    let entryCoordinate: CLLocationCoordinate2D
    let entryAlongDistance: Double
    let exitAlongDistance: Double
    let name: String
}

/// A forward point on the saved route worth routing back to.
struct RejoinCandidate {
    enum Kind { case macroLegEntry, nextManeuver, lookAhead, destination }
    let coordinate: CLLocationCoordinate2D
    let alongDistance: Double
    let kind: Kind
}

/// A fetched recovery route to one candidate, reduced to what scoring needs.
struct RecoveryOption {
    let candidateIndex: Int
    let etaSeconds: TimeInterval
    /// Bearing of the recovery route's first ~75m, for reversal detection.
    let initialBearingDegrees: Double?
    /// True when the first steps read as a U-turn.
    let beginsWithUTurn: Bool
}

enum RecoveryDecision: Equatable {
    case rejoin(candidateIndex: Int)
    case abandonToDestination
}

/// Pure decision logic for off-route recovery. No networking, no MapKit
/// requests — shaped like RerouteEngine so every rule is unit-testable.
///
/// The owner's spec: find a FORWARD rejoin target, weight macro legs over
/// micro waypoints, never default to a U-turn, and never gate recovery behind
/// the opportunistic time-savings threshold.
enum RouteRecoveryEngine {

    /// Base forward offset for rejoin candidates; grows with speed so a
    /// freeway deviation aims further ahead.
    static func minForwardOffset(speedMPS: Double) -> Double {
        max(250, speedMPS * 30)
    }

    // MARK: - Macro Leg Classification

    /// Instruction patterns that read as highway/freeway intent.
    private static let macroPatterns = [
        "merge", "freeway", "fwy", "highway", "hwy", "interstate",
        "i-", "ca-", "sr-", "us-", "ramp", "exit",
    ]
    /// Steps at least this long carry macro intent regardless of wording
    /// (covers nameless CustomRouteBuilder geometry steps).
    static let macroDistanceFloor: Double = 1500

    static func isMacroStep(_ step: NavStep) -> Bool {
        if step.distance >= macroDistanceFloor { return true }
        let lower = step.instruction.lowercased()
        return macroPatterns.contains { lower.contains($0) }
    }

    /// Merge consecutive macro steps into legs, positioned by arc length.
    /// `alongDistances` must align 1:1 with `steps` (step start positions).
    static func classifyLegs(
        steps: [NavStep],
        alongDistances: [Double],
        totalDistance: Double
    ) -> [MacroLeg] {
        guard steps.count == alongDistances.count, !steps.isEmpty else { return [] }
        var legs: [MacroLeg] = []
        var openEntry: (coordinate: CLLocationCoordinate2D, along: Double, name: String)?

        for (i, step) in steps.enumerated() {
            let along = alongDistances[i]
            let exit = i + 1 < alongDistances.count ? alongDistances[i + 1] : totalDistance
            if isMacroStep(step) {
                if openEntry == nil {
                    openEntry = (step.coordinate, along, step.instruction)
                }
                if i == steps.count - 1, let entry = openEntry {
                    legs.append(MacroLeg(entryCoordinate: entry.coordinate, entryAlongDistance: entry.along, exitAlongDistance: exit, name: entry.name))
                    openEntry = nil
                }
            } else if let entry = openEntry {
                legs.append(MacroLeg(entryCoordinate: entry.coordinate, entryAlongDistance: entry.along, exitAlongDistance: along, name: entry.name))
                openEntry = nil
            }
        }
        return legs
    }

    // MARK: - Rejoin Candidates

    /// Up to 4 candidates, all strictly FORWARD of the deviation point —
    /// U-turns can't be the default because nothing behind the driver is
    /// ever offered. The destination is always the final fallback candidate.
    static func rejoinCandidates(
        event: OffRouteEvent,
        legs: [MacroLeg],
        steps: [NavStep],
        alongDistances: [Double],
        polyline: [CLLocationCoordinate2D],
        totalDistance: Double
    ) -> [RejoinCandidate] {
        // No polyline means no destination fallback and no look-ahead — the
        // docstring's "destination is always present" guarantee can't be met, so
        // return nothing rather than emit candidates with no geometry to anchor.
        guard !polyline.isEmpty else { return [] }

        let floorAlong = event.distanceAlongRoute + minForwardOffset(speedMPS: event.speedMPS)
        var candidates: [RejoinCandidate] = []

        // 1. Entry of the nearest macro leg at/ahead of the deviation —
        //    "get on the freeway going the right way" beats every drawn turn
        //    before it. A leg we're already inside counts via its exit.
        if let leg = legs.first(where: { $0.entryAlongDistance >= floorAlong }) {
            candidates.append(RejoinCandidate(coordinate: leg.entryCoordinate, alongDistance: leg.entryAlongDistance, kind: .macroLegEntry))
        }

        // 2. Next maneuver far enough ahead.
        if steps.count == alongDistances.count,
           let idx = alongDistances.firstIndex(where: { $0 >= floorAlong }),
           idx < steps.count {
            candidates.append(RejoinCandidate(coordinate: steps[idx].coordinate, alongDistance: alongDistances[idx], kind: .nextManeuver))
        }

        // 3. Pure look-ahead point on the polyline.
        let lookAhead = event.distanceAlongRoute + max(500, event.speedMPS * 60)
        if lookAhead < totalDistance,
           let coord = RouteGeometry.coordinate(
               atDistance: lookAhead,
               polyline: polyline,
               cumulative: RouteGeometry.cumulativeDistances(polyline)
           ) {
            candidates.append(RejoinCandidate(coordinate: coord, alongDistance: lookAhead, kind: .lookAhead))
        }

        // 4. Destination — the give-up candidate, always present.
        if let dest = polyline.last {
            candidates.append(RejoinCandidate(coordinate: dest, alongDistance: totalDistance, kind: .destination))
        }

        // Forward-only invariant, dedupe near-identical along positions, cap 4.
        var seen: [Double] = []
        return candidates
            .filter { $0.alongDistance >= floorAlong || $0.kind == .destination }
            .filter { candidate in
                if seen.contains(where: { abs($0 - candidate.alongDistance) < 100 }) { return false }
                seen.append(candidate.alongDistance)
                return true
            }
            .prefix(4)
            .map { $0 }
    }

    // MARK: - Scoring

    /// Penalty ramp for setting off opposite to the current course: zero at
    /// <=60 degrees, ~600s at >=150 degrees. Disabled at crawl speed where
    /// GPS course is noise.
    static func reversalPenalty(courseDegrees: Double?, initialBearing: Double?, speedMPS: Double) -> TimeInterval {
        guard speedMPS >= 3, let course = courseDegrees, let bearing = initialBearing else { return 0 }
        var delta = abs(course - bearing).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta = 360 - delta }
        guard delta > 60 else { return 0 }
        return min(600, (delta - 60) / 90 * 600)
    }

    static let uTurnTextPenalty: TimeInterval = 900

    /// Remaining saved-route time from a rejoin point, prorated from the
    /// route's own typical duration — no extra network.
    static func proratedRemainingETA(
        fromAlong along: Double,
        totalDistance: Double,
        expectedTravelTime: TimeInterval
    ) -> TimeInterval {
        guard totalDistance > 0 else { return 0 }
        let remainingFraction = max(0, 1 - along / totalDistance)
        return expectedTravelTime * remainingFraction
    }

    /// Pick the recovery target. `options` must reference `candidates` by
    /// index; absent options (failed fetches) are simply not considered.
    static func choose(
        candidates: [RejoinCandidate],
        options: [RecoveryOption],
        event: OffRouteEvent,
        totalDistance: Double,
        expectedTravelTime: TimeInterval,
        recoveriesThisTrip: Int
    ) -> RecoveryDecision {
        guard !options.isEmpty else { return .abandonToDestination }

        // Driver clearly improvising — stop fighting for the saved route.
        if recoveriesThisTrip >= 3 { return .abandonToDestination }

        var bestIndex: Int?
        var bestScore = Double.greatestFiniteMagnitude
        var destinationScore = Double.greatestFiniteMagnitude

        for option in options {
            guard option.candidateIndex < candidates.count else { continue }
            let candidate = candidates[option.candidateIndex]
            var score = option.etaSeconds
                + proratedRemainingETA(fromAlong: candidate.alongDistance, totalDistance: totalDistance, expectedTravelTime: expectedTravelTime)
                + reversalPenalty(courseDegrees: event.courseDegrees, initialBearing: option.initialBearingDegrees, speedMPS: event.speedMPS)
            if option.beginsWithUTurn { score += uTurnTextPenalty }

            if candidate.kind == .destination {
                destinationScore = min(destinationScore, score)
                continue
            }

            // Rejoining within the final stretch isn't worth the detour.
            let nearEnd = candidate.alongDistance > totalDistance - max(1000, totalDistance * 0.15)
            if nearEnd { continue }

            if score < bestScore {
                bestScore = score
                bestIndex = option.candidateIndex
            }
        }

        guard let bestIndex else { return .abandonToDestination }

        // Give-up rule: the best rejoin must beat going direct by enough.
        if destinationScore < .greatestFiniteMagnitude,
           bestScore > destinationScore * 1.2 + 180 {
            return .abandonToDestination
        }
        return .rejoin(candidateIndex: bestIndex)
    }
}
