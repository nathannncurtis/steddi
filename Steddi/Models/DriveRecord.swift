import Foundation
import SwiftData
import CoreLocation

@Model
final class DriveRecord {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var rawGPSPoints: [GPSPoint]     // Raw recorded trace
    var matchedPolyline: String?     // Encoded polyline after Map Matching
    // Explicit inverse of `Commute.driveRecords` with a `.nullify` rule: deleting
    // a Commute must NULL this back-reference (analytics deliberately retains the
    // historical drive), never cascade-delete the drive or leave it pointing at an
    // invalidated model. The inverse on Commute is what makes SwiftData propagate
    // the delete rule here — without it the FK dangled.
    @Relationship(deleteRule: .nullify, inverse: \Commute.driveRecords)
    var associatedCommute: Commute?
    var wasConverted: Bool           // Whether this was saved as a Route

    // MARK: - Computed-on-Write Summary Fields
    //
    // Cached at save time (finalizeSummary) so analytics never decodes the
    // GPS blob for list views or aggregation. Optional so pre-existing
    // records (nil) can be detected and backfilled lazily.

    /// Seconds spent stopped or crawling (< 2 m/s) during the drive.
    var trafficDurationSeconds: Double?
    /// Total drive duration in seconds (endedAt - startedAt).
    var totalDurationSeconds: Double?
    /// Peak recorded speed in m/s, outliers (> 67 m/s / 150 mph) excluded.
    var maxSpeedMps: Double?
    /// Mean of valid speed samples in m/s.
    var averageSpeedMps: Double?

    init(startedAt: Date = Date()) {
        self.id = UUID()
        self.startedAt = startedAt
        self.rawGPSPoints = []
        self.wasConverted = false
    }

    /// Whether the cached summary fields have been computed.
    var hasSummary: Bool { totalDurationSeconds != nil }

    /// Speed below which a sample counts as "in traffic" (stopped/crawling).
    static let trafficSpeedThresholdMps: Double = 2.0
    /// Speeds above 150 mph are GPS glitches, not driving.
    static let maxPlausibleSpeedMps: Double = 67.0
    /// Gaps between samples longer than this are signal loss, not traffic.
    static let maxSampleGapSeconds: Double = 30.0

    /// Computes the cached summary fields from the raw GPS trace.
    /// Call once after `endedAt` is set, before saving. Safe to re-run
    /// (idempotent) — used to backfill records saved before these fields
    /// existed.
    func finalizeSummary() {
        guard let endedAt else { return }
        totalDurationSeconds = max(0, endedAt.timeIntervalSince(startedAt))

        var trafficSeconds = 0.0
        var speedSum = 0.0
        var speedCount = 0
        var maxSpeed = 0.0

        for (index, point) in rawGPSPoints.enumerated() {
            let speed = point.speed
            guard speed >= 0, speed <= Self.maxPlausibleSpeedMps else { continue }
            speedSum += speed
            speedCount += 1
            maxSpeed = max(maxSpeed, speed)

            // Time-in-traffic: credit the interval to the next sample when
            // this sample was stopped/crawling. Capped so GPS dropouts don't
            // masquerade as traffic.
            if speed < Self.trafficSpeedThresholdMps, index + 1 < rawGPSPoints.count {
                let dt = rawGPSPoints[index + 1].timestamp.timeIntervalSince(point.timestamp)
                if dt > 0, dt <= Self.maxSampleGapSeconds {
                    trafficSeconds += dt
                }
            }
        }

        trafficDurationSeconds = trafficSeconds
        maxSpeedMps = speedCount > 0 ? maxSpeed : nil
        averageSpeedMps = speedCount > 0 ? speedSum / Double(speedCount) : nil
    }
}

/// Lightweight GPS point for trace recording.
/// Stored as a Codable array inside DriveRecord rather than a separate @Model
/// to avoid thousands of individual SwiftData objects per drive.
struct GPSPoint: Codable, Hashable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let timestamp: Date
    let speed: Double // m/s, -1 if unavailable

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(from location: CLLocation) {
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.altitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.timestamp = location.timestamp
        self.speed = location.speed
    }

    init(
        latitude: Double,
        longitude: Double,
        altitude: Double,
        horizontalAccuracy: Double,
        timestamp: Date,
        speed: Double
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
        self.speed = speed
    }
}
