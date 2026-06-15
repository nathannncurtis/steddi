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
    var skipRoutePreview: Bool?  // Skip the route preview screen for this commute

    // Schedule-based direction rules
    var scheduleToDestDays: String?      // e.g. "2,3,4,5,6" (weekday components, Sun=1..Sat=7)
    var scheduleToDestStartHour: Int?    // e.g. 6
    var scheduleToDestEndHour: Int?      // e.g. 10
    var scheduleToOriginDays: String?    // e.g. "2,3,4,5,6"
    var scheduleToOriginStartHour: Int?  // e.g. 15
    var scheduleToOriginEndHour: Int?    // e.g. 19

    // Smart-commute notification settings (defaults enable lightweight migration)
    var notificationsEnabled: Bool = true
    var quietHoursStart: Int? = nil        // Hour 0–23, e.g. 22 (10pm)
    var quietHoursEnd: Int? = nil          // Hour 0–23, e.g. 7 (7am)
    var notificationLeadMinutes: Int = 15  // How early to alert (15–120 min)

    @Relationship(deleteRule: .cascade)
    var routes: [Route]?

    /// Pattern-learning trip history for this commute. Cascade-deletes with the
    /// commute (mirroring `routes`) so deleting a commute never leaves orphan
    /// CommuteTrip rows behind to accumulate forever. The explicit inverse pins
    /// `CommuteTrip.commute` as the back-reference so SwiftData applies the rule.
    @Relationship(deleteRule: .cascade, inverse: \CommuteTrip.commute)
    var trips: [CommuteTrip]?

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
