import Foundation
import SwiftData

/// Persists user-submitted road reports (hazard, police, accident, etc.)
/// with location and timestamp so the app can display them on the map.
@Model
final class Report {
    var id: UUID
    var type: String
    var latitude: Double
    var longitude: Double
    var createdAt: Date

    init(type: String, latitude: Double, longitude: Double) {
        self.id = UUID()
        self.type = type
        self.latitude = latitude
        self.longitude = longitude
        self.createdAt = Date()
    }
}
