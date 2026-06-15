import Foundation

/// A request to start a commute, raised from outside the SwiftUI tree (Siri /
/// CarPlay / a notification action or deep link) and consumed by HomeView.
enum PendingCommuteStart: Equatable {

    /// Start a specific commute+direction (from a smart-commute alert deep link
    /// that carries the ids).
    case specific(commuteId: UUID, direction: CommuteDirection?)

    /// Start the user's first active commute, resolving direction at consume
    /// time (Siri "start my commute", the CarPlay dashboard button).
    case firstActive
}

/// Durable hand-off for start-commute requests that can race the SwiftUI tree.
///
/// Siri intents, the CarPlay dashboard, and notification "Start Commute" actions
/// can all fire *before* HomeView has attached its observers — most painfully on
/// a cold launch, where the intent runs during scene connection and any
/// `NotificationCenter.post` lands with no subscriber. Rather than posting into
/// the void, callers stash the request here; HomeView drains it both on attach
/// (covering cold launch) and reactively while foregrounded (covering the
/// warm-launch case where it's already listening).
///
/// MainActor-isolated and a single shared instance so the producer and consumer
/// agree on one mailbox. The `version` token lets the consumer observe repeated
/// requests even when the payload is identical.
@Observable
@MainActor
final class PendingCommuteStartStore {

    static let shared = PendingCommuteStartStore()

    /// The queued request, or nil when there's nothing to consume.
    private(set) var pending: PendingCommuteStart?

    /// Bumped on every `request` so an Observation-tracking view re-runs even
    /// when two consecutive requests carry the same payload.
    private(set) var version: Int = 0

    init() {}

    /// Queue a start request. The most recent request wins — if HomeView hasn't
    /// drained the previous one yet, there's no value in starting two commutes.
    func request(_ action: PendingCommuteStart) {
        pending = action
        version &+= 1
    }

    /// Take and clear the pending request, if any. Returns nil when empty.
    func consume() -> PendingCommuteStart? {
        defer { pending = nil }
        return pending
    }
}
