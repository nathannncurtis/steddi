import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import Steddi

// MARK: - Helpers

private let downtown = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)

/// A coordinate roughly `meters` north of a base point (~111,320 m / degree lat).
private func north(of base: CLLocationCoordinate2D, meters: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: base.latitude + meters / 111_320.0, longitude: base.longitude)
}

/// A coordinate roughly `meters` east of a base point (longitude scaled by cos lat).
private func east(of base: CLLocationCoordinate2D, meters: Double) -> CLLocationCoordinate2D {
    let metersPerDegLon = 111_320.0 * cos(base.latitude * .pi / 180)
    return CLLocationCoordinate2D(latitude: base.latitude, longitude: base.longitude + meters / metersPerDegLon)
}

private func node(_ id: Int, _ kind: CameraReportKind, at coord: CLLocationCoordinate2D) -> SpeedCameraNode {
    SpeedCameraNode(nodeID: id, kind: kind, lat: coord.latitude, lon: coord.longitude)
}

private func alert(_ id: String, _ kind: CameraReportKind, at coord: CLLocationCoordinate2D, distance: Double = 0) -> SpeedCameraAlert {
    SpeedCameraAlert(alertID: id, kind: kind, coordinate: coord, distanceMeters: distance)
}

private func inMemoryContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: ModelStoreLocator.schema, configurations: [config])
}

// MARK: - Overpass node JSON builders

private func nodeJSON(id: Int, lat: Double, lon: Double, tags: [String: String]) -> String {
    let tagPairs = tags.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
    return #"{"type":"node","id":\#(id),"lat":\#(lat),"lon":\#(lon),"tags":{\#(tagPairs)}}"#
}

private func overpassData(_ elements: String...) -> Data {
    Data(#"{"elements":[\#(elements.joined(separator: ","))]}"#.utf8)
}

// MARK: - Tag classification

@Suite("SpeedCameraService.cameraKind tag classification")
struct CameraKindClassificationTests {

    @Test("highway=speed_camera is a speed camera")
    func highwaySpeedCamera() {
        #expect(SpeedCameraService.cameraKind(from: ["highway": "speed_camera"]) == .speedCamera)
    }

    @Test("enforcement=maxspeed is a speed camera")
    func enforcementMaxspeed() {
        #expect(SpeedCameraService.cameraKind(from: ["enforcement": "maxspeed"]) == .speedCamera)
    }

    @Test("enforcement=average_speed is a speed camera")
    func enforcementAverageSpeed() {
        #expect(SpeedCameraService.cameraKind(from: ["enforcement": "average_speed"]) == .speedCamera)
    }

    @Test("enforcement=traffic_signals is a red-light camera")
    func enforcementTrafficSignals() {
        #expect(SpeedCameraService.cameraKind(from: ["enforcement": "traffic_signals"]) == .redLightCamera)
    }

    @Test("Traffic-signals enforcement outranks a speed component")
    func redLightTakesPrecedence() {
        // A combined node enforcing both signals and speed reads as red-light.
        #expect(SpeedCameraService.cameraKind(from: ["enforcement": "traffic_signals;maxspeed"]) == .redLightCamera)
    }

    @Test("Uppercase tag values still classify")
    func uppercaseValues() {
        #expect(SpeedCameraService.cameraKind(from: ["highway": "SPEED_CAMERA"]) == .speedCamera)
        #expect(SpeedCameraService.cameraKind(from: ["enforcement": "MAXSPEED"]) == .speedCamera)
    }

    @Test("Non-camera enforcement (toll) is nil")
    func nonCameraEnforcement() {
        #expect(SpeedCameraService.cameraKind(from: ["enforcement": "toll"]) == nil)
    }

    @Test("Unrelated tags are nil")
    func unrelatedTags() {
        #expect(SpeedCameraService.cameraKind(from: ["amenity": "cafe"]) == nil)
    }

    @Test("nil tags are nil")
    func nilTags() {
        #expect(SpeedCameraService.cameraKind(from: nil) == nil)
    }
}

// MARK: - Overpass parsing

@Suite("SpeedCameraService.parseOverpassResponse")
struct CameraParsingTests {

    @Test("Speed camera node parses with correct kind and coords")
    func speedCameraNode() throws {
        let data = overpassData(nodeJSON(id: 1, lat: 34.05, lon: -118.24, tags: ["highway": "speed_camera"]))
        let cameras = try SpeedCameraService.parseOverpassResponse(data)
        #expect(cameras.count == 1)
        #expect(cameras.first?.nodeID == 1)
        #expect(cameras.first?.kind == .speedCamera)
        #expect(cameras.first?.lat == 34.05)
        #expect(cameras.first?.lon == -118.24)
    }

    @Test("Red-light enforcement node parses as red-light camera")
    func redLightNode() throws {
        let data = overpassData(nodeJSON(id: 2, lat: 34.05, lon: -118.24, tags: ["enforcement": "traffic_signals"]))
        let cameras = try SpeedCameraService.parseOverpassResponse(data)
        #expect(cameras.first?.kind == .redLightCamera)
    }

    @Test("Non-camera nodes are filtered out")
    func nonCameraFiltered() throws {
        let data = overpassData(
            nodeJSON(id: 3, lat: 34.05, lon: -118.24, tags: ["highway": "speed_camera"]),
            nodeJSON(id: 4, lat: 34.05, lon: -118.24, tags: ["amenity": "bench"]),
            nodeJSON(id: 5, lat: 34.05, lon: -118.24, tags: ["enforcement": "toll"])
        )
        let cameras = try SpeedCameraService.parseOverpassResponse(data)
        #expect(cameras.count == 1)
        #expect(cameras.first?.nodeID == 3)
    }

    @Test("Node missing coordinates is skipped")
    func missingCoords() throws {
        let bad = #"{"type":"node","id":6,"tags":{"highway":"speed_camera"}}"#
        let data = overpassData(bad)
        let cameras = try SpeedCameraService.parseOverpassResponse(data)
        #expect(cameras.isEmpty)
    }

    @Test("Empty element list parses to empty")
    func emptyList() throws {
        let cameras = try SpeedCameraService.parseOverpassResponse(Data(#"{"elements":[]}"#.utf8))
        #expect(cameras.isEmpty)
    }

    @Test("Malformed JSON throws")
    func malformedJSON() {
        #expect(throws: (any Error).self) {
            _ = try SpeedCameraService.parseOverpassResponse(Data("not json".utf8))
        }
    }

    @Test("A non-node element (way) carrying camera tags is skipped")
    func nonNodeTypeSkipped() throws {
        // Overpass can return way/relation elements; only point nodes are cameras.
        let way = #"{"type":"way","id":7,"lat":34.05,"lon":-118.24,"tags":{"highway":"speed_camera"}}"#
        let cameras = try SpeedCameraService.parseOverpassResponse(overpassData(way))
        #expect(cameras.isEmpty)
    }

    @Test("Node with no tags object is skipped")
    func nodeWithoutTags() throws {
        let untagged = #"{"type":"node","id":8,"lat":34.05,"lon":-118.24}"#
        let cameras = try SpeedCameraService.parseOverpassResponse(overpassData(untagged))
        #expect(cameras.isEmpty)
    }

    @Test("average_speed enforcement and a combined signals;speed mix both parse")
    func averageAndCombinedParse() throws {
        let data = overpassData(
            nodeJSON(id: 9, lat: 34.05, lon: -118.24, tags: ["enforcement": "average_speed"]),
            nodeJSON(id: 10, lat: 34.06, lon: -118.25, tags: ["enforcement": "traffic_signals;maxspeed"])
        )
        let cameras = try SpeedCameraService.parseOverpassResponse(data)
        #expect(cameras.count == 2)
        #expect(cameras.first { $0.nodeID == 9 }?.kind == .speedCamera)
        #expect(cameras.first { $0.nodeID == 10 }?.kind == .redLightCamera)
    }
}

// MARK: - Overpass query

@Suite("SpeedCameraService.overpassQuery")
struct CameraQueryTests {

    @Test("Query targets speed_camera and enforcement nodes")
    func queryShape() {
        let query = SpeedCameraService.overpassQuery(for: [downtown])
        #expect(query.contains(#"["highway"="speed_camera"]"#))
        #expect(query.contains(#"["enforcement"]"#))
        #expect(query.contains("node(around:"))
        #expect(query.contains("out tags;"))
    }

    @Test("Empty point list yields empty query")
    func emptyPoints() {
        #expect(SpeedCameraService.overpassQuery(for: []).isEmpty)
    }
}

// MARK: - Spatial grid lookup

@Suite("SpeedCameraGridIndex spatial lookup")
struct CameraGridIndexTests {

    @Test("A camera is found from its own cell")
    func findsInOwnCell() {
        let index = SpeedCameraGridIndex(osmCameras: [node(1, .speedCamera, at: downtown)], reports: [])
        let found = index.candidates(near: downtown)
        #expect(found.contains { $0.alertID == "osm-1" })
    }

    @Test("A camera one cell over is still a candidate via neighbor search")
    func findsAcrossCellBoundary() {
        // ~150m north lands in (or adjacent to) the next ~278m cell; the
        // center-plus-8-neighbors query must still surface it.
        let near = north(of: downtown, meters: 150)
        let index = SpeedCameraGridIndex(osmCameras: [node(1, .speedCamera, at: near)], reports: [])
        let found = index.candidates(near: downtown)
        #expect(found.contains { $0.alertID == "osm-1" })
    }

    @Test("A camera far away is not a candidate")
    func excludesDistant() {
        let far = north(of: downtown, meters: 5_000)
        let index = SpeedCameraGridIndex(osmCameras: [node(1, .speedCamera, at: far)], reports: [])
        let found = index.candidates(near: downtown)
        #expect(found.isEmpty)
    }

    @Test("OSM cameras and active reports are unified in one index")
    func unifiesSources() throws {
        let report = CameraReport(kind: .redLightCamera, coordinate: downtown)
        let index = SpeedCameraGridIndex(
            osmCameras: [node(1, .speedCamera, at: downtown)],
            reports: [report]
        )
        #expect(index.cameraCount == 2)
        let found = index.candidates(near: downtown)
        #expect(found.contains { $0.kind == .speedCamera })
        #expect(found.contains { $0.kind == .redLightCamera })
    }

    @Test("Expired reports are excluded from the index")
    func excludesExpiredReports() {
        let expired = CameraReport(kind: .speedCamera, coordinate: downtown, status: .expired)
        let index = SpeedCameraGridIndex(osmCameras: [], reports: [expired])
        #expect(index.cameraCount == 0)
    }

    @Test("Two cameras in the same cell both surface as candidates")
    func multipleInSameCell() {
        // ~20m apart -> same ~278m cell; both must be returned.
        let a = node(1, .speedCamera, at: downtown)
        let b = node(2, .redLightCamera, at: north(of: downtown, meters: 20))
        let index = SpeedCameraGridIndex(osmCameras: [a, b], reports: [])
        let found = index.candidates(near: downtown)
        #expect(found.contains { $0.alertID == "osm-1" })
        #expect(found.contains { $0.alertID == "osm-2" })
    }

    @Test("Alert IDs are namespaced so an OSM node and a report can't collide")
    func alertIDsNamespaced() {
        let report = CameraReport(kind: .speedCamera, coordinate: downtown)
        let index = SpeedCameraGridIndex(
            osmCameras: [node(42, .speedCamera, at: downtown)],
            reports: [report]
        )
        let ids = Set(index.candidates(near: downtown).map(\.alertID))
        #expect(ids.contains("osm-42"))
        #expect(ids.contains("report-\(report.id.uuidString)"))
        #expect(ids.count == 2)
    }

    @Test("A camera within the alert radius due east is found at a high latitude")
    func findsHighLatitudeEastCamera() {
        // Anchorage (~61°N): the 0.005° cell is only ~270m wide E/W, so a fixed
        // 3×3 scan guarantees coverage to just ~270m — under the 350m alert
        // radius. A camera ~330m due east near a longitudinal cell boundary must
        // still be a candidate via the latitude-robust ring.
        let anchorage = CLLocationCoordinate2D(latitude: 61.2181, longitude: -149.9003)
        let cam = east(of: anchorage, meters: 330)
        // Sanity: the camera really is inside the alert radius.
        #expect(RouteGeometry.haversineDistance(from: anchorage, to: cam) <= SpeedCameraTuning.alertRadiusMeters)
        let index = SpeedCameraGridIndex(osmCameras: [node(1, .speedCamera, at: cam)], reports: [])
        let found = index.candidates(near: anchorage)
        #expect(found.contains { $0.alertID == "osm-1" })
    }

    @Test("High-latitude camera near a cell boundary surfaces from the worst-case offset")
    func findsHighLatitudeBoundaryCamera() {
        // Place the query point hard against the eastern edge of its cell so the
        // worst-case (point on the near boundary) is exercised, then a camera
        // ~340m further east must still be reachable.
        let baseLat = 61.0
        let cellWidthLon = SpeedCameraGridIndex.cellSizeDegrees
        let cellLon = floor(-150.0 / cellWidthLon)
        // ~1m inside the eastern boundary of the cell.
        let query = CLLocationCoordinate2D(
            latitude: baseLat,
            longitude: (cellLon + 1) * cellWidthLon - 0.0000001
        )
        let cam = east(of: query, meters: 340)
        #expect(RouteGeometry.haversineDistance(from: query, to: cam) <= SpeedCameraTuning.alertRadiusMeters)
        let index = SpeedCameraGridIndex(osmCameras: [node(7, .speedCamera, at: cam)], reports: [])
        let found = index.candidates(near: query)
        #expect(found.contains { $0.alertID == "osm-7" })
    }

    @Test("cellSearchRadius grows with latitude to keep the alert radius covered")
    func cellSearchRadiusLatitudeRobust() {
        let r = SpeedCameraTuning.alertRadiusMeters
        let socal = SpeedCameraGridIndex.cellSearchRadius(forMaxDistanceMeters: r, atLatitude: 34.0)
        let anchorage = SpeedCameraGridIndex.cellSearchRadius(forMaxDistanceMeters: r, atLatitude: 61.0)
        // Always at least the original 3×3 behavior, and never shrinking as the
        // cell narrows toward the pole.
        #expect(socal >= 1)
        #expect(anchorage >= socal)
        // The guaranteed-covered distance (ring cells × E/W meters-per-cell) must
        // reach the alert radius at the high latitude.
        let metersPerCellAnchorage = SpeedCameraGridIndex.cellSizeDegrees * 111_320.0 * cos(61.0 * .pi / 180)
        #expect(Double(anchorage) * metersPerCellAnchorage >= r)
    }
}

// MARK: - Proximity selection (closestAlert)

@Suite("SpeedCameraService.closestAlert proximity logic")
struct CameraProximityTests {

    @Test("In-range camera ahead is returned")
    func returnsInRange() throws {
        let cam = alert("a", .speedCamera, at: north(of: downtown, meters: 200))
        let result = SpeedCameraService.closestAlert(
            currentCoord: downtown,
            heading: 0, // heading north, camera is north -> ahead
            candidates: [cam],
            proximityThresholdMeters: 350
        )
        let hit = try #require(result)
        #expect(hit.alertID == "a")
        #expect(hit.distanceMeters > 150 && hit.distanceMeters < 250)
    }

    @Test("Camera beyond the threshold is nil")
    func excludesBeyondThreshold() {
        let cam = alert("a", .speedCamera, at: north(of: downtown, meters: 500))
        let result = SpeedCameraService.closestAlert(
            currentCoord: downtown,
            heading: 0,
            candidates: [cam],
            proximityThresholdMeters: 350
        )
        #expect(result == nil)
    }

    @Test("Camera behind the driver is ignored when heading is known")
    func ignoresBehind() {
        // Camera is north; driver heading south (180) -> camera is behind.
        let cam = alert("a", .speedCamera, at: north(of: downtown, meters: 200))
        let result = SpeedCameraService.closestAlert(
            currentCoord: downtown,
            heading: 180,
            candidates: [cam],
            proximityThresholdMeters: 350
        )
        #expect(result == nil)
    }

    @Test("With no heading, behind/ahead is not filtered")
    func noHeadingNoFilter() throws {
        let cam = alert("a", .speedCamera, at: north(of: downtown, meters: 200))
        let result = SpeedCameraService.closestAlert(
            currentCoord: downtown,
            heading: nil,
            candidates: [cam],
            proximityThresholdMeters: 350
        )
        #expect(result?.alertID == "a")
    }

    @Test("Higher-priority kind wins over a closer lower-priority camera")
    func priorityOverDistance() throws {
        // Both ahead and in range: red-light at 250m beats speed camera at 120m.
        let speed = alert("speed", .speedCamera, at: north(of: downtown, meters: 120))
        let redLight = alert("red", .redLightCamera, at: north(of: downtown, meters: 250))
        let result = SpeedCameraService.closestAlert(
            currentCoord: downtown,
            heading: 0,
            candidates: [speed, redLight],
            proximityThresholdMeters: 350
        )
        #expect(result?.alertID == "red")
    }

    @Test("Same-priority ties break to the closest")
    func tiesBreakClosest() throws {
        let nearCam = alert("near", .speedCamera, at: north(of: downtown, meters: 100))
        let farCam = alert("far", .speedCamera, at: north(of: downtown, meters: 300))
        let result = SpeedCameraService.closestAlert(
            currentCoord: downtown,
            heading: 0,
            candidates: [farCam, nearCam],
            proximityThresholdMeters: 350
        )
        #expect(result?.alertID == "near")
    }

    @Test("Empty candidate list is nil")
    func emptyCandidates() {
        let result = SpeedCameraService.closestAlert(
            currentCoord: downtown,
            heading: 0,
            candidates: [],
            proximityThresholdMeters: 350
        )
        #expect(result == nil)
    }

    @Test("The threshold is exclusive — a camera exactly at the radius is excluded")
    func thresholdIsExclusive() {
        // Place a camera ~200m north and use 200m as the exact threshold. The
        // haversine distance lands fractionally under/over 200; assert the
        // comparison is the strict `<` the implementation documents by using a
        // threshold just below the measured distance.
        let coord = north(of: downtown, meters: 200)
        let measured = RouteGeometry.haversineDistance(from: downtown, to: coord)
        let cam = alert("edge", .speedCamera, at: coord)
        // Threshold equal to the measured distance -> excluded (strict <).
        let atEdge = SpeedCameraService.closestAlert(
            currentCoord: downtown, heading: 0, candidates: [cam], proximityThresholdMeters: measured
        )
        #expect(atEdge == nil)
        // A hair above -> included.
        let justInside = SpeedCameraService.closestAlert(
            currentCoord: downtown, heading: 0, candidates: [cam], proximityThresholdMeters: measured + 0.01
        )
        #expect(justInside?.alertID == "edge")
    }

    @Test("Mobile trap loses to an equidistant speed camera on priority")
    func mobileLosesToSpeedCamera() throws {
        let here = north(of: downtown, meters: 150)
        let mobile = alert("mob", .mobileSpeedTrap, at: here)
        let speed = alert("spd", .speedCamera, at: here)
        let result = SpeedCameraService.closestAlert(
            currentCoord: downtown, heading: 0, candidates: [mobile, speed], proximityThresholdMeters: 350
        )
        #expect(result?.alertID == "spd")
    }
}

// MARK: - isAhead heading gate

@Suite("SpeedCameraService.isAhead heading gate")
struct CameraIsAheadTests {

    @Test("Target directly ahead is ahead")
    func directlyAhead() {
        let target = north(of: downtown, meters: 200)
        #expect(SpeedCameraService.isAhead(from: downtown, to: target, heading: 0))
    }

    @Test("Target directly behind is not ahead")
    func directlyBehind() {
        let target = north(of: downtown, meters: 200)
        #expect(!SpeedCameraService.isAhead(from: downtown, to: target, heading: 180))
    }

    @Test("Target within the cone is ahead")
    func withinCone() {
        // Camera to the NE while heading N (~45 deg off, inside the 75 deg cone).
        let target = CLLocationCoordinate2D(
            latitude: downtown.latitude + 0.0015,
            longitude: downtown.longitude + 0.0015
        )
        #expect(SpeedCameraService.isAhead(from: downtown, to: target, heading: 0))
    }

    @Test("Target perpendicular and far is outside the cone")
    func perpendicularOutsideCone() {
        let target = east(of: downtown, meters: 200) // 90 deg from a north heading
        #expect(!SpeedCameraService.isAhead(from: downtown, to: target, heading: 0))
    }

    @Test("A point-blank target always counts as ahead regardless of heading")
    func pointBlankBypass() {
        let target = north(of: downtown, meters: 10) // within aheadBypassMeters
        #expect(SpeedCameraService.isAhead(from: downtown, to: target, heading: 180))
    }

    @Test("Heading wraparound near 360/0 is handled (camera N, heading 350)")
    func wraparoundHeading() {
        // Camera due north (bearing 0); heading 350 is only 10 deg off, inside cone.
        let target = north(of: downtown, meters: 200)
        #expect(SpeedCameraService.isAhead(from: downtown, to: target, heading: 350))
    }

    @Test("Just inside the cone edge is ahead; just outside is not")
    func coneBoundary() {
        // East-ish target: bearing ~90 from the origin. Heading 20 -> 70 deg off
        // (inside the 75 cone); heading 10 -> 80 deg off (outside).
        let target = east(of: downtown, meters: 300)
        #expect(SpeedCameraService.isAhead(from: downtown, to: target, heading: 20))
        #expect(!SpeedCameraService.isAhead(from: downtown, to: target, heading: 10))
    }
}

// MARK: - Decay windows

@Suite("CameraReportDecay expiry windows")
struct CameraDecayTests {

    @Test("Mobile traps expire fast, fixed cameras slowly")
    func expirySeconds() {
        let mobile = CameraReportDecay.expirySeconds(for: .mobileSpeedTrap)
        let speed = CameraReportDecay.expirySeconds(for: .speedCamera)
        let redLight = CameraReportDecay.expirySeconds(for: .redLightCamera)
        #expect(mobile == 6 * 3_600)
        #expect(speed == 365 * 86_400)
        #expect(redLight == 365 * 86_400)
        #expect(mobile < speed)
    }
}

// MARK: - CRUD + sweep (store-backed)

@Suite("SpeedCameraService report CRUD and sweep")
@MainActor
struct CameraReportCRUDTests {

    private func makeService(now: @escaping () -> Date = { Date() }) throws -> SpeedCameraService {
        let service = SpeedCameraService(now: now)
        service.configure(container: try inMemoryContainer())
        return service
    }

    @Test("Reporting a camera persists an active report")
    func reportPersists() throws {
        let service = try makeService()
        let report = try #require(service.reportCamera(kind: .speedCamera, coordinate: downtown))
        #expect(report.status == .active)
        #expect(report.source == .userReport)
        #expect(service.fetchActiveReports().count == 1)
    }

    @Test("A reported camera becomes a proximity hit")
    func reportFeedsProximity() throws {
        let service = try makeService()
        service.reportCamera(kind: .redLightCamera, coordinate: north(of: downtown, meters: 150))
        let hit = service.checkProximity(currentCoord: downtown, heading: 0)
        #expect(hit?.kind == .redLightCamera)
    }

    @Test("Dismissing a report drops it from alerts immediately")
    func dismissRemovesFromAlerts() throws {
        let service = try makeService()
        let report = try #require(service.reportCamera(kind: .speedCamera, coordinate: north(of: downtown, meters: 100)))
        #expect(service.checkProximity(currentCoord: downtown, heading: 0) != nil)
        service.dismissReport(report)
        #expect(service.checkProximity(currentCoord: downtown, heading: 0) == nil)
        #expect(service.fetchActiveReports().isEmpty)
    }

    @Test("Confirming a report bumps the count and resets the decay timer")
    func confirmBumpsCount() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let service = try makeService(now: { clock })
        let report = try #require(service.reportCamera(kind: .mobileSpeedTrap, coordinate: downtown))
        clock = clock.addingTimeInterval(3_600)
        service.confirmReport(report)
        #expect(report.confirmationCount == 1)
        #expect(report.lastConfirmedAt == clock)
    }

    @Test("A confirmed-recently mobile trap survives the sweep (decay timer reset)")
    func confirmKeepsMobileTrapAlive() throws {
        var clock = Date(timeIntervalSince1970: 3_000_000)
        let service = try makeService(now: { clock })
        let trap = try #require(service.reportCamera(kind: .mobileSpeedTrap, coordinate: downtown))

        // Drive 5 hours, reconfirm, then drive 5 more (10h total since creation
        // but only 5h since last confirm -> still inside the 6h window).
        clock = clock.addingTimeInterval(5 * 3_600)
        service.confirmReport(trap)
        clock = clock.addingTimeInterval(5 * 3_600)
        let deleted = service.sweepExpiredReports()
        #expect(deleted == 0)
        #expect(service.fetchActiveReports().count == 1)
    }

    @Test("Sweep hard-deletes a soft-expired mobile trap once past its window")
    func sweepCollectsSoftExpired() throws {
        var clock = Date(timeIntervalSince1970: 4_000_000)
        let service = try makeService(now: { clock })
        let trap = try #require(service.reportCamera(kind: .mobileSpeedTrap, coordinate: downtown))
        service.dismissReport(trap) // soft-expire now
        #expect(service.fetchActiveReports().isEmpty) // hidden immediately

        // Still present as a row until past the decay window.
        #expect(service.sweepExpiredReports() == 0)
        clock = clock.addingTimeInterval(7 * 3_600)
        #expect(service.sweepExpiredReports() == 1)
    }

    @Test("Sweep removes stale mobile traps but keeps fixed cameras")
    func sweepHonorsKindWindows() throws {
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let service = try makeService(now: { clock })
        service.reportCamera(kind: .mobileSpeedTrap, coordinate: downtown)
        service.reportCamera(kind: .speedCamera, coordinate: east(of: downtown, meters: 500))

        // Advance 7 hours: past the 6h mobile window, well within the fixed window.
        clock = clock.addingTimeInterval(7 * 3_600)
        let deleted = service.sweepExpiredReports()
        #expect(deleted == 1)
        let remaining = service.fetchActiveReports()
        #expect(remaining.count == 1)
        #expect(remaining.first?.kind == .speedCamera)
    }
}

// MARK: - Engine debounce (one alert per camera per session)

@Suite("NavigationEngine speed-camera alert debounce")
@MainActor
struct CameraAlertDebounceTests {

    /// North-running straight route from (33, -117), ~111m per 0.001 deg.
    private func straightRoute(segments: Int) -> [CLLocationCoordinate2D] {
        (0...segments).map { CLLocationCoordinate2D(latitude: 33.0 + Double($0) * 0.001, longitude: -117.0) }
    }

    private func silentSteps(along polyline: [CLLocationCoordinate2D]) -> [NavStep] {
        [
            NavStep(instruction: "", distance: 1000, coordinate: polyline.first ?? CLLocationCoordinate2D(), maneuverSymbol: "arrow.up"),
            NavStep(instruction: "", distance: 0, coordinate: polyline.last ?? CLLocationCoordinate2D(), maneuverSymbol: "flag.fill"),
        ]
    }

    private func fix(lat: Double, lon: Double, t: TimeInterval) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: -1, courseAccuracy: -1, speed: 13, speedAccuracy: 1,
            timestamp: Date(timeIntervalSince1970: 1_750_000_000 + t)
        )
    }

    @Test("A single camera fires the approach callback exactly once")
    func firesOncePerCamera() {
        let engine = NavigationEngine()
        let polyline = straightRoute(segments: 20)
        engine.startNavigation(polyline: polyline, steps: silentSteps(along: polyline))

        let camera = alert("cam-1", .speedCamera, at: CLLocationCoordinate2D(latitude: 33.005, longitude: -117.0))
        engine.speedCameraProvider = { _, _ in camera }
        var fireCount = 0
        engine.onSpeedCameraApproaching = { _ in fireCount += 1 }

        // Several consecutive fixes while the same camera stays in range.
        for i in 0..<5 {
            engine.updateLocation(fix(lat: 33.001 + Double(i) * 0.0005, lon: -117.0, t: Double(i)))
        }
        #expect(fireCount == 1)
    }

    @Test("The approaching-camera banner state tracks and clears with range")
    func bannerStateTracksRange() {
        let engine = NavigationEngine()
        let polyline = straightRoute(segments: 20)
        engine.startNavigation(polyline: polyline, steps: silentSteps(along: polyline))

        var current: SpeedCameraAlert? = alert("cam-1", .redLightCamera, at: CLLocationCoordinate2D(latitude: 33.005, longitude: -117.0))
        engine.speedCameraProvider = { _, _ in current }

        engine.updateLocation(fix(lat: 33.002, lon: -117.0, t: 0))
        #expect(engine.approachingCamera?.alertID == "cam-1")

        // Camera passed — provider returns nil; banner clears.
        current = nil
        engine.updateLocation(fix(lat: 33.006, lon: -117.0, t: 1))
        #expect(engine.approachingCamera == nil)
    }

    @Test("Two distinct cameras each fire once")
    func distinctCamerasEachFire() {
        let engine = NavigationEngine()
        let polyline = straightRoute(segments: 20)
        engine.startNavigation(polyline: polyline, steps: silentSteps(along: polyline))

        let camA = alert("cam-A", .speedCamera, at: CLLocationCoordinate2D(latitude: 33.004, longitude: -117.0))
        let camB = alert("cam-B", .speedCamera, at: CLLocationCoordinate2D(latitude: 33.010, longitude: -117.0))
        var current: SpeedCameraAlert? = camA
        engine.speedCameraProvider = { _, _ in current }
        var fired: [String] = []
        engine.onSpeedCameraApproaching = { fired.append($0.alertID) }

        engine.updateLocation(fix(lat: 33.003, lon: -117.0, t: 0))
        engine.updateLocation(fix(lat: 33.0035, lon: -117.0, t: 1))
        current = camB
        engine.updateLocation(fix(lat: 33.009, lon: -117.0, t: 2))
        engine.updateLocation(fix(lat: 33.0095, lon: -117.0, t: 3))

        #expect(fired == ["cam-A", "cam-B"])
    }

    @Test("Debounce resets on a new navigation session")
    func debounceResetsOnRestart() {
        let engine = NavigationEngine()
        let polyline = straightRoute(segments: 20)
        let camera = alert("cam-1", .speedCamera, at: CLLocationCoordinate2D(latitude: 33.005, longitude: -117.0))
        engine.speedCameraProvider = { _, _ in camera }
        var fireCount = 0
        engine.onSpeedCameraApproaching = { _ in fireCount += 1 }

        engine.startNavigation(polyline: polyline, steps: silentSteps(along: polyline))
        engine.updateLocation(fix(lat: 33.002, lon: -117.0, t: 0))
        #expect(fireCount == 1)

        // Fresh session re-arms the same camera.
        engine.startNavigation(polyline: polyline, steps: silentSteps(along: polyline))
        engine.updateLocation(fix(lat: 33.002, lon: -117.0, t: 10))
        #expect(fireCount == 2)
    }
}
