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
        #expect(engine.headingDegrees == nil)
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
        #expect(engine.headingDegrees == nil)
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

// MARK: - Off-Route Detection Tests

@Suite("NavigationEngine off-route detection")
@MainActor
struct NavigationEngineOffRouteTests {

    /// Victoria Ave corridor (TestLocations/victoria_clean_drive.waypoints)
    private static let corridor: [CLLocationCoordinate2D] = [
        .init(latitude: 33.957140, longitude: -117.350939),
        .init(latitude: 33.961500, longitude: -117.355800),
        .init(latitude: 33.966000, longitude: -117.360700),
        .init(latitude: 33.968000, longitude: -117.362900),
        .init(latitude: 33.969500, longitude: -117.364500),
        .init(latitude: 33.973500, longitude: -117.370300),
        .init(latitude: 33.977740, longitude: -117.376010)
    ]

    /// Same drive with a mid-drive deviation (TestLocations/victoria_offroute_drive.waypoints)
    private static let offRouteDrive: [CLLocationCoordinate2D] = [
        .init(latitude: 33.957140, longitude: -117.350939),
        .init(latitude: 33.961500, longitude: -117.355800),
        .init(latitude: 33.966000, longitude: -117.360700),
        .init(latitude: 33.968000, longitude: -117.362900),
        .init(latitude: 33.966500, longitude: -117.366500),
        .init(latitude: 33.965800, longitude: -117.368000),
        .init(latitude: 33.969500, longitude: -117.364500),
        .init(latitude: 33.973500, longitude: -117.370300),
        .init(latitude: 33.977740, longitude: -117.376010)
    ]

    @Test("Victoria off-route drive fires after grace period plus consecutive threshold")
    func offRouteFiresOnDeviation() throws {
        let engine = NavigationEngine()
        let steps = [
            NavStep(instruction: "", distance: 3500, coordinate: Self.corridor[0], maneuverSymbol: "location.fill"),
            NavStep(instruction: "", distance: 0, coordinate: Self.corridor[6], maneuverSymbol: "flag.fill")
        ]
        engine.startNavigation(polyline: Self.corridor, steps: steps)

        // 15 m/s sampled every 500ms, matching tests/sim/drive.sh defaults
        let locations = Self.driveLocations(along: Self.offRouteDrive, speedMPS: 15, cadence: 0.5)

        var updatesDelivered = 0
        var firstFireUpdate: Int?
        engine.onOffRoute = { _, _ in
            if firstFireUpdate == nil { firstFireUpdate = updatesDelivered }
        }

        for location in locations {
            updatesDelivered += 1
            engine.updateLocation(location)
        }

        // First update more than 80m off the corridor (1-based, matching update count)
        let deviationStart = try #require(locations.firstIndex { location in
            NavigationEngine.distanceFromPointToNearestSegment(
                point: location.coordinate,
                polyline: Self.corridor
            ).perpendicularDistance > 80
        }) + 1

        let fireUpdate = try #require(firstFireUpdate)
        #expect(fireUpdate > 10 + 5)
        #expect(fireUpdate == deviationStart + 4)
    }

    /// Interpolate a waypoint path into evenly spaced synthetic CLLocations at a fixed cadence.
    private static func driveLocations(
        along path: [CLLocationCoordinate2D],
        speedMPS: Double,
        cadence: TimeInterval
    ) -> [CLLocation] {
        let spacing = speedMPS * cadence
        var coords: [CLLocationCoordinate2D] = []
        for i in 0..<(path.count - 1) {
            let a = path[i]
            let b = path[i + 1]
            let samples = max(1, Int(NavigationEngine.haversineDistance(from: a, to: b) / spacing))
            for sample in 0..<samples {
                let t = Double(sample) / Double(samples)
                coords.append(CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t
                ))
            }
        }
        if let last = path.last {
            coords.append(last)
        }

        let start = Date()
        return coords.enumerated().map { index, coord in
            CLLocation(
                coordinate: coord,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                course: 0,
                speed: speedMPS,
                timestamp: start.addingTimeInterval(cadence * Double(index))
            )
        }
    }
}
