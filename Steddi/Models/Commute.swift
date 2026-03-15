import Foundation
import SwiftData

@Model
final class Commute {
    var id: UUID
    var name: String
    var origin: PinnedLocation?
    var destination: PinnedLocation?
    var thresholdPercentage: Double  // Base percentage for reroute sensitivity (e.g., 0.20 = 20%)
    var hardMinuteFloor: Int?        // Optional hard minute floor for long drives (e.g., 10)
    var isActive: Bool
    var createdAt: Date

    @Relationship(deleteRule: .cascade)
    var routes: [Route]?

    /// Routes sorted by rank (preferred first, then fallbacks in order)
    var orderedRoutes: [Route] {
        (routes ?? []).sorted { $0.rank < $1.rank }
    }

    var preferredRoute: Route? {
        orderedRoutes.first
    }

    init(
        name: String,
        origin: PinnedLocation? = nil,
        destination: PinnedLocation? = nil,
        thresholdPercentage: Double = 0.20,
        hardMinuteFloor: Int? = 10
    ) {
        self.id = UUID()
        self.name = name
        self.origin = origin
        self.destination = destination
        self.thresholdPercentage = thresholdPercentage
        self.hardMinuteFloor = hardMinuteFloor
        self.isActive = true
        self.createdAt = Date()
    }
}
