import Foundation
import SwiftData
import CoreLocation

/// One ordered stop within a Trip. Each stop is a leg destination; the leg to
/// the next stop can optionally carry a saved Route (reusing the existing
/// Route model — polyline, steps, no-go zones all come along).
@Model
final class TripStop {
    var id: UUID
    var order: Int                 // 0-indexed position in the trip
    var name: String
    var latitude: Double
    var longitude: Double
    var address: String?
    var notes: String?             // User memo, e.g. "lunch spot", "photo op"
    var arrivalTime: Date?         // Captured when the user arrives

    /// Optional saved route for the leg ENDING at this stop.
    @Relationship(deleteRule: .cascade)
    var savedRoute: Route?

    // Per-leg toll/highway overrides (nil = use Trip defaults)
    var avoidsTolls: Bool?
    var avoidsHighways: Bool?

    var trip: Trip?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(
        order: Int,
        name: String,
        latitude: Double,
        longitude: Double,
        address: String? = nil,
        notes: String? = nil
    ) {
        self.id = UUID()
        self.order = order
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.notes = notes
    }
}
