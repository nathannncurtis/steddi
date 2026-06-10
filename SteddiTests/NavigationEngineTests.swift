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
            var projector = RouteProjector(polyline: Self.corridor)
            guard let projection = projector.project(location.coordinate) else { return false }
            return projection.perpendicularDistance > 80
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

// MARK: - Pose & Bearing Tests

@Suite("NavigationEngine pose & bearing")
@MainActor
struct NavigationEnginePoseTests {

    /// Straight route running north from (33, -117), ~111m per segment.
    private func straightRoute(segments: Int) -> [CLLocationCoordinate2D] {
        (0...segments).map { CLLocationCoordinate2D(latitude: 33.0 + Double($0) * 0.001, longitude: -117.0) }
    }

    /// Steps with empty instructions so tests stay silent (no voice guidance).
    private func silentSteps(along polyline: [CLLocationCoordinate2D]) -> [NavStep] {
        [
            NavStep(instruction: "", distance: 1000, coordinate: polyline.first ?? CLLocationCoordinate2D(), maneuverSymbol: "arrow.up"),
            NavStep(instruction: "", distance: 0, coordinate: polyline.last ?? CLLocationCoordinate2D(), maneuverSymbol: "flag.fill"),
        ]
    }

    private func fix(
        lat: Double, lon: Double,
        course: Double = -1, courseAccuracy: Double = -1,
        speed: Double = 13, t: TimeInterval = 0
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: course,
            courseAccuracy: courseAccuracy,
            speed: speed,
            speedAccuracy: 1,
            timestamp: Date(timeIntervalSince1970: 1_750_000_000 + t)
        )
    }

    private func circularDelta(_ a: Double, _ b: Double) -> Double {
        var d = abs(a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        return d
    }

    @Test("Snapped pose is published from an offset fix")
    func snappedPosePublished() throws {
        let engine = NavigationEngine()
        let polyline = straightRoute(segments: 20)
        engine.startNavigation(polyline: polyline, steps: silentSteps(along: polyline))

        // ~18m east of the line, halfway up the route
        let location = fix(lat: 33.005, lon: -116.9998)
        engine.updateLocation(location)

        let pose = try #require(engine.navPose)
        #expect(abs(pose.snappedCoordinate.longitude - (-117.0)) < 1e-6)
        #expect(abs(pose.snappedCoordinate.latitude - 33.005) < 1e-5)
        #expect(pose.t >= 0 && pose.t <= 1)
        #expect(pose.speedMPS == 13)
        #expect(pose.fixTimestamp == location.timestamp)

        let snapped = try #require(engine.snappedCoordinate)
        #expect(snapped.latitude == pose.snappedCoordinate.latitude)
        #expect(snapped.longitude == pose.snappedCoordinate.longitude)

        engine.stopNavigation()
        #expect(engine.navPose == nil)
    }

    @Test("Distance along route is monotonic for forward fixes")
    func projectionMonotonic() throws {
        let engine = NavigationEngine()
        let polyline = straightRoute(segments: 20)
        engine.startNavigation(polyline: polyline, steps: silentSteps(along: polyline))

        var lastAlong = -1.0
        for i in 0..<15 {
            // ~55m steps north with a small westward GPS offset
            engine.updateLocation(fix(lat: 33.0 + Double(i) * 0.0005, lon: -117.00005, t: Double(i)))
            let along = try #require(engine.navPose).distanceAlongRoute
            #expect(along >= lastAlong)
            lastAlong = along
        }
        engine.stopNavigation()
    }

    @Test("Out-and-back route stays on the return leg via the window")
    func outAndBackDisambiguation() throws {
        // North ~555m then straight back south on the identical line
        let out = (0...10).map { CLLocationCoordinate2D(latitude: 33.0 + Double($0) * 0.0005, longitude: -117.0) }
        let back = (1...10).map { CLLocationCoordinate2D(latitude: 33.005 - Double($0) * 0.0005, longitude: -117.0) }
        let polyline = out + back

        let engine = NavigationEngine()
        engine.startNavigation(polyline: polyline, steps: silentSteps(along: polyline))

        let halfway = RouteGeometry.cumulativeDistances(polyline)[10]

        // Drive out, turn around, and come back
        let lats = [33.001, 33.002, 33.003, 33.0045, 33.005, 33.0045, 33.003, 33.002]
        var lastAlong = -1.0
        var alongAtReturn: Double = 0
        for (i, lat) in lats.enumerated() {
            engine.updateLocation(fix(lat: lat, lon: -117.00003, t: Double(i)))
            let along = try #require(engine.navPose).distanceAlongRoute
            #expect(along >= lastAlong)
            lastAlong = along
            alongAtReturn = along
        }

        // The final fix is physically at 33.002 — a full-polyline nearest scan
        // would put it ~222m along the outbound leg; the window keeps it on the
        // return leg, well past the turnaround.
        #expect(alongAtReturn > halfway)
        engine.stopNavigation()
    }

    @Test("Bearing rotates continuously along an arc with no vertex steps")
    func bearingContinuityOnArc() throws {
        // Quarter circle, radius 500m, one vertex every 3 degrees
        let center = CLLocationCoordinate2D(latitude: 33.0, longitude: -117.0)
        let polyline = stride(from: 0.0, through: 90.0, by: 3.0).map {
            RouteGeometry.offsetCoordinate(center, distanceMeters: 500, bearingDegrees: $0)
        }

        let engine = NavigationEngine()
        engine.startNavigation(polyline: polyline, steps: silentSteps(along: polyline))

        var bearings: [Double] = []
        for i in stride(from: 0, to: 20, by: 2) {
            engine.updateLocation(fix(lat: polyline[i].latitude, lon: polyline[i].longitude, t: Double(i)))
            let pose = try #require(engine.navPose)
            bearings.append(try #require(pose.segmentBearingDegrees))
        }

        #expect(bearings.count == 10)
        for i in 1..<bearings.count {
            #expect(circularDelta(bearings[i], bearings[i - 1]) < 12)
        }
        // The tangent should have rotated meaningfully across the arc
        #expect(circularDelta(bearings.first ?? 0, bearings.last ?? 0) > 30)
        engine.stopNavigation()
    }

    @Test("No polyline yields nil pose and heading holds nil without course")
    func nilPoseAndHeading() {
        let engine = NavigationEngine()
        let steps = [NavStep(instruction: "", distance: 100, coordinate: CLLocationCoordinate2D(latitude: 34, longitude: -118), maneuverSymbol: "arrow.up")]
        engine.startNavigation(polyline: [], steps: steps)

        engine.updateLocation(fix(lat: 33.0, lon: -117.0, course: -1, speed: 0))
        #expect(engine.navPose == nil)
        #expect(engine.headingDegrees == nil)
        engine.stopNavigation()
    }

    @Test("Heading uses GPS course off-route and holds when course goes invalid")
    func headingPriorityAndHold() throws {
        let engine = NavigationEngine()
        let polyline = straightRoute(segments: 20)
        engine.startNavigation(polyline: polyline, steps: silentSteps(along: polyline))

        // ~900m east of the route: off-route, so route bearing is not trusted
        engine.updateLocation(fix(lat: 33.005, lon: -116.99, course: 90, courseAccuracy: 5, speed: 13, t: 0))
        let heading = try #require(engine.headingDegrees)
        #expect(abs(heading - 90) < 0.01)

        // Stopped with invalid course: bearing must hold, never reset
        engine.updateLocation(fix(lat: 33.005, lon: -116.99, course: -1, speed: 0, t: 1))
        #expect(try #require(engine.headingDegrees) == heading)
        engine.stopNavigation()
    }

    @Test("Outbound fixes on an out-and-back stay on the outbound leg")
    func outAndBackOutboundLeg() throws {
        // Identical geometry to the return-leg test, but drive only OUTBOUND:
        // every fix must project near its true outbound arc length, never jump
        // ahead to the geometrically identical return leg.
        let out = (0...10).map { CLLocationCoordinate2D(latitude: 33.0 + Double($0) * 0.0005, longitude: -117.0) }
        let back = (1...10).map { CLLocationCoordinate2D(latitude: 33.005 - Double($0) * 0.0005, longitude: -117.0) }
        let polyline = out + back

        let engine = NavigationEngine()
        engine.startNavigation(polyline: polyline, steps: silentSteps(along: polyline))

        let halfway = RouteGeometry.cumulativeDistances(polyline)[10]

        for (i, lat) in [33.001, 33.002, 33.003, 33.004].enumerated() {
            engine.updateLocation(fix(lat: lat, lon: -117.00003, t: Double(i)))
            let along = try #require(engine.navPose).distanceAlongRoute
            let expected = (lat - 33.0) / 0.005 * halfway
            #expect(abs(along - expected) < 15)
            #expect(along < halfway)
        }
        engine.stopNavigation()
    }

    @Test("Valid GPS course below the speed gate holds the heading")
    func slowSpeedCourseGated() throws {
        let engine = NavigationEngine()
        let polyline = straightRoute(segments: 20)
        engine.startNavigation(polyline: polyline, steps: silentSteps(along: polyline))

        // Establish a heading from a fast off-route fix with a valid course
        engine.updateLocation(fix(lat: 33.005, lon: -116.99, course: 90, courseAccuracy: 5, speed: 13, t: 0))
        let heading = try #require(engine.headingDegrees)
        #expect(abs(heading - 90) < 0.01)

        // Crawling (2.0 m/s <= 2.5 gate) with a wildly different valid course:
        // the course must not be trusted — heading holds
        engine.updateLocation(fix(lat: 33.005, lon: -116.99, course: 180, courseAccuracy: 5, speed: 2.0, t: 1))
        #expect(try #require(engine.headingDegrees) == heading)
        engine.stopNavigation()
    }

    @Test("Negative courseAccuracy gates the GPS course even at speed")
    func negativeCourseAccuracyGated() throws {
        let engine = NavigationEngine()
        let polyline = straightRoute(segments: 20)
        engine.startNavigation(polyline: polyline, steps: silentSteps(along: polyline))

        engine.updateLocation(fix(lat: 33.005, lon: -116.99, course: 90, courseAccuracy: 5, speed: 13, t: 0))
        let heading = try #require(engine.headingDegrees)

        // Fast fix, plausible course value, but courseAccuracy says invalid
        engine.updateLocation(fix(lat: 33.005, lon: -116.99, course: 180, courseAccuracy: -1, speed: 13, t: 1))
        #expect(try #require(engine.headingDegrees) == heading)
        engine.stopNavigation()
    }

    @Test("On-route heading converges to the route bearing")
    func headingConvergesToRouteBearing() throws {
        let engine = NavigationEngine()
        let polyline = straightRoute(segments: 20)
        engine.startNavigation(polyline: polyline, steps: silentSteps(along: polyline))

        // Route runs due north (0 degrees); feed fixes with a noisy east course
        for i in 0..<12 {
            engine.updateLocation(fix(lat: 33.0 + Double(i) * 0.0003, lon: -117.0, course: 40, courseAccuracy: 5, t: Double(i)))
        }
        let heading = try #require(engine.headingDegrees)
        #expect(circularDelta(heading, 0) < 5)
        engine.stopNavigation()
    }
}
