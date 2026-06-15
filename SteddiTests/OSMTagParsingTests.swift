import Testing
import Foundation
@testable import Steddi

// The maxspeed/highway-class matrix was promoted out of `OSMSpeedLimitService`
// into `OSMTagParsing`; these suites re-pin it directly on the shared namespace
// and extend it to the new routing tag parsers (oneway, access, turn:lanes,
// road class, oncoming-lane estimation, boolean tags, free-flow m/s).
// `OSMSpeedLimitService` still forwards to these, so its own tests also stand.

// MARK: - Maxspeed

@Suite("OSMTagParsing.parseMaxspeed")
struct OSMTagParsingMaxspeedTests {

    @Test("mph value parses directly")
    func mphValue() {
        #expect(OSMTagParsing.parseMaxspeed("35 mph") == 35)
    }

    @Test("mph without space parses")
    func mphNoSpace() {
        #expect(OSMTagParsing.parseMaxspeed("65mph") == 65)
    }

    @Test("Uppercase MPH parses")
    func mphUppercase() {
        #expect(OSMTagParsing.parseMaxspeed("25 MPH") == 25)
    }

    @Test("Bare number is km/h converted to mph")
    func bareNumberIsKmh() throws {
        let result = try #require(OSMTagParsing.parseMaxspeed("50"))
        #expect(abs(result - 31.06855) < 0.001)
    }

    @Test("Explicit km/h suffix converts to mph")
    func explicitKmh() throws {
        let result = try #require(OSMTagParsing.parseMaxspeed("30 km/h"))
        #expect(abs(result - 18.64113) < 0.001)
    }

    @Test("Non-numeric values return nil", arguments: [
        "none", "signals", "walk", "fast", "variable", "10 knots", "30 mph;45 mph",
    ])
    func nonNumeric(value: String) {
        #expect(OSMTagParsing.parseMaxspeed(value) == nil)
    }

    @Test("Empty, nil, zero, negative return nil", arguments: ["", "0", "-10"])
    func degenerate(value: String) {
        #expect(OSMTagParsing.parseMaxspeed(value) == nil)
    }

    @Test("nil returns nil")
    func nilValue() {
        #expect(OSMTagParsing.parseMaxspeed(nil) == nil)
    }

    @Test("Surrounding whitespace is trimmed")
    func whitespacePadded() {
        #expect(OSMTagParsing.parseMaxspeed("  35 mph  ") == 35)
    }

    @Test("Uppercase KM/H suffix converts")
    func uppercaseKmh() throws {
        let result = try #require(OSMTagParsing.parseMaxspeed("30 KM/H"))
        #expect(abs(result - 18.64113) < 0.001)
    }

    @Test("Decimal bare value converts as km/h")
    func decimalKmh() throws {
        let result = try #require(OSMTagParsing.parseMaxspeed("32.5"))
        #expect(abs(result - 32.5 * 0.621371) < 0.001)
    }
}

// MARK: - Highway-class defaults

@Suite("OSMTagParsing.defaultSpeedMph")
struct OSMTagParsingClassDefaultTests {

    @Test("Highway class defaults", arguments: [
        ("motorway", 65.0),
        ("trunk", 55.0),
        ("primary", 45.0),
        ("secondary", 40.0),
        ("tertiary", 35.0),
        ("unclassified", 35.0),
        ("residential", 25.0),
        ("living_street", 10.0),
        ("service", 15.0),
        ("motorway_link", 35.0),
        ("trunk_link", 35.0),
        ("primary_link", 35.0),
        ("secondary_link", 35.0),
        ("tertiary_link", 35.0),
    ])
    func classDefault(highway: String, expected: Double) {
        #expect(OSMTagParsing.defaultSpeedMph(forHighwayClass: highway) == expected)
    }

    @Test("Unknown classes return nil", arguments: ["footway", "cycleway", "path", "steps"])
    func unknownClass(highway: String) {
        #expect(OSMTagParsing.defaultSpeedMph(forHighwayClass: highway) == nil)
    }
}

// MARK: - Free-flow m/s

@Suite("OSMTagParsing.freeFlowSpeedMPS")
struct OSMTagParsingFreeFlowTests {

    @Test("Parsed maxspeed converts mph -> m/s")
    func parsedMaxspeed() throws {
        // 35 mph * 0.44704 = 15.6464 m/s
        let mps = try #require(OSMTagParsing.freeFlowSpeedMPS(maxspeed: "35 mph", highway: "residential"))
        #expect(abs(mps - 35 * 0.44704) < 0.001)
    }

    @Test("Missing maxspeed falls back to class default in m/s")
    func classFallback() throws {
        // motorway default 65 mph -> m/s
        let mps = try #require(OSMTagParsing.freeFlowSpeedMPS(maxspeed: nil, highway: "motorway"))
        #expect(abs(mps - 65 * 0.44704) < 0.001)
    }

    @Test("Unparseable maxspeed falls back to class default")
    func unparseableFallsBack() throws {
        let mps = try #require(OSMTagParsing.freeFlowSpeedMPS(maxspeed: "none", highway: "primary"))
        #expect(abs(mps - 45 * 0.44704) < 0.001)
    }

    @Test("Unknown class with no maxspeed returns nil")
    func unknownClassNil() {
        #expect(OSMTagParsing.freeFlowSpeedMPS(maxspeed: nil, highway: "footway") == nil)
    }
}

// MARK: - Oneway

@Suite("OSMTagParsing.parseOneway")
struct OSMTagParsingOnewayTests {

    @Test("Explicit forward values", arguments: ["yes", "true", "1", " YES "])
    func forward(value: String) {
        #expect(OSMTagParsing.parseOneway(oneway: value) == .forward)
    }

    @Test("Explicit reverse values", arguments: ["-1", "reverse"])
    func reverse(value: String) {
        #expect(OSMTagParsing.parseOneway(oneway: value) == .reverse)
    }

    @Test("Explicit no/false/0 is bidirectional", arguments: ["no", "false", "0"])
    func both(value: String) {
        #expect(OSMTagParsing.parseOneway(oneway: value) == .both)
    }

    @Test("Absent oneway with no implicit default is bidirectional")
    func absentDefaultsBoth() {
        #expect(OSMTagParsing.parseOneway(oneway: nil) == .both)
    }

    @Test("junction=roundabout implies forward without explicit oneway")
    func roundaboutImpliesForward() {
        #expect(OSMTagParsing.parseOneway(oneway: nil, junction: "roundabout") == .forward)
        #expect(OSMTagParsing.parseOneway(oneway: nil, junction: "circular") == .forward)
    }

    @Test("highway=motorway implies forward without explicit oneway")
    func motorwayImpliesForward() {
        #expect(OSMTagParsing.parseOneway(oneway: nil, highway: "motorway") == .forward)
    }

    @Test("Explicit oneway=no overrides roundabout/motorway implicit default")
    func explicitOverridesImplicit() {
        #expect(OSMTagParsing.parseOneway(oneway: "no", junction: "roundabout") == .both)
        #expect(OSMTagParsing.parseOneway(oneway: "no", highway: "motorway") == .both)
    }

    @Test("Direction helpers report traversability")
    func directionHelpers() {
        #expect(OSMTagParsing.OnewayDirection.forward.allowsForward)
        #expect(!OSMTagParsing.OnewayDirection.forward.allowsReverse)
        #expect(!OSMTagParsing.OnewayDirection.reverse.allowsForward)
        #expect(OSMTagParsing.OnewayDirection.reverse.allowsReverse)
        #expect(OSMTagParsing.OnewayDirection.both.allowsForward)
        #expect(OSMTagParsing.OnewayDirection.both.allowsReverse)
    }
}

// MARK: - Access

@Suite("OSMTagParsing.parseAccess")
struct OSMTagParsingAccessTests {

    @Test("Default access is allowed")
    func defaultAllowed() {
        #expect(OSMTagParsing.parseAccess(access: nil) == .allowed)
    }

    @Test("private / no are restricted", arguments: ["private", "no"])
    func restricted(value: String) {
        #expect(OSMTagParsing.parseAccess(access: value) == .restricted)
    }

    @Test("destination / customers / delivery / permit are destination-only", arguments: [
        "destination", "customers", "delivery", "permit", "destination_only",
    ])
    func destinationOnly(value: String) {
        #expect(OSMTagParsing.parseAccess(access: value) == .destinationOnly)
    }

    @Test("permissive / designated / yes are allowed", arguments: ["permissive", "designated", "yes"])
    func allowed(value: String) {
        #expect(OSMTagParsing.parseAccess(access: value) == .allowed)
    }

    @Test("motor_vehicle takes precedence over generic access")
    func motorVehiclePrecedence() {
        // access=yes but motor_vehicle=no -> restricted for the driving profile.
        #expect(OSMTagParsing.parseAccess(access: "yes", motorVehicle: "no") == .restricted)
    }

    @Test("vehicle takes precedence over generic access when motor_vehicle absent")
    func vehiclePrecedence() {
        #expect(OSMTagParsing.parseAccess(access: "yes", vehicle: "destination") == .destinationOnly)
    }

    @Test("Unknown token falls through to the next mode tag")
    func unknownFallsThrough() {
        // motor_vehicle has an unrecognized value; access=private decides.
        #expect(OSMTagParsing.parseAccess(access: "private", motorVehicle: "agricultural") == .restricted)
    }
}

// MARK: - Turn lanes

@Suite("OSMTagParsing.parseTurnLanes")
struct OSMTagParsingTurnLanesTests {

    @Test("Empty / nil tag yields no lanes")
    func emptyYieldsNone() {
        #expect(OSMTagParsing.parseTurnLanes(nil).isEmpty)
        #expect(OSMTagParsing.parseTurnLanes("").isEmpty)
    }

    @Test("Four-lane left|through|through|right parses per lane")
    func fourLanes() {
        let lanes = OSMTagParsing.parseTurnLanes("left|through|through|right")
        #expect(lanes.count == 4)
        #expect(lanes[0].isDedicatedLeft)
        #expect(lanes[1].through && !lanes[1].left && !lanes[1].right)
        #expect(lanes[3].isDedicatedRight)
    }

    @Test("Empty cell ('none') is an unrestricted through lane")
    func emptyCellIsThrough() {
        let lanes = OSMTagParsing.parseTurnLanes("left|none|")
        #expect(lanes.count == 3)
        #expect(lanes[0].isDedicatedLeft)
        #expect(lanes[1].through && !lanes[1].left && !lanes[1].right)
        #expect(lanes[2].through)
    }

    @Test("Combined directions in one cell set multiple flags")
    func combinedCell() {
        let lanes = OSMTagParsing.parseTurnLanes("left;through")
        #expect(lanes.count == 1)
        #expect(lanes[0].left && lanes[0].through)
        #expect(!lanes[0].isDedicatedLeft)
    }

    @Test("slight_left / sharp_right map to cardinal left / right")
    func slightAndSharp() {
        let lanes = OSMTagParsing.parseTurnLanes("slight_left|sharp_right")
        #expect(lanes[0].left)
        #expect(lanes[1].right)
    }

    @Test("reverse is a U-turn lane, not a dedicated left pocket")
    func reverseIsUTurn() {
        // `reverse` is a U-turn lane. It must NOT read as a dedicated left, or the
        // cost model bills it a protected-left phase it doesn't have.
        let reverse = OSMTagParsing.parseTurnLanes("reverse")
        #expect(reverse[0].uTurn)
        #expect(!reverse[0].left)
        #expect(!reverse[0].isDedicatedLeft)
        // A shared left+U-turn pocket keeps left but is no longer "dedicated".
        let leftReverse = OSMTagParsing.parseTurnLanes("left;reverse")
        #expect(leftReverse[0].left && leftReverse[0].uTurn)
        #expect(!leftReverse[0].isDedicatedLeft)
    }

    @Test("merge_to_left / merge_to_right are through lanes, not turns")
    func mergeIsThrough() {
        // A merge lane is ending; the driver continues straight while changing
        // lanes. `_to_left`/`_to_right` names the adjacent lane to move into, not a
        // turn — neither sets a turn flag.
        let mergeLeft = OSMTagParsing.parseTurnLanes("merge_to_left")
        #expect(mergeLeft[0].through && !mergeLeft[0].left && !mergeLeft[0].right)
        let mergeRight = OSMTagParsing.parseTurnLanes("merge_to_right")
        #expect(mergeRight[0].through && !mergeRight[0].left && !mergeRight[0].right)
    }

    @Test("Trailing empty cell is preserved as an unrestricted lane")
    func trailingEmptyCellPreserved() {
        // omittingEmptySubsequences:false keeps the trailing "" cell so lane
        // count stays aligned with the physical lanes.
        let lanes = OSMTagParsing.parseTurnLanes("left||right")
        #expect(lanes.count == 3)
        #expect(lanes[0].isDedicatedLeft)
        #expect(lanes[1].through) // empty middle cell → through
        #expect(lanes[2].isDedicatedRight)
    }
}

// MARK: - Oncoming lane count

@Suite("OSMTagParsing.oncomingLaneCount")
struct OSMTagParsingOncomingTests {

    @Test("Oneway road has zero oncoming lanes")
    func onewayZero() {
        #expect(OSMTagParsing.oncomingLaneCount(lanes: "4", oneway: .forward) == 0)
        #expect(OSMTagParsing.oncomingLaneCount(lanes: "4", oneway: .reverse) == 0)
    }

    @Test("Two-way lanes=4 estimates 2 oncoming")
    func twoWayHalf() {
        #expect(OSMTagParsing.oncomingLaneCount(lanes: "4", oneway: .both) == 2)
    }

    @Test("Two-way lanes=2 estimates 1 oncoming")
    func twoWayMinOne() {
        #expect(OSMTagParsing.oncomingLaneCount(lanes: "2", oneway: .both) == 1)
    }

    @Test("lanes:forward refines the oncoming estimate")
    func forwardRefines() {
        // total 5, forward 3 -> 2 oncoming.
        #expect(OSMTagParsing.oncomingLaneCount(lanes: "5", lanesForward: "3", oneway: .both) == 2)
    }

    @Test("No lane data assumes one oncoming lane")
    func noDataAssumesOne() {
        #expect(OSMTagParsing.oncomingLaneCount(lanes: nil, oneway: .both) == 1)
    }
}

// MARK: - Road class

@Suite("OSMTagParsing.parseRoadClass")
struct OSMTagParsingRoadClassTests {

    @Test("Drivable classes map to their enum case", arguments: [
        ("motorway", RoadClass.motorway),
        ("trunk", .trunk),
        ("primary", .primary),
        ("secondary", .secondary),
        ("tertiary", .tertiary),
        ("unclassified", .unclassified),
        ("residential", .residential),
        ("living_street", .livingStreet),
        ("service", .service),
    ])
    func drivable(highway: String, expected: RoadClass) {
        #expect(OSMTagParsing.parseRoadClass(highway) == expected)
    }

    @Test("All *_link ramps collapse to .link", arguments: [
        "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link",
    ])
    func links(highway: String) {
        #expect(OSMTagParsing.parseRoadClass(highway) == .link)
    }

    @Test("Non-drivable classes map to .unknown", arguments: [
        "footway", "path", "cycleway", "steps", "track", "pedestrian", "bridleway",
    ])
    func nonDrivable(highway: String) {
        #expect(OSMTagParsing.parseRoadClass(highway) == .unknown)
    }

    @Test("nil / empty highway is .unknown")
    func nilUnknown() {
        #expect(OSMTagParsing.parseRoadClass(nil) == .unknown)
        #expect(OSMTagParsing.parseRoadClass("") == .unknown)
    }

    @Test("RoadClass ordering follows priority (motorway < residential)")
    func ordering() {
        #expect(RoadClass.motorway < RoadClass.residential)
        #expect(RoadClass.primary < RoadClass.service)
    }
}

// MARK: - Boolean tags

@Suite("OSMTagParsing.parseBoolTag")
struct OSMTagParsingBoolTests {

    @Test("Strict yes/true/1 are true", arguments: ["yes", "true", "1"])
    func strictTrue(value: String) {
        #expect(OSMTagParsing.parseBoolTag(value))
    }

    @Test("Strict mode treats anything else as false", arguments: ["no", "culvert", "viaduct", ""])
    func strictFalse(value: String) {
        #expect(!OSMTagParsing.parseBoolTag(value))
    }

    @Test("nil is false in both modes")
    func nilFalse() {
        #expect(!OSMTagParsing.parseBoolTag(nil))
        #expect(!OSMTagParsing.parseBoolTag(nil, presentIfNonNo: true))
    }

    @Test("presentIfNonNo treats tunnel/bridge values other than no as present", arguments: [
        "yes", "culvert", "viaduct", "building_passage",
    ])
    func presentIfNonNo(value: String) {
        #expect(OSMTagParsing.parseBoolTag(value, presentIfNonNo: true))
    }

    @Test("presentIfNonNo treats no/false/0 as absent", arguments: ["no", "false", "0"])
    func presentIfNonNoNegatives(value: String) {
        #expect(!OSMTagParsing.parseBoolTag(value, presentIfNonNo: true))
    }
}
