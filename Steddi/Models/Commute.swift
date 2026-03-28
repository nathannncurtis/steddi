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

    // Route preferences (nil = use global defaults from Settings)
    var avoidsTolls: Bool?
    var avoidsHighways: Bool?

    // Schedule-based direction rules
    var scheduleToDestDays: String?      // e.g. "2,3,4,5,6" (weekday components, Sun=1..Sat=7)
    var scheduleToDestStartHour: Int?    // e.g. 6
    var scheduleToDestEndHour: Int?      // e.g. 10
    var scheduleToOriginDays: String?    // e.g. "2,3,4,5,6"
    var scheduleToOriginStartHour: Int?  // e.g. 15
    var scheduleToOriginEndHour: Int?    // e.g. 19

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
