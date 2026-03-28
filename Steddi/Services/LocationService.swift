import Foundation
import CoreLocation
import Observation

/// Manages location permissions and continuous location updates.
@Observable
@MainActor
final class LocationService {
    var currentLocation: CLLocation?
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
    }

    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func requestAlwaysPermission() {
        locationManager.requestAlwaysAuthorization()
    }

    func startUpdating() {
        locationManager.startUpdatingLocation()
    }

    func stopUpdating() {
        locationManager.stopUpdatingLocation()
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

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        onLocationUpdate?(location)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthChange?(manager.authorizationStatus)
    }
}
