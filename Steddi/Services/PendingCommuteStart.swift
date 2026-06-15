import Foundation
import CoreLocation

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

// MARK: - UI / Navigation Routes

/// A UI/navigation route raised from outside the SwiftUI tree (CarPlay, the
/// dashboard, a deep link) and consumed by HomeView. The sibling of
/// `PendingCommuteStart` for intents that aren't "start a saved commute".
enum PendingUIRoute: Equatable {

    /// Surface the Places tab so the driver can pick a destination (CarPlay
    /// dashboard "Recent Places").
    case showPlaces

    /// Begin navigation to an arbitrary coordinate (CarPlay route-preview
    /// "Start Navigation", `steddi://navigate?lat=&lng=&name=`).
    case navigate(name: String, coordinate: CLLocationCoordinate2D)

    static func == (lhs: PendingUIRoute, rhs: PendingUIRoute) -> Bool {
        switch (lhs, rhs) {
        case (.showPlaces, .showPlaces):
            return true
        case let (.navigate(ln, lc), .navigate(rn, rc)):
            return ln == rn
                && lc.latitude == rc.latitude
                && lc.longitude == rc.longitude
        default:
            return false
        }
    }
}

/// Durable hand-off for UI/navigation routes that can race the SwiftUI tree.
///
/// Like `PendingCommuteStartStore`, CarPlay and dashboard deep links can fire
/// *before* HomeView has attached its `NotificationCenter` observers — most
/// painfully on a cold launch, where the route arrives during scene connection
/// and any `NotificationCenter.post` lands with no subscriber and evaporates
/// (the driver ends up on the wrong tab, or "Start Navigation" does nothing).
/// Producers stash the route here; HomeView drains it both on attach (covering
/// cold launch) and reactively while foregrounded.
///
/// MainActor-isolated, single shared instance, so producer and consumer agree
/// on one mailbox. The `version` token lets the consumer observe repeated
/// requests even when the payload is identical.
@Observable
@MainActor
final class PendingUIRouteStore {

    static let shared = PendingUIRouteStore()

    /// The queued route, or nil when there's nothing to consume.
    private(set) var pending: PendingUIRoute?

    /// Bumped on every `request` so an Observation-tracking view re-runs even
    /// when two consecutive requests carry the same payload.
    private(set) var version: Int = 0

    init() {}

    /// Queue a route. The most recent route wins.
    func request(_ route: PendingUIRoute) {
        pending = route
        version &+= 1
    }

    /// Take and clear the pending route, if any. Returns nil when empty.
    func consume() -> PendingUIRoute? {
        defer { pending = nil }
        return pending
    }
}
