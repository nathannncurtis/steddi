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

// MARK: - SF Symbol From Instruction Tests

@Suite("sfSymbolFromInstruction")
struct SFSymbolFromInstructionTests {

    @Test("Turn left returns arrow.turn.up.left")
    func turnLeft() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Turn left onto Main St") == "arrow.turn.up.left")
    }

    @Test("Turn right returns arrow.turn.up.right")
    func turnRight() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Turn right onto Broadway") == "arrow.turn.up.right")
    }

    @Test("Sharp left returns arrow.turn.up.left")
    func sharpLeft() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Make a sharp left") == "arrow.turn.up.left")
    }

    @Test("Sharp right returns arrow.turn.up.right")
    func sharpRight() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Make a sharp right") == "arrow.turn.up.right")
    }

    @Test("Slight left returns arrow.turn.up.left")
    func slightLeft() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Slight left onto I-10") == "arrow.turn.up.left")
    }

    @Test("Bear right returns arrow.turn.up.right")
    func bearRight() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Bear right onto US-60") == "arrow.turn.up.right")
    }

    @Test("U-turn returns arrow.uturn.down")
    func uTurn() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Make a U-turn") == "arrow.uturn.down")
    }

    @Test("Merge returns arrow.merge")
    func merge() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Merge onto I-15") == "arrow.merge")
    }

    @Test("Ramp left returns arrow.up.left")
    func rampLeft() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Take the ramp on the left") == "arrow.up.left")
    }

    @Test("Ramp right returns arrow.up.right")
    func rampRight() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Take the ramp") == "arrow.up.right")
    }

    @Test("Roundabout returns arrow.triangle.2.circlepath")
    func roundabout() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Enter the roundabout") == "arrow.triangle.2.circlepath")
    }

    @Test("Arrive returns flag.fill")
    func arrive() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Arrive at your destination") == "flag.fill")
    }

    @Test("Depart returns location.fill")
    func depart() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Depart south on Main St") == "location.fill")
    }

    @Test("Continue straight returns arrow.up")
    func continueStraight() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Continue on Main St") == "arrow.up")
    }

    @Test("Unknown instruction returns arrow.up")
    func unknownInstruction() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Proceed carefully") == "arrow.up")
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

        // Simulate having some state set
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
