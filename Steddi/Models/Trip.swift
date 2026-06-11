import Foundation
import SwiftData

/// A planned multi-stop, non-recurring journey — the third pillar alongside
/// Commutes (recurring routes) and Places (pinned locations). A trip holds an
/// ordered sequence of stops and navigates leg by leg, either auto-advancing
/// on arrival (continuous) or waiting for a next-leg confirmation (manual).
@Model
final class Trip {
    var id: UUID
    var name: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \TripStop.trip)
    var stops: [TripStop]?

    /// Navigation behavior between legs.
    var flowMode: TripFlowMode

    // Per-trip route preferences (nil = use global Settings defaults)
    var avoidsTolls: Bool?
    var avoidsHighways: Bool?
    var thresholdPercentage: Double?   // Reroute sensitivity for all legs
    var hardMinuteFloor: Int?          // Hard minute floor for long drives

    var isArchived: Bool
    var completedAt: Date?             // Set when the final stop is reached
    /// Timestamp of the last leg navigation — drives the resume banner.
    var lastNavigatedAt: Date?

    /// The stop currently being navigated to, by UUID. Position is id-based
    /// rather than index-based so reordering stops mid-trip can never orphan
    /// the navigation position. nil = trip not started.
    var currentStopId: UUID?

    init(name: String, flowMode: TripFlowMode = .continuous) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.flowMode = flowMode
        self.isArchived = false
    }

    // MARK: - Ordered Stops

    /// All stops sorted by order.
    var orderedStops: [TripStop] {
        (stops ?? []).sorted { $0.order < $1.order }
    }

    /// Pure state-machine view of this trip's position.
    var progression: TripProgression {
        TripProgression(stopIds: orderedStops.map(\.id), currentStopId: currentStopId)
    }

    /// Ordinal of the stop being navigated to (0 when not started).
    var currentStopIndex: Int {
        progression.currentIndex
    }

    /// Current stop being navigated to (nil if the trip has no stops).
    var currentStop: TripStop? {
        let ordered = orderedStops
        guard currentStopIndex < ordered.count else { return nil }
        return ordered[currentStopIndex]
    }

    /// Stops after the current one (for ETA summing and leg counts).
    var remainingStops: [TripStop] {
        let ordered = orderedStops
        guard currentStopIndex < ordered.count else { return [] }
        return Array(ordered.dropFirst(currentStopIndex + 1))
    }

    /// Whether navigation has begun and the trip hasn't been completed.
    var isInProgress: Bool {
        currentStopId != nil && completedAt == nil
    }

    // MARK: - Lifecycle

    /// Begin (or restart) the trip from its first stop.
    func start() {
        currentStopId = orderedStops.first?.id
        completedAt = nil
        isArchived = false
        lastNavigatedAt = Date()
    }

    /// Arrival fired at the current stop — step to the next leg, or complete
    /// and archive on the final stop. Persisted position moves immediately so
    /// an app death after arrival resumes on the right leg.
    @discardableResult
    func advanceAfterArrival() -> TripProgression.AdvanceResult {
        var progression = progression
        let result = progression.advance()
        switch result {
        case .nextLeg(let nextId):
            currentStopId = nextId
        case .completed:
            currentStopId = nil
            completedAt = Date()
            isArchived = true
        }
        lastNavigatedAt = Date()
        return result
    }

    /// Remove a stop, rolling the navigation position back when the deleted
    /// stop is the current one (resume from the previous stop, clamped to the
    /// first). Remaining stops are renumbered to keep order contiguous.
    func removeStop(_ stop: TripStop) {
        var progression = progression
        progression.removeStop(id: stop.id)
        currentStopId = progression.currentStopId

        stops?.removeAll { $0.id == stop.id }
        renumberStops()
    }

    /// Apply a new stop ordering (drag reorder). The current stop keeps its
    /// identity — only the ordinals shift.
    func reorderStops(_ newOrder: [TripStop]) {
        for (index, stop) in newOrder.enumerated() {
            stop.order = index
        }
    }

    /// Abandon progress: back to not-started so the next tap starts at stop 0.
    func resetProgress() {
        currentStopId = nil
        completedAt = nil
        isArchived = false
        for stop in orderedStops { stop.arrivalTime = nil }
    }

    /// Keep order values contiguous after a removal.
    private func renumberStops() {
        for (index, stop) in orderedStops.enumerated() {
            stop.order = index
        }
    }
}

/// Navigation behavior between trip legs.
enum TripFlowMode: String, Codable {
    case continuous  // Auto-start next leg on arrival at a stop
    case manual      // Show a next-leg prompt; user confirms to continue
}

// MARK: - Route Preferences

extension Trip {
    /// Resolve toll/highway preferences for a leg: per-stop overrides beat
    /// per-trip overrides beat global Settings defaults — the same layering
    /// Commute uses.
    func routePreferences(for stop: TripStop?) -> RoutePreferences {
        let globalTolls = UserDefaults.standard.bool(forKey: "steddi.defaultAvoidsTolls")
        let globalHighways = UserDefaults.standard.bool(forKey: "steddi.defaultAvoidsHighways")
        return RoutePreferences(
            avoidsTolls: stop?.avoidsTolls ?? avoidsTolls ?? globalTolls,
            avoidsHighways: stop?.avoidsHighways ?? avoidsHighways ?? globalHighways
        )
    }
}
