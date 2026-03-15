import SwiftUI
import MapboxMaps
import MapboxNavigationUIKit
import MapboxNavigationCore
import MapboxDirections
import CoreLocation

/// Manages the map and navigation in a single UIKit view controller.
/// The home map and turn-by-turn share the same container — navigation
/// crossfades in/out rather than presenting as a separate screen.
struct SteddiMapView: UIViewControllerRepresentable {
    @Binding var isNavigating: Bool
    let navigationRoutes: NavigationRoutes?
    let provider: MapboxNavigationProvider?
    let onLongPress: (CLLocationCoordinate2D) -> Void
    let onArrival: () -> Void
    let onCancelled: () -> Void

    func makeUIViewController(context: Context) -> SteddiMapContainer {
        let vc = SteddiMapContainer()
        vc.onLongPress = onLongPress
        vc.onArrival = onArrival
        vc.onCancelled = onCancelled
        return vc
    }

    func updateUIViewController(_ vc: SteddiMapContainer, context: Context) {
        vc.onArrival = onArrival
        vc.onCancelled = onCancelled

        if isNavigating, let routes = navigationRoutes, let provider = provider {
            if !vc.isInNavigation {
                vc.startNavigation(routes: routes, provider: provider)
            }
        } else if !isNavigating && vc.isInNavigation {
            vc.stopNavigation()
        }
    }
}

class SteddiMapContainer: UIViewController {
    private var mapView: MapView!
    private var navigationVC: NavigationViewController?
    var isInNavigation = false

    var onLongPress: ((CLLocationCoordinate2D) -> Void)?
    var onArrival: (() -> Void)?
    var onCancelled: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()

        // Home map — standard Mapbox Maps SDK
        let initOptions = MapInitOptions(styleURI: .dark)
        mapView = MapView(frame: view.bounds, mapInitOptions: initOptions)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.location.options.puckType = .puck2D(.init())
        mapView.mapboxMap.setCamera(to: CameraOptions(zoom: 14))

        view.addSubview(mapView)

        // Follow user location
        mapView.location.options.puckBearing = .heading
        mapView.mapboxMap.onStyleLoaded.observeNext { [weak self] _ in
            guard let self else { return }
            let cameraState = CameraOptions(
                center: self.mapView.location.latestLocation?.coordinate,
                zoom: 14
            )
            self.mapView.mapboxMap.setCamera(to: cameraState)
        }.store(in: &cancellables)

        // Long press
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        mapView.addGestureRecognizer(lp)
    }

    private var cancellables: [AnyCancelable] = []

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: mapView)
        let coordinate = mapView.mapboxMap.coordinate(for: point)
        onLongPress?(coordinate)
    }

    func startNavigation(routes: NavigationRoutes, provider: MapboxNavigationProvider) {
        guard !isInNavigation else { return }
        isInNavigation = true

        let options = NavigationOptions(
            mapboxNavigation: provider.mapboxNavigation,
            voiceController: provider.routeVoiceController,
            eventsManager: provider.eventsManager(),
            styles: [SteddiDayStyle(), SteddiNightStyle()]
        )

        let navVC = NavigationViewController(
            navigationRoutes: routes,
            navigationOptions: options
        )
        navVC.usesNightStyleInDarkMode = true
        navVC.delegate = self

        // Embed as child — crossfade in
        addChild(navVC)
        navVC.view.frame = view.bounds
        navVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        navVC.view.alpha = 0
        view.addSubview(navVC.view)
        navVC.didMove(toParent: self)

        UIView.animate(withDuration: 0.5, delay: 0, options: .curveEaseInOut) {
            navVC.view.alpha = 1
        }

        self.navigationVC = navVC
    }

    func stopNavigation() {
        guard isInNavigation, let navVC = navigationVC else { return }
        isInNavigation = false

        UIView.animate(withDuration: 0.4, delay: 0, options: .curveEaseInOut, animations: {
            navVC.view.alpha = 0
        }) { _ in
            navVC.willMove(toParent: nil)
            navVC.view.removeFromSuperview()
            navVC.removeFromParent()
            self.navigationVC = nil
        }
    }
}

extension SteddiMapContainer: NavigationViewControllerDelegate {
    func navigationViewControllerDidDismiss(
        _ navigationViewController: NavigationViewController,
        byCanceling canceled: Bool
    ) {
        if canceled {
            onCancelled?()
        } else {
            onArrival?()
        }
    }

    func navigationViewController(
        _ navigationViewController: NavigationViewController,
        didArriveAt waypoint: Waypoint
    ) -> Bool {
        onArrival?()
        return true
    }
}
