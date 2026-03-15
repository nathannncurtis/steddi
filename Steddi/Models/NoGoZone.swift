import Foundation
import SwiftData
import CoreLocation

@Model
final class NoGoZone {
    var id: UUID
    var name: String?                // Optional label, e.g. "School zone on Main St"
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double         // Circular exclusion zone
    var isGlobal: Bool               // true = applies everywhere, false = route-specific
    var createdAt: Date

    var route: Route?                // nil if global

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

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
}
