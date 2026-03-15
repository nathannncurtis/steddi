import Foundation
import SwiftData
import CoreLocation

@Model
final class PinnedLocation {
    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var address: String?
    var icon: String // SF Symbol name
    var createdAt: Date
    var sortOrder: Int

    @Relationship(deleteRule: .nullify, inverse: \Commute.origin)
    var commutesAsOrigin: [Commute]?

    @Relationship(deleteRule: .nullify, inverse: \Commute.destination)
    var commutesAsDestination: [Commute]?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(
        name: String,
        latitude: Double,
        longitude: Double,
        address: String? = nil,
        icon: String = "mappin.circle.fill",
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.icon = icon
        self.createdAt = Date()
        self.sortOrder = sortOrder
    }
}
