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

    /// All routes sorted by rank
    var orderedRoutes: [Route] {
        (routes ?? []).sorted { $0.rank < $1.rank }
    }

    /// Routes for a specific direction, sorted by rank
    func orderedRoutes(for direction: CommuteDirection) -> [Route] {
        (routes ?? []).filter { $0.direction == direction }.sorted { $0.rank < $1.rank }
    }

    /// Preferred route for a direction
    func preferredRoute(for direction: CommuteDirection) -> Route? {
        orderedRoutes(for: direction).first
    }

    /// Legacy — first route regardless of direction
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
