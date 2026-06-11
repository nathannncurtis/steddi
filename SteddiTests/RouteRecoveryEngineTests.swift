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
