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
    /// Category key (see `PlaceCategory`). Stored as a String so the category
    /// set can grow without a SwiftData migration.
    ///
    /// The STORED default is "" (uncategorized), NOT a concrete category. This is
    /// load-bearing: SwiftData's automatic lightweight migration stamps the
    /// *declared* default onto rows persisted before this property existed, so a
    /// non-empty default ("other") would migrate every legacy pin to "other" and
    /// the `.isEmpty` backfill trigger in `HomeView.migrateExistingPinsToCategories()`
    /// would never match — the icon-inference backfill would be dead. Declaring ""
    /// keeps that trigger reachable: legacy pins migrate to "", the backfill infers
    /// a category from their icon, and `resolvedCategory` maps any residual "" to
    /// `.other` so nothing ever renders uncategorized. New pins are created with an
    /// explicit non-empty category (see `init`), so they are never re-backfilled.
    var category: String = ""
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
        category: String = PlaceCategory.other.key,
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.icon = icon
        self.category = category
        self.createdAt = Date()
        self.sortOrder = sortOrder
    }

    /// Resolved category enum for this pin. Unknown or uncategorized ("") keys
    /// fall back to `.other` (see `PlaceCategory.category(for:)`), so a legacy pin
    /// whose backfill hasn't run yet still renders as Other rather than blank.
    var resolvedCategory: PlaceCategory {
        PlaceCategory.category(for: category)
    }
}
