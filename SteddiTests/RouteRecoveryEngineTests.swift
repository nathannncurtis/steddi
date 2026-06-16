import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - Helpers

private func step(_ instruction: String, distance: Double, lat: Double, lon: Double = -117.0) -> NavStep {
    NavStep(instruction: instruction, distance: distance, coordinate: .init(latitude: lat, longitude: lon), maneuverSymbol: "arrow.up")
}

private func event(
    along: Double,
    course: Double? = nil,
    speed: Double = 13
) -> OffRouteEvent {
    OffRouteEvent(
        coordinate: .init(latitude: 33.0, longitude: -117.001),
        courseDegrees: course,
        speedMPS: speed,
        distanceAlongRoute: along,
        currentStepIndex: 0
    )
}

/// Straight 10km route north with ~111m vertices.
private let straightPolyline: [CLLocationCoordinate2D] =
    (0...90).map { .init(latitude: 33.0 + Double($0) * 0.001, longitude: -117.0) }

// MARK: - Macro Classification

@Suite("RouteRecoveryEngine.classifyLegs")
struct ClassifyLegsTests {

    @Test("Freeway instructions classify as macro")
    func freewayIsMacro() {
        #expect(RouteRecoveryEngine.isMacroStep(step("Merge onto I-10 West", distance: 300, lat: 33)))
        #expect(RouteRecoveryEngine.isMacroStep(step("Take the ramp toward CA-91", distance: 200, lat: 33)))
    }

    @Test("Short surface turns are micro")
    func surfaceTurnIsMicro() {
        #expect(!RouteRecoveryEngine.isMacroStep(step("Turn left onto Elm St", distance: 200, lat: 33)))
    }

    @Test("Nameless long steps classify macro by distance")
    func longStepIsMacro() {
        #expect(RouteRecoveryEngine.isMacroStep(step("Continue straight", distance: 2000, lat: 33)))
    }

    @Test("Consecutive macro steps merge into one leg")
    func consecutiveMerge() {
        let steps = [
            step("Head north", distance: 400, lat: 33.000),
            step("Merge onto I-215 N", distance: 3000, lat: 33.004),
            step("Continue on I-215 N", distance: 4000, lat: 33.031),
            step("Exit toward Main St", distance: 300, lat: 33.067),
            step("Turn right onto Main St", distance: 200, lat: 33.070),
        ]
        let alongs = [0.0, 444.0, 3444.0, 7444.0, 7777.0]
        let legs = RouteRecoveryEngine.classifyLegs(steps: steps, alongDistances: alongs, totalDistance: 8000)
        // merge + continue + exit are one contiguous macro run
        #expect(legs.count == 1)
        #expect(legs[0].entryAlongDistance == 444.0)
        #expect(legs[0].name.contains("I-215"))
    }
}

// MARK: - Rejoin Candidates

@Suite("RouteRecoveryEngine.rejoinCandidates")
struct RejoinCandidatesTests {

    @Test("Every candidate is forward of the deviation point")
    func forwardOnlyInvariant() {
        let steps = (0..<9).map { step("Turn \($0)", distance: 1000, lat: 33.0 + Double($0) * 0.01) }
        let alongs = (0..<9).map { Double($0) * 1111.0 }
        let ev = event(along: 4000)
        let candidates = RouteRecoveryEngine.rejoinCandidates(
            event: ev, legs: [], steps: steps, alongDistances: alongs,
            polyline: straightPolyline, totalDistance: 10000
        )
        let floorAlong = ev.distanceAlongRoute + RouteRecoveryEngine.minForwardOffset(speedMPS: ev.speedMPS)
        for candidate in candidates where candidate.kind != .destination {
            #expect(candidate.alongDistance >= floorAlong)
        }
        #expect(candidates.contains { $0.kind == .destination })
    }

    @Test("Macro leg entry ahead beats intervening micro steps")
    func macroLegPreferred() {
        let legs = [MacroLeg(entryCoordinate: .init(latitude: 33.06, longitude: -117), entryAlongDistance: 6666, exitAlongDistance: 9500, name: "Merge onto I-10")]
        let steps = (0..<9).map { step("Turn \($0)", distance: 1000, lat: 33.0 + Double($0) * 0.01) }
        let alongs = (0..<9).map { Double($0) * 1111.0 }
        let candidates = RouteRecoveryEngine.rejoinCandidates(
            event: event(along: 4000), legs: legs, steps: steps, alongDistances: alongs,
            polyline: straightPolyline, totalDistance: 10000
        )
        #expect(candidates.first?.kind == .macroLegEntry)
        #expect(candidates.first?.alongDistance == 6666)
    }

    @Test("Deviation near the end yields only the destination")
    func endgameOnlyDestination() {
        let steps = [step("Arrive", distance: 0, lat: 33.09)]
        let alongs = [9900.0]
        let candidates = RouteRecoveryEngine.rejoinCandidates(
            event: event(along: 9700), legs: [], steps: steps, alongDistances: alongs,
            polyline: straightPolyline, totalDistance: 10000
        )
        #expect(candidates.allSatisfy { $0.kind == .destination })
    }

    @Test("Faster deviations aim further ahead")
    func speedScalesOffset() {
        #expect(RouteRecoveryEngine.minForwardOffset(speedMPS: 5) == 250)
        #expect(RouteRecoveryEngine.minForwardOffset(speedMPS: 30) == 900)
    }

    @Test("Destination survives a near-end look-ahead that lands within the dedupe window")
    func destinationNotDedupedByNearEndLookAhead() {
        // Deviation late on a 10km route: distanceAlong 9170, speed 13 →
        //   floorAlong = 9170 + max(250, 13*30=390) = 9560
        //   lookAhead  = 9170 + max(500, 13*60=780) = 9950  (passes the forward
        //               filter and sits within 100m of totalDistance 10000).
        // The lookAhead candidate is appended before the destination and recorded
        // in `seen`; pre-fix the dedupe then dropped the destination because
        // abs(9950 - 10000) = 50 < 100, silently disabling abandon-to-destination.
        // The destination must remain present regardless.
        let candidates = RouteRecoveryEngine.rejoinCandidates(
            event: event(along: 9170, speed: 13), legs: [], steps: [], alongDistances: [],
            polyline: straightPolyline, totalDistance: 10000
        )
        #expect(candidates.contains { $0.kind == .destination },
                "destination give-up candidate must never be deduped away by a near-end look-ahead")
        #expect(candidates.contains { $0.kind == .lookAhead },
                "sanity: the near-end look-ahead that triggers the collision is present")
        // The destination must anchor at totalDistance, not be replaced by lookAhead.
        #expect(candidates.first { $0.kind == .destination }?.alongDistance == 10000)
    }
}

// MARK: - Scoring & Choice

@Suite("RouteRecoveryEngine.choose")
struct ChooseTests {

    private let candidates = [
        RejoinCandidate(coordinate: .init(latitude: 33.05, longitude: -117), alongDistance: 5000, kind: .macroLegEntry),
        RejoinCandidate(coordinate: .init(latitude: 33.09, longitude: -117), alongDistance: 10000, kind: .destination),
    ]

    @Test("Forward-aligned candidate wins despite slightly longer ETA")
    func reversalLoses() {
        let cands = [
            RejoinCandidate(coordinate: .init(latitude: 33.05, longitude: -117), alongDistance: 5000, kind: .macroLegEntry),
            RejoinCandidate(coordinate: .init(latitude: 33.055, longitude: -117), alongDistance: 5500, kind: .nextManeuver),
            RejoinCandidate(coordinate: .init(latitude: 33.09, longitude: -117), alongDistance: 10000, kind: .destination),
        ]
        // option 0: shorter ETA but its route sets off opposite the course
        let options = [
            RecoveryOption(candidateIndex: 0, etaSeconds: 240, initialBearingDegrees: 180, beginsWithUTurn: false),
            RecoveryOption(candidateIndex: 1, etaSeconds: 320, initialBearingDegrees: 10, beginsWithUTurn: false),
        ]
        let decision = RouteRecoveryEngine.choose(
            candidates: cands, options: options, event: event(along: 4000, course: 0, speed: 13),
            totalDistance: 10000, expectedTravelTime: 900, recoveriesThisTrip: 0
        )
        #expect(decision == .rejoin(candidateIndex: 1))
    }

    @Test("U-turn first step carries a hard penalty")
    func uTurnPenalized() {
        let cands = candidates + [RejoinCandidate(coordinate: .init(latitude: 33.06, longitude: -117), alongDistance: 6000, kind: .nextManeuver)]
        let options = [
            RecoveryOption(candidateIndex: 0, etaSeconds: 200, initialBearingDegrees: nil, beginsWithUTurn: true),
            RecoveryOption(candidateIndex: 2, etaSeconds: 500, initialBearingDegrees: nil, beginsWithUTurn: false),
        ]
        let decision = RouteRecoveryEngine.choose(
            candidates: cands, options: options, event: event(along: 4000),
            totalDistance: 10000, expectedTravelTime: 900, recoveriesThisTrip: 0
        )
        #expect(decision == .rejoin(candidateIndex: 2))
    }

    @Test("Crawl speed disables the bearing penalty")
    func crawlSkipsBearingPenalty() {
        #expect(RouteRecoveryEngine.reversalPenalty(courseDegrees: 0, initialBearing: 180, speedMPS: 1.5) == 0)
        #expect(RouteRecoveryEngine.reversalPenalty(courseDegrees: 0, initialBearing: 180, speedMPS: 13) > 0)
    }

    @Test("Penalty ramps from 60 to 150 degrees")
    func penaltyRamp() {
        #expect(RouteRecoveryEngine.reversalPenalty(courseDegrees: 0, initialBearing: 50, speedMPS: 13) == 0)
        let mid = RouteRecoveryEngine.reversalPenalty(courseDegrees: 0, initialBearing: 105, speedMPS: 13)
        #expect(mid > 0 && mid < 600)
        #expect(RouteRecoveryEngine.reversalPenalty(courseDegrees: 0, initialBearing: 170, speedMPS: 13) == 600)
    }

    @Test("Give-up when rejoin costs far more than going direct")
    func giveUpOnExpensiveRejoin() {
        let options = [
            RecoveryOption(candidateIndex: 0, etaSeconds: 1500, initialBearingDegrees: nil, beginsWithUTurn: false),
            RecoveryOption(candidateIndex: 1, etaSeconds: 400, initialBearingDegrees: nil, beginsWithUTurn: false),
        ]
        let decision = RouteRecoveryEngine.choose(
            candidates: candidates, options: options, event: event(along: 4000),
            totalDistance: 10000, expectedTravelTime: 900, recoveriesThisTrip: 0
        )
        #expect(decision == .abandonToDestination)
    }

    @Test("Third recovery of the trip stops fighting the driver")
    func improvisingDriverWins() {
        let options = [RecoveryOption(candidateIndex: 0, etaSeconds: 200, initialBearingDegrees: nil, beginsWithUTurn: false)]
        let decision = RouteRecoveryEngine.choose(
            candidates: candidates, options: options, event: event(along: 4000),
            totalDistance: 10000, expectedTravelTime: 900, recoveriesThisTrip: 3
        )
        #expect(decision == .abandonToDestination)
    }

    @Test("No options means abandon")
    func noOptionsAbandons() {
        let decision = RouteRecoveryEngine.choose(
            candidates: candidates, options: [], event: event(along: 4000),
            totalDistance: 10000, expectedTravelTime: 900, recoveriesThisTrip: 0
        )
        #expect(decision == .abandonToDestination)
    }

    @Test("Prorated remaining ETA scales with rejoin position")
    func proratedRemaining() {
        #expect(RouteRecoveryEngine.proratedRemainingETA(fromAlong: 5000, totalDistance: 10000, expectedTravelTime: 1000) == 500)
        #expect(RouteRecoveryEngine.proratedRemainingETA(fromAlong: 10000, totalDistance: 10000, expectedTravelTime: 1000) == 0)
    }
}

// MARK: - Abandon-retry prompt budget (HomeView nag guard)

/// Regression guard for the MEDIUM bug: handleOffRoute used to re-prompt
/// voice/haptic on EVERY off-route retry but only consumed the per-trip recovery
/// budget on a COMMITTED splice. A driver deliberately detouring (the engine
/// keeps scoring .abandonToDestination) therefore never hit the cap, so recovery
/// re-fired the haptic + "Rerouting ahead" voice line + MKDirections fetches
/// roughly every 30s for the rest of the trip — nagging indefinitely.
///
/// The fix: a genuine abandon DECISION from a non-empty options set consumes the
/// budget too, and handleOffRoute throttles (suppresses the prompt + fetch)
/// once `recoveriesThisTrip >= RouteRecoveryEngine.recoveryBudget`. These tests
/// model that caller-side accounting + throttle over `choose` to prove prompts
/// are BOUNDED on a pure-abandon trajectory while a genuine splice still works.
@Suite("Off-route recovery abandon-retry prompt budget")
struct AbandonRetryPromptBudgetTests {

    // A deliberate-detour driver: a usable forward rejoin route exists, but it
    // costs far more than going direct, so `choose` keeps returning
    // .abandonToDestination — the exact pre-fix nag trajectory.
    private let candidates = [
        RejoinCandidate(coordinate: .init(latitude: 33.05, longitude: -117), alongDistance: 5000, kind: .macroLegEntry),
        RejoinCandidate(coordinate: .init(latitude: 33.09, longitude: -117), alongDistance: 10000, kind: .destination),
    ]
    private let abandonOptions = [
        // Expensive rejoin (>> direct), so choose abandons even below the cap.
        RecoveryOption(candidateIndex: 0, etaSeconds: 1500, initialBearingDegrees: nil, beginsWithUTurn: false),
        RecoveryOption(candidateIndex: 1, etaSeconds: 400, initialBearingDegrees: nil, beginsWithUTurn: false),
    ]

    /// Drive the SAME accounting handleOffRoute now uses: throttle the prompt
    /// once the budget is spent; consume the budget on a genuine abandon from a
    /// non-empty options set. Count how many times a prompt would actually fire
    /// over many off-route retries. It must be BOUNDED by the recovery budget,
    /// not unbounded.
    @Test("A deliberate-detour driver gets a bounded number of recovery prompts")
    func boundedPromptsOnRepeatedAbandon() {
        var recoveriesThisTrip = 0
        var promptCount = 0

        // One off-route retry, mirroring handleOffRoute's structure.
        func retry() {
            // Entry throttle: budget spent -> suppress prompt + fetch entirely.
            guard recoveriesThisTrip < RouteRecoveryEngine.recoveryBudget else { return }
            // Past the throttle, the haptic + "Rerouting ahead" voice fire.
            promptCount += 1
            let decision = RouteRecoveryEngine.choose(
                candidates: candidates, options: abandonOptions, event: event(along: 4000),
                totalDistance: 10000, expectedTravelTime: 900, recoveriesThisTrip: recoveriesThisTrip
            )
            // A genuine abandon from a non-empty options set consumes the budget.
            if case .abandonToDestination = decision, !abandonOptions.isEmpty {
                recoveriesThisTrip += 1
            }
        }

        // Simulate a long detour: many off-route episodes (pre-fix: ~one prompt
        // every 30s for the whole trip).
        for _ in 0..<50 { retry() }

        // Prompts are bounded by the budget — not 50.
        #expect(promptCount == RouteRecoveryEngine.recoveryBudget)
        #expect(promptCount < 50)
        // And the engine is now firmly in abandon mode.
        let final = RouteRecoveryEngine.choose(
            candidates: candidates, options: abandonOptions, event: event(along: 4000),
            totalDistance: 10000, expectedTravelTime: 900, recoveriesThisTrip: recoveriesThisTrip
        )
        #expect(final == .abandonToDestination)
    }

    /// A TRANSIENT failure (every fetch failed -> empty options) must NOT consume
    /// the budget, so saved-route recovery isn't permanently disabled by a brief
    /// network blip. Prompts keep retrying (the failure is recoverable), but the
    /// cap is never burned by the blip itself.
    @Test("Transient all-fetches-failed abandon does not consume the budget")
    func transientFailureDoesNotConsumeBudget() {
        var recoveriesThisTrip = 0

        func retryWithNoOptions() {
            guard recoveriesThisTrip < RouteRecoveryEngine.recoveryBudget else { return }
            let emptyOptions: [RecoveryOption] = []
            let decision = RouteRecoveryEngine.choose(
                candidates: candidates, options: emptyOptions, event: event(along: 4000),
                totalDistance: 10000, expectedTravelTime: 900, recoveriesThisTrip: recoveriesThisTrip
            )
            #expect(decision == .abandonToDestination) // no options -> abandon
            // Caller rule: empty options is transient, so DON'T consume budget.
            if case .abandonToDestination = decision, !emptyOptions.isEmpty {
                recoveriesThisTrip += 1
            }
        }

        for _ in 0..<10 { retryWithNoOptions() }
        // The blip never burned the budget — recovery can still splice once the
        // network returns.
        #expect(recoveriesThisTrip == 0)
    }

    /// A genuine successful recovery is preserved: when a forward rejoin is
    /// cheaper than going direct, `choose` rejoins (no abandon), and that path
    /// consumes the budget on a committed splice — exactly as before.
    @Test("A genuine cheap rejoin still recovers (not throttled away)")
    func genuineRecoveryPreserved() {
        let cheapRejoin = [
            RecoveryOption(candidateIndex: 0, etaSeconds: 200, initialBearingDegrees: nil, beginsWithUTurn: false),
        ]
        let decision = RouteRecoveryEngine.choose(
            candidates: candidates, options: cheapRejoin, event: event(along: 4000),
            totalDistance: 10000, expectedTravelTime: 900, recoveriesThisTrip: 0
        )
        #expect(decision == .rejoin(candidateIndex: 0))
    }
}

// MARK: - Per-trip recovery budget reset

/// The 3-recovery cap (`RouteRecoveryEngine.choose`) is PER-TRIP. The reset
/// decision (`RecoveryBudget.shouldReset`) is what keeps it per-trip rather than
/// per-leg: a multi-stop trip must NOT re-arm the budget on every leg, or the
/// cap would never bind. These tests pin that contract.
@Suite("RecoveryBudget.shouldReset")
struct RecoveryBudgetTests {

    @Test("Standalone drive (no active trip) resets at its start")
    func standaloneDriveResets() {
        // begin* with activeTrip == nil → not a continuing leg → reset.
        #expect(RecoveryBudget.shouldReset(isContinuingTripLeg: false))
    }

    @Test("First leg of a trip resets once (trip start)")
    func firstLegResets() {
        // startTrip resets the counter directly; the helper also confirms that
        // a non-continuing start (the trip's first leg) is a reset point.
        #expect(RecoveryBudget.shouldReset(isContinuingTripLeg: false))
    }

    @Test("Continuing trip leg does NOT reset — the cap holds across legs")
    func continuingLegDoesNotReset() {
        // begin* with activeTrip != nil (every leg after the first) → continuing
        // leg → no reset, so the running count survives across legs.
        #expect(!RecoveryBudget.shouldReset(isContinuingTripLeg: true))
    }

    /// End-to-end simulation of the HomeView reset wiring, proving the cap binds
    /// across a multi-leg trip. Mirrors: startTrip resets once; each leg's begin*
    /// resets only when NOT a continuing trip leg; choose() abandons at >= 3.
    @Test("Multi-leg trip: recoveries accumulate across legs and hit the cap")
    func capHoldsAcrossLegs() {
        var recoveriesThisTrip = 0

        // Apply the same reset rule begin* uses, given whether a trip is active.
        func beginLeg(activeTrip: Bool) {
            if RecoveryBudget.shouldReset(isContinuingTripLeg: activeTrip) {
                recoveriesThisTrip = 0
            }
        }

        // Same proven setup as `improvisingDriverWins`: a forward macro-leg
        // candidate that choose() rejoins below the cap and abandons at >= 3.
        let candidates = [
            RejoinCandidate(coordinate: .init(latitude: 33.05, longitude: -117), alongDistance: 5000, kind: .macroLegEntry),
            RejoinCandidate(coordinate: .init(latitude: 33.09, longitude: -117), alongDistance: 10000, kind: .destination),
        ]
        let options = [RecoveryOption(candidateIndex: 0, etaSeconds: 200, initialBearingDegrees: nil, beginsWithUTurn: false)]
        func decide() -> RecoveryDecision {
            RouteRecoveryEngine.choose(
                candidates: candidates, options: options, event: event(along: 4000),
                totalDistance: 10000, expectedTravelTime: 900, recoveriesThisTrip: recoveriesThisTrip
            )
        }

        // Trip starts: startTrip zeroes the budget, first leg begins (active trip).
        recoveriesThisTrip = 0
        beginLeg(activeTrip: true) // first leg runs with activeTrip already set
        #expect(recoveriesThisTrip == 0)

        // Leg 1: two committed recoveries.
        #expect(decide() != .abandonToDestination); recoveriesThisTrip += 1
        #expect(decide() != .abandonToDestination); recoveriesThisTrip += 1

        // Leg 2 auto-advances (activeTrip still set) — budget must NOT reset.
        beginLeg(activeTrip: true)
        #expect(recoveriesThisTrip == 2)

        // A third recovery on leg 2 reaches the cap — choose abandons.
        #expect(decide() != .abandonToDestination); recoveriesThisTrip += 1
        #expect(recoveriesThisTrip == 3)
        #expect(decide() == .abandonToDestination)

        // A brand-new standalone drive (no trip) resets and recovers again.
        beginLeg(activeTrip: false)
        #expect(recoveriesThisTrip == 0)
        #expect(decide() != .abandonToDestination)
    }
}

// MARK: - Post-await Liveness Re-check
//
// Off-route recovery awaits a directions fetch (MKDirections / OSRM) for
// seconds, freeing the main actor. If the drive ends, switches route, or the
// active trip is deleted during that await, resuming the splice would
// resurrect a torn-down engine (no GPS feed) or clobber a fresh live session.
// canResumeRecovery is the guard the recovery rechecks after every await.

@Suite("RouteRecoveryEngine liveness re-check")
struct RouteRecoveryLivenessTests {

    @Test("Resumes only when the captured engine is still the live navigating session")
    func resumesWhenFullyLive() {
        #expect(RouteRecoveryEngine.canResumeRecovery(
            engineIsCurrent: true,
            viewIsNavigating: true,
            engineIsNavigating: true,
            engineHasArrived: false
        ))
    }

    @Test("Bails when the user ended the drive during the await (engine stopped)")
    func bailsWhenEngineStopped() {
        // End tapped mid-await: engine.stopNavigation() flips isNavigating false.
        #expect(!RouteRecoveryEngine.canResumeRecovery(
            engineIsCurrent: true,
            viewIsNavigating: false,
            engineIsNavigating: false,
            engineHasArrived: false
        ))
    }

    @Test("Bails when a switchToRoute/begin* swapped in a new engine instance")
    func bailsWhenEngineSuperseded() {
        // The captured engine is no longer === the view's current engine, even
        // though that OLD instance may still report isNavigating from before it
        // was discarded. Restarting it would corrupt the new live session.
        #expect(!RouteRecoveryEngine.canResumeRecovery(
            engineIsCurrent: false,
            viewIsNavigating: true,
            engineIsNavigating: true,
            engineHasArrived: false
        ))
    }

    @Test("Bails when the engine arrived during the await")
    func bailsWhenArrived() {
        #expect(!RouteRecoveryEngine.canResumeRecovery(
            engineIsCurrent: true,
            viewIsNavigating: true,
            engineIsNavigating: true,
            engineHasArrived: true
        ))
    }

    @Test("Bails when the view left the navigating state (e.g. trip deleted)")
    func bailsWhenViewNotNavigating() {
        // Trip-delete teardown flips the view's isNavigating false even if a
        // stale engine reference still claims to be navigating.
        #expect(!RouteRecoveryEngine.canResumeRecovery(
            engineIsCurrent: true,
            viewIsNavigating: false,
            engineIsNavigating: true,
            engineHasArrived: false
        ))
    }

    @Test("Every non-live combination bails; only all-true resumes")
    func onlyAllTrueResumes() {
        for current in [true, false] {
            for viewNav in [true, false] {
                for engineNav in [true, false] {
                    for arrived in [true, false] {
                        let expected = current && viewNav && engineNav && !arrived
                        #expect(RouteRecoveryEngine.canResumeRecovery(
                            engineIsCurrent: current,
                            viewIsNavigating: viewNav,
                            engineIsNavigating: engineNav,
                            engineHasArrived: arrived
                        ) == expected)
                    }
                }
            }
        }
    }
}
