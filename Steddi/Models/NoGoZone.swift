import Foundation
import SwiftData
import CoreLocation

/// A no-go zone the router avoids. Originally a single circle (lat/lon/radius);
/// evolved to a geometry enum supporting circles, road corridors, and arbitrary
/// polygons, plus optional time-window activation.
///
/// Backward compatibility / SwiftData migration:
/// The original scalar columns (`latitude`, `longitude`, `radiusMeters`) are
/// retained so existing rows lightweight-migrate with no transform — a legacy
/// zone with no encoded `geometryData` still resolves to its original circle
/// via the `geometry` accessor. New geometry/time-window state is persisted in
/// optional `Data` blobs added additively (the only schema change is two new
/// optional columns, which SwiftData migrates automatically).
@Model
final class NoGoZone {
    var id: UUID
    var name: String?                // Optional label, e.g. "School zone on Main St"
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double         // Legacy circular exclusion zone (also the .circle fallback)
    var isGlobal: Bool               // true = applies everywhere, false = route-specific
    var createdAt: Date

    var route: Route?                // nil if global

    /// JSON-encoded `ZoneGeometry`. nil for legacy rows — `geometry` then falls
    /// back to the circle described by the scalar lat/lon/radius columns.
    var geometryData: Data?

    /// JSON-encoded `TimeWindow`. nil means the zone is always active.
    var timeWindowData: Data?

    /// Original circle center. nil when the zone is a corridor or polygon.
    var coordinate: CLLocationCoordinate2D? {
        if case .circle(let center, _) = geometry { return center }
        return nil
    }

    /// Resolved geometry. Decodes `geometryData` when present; otherwise
    /// reconstructs the legacy circle from the scalar columns so pre-v2 zones
    /// keep working without a data transform.
    var geometry: ZoneGeometry {
        get {
            if let data = geometryData,
               let decoded = try? JSONDecoder().decode(ZoneGeometry.self, from: data) {
                return decoded
            }
            return .circle(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                radiusMeters: radiusMeters
            )
        }
        set {
            geometryData = try? JSONEncoder().encode(newValue)
            // Keep the legacy scalar columns coherent so any code (and SwiftData
            // queries) reading them sees a sensible representative point.
            switch newValue {
            case .circle(let center, let radius):
                latitude = center.latitude
                longitude = center.longitude
                radiusMeters = radius
            case .corridor(let encodedPolyline, _), .polygon(let encodedPolyline):
                if let first = PolylineEncoder.decode(encodedPolyline, precision: 6).first {
                    latitude = first.latitude
                    longitude = first.longitude
                }
            }
        }
    }

    /// Resolved time window, or nil when the zone is always active.
    var timeWindow: TimeWindow? {
        get {
            guard let data = timeWindowData else { return nil }
            return try? JSONDecoder().decode(TimeWindow.self, from: data)
        }
        set {
            timeWindowData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    /// Whether the zone is active at the given instant (always true with no
    /// time window).
    func isActive(now: Date = Date()) -> Bool {
        timeWindow?.isActive(now: now) ?? true
    }

    /// Human-readable, geometry-appropriate description for list rows. Circles
    /// report their radius; corridors report their buffer width; polygons report
    /// an area label. Avoids the misleading "0m radius" that legacy radius-based
    /// formatting produces for corridor/polygon zones (whose `radiusMeters` is 0
    /// by design).
    var displayLabel: String {
        switch geometry {
        case .circle(_, let radiusMeters):
            return "\(Int(radiusMeters))m radius"
        case .corridor(_, let bufferMeters):
            return "Road corridor · \(Int(bufferMeters))m buffer"
        case .polygon:
            return "Custom area"
        }
    }

    /// Legacy circle initializer — preserved so existing call sites compile
    /// unchanged.
    init(
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = 200,
        name: String? = nil,
        isGlobal: Bool = true
    ) {
        self.id = UUID()
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.isGlobal = isGlobal
        self.createdAt = Date()
    }

    /// v2 initializer accepting any geometry plus an optional time window.
    init(
        geometry: ZoneGeometry,
        name: String? = nil,
        isGlobal: Bool = true,
        route: Route? = nil,
        timeWindow: TimeWindow? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.isGlobal = isGlobal
        self.createdAt = Date()
        self.route = route

        // Seed the scalar columns from the geometry's representative point.
        switch geometry {
        case .circle(let center, let radius):
            self.latitude = center.latitude
            self.longitude = center.longitude
            self.radiusMeters = radius
        case .corridor(let encodedPolyline, _), .polygon(let encodedPolyline):
            let first = PolylineEncoder.decode(encodedPolyline, precision: 6).first
            self.latitude = first?.latitude ?? 0
            self.longitude = first?.longitude ?? 0
            self.radiusMeters = 0
        }

        self.geometryData = try? JSONEncoder().encode(geometry)
        self.timeWindowData = timeWindow.flatMap { try? JSONEncoder().encode($0) }
    }
}

// MARK: - Geometry

/// Unified no-go zone shape. Encoded into `NoGoZone.geometryData`.
enum ZoneGeometry: Codable, Equatable {
    /// Circle: a center coordinate and a radius in meters.
    case circle(center: CLLocationCoordinate2D, radiusMeters: Double)

    /// Corridor: an encoded polyline (precision 6) with a buffer in meters on
    /// each side of the centerline. Used for road-traced and named-road zones.
    case corridor(encodedPolyline: String, bufferMeters: Double)

    /// Polygon: an encoded polyline (precision 6) that loops back to its start,
    /// describing an arbitrary closed area.
    case polygon(encodedPolyline: String)

    // CLLocationCoordinate2D isn't Codable, so encode geometry with an explicit
    // discriminator and primitive payloads.
    private enum Kind: String, Codable {
        case circle, corridor, polygon
    }

    private enum CodingKeys: String, CodingKey {
        case kind, latitude, longitude, radiusMeters, encodedPolyline, bufferMeters
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .circle(let center, let radiusMeters):
            try c.encode(Kind.circle, forKey: .kind)
            try c.encode(center.latitude, forKey: .latitude)
            try c.encode(center.longitude, forKey: .longitude)
            try c.encode(radiusMeters, forKey: .radiusMeters)
        case .corridor(let encodedPolyline, let bufferMeters):
            try c.encode(Kind.corridor, forKey: .kind)
            try c.encode(encodedPolyline, forKey: .encodedPolyline)
            try c.encode(bufferMeters, forKey: .bufferMeters)
        case .polygon(let encodedPolyline):
            try c.encode(Kind.polygon, forKey: .kind)
            try c.encode(encodedPolyline, forKey: .encodedPolyline)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .circle:
            let lat = try c.decode(Double.self, forKey: .latitude)
            let lon = try c.decode(Double.self, forKey: .longitude)
            let radius = try c.decode(Double.self, forKey: .radiusMeters)
            self = .circle(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                radiusMeters: radius
            )
        case .corridor:
            let polyline = try c.decode(String.self, forKey: .encodedPolyline)
            let buffer = try c.decode(Double.self, forKey: .bufferMeters)
            self = .corridor(encodedPolyline: polyline, bufferMeters: buffer)
        case .polygon:
            let polyline = try c.decode(String.self, forKey: .encodedPolyline)
            self = .polygon(encodedPolyline: polyline)
        }
    }

    static func == (lhs: ZoneGeometry, rhs: ZoneGeometry) -> Bool {
        switch (lhs, rhs) {
        case let (.circle(c1, r1), .circle(c2, r2)):
            return c1.latitude == c2.latitude && c1.longitude == c2.longitude && r1 == r2
        case let (.corridor(p1, b1), .corridor(p2, b2)):
            return p1 == p2 && b1 == b2
        case let (.polygon(p1), .polygon(p2)):
            return p1 == p2
        default:
            return false
        }
    }
}

// MARK: - Time Window

/// Optional activation window for a zone. All comparisons use the device's
/// current calendar so daylight-saving transitions are handled by Foundation.
struct TimeWindow: Codable, Equatable {
    /// Active weekdays, using `Calendar` weekday numbering (Sun = 1 … Sat = 7).
    var daysOfWeek: Set<Int>
    /// Inclusive start hour, 0...23.
    var startHour: Int
    /// Exclusive end hour, 0...24. When <= startHour the window wraps past
    /// midnight (e.g. 22→6 covers 10pm through 6am).
    var endHour: Int

    init(daysOfWeek: Set<Int>, startHour: Int, endHour: Int) {
        // The UI (HourRangePicker) already constrains these, but the model type
        // guards itself so a malformed window never silently misbehaves: hours
        // are clamped into [0, 24] and weekdays into Calendar's 1...7 range.
        self.daysOfWeek = daysOfWeek.filter { (1...7).contains($0) }
        self.startHour = min(max(startHour, 0), 24)
        self.endHour = min(max(endHour, 0), 24)
    }

    // Route decoding through the validating initializer so persisted windows are
    // clamped on read too, not just on construction.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            daysOfWeek: try c.decode(Set<Int>.self, forKey: .daysOfWeek),
            startHour: try c.decode(Int.self, forKey: .startHour),
            endHour: try c.decode(Int.self, forKey: .endHour)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case daysOfWeek, startHour, endHour
    }

    /// Whether the window is active at `now`. Handles windows that wrap past
    /// midnight by treating the post-midnight portion as belonging to the
    /// start day.
    func isActive(now: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: now)
        let day = calendar.component(.weekday, from: now)

        if startHour < endHour {
            // Same-day window: day must match and hour within [start, end).
            return daysOfWeek.contains(day) && hour >= startHour && hour < endHour
        } else if startHour > endHour {
            // Wrapping window (e.g. 22→6). The evening portion belongs to the
            // start day; the morning portion belongs to the previous day's
            // window, so check the prior weekday for early-morning hours.
            if hour >= startHour {
                return daysOfWeek.contains(day)
            }
            if hour < endHour {
                let prevDay = day == 1 ? 7 : day - 1
                return daysOfWeek.contains(prevDay)
            }
            return false
        } else {
            // startHour == endHour: zero-length window, never active.
            return false
        }
    }
}
