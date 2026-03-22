import Testing
import Foundation
@testable import Steddi

// MARK: - UpcomingStep Tests

@Suite("UpcomingStep")
struct UpcomingStepTests {

    @Test("Holds all required properties")
    func holdsProperties() {
        let step = UpcomingStep(
            instruction: "Turn left onto Main St",
            distance: "0.3 mi",
            maneuverSymbol: "arrow.turn.up.left",
            roadName: "Main St"
        )
        #expect(step.instruction == "Turn left onto Main St")
        #expect(step.distance == "0.3 mi")
        #expect(step.maneuverSymbol == "arrow.turn.up.left")
        #expect(step.roadName == "Main St")
    }

    @Test("Road name can be nil")
    func roadNameNil() {
        let step = UpcomingStep(
            instruction: "Continue straight",
            distance: "1.2 mi",
            maneuverSymbol: "arrow.up",
            roadName: nil
        )
        #expect(step.roadName == nil)
    }

    @Test("Each instance gets a unique ID")
    func uniqueIds() {
        let a = UpcomingStep(instruction: "A", distance: "1 mi", maneuverSymbol: "arrow.up", roadName: nil)
        let b = UpcomingStep(instruction: "A", distance: "1 mi", maneuverSymbol: "arrow.up", roadName: nil)
        #expect(a.id != b.id)
    }
}

// MARK: - Format Distance Tests

@Suite("formatDistance")
struct FormatDistanceTests {

    @Test("Very short distance shows feet")
    func veryShortFeet() {
        // 50 meters ≈ 164 ft
        let result = NavigationStateManager.formatDistance(50)
        #expect(result == "164 ft")
    }

    @Test("Zero meters shows 0 ft")
    func zeroMeters() {
        let result = NavigationStateManager.formatDistance(0)
        #expect(result == "0 ft")
    }

    @Test("Just below 160m threshold shows feet")
    func justBelow160m() {
        let result = NavigationStateManager.formatDistance(159)
        #expect(result.hasSuffix("ft"))
    }

    @Test("At 160m switches to miles")
    func at160mShowsMiles() {
        let result = NavigationStateManager.formatDistance(160)
        #expect(result.hasSuffix("mi"))
    }

    @Test("Medium distance shows one decimal mile")
    func mediumDistanceDecimalMile() {
        // 1609.34m = 1.0 miles
        let result = NavigationStateManager.formatDistance(1609.34)
        #expect(result == "1.0 mi")
    }

    @Test("Half mile shows 0.5 mi")
    func halfMile() {
        let result = NavigationStateManager.formatDistance(804.67)
        #expect(result == "0.5 mi")
    }

    @Test("Just under 10 miles shows one decimal")
    func justUnder10Miles() {
        // 9.9 miles in meters
        let result = NavigationStateManager.formatDistance(9.9 * 1609.34)
        #expect(result == "9.9 mi")
    }

    @Test("At 10 miles shows whole number")
    func at10MilesWholeNumber() {
        let result = NavigationStateManager.formatDistance(10 * 1609.34)
        #expect(result == "10 mi")
    }

    @Test("Large distance shows whole miles")
    func largeDistanceWholeMiles() {
        // 25 miles
        let result = NavigationStateManager.formatDistance(25 * 1609.34)
        #expect(result == "25 mi")
    }

    @Test("100 miles shows whole number")
    func hundredMiles() {
        let result = NavigationStateManager.formatDistance(100 * 1609.34)
        #expect(result == "100 mi")
    }
}

// MARK: - Format Arrival Time Tests

@Suite("formatArrivalTime")
struct FormatArrivalTimeTests {

    @Test("Returns h:mm a format")
    func returnsCorrectFormat() {
        let result = NavigationStateManager.formatArrivalTime(3600) // 1 hour from now
        // Should match pattern like "1:30 PM" or "12:00 AM"
        let pattern = #/\d{1,2}:\d{2}\s(AM|PM)/#
        #expect(result.contains(try! Regex(#"\d{1,2}:\d{2} (AM|PM)"#)))
    }

    @Test("Zero seconds remaining gives current time")
    func zeroSecondsGivesNow() {
        let result = NavigationStateManager.formatArrivalTime(0)
        // Format current time the same way for comparison
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let expected = formatter.string(from: Date())
        #expect(result == expected)
    }

    @Test("Large duration produces valid time string")
    func largeDuration() {
        // 24 hours from now
        let result = NavigationStateManager.formatArrivalTime(86400)
        #expect(!result.isEmpty)
        #expect(result.contains(try! Regex(#"\d{1,2}:\d{2} (AM|PM)"#)))
    }
}

// MARK: - SF Symbol Mapping Tests

@Suite("sfSymbol mapping")
struct SFSymbolTests {

    // MARK: Turn

    @Test("Turn left returns arrow.turn.up.left")
    func turnLeft() {
        #expect(NavigationStateManager.sfSymbol(for: .turn, direction: .left) == "arrow.turn.up.left")
    }

    @Test("Turn sharp left returns arrow.turn.up.left")
    func turnSharpLeft() {
        #expect(NavigationStateManager.sfSymbol(for: .turn, direction: .sharpLeft) == "arrow.turn.up.left")
    }

    @Test("Turn slight left returns arrow.turn.up.left")
    func turnSlightLeft() {
        #expect(NavigationStateManager.sfSymbol(for: .turn, direction: .slightLeft) == "arrow.turn.up.left")
    }

    @Test("Turn right returns arrow.turn.up.right")
    func turnRight() {
        #expect(NavigationStateManager.sfSymbol(for: .turn, direction: .right) == "arrow.turn.up.right")
    }

    @Test("Turn sharp right returns arrow.turn.up.right")
    func turnSharpRight() {
        #expect(NavigationStateManager.sfSymbol(for: .turn, direction: .sharpRight) == "arrow.turn.up.right")
    }

    @Test("Turn slight right returns arrow.turn.up.right")
    func turnSlightRight() {
        #expect(NavigationStateManager.sfSymbol(for: .turn, direction: .slightRight) == "arrow.turn.up.right")
    }

    @Test("U-turn returns arrow.uturn.down")
    func uTurn() {
        #expect(NavigationStateManager.sfSymbol(for: .turn, direction: .uTurn) == "arrow.uturn.down")
    }

    @Test("Turn with no direction returns arrow.up")
    func turnNoDirection() {
        #expect(NavigationStateManager.sfSymbol(for: .turn, direction: nil) == "arrow.up")
    }

    @Test("Turn with straight direction returns arrow.up")
    func turnStraight() {
        #expect(NavigationStateManager.sfSymbol(for: .turn, direction: .straightAhead) == "arrow.up")
    }

    // MARK: Merge

    @Test("Merge returns arrow.merge")
    func merge() {
        #expect(NavigationStateManager.sfSymbol(for: .merge, direction: nil) == "arrow.merge")
    }

    @Test("Merge with direction still returns arrow.merge")
    func mergeWithDirection() {
        #expect(NavigationStateManager.sfSymbol(for: .merge, direction: .left) == "arrow.merge")
    }

    // MARK: On-ramp / Off-ramp

    @Test("On-ramp left returns arrow.up.left")
    func onRampLeft() {
        #expect(NavigationStateManager.sfSymbol(for: .takeOnRamp, direction: .left) == "arrow.up.left")
    }

    @Test("On-ramp right returns arrow.up.right")
    func onRampRight() {
        #expect(NavigationStateManager.sfSymbol(for: .takeOnRamp, direction: .right) == "arrow.up.right")
    }

    @Test("On-ramp slight left returns arrow.up.left")
    func onRampSlightLeft() {
        #expect(NavigationStateManager.sfSymbol(for: .takeOnRamp, direction: .slightLeft) == "arrow.up.left")
    }

    @Test("On-ramp sharp right returns arrow.up.right")
    func onRampSharpRight() {
        #expect(NavigationStateManager.sfSymbol(for: .takeOnRamp, direction: .sharpRight) == "arrow.up.right")
    }

    @Test("On-ramp nil direction defaults to arrow.up.right")
    func onRampNilDirection() {
        #expect(NavigationStateManager.sfSymbol(for: .takeOnRamp, direction: nil) == "arrow.up.right")
    }

    @Test("Off-ramp left returns arrow.up.left")
    func offRampLeft() {
        #expect(NavigationStateManager.sfSymbol(for: .takeOffRamp, direction: .left) == "arrow.up.left")
    }

    @Test("Off-ramp right returns arrow.up.right")
    func offRampRight() {
        #expect(NavigationStateManager.sfSymbol(for: .takeOffRamp, direction: .right) == "arrow.up.right")
    }

    @Test("Off-ramp nil direction defaults to arrow.up.right")
    func offRampNilDirection() {
        #expect(NavigationStateManager.sfSymbol(for: .takeOffRamp, direction: nil) == "arrow.up.right")
    }

    // MARK: Fork

    @Test("Fork left returns arrow.up.left")
    func forkLeft() {
        #expect(NavigationStateManager.sfSymbol(for: .reachFork, direction: .left) == "arrow.up.left")
    }

    @Test("Fork slight left returns arrow.up.left")
    func forkSlightLeft() {
        #expect(NavigationStateManager.sfSymbol(for: .reachFork, direction: .slightLeft) == "arrow.up.left")
    }

    @Test("Fork right returns arrow.up.right")
    func forkRight() {
        #expect(NavigationStateManager.sfSymbol(for: .reachFork, direction: .right) == "arrow.up.right")
    }

    @Test("Fork nil direction defaults to arrow.up.right")
    func forkNilDirection() {
        #expect(NavigationStateManager.sfSymbol(for: .reachFork, direction: nil) == "arrow.up.right")
    }

    // MARK: End of Road

    @Test("End of road returns arrow.turn.up.right")
    func endOfRoad() {
        #expect(NavigationStateManager.sfSymbol(for: .reachEnd, direction: nil) == "arrow.turn.up.right")
    }

    // MARK: Lane

    @Test("Use lane returns arrow.up")
    func useLane() {
        #expect(NavigationStateManager.sfSymbol(for: .useLane, direction: nil) == "arrow.up")
    }

    // MARK: Rotary / Roundabout

    @Test("Rotary returns arrow.triangle.2.circlepath")
    func rotary() {
        #expect(NavigationStateManager.sfSymbol(for: .takeRotary, direction: nil) == "arrow.triangle.2.circlepath")
    }

    @Test("Roundabout returns arrow.triangle.2.circlepath")
    func roundabout() {
        #expect(NavigationStateManager.sfSymbol(for: .takeRoundabout, direction: nil) == "arrow.triangle.2.circlepath")
    }

    // MARK: Arrive / Depart

    @Test("Arrive returns flag.fill")
    func arrive() {
        #expect(NavigationStateManager.sfSymbol(for: .arrive, direction: nil) == "flag.fill")
    }

    @Test("Depart returns location.fill")
    func depart() {
        #expect(NavigationStateManager.sfSymbol(for: .depart, direction: nil) == "location.fill")
    }

    // MARK: Default

    @Test("Unknown maneuver type returns arrow.up")
    func unknownType() {
        #expect(NavigationStateManager.sfSymbol(for: .continue, direction: nil) == "arrow.up")
    }

    @Test("Continue maneuver type returns arrow.up")
    func continueType() {
        #expect(NavigationStateManager.sfSymbol(for: .continue, direction: nil) == "arrow.up")
    }
}

// MARK: - State Reset Tests

@Suite("NavigationStateManager state")
@MainActor
struct NavigationStateManagerStateTests {

    @Test("Initial state has sensible defaults")
    func initialDefaults() {
        let manager = NavigationStateManager()

        #expect(manager.isNavigating == false)
        #expect(manager.isCarPlayActive == false)
        #expect(manager.instruction == "")
        #expect(manager.stepDistance == "")
        #expect(manager.stepDistanceRaw == 0)
        #expect(manager.etaMinutes == 0)
        #expect(manager.distanceRemaining == "")
        #expect(manager.arrivalTime == "")
        #expect(manager.roadName == "")
        #expect(manager.maneuverType == "arrow.up")
        #expect(manager.followOnInstruction == "")
        #expect(manager.followOnManeuverSymbol == "")
        #expect(manager.currentSpeedMph == 0)
        #expect(manager.speedLimitMph == nil)
        #expect(manager.headingDegrees == 0)
        #expect(manager.currentCoordinate == nil)
        #expect(manager.hasArrived == false)
        #expect(manager.activeCommute == nil)
        #expect(manager.activeDirection == nil)
        #expect(manager.rerouteSuggestion == nil)
        #expect(manager.currentRemainingETA == 0)
        #expect(manager.upcomingSteps.isEmpty)
    }

    @Test("stopObserving resets all properties to defaults")
    func stopObservingResetsState() {
        let manager = NavigationStateManager()

        // Simulate having some state set (without needing MapboxNavigationProvider)
        manager.isNavigating = true
        manager.isCarPlayActive = true
        manager.instruction = "Turn left"
        manager.stepDistance = "0.3 mi"
        manager.stepDistanceRaw = 482.8
        manager.etaMinutes = 15
        manager.distanceRemaining = "5.2 mi"
        manager.arrivalTime = "3:45 PM"
        manager.roadName = "Main St"
        manager.maneuverType = "arrow.turn.up.left"
        manager.followOnInstruction = "Then turn right"
        manager.followOnManeuverSymbol = "arrow.turn.up.right"
        manager.currentSpeedMph = 45.0
        manager.speedLimitMph = 55.0
        manager.headingDegrees = 180.0
        manager.hasArrived = false
        manager.currentRemainingETA = 900

        manager.stopObserving()

        #expect(manager.isNavigating == false)
        #expect(manager.instruction == "")
        #expect(manager.stepDistance == "")
        #expect(manager.stepDistanceRaw == 0)
        #expect(manager.etaMinutes == 0)
        #expect(manager.distanceRemaining == "")
        #expect(manager.arrivalTime == "")
        #expect(manager.roadName == "")
        #expect(manager.maneuverType == "arrow.up")
        #expect(manager.followOnInstruction == "")
        #expect(manager.followOnManeuverSymbol == "")
        #expect(manager.currentSpeedMph == 0)
        #expect(manager.speedLimitMph == nil)
        #expect(manager.headingDegrees == 0)
        #expect(manager.currentCoordinate == nil)
        #expect(manager.hasArrived == false)
        #expect(manager.activeCommute == nil)
        #expect(manager.activeDirection == nil)
        #expect(manager.rerouteSuggestion == nil)
        #expect(manager.currentRemainingETA == 0)
        #expect(manager.upcomingSteps.isEmpty)
    }

    @Test("stopObserving is idempotent")
    func stopObservingIdempotent() {
        let manager = NavigationStateManager()
        manager.instruction = "Turn left"

        manager.stopObserving()
        manager.stopObserving()

        #expect(manager.instruction == "")
        #expect(manager.isNavigating == false)
    }

    @Test("Default maneuver type is arrow.up")
    func defaultManeuverType() {
        let manager = NavigationStateManager()
        #expect(manager.maneuverType == "arrow.up")
    }
}
