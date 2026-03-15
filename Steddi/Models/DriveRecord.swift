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
    var associatedCommute: Commute?
    var wasConverted: Bool           // Whether this was saved as a Route

    init(startedAt: Date = Date()) {
        self.id = UUID()
        self.startedAt = startedAt
        self.rawGPSPoints = []
        self.wasConverted = false
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
}
