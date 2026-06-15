import Foundation
import CoreLocation

/// A single, bounded location fix for out-of-app contexts (App Intents / Siri).
///
/// `CLLocationManager().location` read cold is almost always nil — the property
/// is only populated after updates have been started or a request resolved.
/// Intents run without the app's running `LocationService`, so they need to
/// *ask* for a fix. This wraps `requestLocation()` (one delivery, then it stops
/// on its own) in an async call with a hard timeout so a Siri response never
/// hangs waiting on a fix that won't arrive (e.g. permission denied, no signal).
///
/// Two correctness contracts this type guarantees:
///   1. `CLLocationManager` and its delegate are created and driven on the MAIN
///      ACTOR. CoreLocation delivers `didUpdateLocations`/`didFailWithError` on
///      the run loop of the thread that started the service; a Swift concurrency
///      cooperative-pool thread has none, so an off-main-actor manager's delegate
///      never fires and the fix never returns. The callers (App Intents) run
///      nonisolated, so the hop is mandatory.
///   2. The timeout is a HARD deadline. Hitting it cancels and abandons the
///      pending CoreLocation request immediately (stopping updates and resuming
///      the bridged continuation with nil) rather than implicitly waiting on
///      CLLocationManager's own ~10s internal timeout. This keeps Siri snappy and
///      guarantees tests can't hang on a sim that grants auth but never delivers.
enum OneShotLocation {

    /// Request a single location fix, returning nil on timeout, denial, or
    /// error. Default timeout keeps Siri snappy. Never throws.
    static func current(timeout: TimeInterval = 5) async -> CLLocation? {
        // Auth check on the main actor (CLLocationManager is main-actor work).
        // Don't even ask if we lack permission — `requestLocation` would just
        // error out after a delay; bail immediately so callers fail gracefully.
        let authorized = await MainActor.run { () -> Bool in
            switch CLLocationManager().authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                return true
            default:
                return false
            }
        }
        guard authorized else { return nil }

        // Race the fix against the timeout. The fix task is wrapped in a
        // cancellation handler so the timeout's `cancelAll()` actually unblocks
        // the group: on cancel we stop the manager and resume the bridged
        // continuation with nil immediately, instead of the group implicitly
        // awaiting CLLocationManager's own internal timeout.
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                await requestSingleFix()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            // First result wins (the fix, or the timeout's nil).
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Bridge `requestLocation`'s delegate callback to an async value. Creates
    /// and drives the manager on the main actor so the delegate fires, and
    /// installs a cancellation handler so a cancelled wait (the timeout winning)
    /// stops updates and resolves nil right away rather than blocking on
    /// CoreLocation's own timeout.
    private static func requestSingleFix() async -> CLLocation? {
        // The bridge owns the manager + delegate and is the single point that
        // resolves the continuation exactly once (fix, failure, or cancel).
        let bridge = await MainActor.run { SingleFixBridge() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
                Task { @MainActor in
                    // If the wait was already cancelled before we got here, bail
                    // without ever starting CoreLocation.
                    if Task.isCancelled {
                        continuation.resume(returning: nil)
                        return
                    }
                    bridge.start(continuation: continuation)
                }
            }
        } onCancel: {
            // Timeout (or caller cancellation) fired — abandon the request now.
            Task { @MainActor in bridge.cancel() }
        }
    }
}

/// Main-actor bridge: creates the manager, requests one fix, and resolves the
/// continuation exactly once on the first fix, failure, or cancellation — then
/// stops updates so nothing lingers.
@MainActor
private final class SingleFixBridge: NSObject, CLLocationManagerDelegate {
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var manager: CLLocationManager?
    /// Self-reference keeping the bridge alive across the async callback even if
    /// the surrounding structured task tree drops its reference; cleared on
    /// resolution so there's no leak.
    private var retainSelf: SingleFixBridge?

    func start(continuation: CheckedContinuation<CLLocation?, Never>) {
        self.continuation = continuation
        retainSelf = self
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        self.manager = manager
        manager.requestLocation()
    }

    /// Cancellation path: stop the request and resolve nil immediately so the
    /// timeout doesn't wait on CoreLocation's own internal timeout.
    func cancel() {
        resolve(with: nil)
    }

    private func resolve(with location: CLLocation?) {
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
        continuation?.resume(returning: location)
        continuation = nil
        retainSelf = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.resolve(with: last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resolve(with: nil) }
    }
}
