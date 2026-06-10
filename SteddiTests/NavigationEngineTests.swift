import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - SF Symbol Tests

@Suite("NavigationEngine.sfSymbolFromInstruction")
struct NavigationEngineSFSymbolTests {

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

    @Test("Ramp with left returns arrow.up.left")
    func rampLeft() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Take the ramp on the left") == "arrow.up.left")
    }

    @Test("Ramp without left returns arrow.up.right")
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

    @Test("Destination keyword returns flag.fill")
    func destinationKeyword() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Your destination is on the right") == "flag.fill")
    }

    @Test("Start keyword returns location.fill")
    func startKeyword() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Start heading north") == "location.fill")
    }

    @Test("Rotary returns arrow.triangle.2.circlepath")
    func rotary() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Enter the rotary") == "arrow.triangle.2.circlepath")
    }

    @Test("Keep left returns arrow.turn.up.left")
    func keepLeft() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Keep left at the fork") == "arrow.turn.up.left")
    }

    @Test("Keep right returns arrow.turn.up.right")
    func keepRight() {
        #expect(NavigationEngine.sfSymbolFromInstruction("Keep right at the fork") == "arrow.turn.up.right")
    }
}

// MARK: - Format Distance Tests

@Suite("NavigationEngine.formatDistance")
struct NavigationEngineFormatDistanceTests {

    @Test("Very short distance shows feet")
    func veryShortFeet() {
        let result = NavigationEngine.formatDistance(50)
        #expect(result == "164 ft")
    }

    @Test("Zero meters shows 0 ft")
    func zeroMeters() {
        let result = NavigationEngine.formatDistance(0)
        #expect(result == "0 ft")
    }

    @Test("Just below 160m threshold shows feet")
    func justBelow160m() {
        let result = NavigationEngine.formatDistance(159)
        #expect(result.hasSuffix("ft"))
    }

    @Test("At 160m switches to miles")
    func at160mShowsMiles() {
        let result = NavigationEngine.formatDistance(160)
        #expect(result.hasSuffix("mi"))
    }

    @Test("One mile shows 1.0 mi")
    func oneMile() {
        let result = NavigationEngine.formatDistance(1609.34)
        #expect(result == "1.0 mi")
    }

    @Test("Half mile shows 0.5 mi")
    func halfMile() {
        let result = NavigationEngine.formatDistance(804.67)
        #expect(result == "0.5 mi")
    }

    @Test("Just under 10 miles shows one decimal")
    func justUnder10Miles() {
        let result = NavigationEngine.formatDistance(9.9 * 1609.34)
        #expect(result == "9.9 mi")
    }

    @Test("At 10 miles shows whole number")
    func at10MilesWholeNumber() {
        let result = NavigationEngine.formatDistance(10 * 1609.34)
        #expect(result == "10 mi")
    }

    @Test("Large distance shows whole miles")
    func largeDistanceWholeMiles() {
        let result = NavigationEngine.formatDistance(25 * 1609.34)
        #expect(result == "25 mi")
    }
}

// MARK: - Format Arrival Time Tests

@Suite("NavigationEngine.formatArrivalTime")
struct NavigationEngineFormatArrivalTimeTests {

    @Test("Returns h:mm a format")
    func returnsCorrectFormat() {
        let result = NavigationEngine.formatArrivalTime(3600)
        #expect(result.contains(try! Regex(#"\d{1,2}:\d{2} (AM|PM)"#)))
    }

    @Test("Zero seconds gives current time")
    func zeroSecondsGivesNow() {
        let result = NavigationEngine.formatArrivalTime(0)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let expected = formatter.string(from: Date())
        #expect(result == expected)
    }
}

// MARK: - Road Name Extraction Tests

@Suite("NavigationEngine.extractRoadName")
struct NavigationEngineRoadNameTests {

    @Test("Extracts road name after 'onto'")
    func ontoPattern() {
        let result = NavigationEngine.extractRoadName(from: "Turn left onto Main St")
        #expect(result == "Main St")
    }

    @Test("Extracts road name after 'onto' with highway")
    func ontoHighway() {
        let result = NavigationEngine.extractRoadName(from: "Merge onto I-10 East")
        #expect(result == "I-10 East")
    }

    @Test("Extracts road name after 'on' when no 'onto'")
    func onPattern() {
        let result = NavigationEngine.extractRoadName(from: "Continue on Broadway")
        #expect(result == "Broadway")
    }

    @Test("Returns empty for instruction without road name")
    func noRoadName() {
        let result = NavigationEngine.extractRoadName(from: "Make a U-turn")
        #expect(result == "")
    }

    @Test("Returns empty for arrive instruction")
    func arriveInstruction() {
        let result = NavigationEngine.extractRoadName(from: "Arrive at your destination")
        #expect(result == "")
    }

    @Test("Handles 'onto' case insensitively")
    func caseInsensitive() {
        let result = NavigationEngine.extractRoadName(from: "Turn right Onto Oak Ave")
        #expect(result == "Oak Ave")
    }
}

// MARK: - Speed Limit Estimation Tests

@Suite("NavigationEngine.estimateSpeedLimit")
struct NavigationEngineSpeedLimitTests {

    @Test("Merge onto interstate classifies by road, not maneuver")
    func mergeOntoInterstate() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Merge onto I-215") == 65)
    }

    @Test("Ramp onto US route classifies by road, not maneuver")
    func rampOntoUSRoute() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Take the ramp onto US-101 North") == 65)
    }

    @Test("CA state route is 65")
    func caStateRoute() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Continue on CA-60 East") == 65)
    }

    @Test("SR state route is 65")
    func srStateRoute() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Merge onto SR-91") == 65)
    }

    @Test("Freeway keyword is 65")
    func freeway() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Continue onto the freeway") == 65)
    }

    @Test("Boulevard is 45")
    func boulevard() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Turn right onto Sunset Blvd") == 45)
    }

    @Test("Parkway is 45")
    func parkway() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Continue on Chino Hills Pkwy") == 45)
    }

    @Test("Street abbreviation at end of instruction is 35")
    func streetAbbreviationAtEnd() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Turn left onto Main St") == 35)
    }

    @Test("Road abbreviation at end of instruction is 35")
    func roadAbbreviationAtEnd() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Turn right onto Euclid Rd") == 35)
    }

    @Test("Drive abbreviation is 35")
    func driveAbbreviation() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Bear left onto Country Club Dr") == 35)
    }

    @Test("Lane abbreviation is 35")
    func laneAbbreviation() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Turn onto Maple Ln") == 35)
    }

    @Test("Court abbreviation is 35")
    func courtAbbreviation() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Turn left onto Oak Ct") == 35)
    }

    @Test("Full street word is 35")
    func fullStreetWord() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Turn left onto First Street") == 35)
    }

    @Test("Avenue is 35")
    func avenue() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Turn right onto 5th Avenue") == 35)
    }

    @Test("st inside a word is not a street")
    func stInsideWord() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Head west") == 45)
    }

    @Test("Word starting with st is not a street")
    func wordStartingWithSt() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Turn onto Standish Way") == 45)
    }

    @Test("Bare ramp is 40")
    func bareRamp() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Take the ramp") == 40)
    }

    @Test("Bare merge is 40")
    func bareMerge() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Merge left") == 40)
    }

    @Test("Unknown instruction defaults to 45")
    func unknownDefault() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Make a U-turn") == 45)
    }

    @Test("Turn right onto Main St is 35")
    func turnRightOntoMainSt() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Turn right onto Main St") == 35)
    }

    @Test("Merge onto CA-60 W is 65")
    func mergeOntoCA60W() {
        #expect(NavigationEngine.estimateSpeedLimit(from: "Merge onto CA-60 W") == 65)
    }
}

// MARK: - Initial State & Stop Navigation Tests

@Suite("NavigationEngine state lifecycle")
@MainActor
struct NavigationEngineStateTests {

    @Test("Initial state has sensible defaults")
    func initialDefaults() {
        let engine = NavigationEngine()

        #expect(engine.isNavigating == false)
        #expect(engine.currentStepIndex == 0)
        #expect(engine.instruction == "")
        #expect(engine.stepDistance == "")
        #expect(engine.stepDistanceRaw == 0)
        #expect(engine.etaMinutes == 0)
        #expect(engine.distanceRemaining == "")
        #expect(engine.arrivalTime == "")
        #expect(engine.roadName == "")
        #expect(engine.maneuverType == "arrow.up")
        #expect(engine.followOnInstruction == "")
        #expect(engine.followOnManeuverSymbol == "")
        #expect(engine.currentSpeedMph == 0)
        #expect(engine.headingDegrees == 0)
        #expect(engine.currentCoordinate == nil)
        #expect(engine.hasArrived == false)
        #expect(engine.routePolylineCoordinates.isEmpty)
    }

    @Test("stopNavigation resets all state to defaults")
    func stopNavigationResetsState() {
        let engine = NavigationEngine()

        // Simulate some state being set
        engine.isNavigating = true
        engine.instruction = "Turn left"
        engine.stepDistance = "0.3 mi"
        engine.stepDistanceRaw = 482.8
        engine.etaMinutes = 15
        engine.distanceRemaining = "5.2 mi"
        engine.arrivalTime = "3:45 PM"
        engine.roadName = "Main St"
        engine.maneuverType = "arrow.turn.up.left"
        engine.followOnInstruction = "Then turn right"
        engine.followOnManeuverSymbol = "arrow.turn.up.right"
        engine.currentSpeedMph = 45.0
        engine.headingDegrees = 180.0
        engine.hasArrived = true

        engine.stopNavigation()

        #expect(engine.isNavigating == false)
        #expect(engine.currentStepIndex == 0)
        #expect(engine.instruction == "")
        #expect(engine.stepDistance == "")
        #expect(engine.stepDistanceRaw == 0)
        #expect(engine.etaMinutes == 0)
        #expect(engine.distanceRemaining == "")
        #expect(engine.arrivalTime == "")
        #expect(engine.roadName == "")
        #expect(engine.maneuverType == "arrow.up")
        #expect(engine.followOnInstruction == "")
        #expect(engine.followOnManeuverSymbol == "")
        #expect(engine.currentSpeedMph == 0)
        #expect(engine.headingDegrees == 0)
        #expect(engine.currentCoordinate == nil)
        #expect(engine.hasArrived == false)
        #expect(engine.routePolylineCoordinates.isEmpty)
    }

    @Test("stopNavigation is idempotent")
    func stopNavigationIdempotent() {
        let engine = NavigationEngine()
        engine.instruction = "Turn left"
        engine.isNavigating = true

        engine.stopNavigation()
        engine.stopNavigation()

        #expect(engine.instruction == "")
        #expect(engine.isNavigating == false)
    }
}
