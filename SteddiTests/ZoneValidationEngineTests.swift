import Testing
import Foundation
import CoreLocation
import SwiftData
@testable import Steddi

@Suite("ZoneValidationEngine")
struct ZoneValidationEngineTests {

    private let engine = ZoneValidationEngine()

    /// Encode a coordinate list to a precision-6 polyline (route under test).
    private func polyline(_ coords: [CLLocationCoordinate2D]) -> String {
        PolylineEncoder.encode(coords, precision: 6)
    }

    // A route running east near the equator, away from the test zones below.
    private var clearRoute: String {
        polyline([
            CLLocationCoordinate2D(latitude: 10, longitude: 10),
            CLLocationCoordinate2D(latitude: 10, longitude: 10.01),
        ])
    }

    @Test("Route clear of all zones is valid")
    func clear() {
        let zone = NoGoZone(latitude: 0, longitude: 0, radiusMeters: 100)
        let result = engine.validateRoute(clearRoute, againstZones: [zone])
        #expect(result.isValid)
        #expect(result.severity == .clear)
    }

    @Test("Route through a circle zone is flagged point-in-zone")
    func circleViolation() {
        let route = polyline([
            CLLocationCoordinate2D(latitude: -0.001, longitude: 0),
            CLLocationCoordinate2D(latitude: 0.001, longitude: 0),
        ])
        let zone = NoGoZone(latitude: 0, longitude: 0, radiusMeters: 200)
        let result = engine.validateRoute(route, againstZones: [zone])
        #expect(!result.isValid)
        #expect(result.violationCount == 1)
        #expect(result.violations.first?.violationType == .pointInZone)
    }

    @Test("Route through a polygon zone is flagged polygon violation")
    func polygonViolation() {
        let square = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 1),
            CLLocationCoordinate2D(latitude: 1, longitude: 1),
            CLLocationCoordinate2D(latitude: 1, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
        ]
        let zone = NoGoZone(geometry: .polygon(encodedPolyline: PolylineEncoder.encode(square, precision: 6)))
        let route = polyline([
            CLLocationCoordinate2D(latitude: 0.5, longitude: -0.5),
            CLLocationCoordinate2D(latitude: 0.5, longitude: 0.5),  // inside square
        ])
        let result = engine.validateRoute(route, againstZones: [zone])
        #expect(!result.isValid)
        #expect(result.violations.first?.violationType == .polygonViolation)
    }

    @Test("Route within a corridor buffer is flagged with its distance")
    func corridorViolation() {
        let centerline = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 0.01),
        ]
        let zone = NoGoZone(geometry: .corridor(
            encodedPolyline: PolylineEncoder.encode(centerline, precision: 6),
            bufferMeters: 50
        ))
        // Route point sits right on the corridor.
        let route = polyline([
            CLLocationCoordinate2D(latitude: 0, longitude: 0.004),
            CLLocationCoordinate2D(latitude: 0, longitude: 0.006),
        ])
        let result = engine.validateRoute(route, againstZones: [zone])
        #expect(!result.isValid)
        if case .corridorViolation(let d) = result.violations.first?.violationType {
            #expect(d <= 50)
        } else {
            Issue.record("expected corridor violation")
        }
    }

    @Test("Severity escalates clear -> warning -> critical with violation count")
    func severityLevels() {
        let z1 = NoGoZone(latitude: 0, longitude: 0, radiusMeters: 300)
        let z2 = NoGoZone(latitude: 0.0001, longitude: 0, radiusMeters: 300)
        let route = polyline([
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0.0001, longitude: 0),
        ])
        #expect(engine.validateRoute(route, againstZones: [z1]).severity == .warning)
        #expect(engine.validateRoute(route, againstZones: [z1, z2]).severity == .critical)
    }

    @Test("Inactive time-window zones are skipped")
    func timeWindowSkipped() {
        // Build a zone the route would violate, but with a window inactive at `now`.
        let zone = NoGoZone(
            geometry: .circle(center: CLLocationCoordinate2D(latitude: 0, longitude: 0), radiusMeters: 300),
            timeWindow: TimeWindow(daysOfWeek: [2], startHour: 7, endHour: 8)
        )
        let route = polyline([
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0.0001, longitude: 0),
        ])
        // A Sunday — window inactive, so no violation despite geometric overlap.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let sunday = utc.date(from: DateComponents(year: 2023, month: 12, day: 31, hour: 9))!
        let result = engine.validateRoute(route, againstZones: [zone], now: sunday)
        #expect(result.isValid)
    }

    @Test("Least-violating candidate index picks the fewest violations")
    func leastViolating() {
        let z1 = NoGoZone(latitude: 0, longitude: 0, radiusMeters: 300)
        let z2 = NoGoZone(latitude: 1, longitude: 1, radiusMeters: 300)
        // Candidate 0 violates both, candidate 1 violates one, candidate 2 violates none-but-far.
        let through = polyline([
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 1, longitude: 1),
        ])
        let oneZone = polyline([
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0.001, longitude: 0),
        ])
        let clear = polyline([
            CLLocationCoordinate2D(latitude: 20, longitude: 20),
            CLLocationCoordinate2D(latitude: 20, longitude: 20.01),
        ])
        let index = engine.leastViolatingRouteIndex(
            candidates: [through, oneZone, clear],
            againstZones: [z1, z2]
        )
        #expect(index == 2)
    }
}

// MARK: - Migration

@Suite("NoGoZone migration & geometry resolution")
struct NoGoZoneMigrationTests {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ModelStoreLocator.schema, configurations: [config])
        return ModelContext(container)
    }

    @Test("Legacy circle zone (scalar columns only) resolves to a circle geometry")
    func legacyResolvesToCircle() throws {
        let context = try makeContext()
        // The legacy initializer leaves geometryData nil, mimicking a pre-v2 row.
        let zone = NoGoZone(latitude: 37.5, longitude: -122.3, radiusMeters: 250, name: "School")
        context.insert(zone)
        try context.save()

        #expect(zone.geometryData == nil)
        if case .circle(let center, let radius) = zone.geometry {
            #expect(abs(center.latitude - 37.5) < 1e-9)
            #expect(abs(center.longitude - -122.3) < 1e-9)
            #expect(radius == 250)
        } else {
            Issue.record("legacy zone should resolve to a circle")
        }
        #expect(zone.isActive())  // no window -> always active
    }

    @Test("v2 corridor zone persists and round-trips through the store")
    func v2CorridorPersists() throws {
        let context = try makeContext()
        let coords = [
            CLLocationCoordinate2D(latitude: 41.7, longitude: -72.6),
            CLLocationCoordinate2D(latitude: 41.8, longitude: -72.6),
        ]
        let encoded = PolylineEncoder.encode(coords, precision: 6)
        let zone = NoGoZone(
            geometry: .corridor(encodedPolyline: encoded, bufferMeters: 40),
            name: "I-91"
        )
        context.insert(zone)
        try context.save()

        // Re-fetch from the same context and confirm geometry decodes.
        let fetched = try context.fetch(FetchDescriptor<NoGoZone>())
        #expect(fetched.count == 1)
        if case .corridor(let polyline, let buffer) = fetched.first!.geometry {
            #expect(polyline == encoded)
            #expect(buffer == 40)
        } else {
            Issue.record("v2 zone should resolve to a corridor")
        }
    }

    @Test("Setting geometry keeps the legacy scalar columns coherent")
    func scalarColumnsStayCoherent() throws {
        let zone = NoGoZone(latitude: 0, longitude: 0, radiusMeters: 100)
        zone.geometry = .circle(
            center: CLLocationCoordinate2D(latitude: 12.34, longitude: 56.78),
            radiusMeters: 500
        )
        #expect(abs(zone.latitude - 12.34) < 1e-9)
        #expect(abs(zone.longitude - 56.78) < 1e-9)
        #expect(zone.radiusMeters == 500)
        #expect(zone.coordinate != nil)
    }

    @Test("Time window persists and gates activity")
    func timeWindowPersists() throws {
        let context = try makeContext()
        let zone = NoGoZone(
            geometry: .circle(center: CLLocationCoordinate2D(latitude: 0, longitude: 0), radiusMeters: 100),
            timeWindow: TimeWindow(daysOfWeek: [2, 3, 4, 5, 6], startHour: 7, endHour: 15)
        )
        context.insert(zone)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<NoGoZone>()).first!
        #expect(fetched.timeWindow != nil)
        #expect(fetched.timeWindow?.startHour == 7)
        #expect(fetched.timeWindow?.daysOfWeek == [2, 3, 4, 5, 6])
    }
}
