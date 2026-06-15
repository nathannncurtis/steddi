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
enum OneShotLocation {

    /// Request a single location fix, returning nil on timeout, denial, or
    /// error. Default timeout keeps Siri snappy. Never throws.
    static func current(timeout: TimeInterval = 5) async -> CLLocation? {
        // Don't even ask if we lack permission — `requestLocation` would just
        // error out after a delay; bail immediately so callers fail gracefully.
        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        default:
            return nil
        }

        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                await requestSingleFix(using: manager)
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

    /// Bridge `requestLocation`'s delegate callback to an async value. The
    /// delegate is retained by the continuation closure for the call's
    /// lifetime; `requestLocation` self-cancels after one delivery.
    private static func requestSingleFix(using manager: CLLocationManager) async -> CLLocation? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
            let delegate = SingleFixDelegate(continuation: continuation)
            manager.delegate = delegate
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            // Keep the delegate alive until it resolves the continuation.
            delegate.retainSelf = delegate
            manager.requestLocation()
        }
    }
}

/// One-shot delegate: resolves the continuation exactly once on the first fix
/// or failure, then releases its self-reference so it can deallocate.
private final class SingleFixDelegate: NSObject, CLLocationManagerDelegate {
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    /// Self-reference keeping the delegate alive across the async callback;
    /// cleared on resolution so there's no leak.
    var retainSelf: SingleFixDelegate?

    init(continuation: CheckedContinuation<CLLocation?, Never>) {
        self.continuation = continuation
    }

    private func resolve(with location: CLLocation?) {
        continuation?.resume(returning: location)
        continuation = nil
        retainSelf = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        resolve(with: locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        resolve(with: nil)
    }
}
