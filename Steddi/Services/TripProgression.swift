import Foundation

/// Pure leg-advancement state machine for trips — operates on stop UUIDs
/// only, no SwiftData, so every transition is unit-testable. The Trip model
/// and HomeView's nav orchestration both delegate position math here.
///
/// Position is UUID-based, not index-based: reordering stops mid-trip shifts
/// the ordinals but the current stop keeps its identity.
struct TripProgression: Equatable {
    /// Stop ids in trip order.
    var stopIds: [UUID]
    /// The stop currently being navigated to. nil = trip not started.
    var currentStopId: UUID?

    /// Outcome of an arrival at the current stop.
    enum AdvanceResult: Equatable {
        case nextLeg(UUID)  // Begin navigation to this stop
        case completed      // That was the final stop
    }

    /// Ordinal of the current stop. A nil or dangling id resolves to 0 — an
    /// unstarted trip (or one whose current stop vanished without going
    /// through removeStop) begins from the first stop.
    var currentIndex: Int {
        guard let currentStopId, let index = stopIds.firstIndex(of: currentStopId) else { return 0 }
        return index
    }

    /// Whether the current leg is the last one.
    var isOnFinalLeg: Bool {
        !stopIds.isEmpty && currentIndex == stopIds.count - 1
    }

    /// Ids of stops after the current one.
    var remainingStopIds: [UUID] {
        guard currentIndex + 1 <= stopIds.count else { return [] }
        return Array(stopIds.dropFirst(currentIndex + 1))
    }

    /// Arrival fired at the current stop — step to the next leg, or report
    /// completion on the final stop (position is left unchanged so callers
    /// decide how to record completion).
    mutating func advance() -> AdvanceResult {
        let next = currentIndex + 1
        guard next < stopIds.count else { return .completed }
        currentStopId = stopIds[next]
        return .nextLeg(stopIds[next])
    }

    /// Remove a stop. Deleting a stop after the current one changes nothing;
    /// deleting the current stop rolls the position back to the previous stop
    /// (clamped to the first remaining stop), per the mid-trip edit rules.
    mutating func removeStop(id: UUID) {
        guard let removedIndex = stopIds.firstIndex(of: id) else { return }
        stopIds.remove(at: removedIndex)

        guard currentStopId == id else { return }
        guard !stopIds.isEmpty else {
            currentStopId = nil
            return
        }
        let rollbackIndex = min(max(0, removedIndex - 1), stopIds.count - 1)
        currentStopId = stopIds[rollbackIndex]
    }

    /// Apply a new ordering. UUID identity keeps the current stop pinned —
    /// only its ordinal moves.
    mutating func reorder(to newOrder: [UUID]) {
        stopIds = newOrder
    }
}

// MARK: - Trip-Aware ETA

extension TripProgression {
    /// One leg's inputs for trip-level ETA summation.
    struct LegEstimate: Equatable {
        /// Duration from a saved Route, when the leg has one.
        var savedDurationSeconds: TimeInterval?
        /// Straight-line meters between the leg's endpoints — the fallback
        /// input when no saved duration exists.
        var straightLineMeters: Double
    }

    /// Average driving speed assumed for legs without a saved duration
    /// (m/s, ~30 mph — same baseline NavigationEngine uses).
    static let fallbackSpeedMPS: Double = 13.4

    /// Road-network inflation over straight-line distance.
    static let roadFactor: Double = 1.3

    /// Seconds estimate for a single leg: saved duration when present,
    /// otherwise straight-line distance inflated to road distance at the
    /// fallback speed.
    static func estimatedSeconds(for leg: LegEstimate) -> TimeInterval {
        if let saved = leg.savedDurationSeconds, saved > 0 { return saved }
        return leg.straightLineMeters * roadFactor / fallbackSpeedMPS
    }

    /// Trip-aware ETA: the live ETA for the current leg plus estimates for
    /// every remaining leg. No direction requests fire — remaining legs use
    /// precomputed/saved durations or distance-based estimates.
    static func remainingTripSeconds(
        currentLegSeconds: TimeInterval,
        remainingLegs: [LegEstimate]
    ) -> TimeInterval {
        max(0, currentLegSeconds) + remainingLegs.reduce(0) { $0 + estimatedSeconds(for: $1) }
    }
}
