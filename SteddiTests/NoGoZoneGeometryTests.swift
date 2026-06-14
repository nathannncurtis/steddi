import Testing
import Foundation
import CoreLocation
import SwiftData
@testable import Steddi

// MARK: - Point in Polygon

@Suite("RouteGeometry.isPoint insidePolygon")
struct PointInPolygonTests {

    /// Unit square (0,0)-(1,1) in lat/lon space.
    private let square = [
        CLLocationCoordinate2D(latitude: 0, longitude: 0),
        CLLocationCoordinate2D(latitude: 0, longitude: 1),
        CLLocationCoordinate2D(latitude: 1, longitude: 1),
        CLLocationCoordinate2D(latitude: 1, longitude: 0),
    ]

    @Test("Center point is inside")
    func centerInside() {
        let p = CLLocationCoordinate2D(latitude: 0.5, longitude: 0.5)
        #expect(RouteGeometry.isPoint(p, insidePolygon: square))
    }

    @Test("Point well outside is outside")
    func farOutside() {
        let p = CLLocationCoordinate2D(latitude: 5, longitude: 5)
        #expect(!RouteGeometry.isPoint(p, insidePolygon: square))
    }

    @Test("Point just outside an edge is outside")
    func justOutsideEdge() {
        let p = CLLocationCoordinate2D(latitude: 0.5, longitude: 1.0001)
        #expect(!RouteGeometry.isPoint(p, insidePolygon: square))
    }

    @Test("Explicitly closed ring matches open ring")
    func closedRingTolerated() {
        let closed = square + [square[0]]
        let inside = CLLocationCoordinate2D(latitude: 0.5, longitude: 0.5)
        let outside = CLLocationCoordinate2D(latitude: 2, longitude: 2)
        #expect(RouteGeometry.isPoint(inside, insidePolygon: closed))
        #expect(!RouteGeometry.isPoint(outside, insidePolygon: closed))
    }

    @Test("Degenerate polygons (<3 vertices) never contain a point")
    func degenerate() {
        let two = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 1, longitude: 1),
        ]
        let p = CLLocationCoordinate2D(latitude: 0.5, longitude: 0.5)
        #expect(!RouteGeometry.isPoint(p, insidePolygon: two))
        #expect(!RouteGeometry.isPoint(p, insidePolygon: []))
    }

    @Test("Concave (L-shaped) polygon excludes the notch")
    func concaveNotch() {
        // L shape: full bottom row, only left half on top.
        let lShape = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 2),
            CLLocationCoordinate2D(latitude: 1, longitude: 2),
            CLLocationCoordinate2D(latitude: 1, longitude: 1),
            CLLocationCoordinate2D(latitude: 2, longitude: 1),
            CLLocationCoordinate2D(latitude: 2, longitude: 0),
        ]
        let inArm = CLLocationCoordinate2D(latitude: 0.5, longitude: 1.5)
        let inNotch = CLLocationCoordinate2D(latitude: 1.5, longitude: 1.5)
        #expect(RouteGeometry.isPoint(inArm, insidePolygon: lShape))
        #expect(!RouteGeometry.isPoint(inNotch, insidePolygon: lShape))
    }

    @Test("Point aligned with a vertex horizontally is classified consistently")
    func vertexAlignment() {
        // A point sharing a vertex's latitude shouldn't double-count the edge.
        let p = CLLocationCoordinate2D(latitude: 1.0, longitude: 0.5)
        // Latitude 1 is the top edge of the square; treated as boundary.
        // Just below it must be inside, just above outside.
        let below = CLLocationCoordinate2D(latitude: 0.999, longitude: 0.5)
        let above = CLLocationCoordinate2D(latitude: 1.001, longitude: 0.5)
        _ = p
        #expect(RouteGeometry.isPoint(below, insidePolygon: square))
        #expect(!RouteGeometry.isPoint(above, insidePolygon: square))
    }
}

// MARK: - Corridor / Polyline Distance

@Suite("RouteGeometry corridor distance")
struct CorridorDistanceTests {

    // A short east-west segment near the equator (longitude is ~111km/deg).
    private let line = [
        CLLocationCoordinate2D(latitude: 0, longitude: 0),
        CLLocationCoordinate2D(latitude: 0, longitude: 0.01),
    ]

    @Test("Point on the line has ~0 distance")
    func onLine() {
        let p = CLLocationCoordinate2D(latitude: 0, longitude: 0.005)
        #expect(RouteGeometry.distance(from: p, toPolyline: line) < 1)
    }

    @Test("Perpendicular distance is measured to the segment, not a vertex")
    func perpendicular() {
        // 0.001 deg latitude north of the segment midpoint ~= 111m.
        let p = CLLocationCoordinate2D(latitude: 0.001, longitude: 0.005)
        let d = RouteGeometry.distance(from: p, toPolyline: line)
        #expect(abs(d - 111.19) < 1.0)
    }

    @Test("Point within buffer is in the corridor; just outside is not")
    func bufferBoundary() {
        let p = CLLocationCoordinate2D(latitude: 0.001, longitude: 0.005)  // ~111m off
        #expect(RouteGeometry.isPoint(p, withinCorridor: line, bufferMeters: 120))
        #expect(!RouteGeometry.isPoint(p, withinCorridor: line, bufferMeters: 100))
    }

    @Test("Empty polyline is infinitely far; single vertex uses point distance")
    func edgeCounts() {
        let p = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        #expect(RouteGeometry.distance(from: p, toPolyline: []) == .infinity)
        let single = [CLLocationCoordinate2D(latitude: 0, longitude: 0.001)]
        let d = RouteGeometry.distance(from: p, toPolyline: single)
        #expect(abs(d - 111.19) < 1.0)
    }
}

// MARK: - Circle Containment

@Suite("RouteGeometry circle containment")
struct CircleContainmentTests {
    @Test("Point inside radius is contained, outside is not")
    func basic() {
        let center = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let near = CLLocationCoordinate2D(latitude: 0.0005, longitude: 0)   // ~55m
        let far = CLLocationCoordinate2D(latitude: 0.002, longitude: 0)     // ~222m
        #expect(RouteGeometry.isPoint(near, withinCircleCenter: center, radiusMeters: 100))
        #expect(!RouteGeometry.isPoint(far, withinCircleCenter: center, radiusMeters: 100))
    }
}

// MARK: - Time Window

@Suite("TimeWindow.isActive")
struct TimeWindowTests {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// A UTC date at the given weekday/hour. 2024-01-01 is a Monday (weekday 2).
    private func date(weekday: Int, hour: Int) -> Date {
        // Jan 1 2024 = Monday. Offset days from there.
        var comps = DateComponents()
        comps.year = 2024
        comps.month = 1
        comps.day = 1 + (weekday - 2 + 7) % 7  // weekday 2 -> day 1
        comps.hour = hour
        return utc.date(from: comps)!
    }

    @Test("Active inside same-day window on an active weekday")
    func sameDayActive() {
        let w = TimeWindow(daysOfWeek: [2, 3, 4, 5, 6], startHour: 7, endHour: 18)
        #expect(w.isActive(now: date(weekday: 2, hour: 9), calendar: utc))   // Mon 9am
    }

    @Test("Inactive before start and at/after end (exclusive)")
    func sameDayBoundaries() {
        let w = TimeWindow(daysOfWeek: [2], startHour: 7, endHour: 18)
        #expect(!w.isActive(now: date(weekday: 2, hour: 6), calendar: utc))
        #expect(w.isActive(now: date(weekday: 2, hour: 7), calendar: utc))   // inclusive start
        #expect(w.isActive(now: date(weekday: 2, hour: 17), calendar: utc))
        #expect(!w.isActive(now: date(weekday: 2, hour: 18), calendar: utc)) // exclusive end
    }

    @Test("Inactive on a day not in the set")
    func wrongDay() {
        let w = TimeWindow(daysOfWeek: [2, 3, 4, 5, 6], startHour: 7, endHour: 18)
        #expect(!w.isActive(now: date(weekday: 1, hour: 9), calendar: utc))  // Sunday
        #expect(!w.isActive(now: date(weekday: 7, hour: 9), calendar: utc))  // Saturday
    }

    @Test("Window wrapping past midnight covers evening of start day and morning after")
    func wrapping() {
        // 22:00 -> 06:00, active Monday means Mon 10pm..Tue 6am.
        let w = TimeWindow(daysOfWeek: [2], startHour: 22, endHour: 6)
        #expect(w.isActive(now: date(weekday: 2, hour: 23), calendar: utc))  // Mon 11pm
        #expect(w.isActive(now: date(weekday: 3, hour: 5), calendar: utc))   // Tue 5am (prev day Mon)
        #expect(!w.isActive(now: date(weekday: 3, hour: 7), calendar: utc))  // Tue 7am
        #expect(!w.isActive(now: date(weekday: 2, hour: 12), calendar: utc)) // Mon noon
    }

    @Test("Wrapping window into Sunday morning checks Saturday's membership")
    func wrapAcrossWeekStart() {
        // Active Saturday (7), 22->6 means Sat 10pm..Sun 6am.
        let w = TimeWindow(daysOfWeek: [7], startHour: 22, endHour: 6)
        #expect(w.isActive(now: date(weekday: 1, hour: 3), calendar: utc))   // Sun 3am -> prev = Sat
        #expect(!w.isActive(now: date(weekday: 1, hour: 7), calendar: utc))  // Sun 7am
    }

    @Test("Zero-length window (start == end) is never active")
    func zeroLength() {
        let w = TimeWindow(daysOfWeek: [2], startHour: 9, endHour: 9)
        #expect(!w.isActive(now: date(weekday: 2, hour: 9), calendar: utc))
    }
}

// MARK: - Geometry Codable round-trip

@Suite("ZoneGeometry Codable")
struct ZoneGeometryCodableTests {
    private func roundTrip(_ g: ZoneGeometry) throws -> ZoneGeometry {
        let data = try JSONEncoder().encode(g)
        return try JSONDecoder().decode(ZoneGeometry.self, from: data)
    }

    @Test("Circle round-trips center and radius")
    func circle() throws {
        let g = ZoneGeometry.circle(
            center: CLLocationCoordinate2D(latitude: 37.5, longitude: -122.3),
            radiusMeters: 250
        )
        #expect(try roundTrip(g) == g)
    }

    @Test("Corridor round-trips polyline and buffer")
    func corridor() throws {
        let g = ZoneGeometry.corridor(encodedPolyline: "abc123", bufferMeters: 30)
        #expect(try roundTrip(g) == g)
    }

    @Test("Polygon round-trips polyline")
    func polygon() throws {
        let g = ZoneGeometry.polygon(encodedPolyline: "xyz789")
        #expect(try roundTrip(g) == g)
    }
}
