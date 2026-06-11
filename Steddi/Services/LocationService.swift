import Foundation
import CoreLocation
import Observation
import UIKit

/// Manages location permissions and continuous location updates.
@Observable
@MainActor
final class LocationService {
    var currentLocation: CLLocation?
    var deviceHeading: Double = 0 // magnetometer heading (direction phone is facing)
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var isRecording: Bool = false

    private let delegate: LocationDelegate
    private let locationManager = CLLocationManager()
    private var recordedPoints: [GPSPoint] = []

    init() {
        delegate = LocationDelegate()
        locationManager.delegate = delegate
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.pausesLocationUpdatesAutomatically = false

        delegate.onLocationUpdate = { [weak self] location in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentLocation = location
                // Theming: every fix feeds tunnel detection. The service
                // dedupes by fix timestamp, so the navigation loop forwarding
                // the same fix is harmless.
                TunnelDetectionService.shared.updateLocation(location)
                if self.isRecording, location.horizontalAccuracy <= 20 {
                    self.recordedPoints.append(GPSPoint(from: location))
                }
            }
        }
        delegate.onAuthChange = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.authorizationStatus = status
            }
        }
        delegate.onHeadingUpdate = { [weak self] heading in
            Task { @MainActor [weak self] in
                self?.deviceHeading = heading
            }
        }

        // Keep the magnetometer reference frame in sync with how the phone is
        // actually held — a portrait frame in a landscape mount skews headings.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateHeadingOrientation()
            }
        }
    }

    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func requestAlwaysPermission() {
        locationManager.requestAlwaysAuthorization()
    }

    func startUpdating() {
        updateHeadingOrientation()
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }

    /// Point the heading reference frame at the device's physical orientation.
    /// Flat or unknown orientations keep the last known frame.
    private func updateHeadingOrientation() {
        let orientation: CLDeviceOrientation
        switch UIDevice.current.orientation {
        case .portrait: orientation = .portrait
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        case .landscapeLeft: orientation = .landscapeLeft
        case .landscapeRight: orientation = .landscapeRight
        default: return
        }
        locationManager.headingOrientation = orientation
    }

    func stopUpdating() {
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
    }

    /// Enable high-accuracy background location for active navigation.
    func enableNavigationMode() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.allowsBackgroundLocationUpdates = true
    }

    /// Downgrade to foreground-only, lower accuracy when not navigating.
    /// Location still updates for the map dot but doesn't track in the background.
    func disableNavigationMode() {
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.allowsBackgroundLocationUpdates = false
    }

    // MARK: - GPS Trace Recording

    func startRecording() {
        recordedPoints = []
        isRecording = true
    }

    func stopRecording() -> [GPSPoint] {
        isRecording = false
        let points = recordedPoints
        recordedPoints = []
        return points
    }
}

/// Separate delegate class since CLLocationManagerDelegate requires NSObject,
/// which conflicts with @Observable.
private class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var onLocationUpdate: ((CLLocation) -> Void)?
    var onAuthChange: ((CLAuthorizationStatus) -> Void)?
    var onHeadingUpdate: ((Double) -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        onLocationUpdate?(location)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Negative accuracy means the magnetometer reading is invalid — discard
        guard newHeading.headingAccuracy >= 0 else { return }
        // trueHeading is relative to true north, -1 if unavailable
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        onHeadingUpdate?(heading)
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        // Let iOS prompt for the figure-eight wave when calibration is needed
        true
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthChange?(manager.authorizationStatus)
    }
}
