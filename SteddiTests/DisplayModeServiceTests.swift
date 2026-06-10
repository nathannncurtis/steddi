import Testing
import Foundation
@testable import Steddi

// MARK: - Instruction Simplifier Tests

@Suite("simplifiedInstruction")
struct SimplifiedInstructionTests {

    @Test("Strips road-name detail to the bare maneuver", arguments: [
        ("Turn left onto N Orange St", "Turn left"),
        ("Turn right onto US-60 W toward Riverside", "Turn right"),
        ("Merge onto I-215 S", "Merge"),
        ("Continue on Main St", "Continue"),
        ("Continue straight to stay on N Orange St", "Continue straight"),
        ("Keep left to stay on I-10 W", "Keep left"),
        ("Turn left to merge onto I-10 W", "Turn left"),
        ("Head south on Market St", "Head south"),
        ("Make a U-turn at Mission Ave", "Make a U-turn"),
        ("Take exit 22 toward Downtown", "Take exit 22"),
        ("Bear right onto the I-10 ramp", "Bear right"),
        ("Slight left towards Magnolia Ave", "Slight left"),
    ])
    func stripsRoadNames(input: String, expected: String) {
        #expect(DisplayModeService.simplifiedInstruction(input) == expected)
    }

    @Test("Keeps side detail when it precedes the road name", arguments: [
        ("Take the ramp on the right toward Los Angeles", "Take the ramp on the right"),
        ("At the roundabout, take the 2nd exit onto High St", "At the roundabout, take the 2nd exit"),
        ("Keep right at the fork to continue on I-15 S", "Keep right at the fork"),
    ])
    func keepsManeuverSideDetail(input: String, expected: String) {
        #expect(DisplayModeService.simplifiedInstruction(input) == expected)
    }

    @Test("Leaves bare maneuvers and arrival phrasing unchanged", arguments: [
        "Turn left",
        "Continue straight",
        "You have arrived",
        "Arrive at your destination",
        "Your destination is on the left",
        "Keep to the right",
        "Turn left at the light",
        "Take the ramp on the right",
    ])
    func leavesUnchanged(input: String) {
        #expect(DisplayModeService.simplifiedInstruction(input) == input)
    }

    @Test("Empty instruction stays empty")
    func emptyStaysEmpty() {
        #expect(DisplayModeService.simplifiedInstruction("") == "")
    }

    @Test("Surrounding whitespace is trimmed")
    func trimsWhitespace() {
        #expect(DisplayModeService.simplifiedInstruction("  Turn left onto Main St  ") == "Turn left")
    }

    @Test("Matching is case-insensitive")
    func caseInsensitive() {
        #expect(DisplayModeService.simplifiedInstruction("TURN LEFT ONTO MAIN ST") == "TURN LEFT")
    }

    @Test("Trailing comma before the connector is stripped")
    func trailingCommaStripped() {
        #expect(DisplayModeService.simplifiedInstruction("Turn left, onto Main St") == "Turn left")
    }
}

// MARK: - Scale Tests

@Suite("DisplayModeService scales", .serialized)
struct DisplayModeScaleTests {

    private func withModes(passenger: Bool, accessibility: Bool, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let priorPassenger = defaults.object(forKey: "steddi.passengerMode")
        let priorAccessibility = defaults.object(forKey: "steddi.accessibilityMode")
        defaults.set(passenger, forKey: "steddi.passengerMode")
        defaults.set(accessibility, forKey: "steddi.accessibilityMode")
        body()
        if let priorPassenger { defaults.set(priorPassenger, forKey: "steddi.passengerMode") } else { defaults.removeObject(forKey: "steddi.passengerMode") }
        if let priorAccessibility { defaults.set(priorAccessibility, forKey: "steddi.accessibilityMode") } else { defaults.removeObject(forKey: "steddi.accessibilityMode") }
    }

    @Test("Both modes off — neutral scales, no flags")
    func neutralScales() {
        withModes(passenger: false, accessibility: false) {
            let service = DisplayModeService.shared
            #expect(service.textScale == 1.0)
            #expect(service.iconScale == 1.0)
            #expect(service.useHighContrast == false)
            #expect(service.useSimplifiedInstructions == false)
        }
    }

    @Test("Passenger mode scales text and icons")
    func passengerScales() {
        withModes(passenger: true, accessibility: false) {
            let service = DisplayModeService.shared
            #expect(service.textScale == 1.2)
            #expect(service.iconScale == 1.2)
            #expect(service.useHighContrast == false)
            #expect(service.useSimplifiedInstructions == false)
        }
    }

    @Test("Accessibility mode wins scaling and turns on contrast + simplification")
    func accessibilityScales() {
        withModes(passenger: true, accessibility: true) {
            let service = DisplayModeService.shared
            #expect(service.textScale == 1.4)
            #expect(service.iconScale == 1.5)
            #expect(service.useHighContrast == true)
            #expect(service.useSimplifiedInstructions == true)
        }
    }
}
