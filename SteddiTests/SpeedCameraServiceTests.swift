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
