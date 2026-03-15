import SwiftUI
import MapboxMaps
import MapboxNavigationCore
import MapboxDirections
import CoreLocation
import Combine

/// Manages the map in a single UIKit view controller.
/// Navigation uses the same map — Steddi's custom SwiftUI overlay replaces Mapbox's stock UI.
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
        return vc
    }

    func updateUIViewController(_ vc: SteddiMapContainer, context: Context) {
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
    var isInNavigation = false
    private var routeLine: [CLLocationCoordinate2D] = []

    var onLongPress: ((CLLocationCoordinate2D) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()

        let initOptions = MapInitOptions(styleURI: .dark)
        mapView = MapView(frame: view.bounds, mapInitOptions: initOptions)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Lavender puck
        var puckConfig = Puck2DConfiguration()
        puckConfig.pulsing = .init(color: UIColor(red: 0.61, green: 0.56, blue: 0.77, alpha: 0.3))
        mapView.location.options.puckType = .puck2D(puckConfig)
        mapView.location.options.puckBearing = .heading

        // Hide ornaments that clash with Steddi UI
        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.compass.visibility = .hidden

        // Initial camera
        mapView.mapboxMap.setCamera(to: CameraOptions(zoom: 14))

        view.addSubview(mapView)

        // Follow user location on style load
        mapView.mapboxMap.onStyleLoaded.observeNext { [weak self] _ in
            guard let self,
                  let coord = self.mapView.location.latestLocation?.coordinate else { return }
            self.mapView.mapboxMap.setCamera(to: CameraOptions(center: coord, zoom: 14))
        }.store(in: &cancellables)

        // Long press gesture
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

        // Start active guidance on the navigation core
        provider.tripSession().startActiveGuidance(with: routes, startLegIndex: 0)

        // Show route line on map
        let coords = routes.mainRoute.route.shape?.coordinates ?? []
        showRouteLine(coords)

        // Camera follows route
        mapView.mapboxMap.setCamera(to: CameraOptions(
            center: mapView.location.latestLocation?.coordinate,
            zoom: 16,
            bearing: 0,
            pitch: 45
        ))

        // Follow location during nav
        provider.navigation().locationMatching
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let coord = state.enhancedLocation.coordinate
                self.mapView.mapboxMap.setCamera(to: CameraOptions(
                    center: coord,
                    zoom: 16,
                    bearing: state.enhancedLocation.course,
                    pitch: 50
                ))
            }
            .store(in: &cancellables)
    }

    func stopNavigation() {
        guard isInNavigation else { return }
        isInNavigation = false

        // Cancel location following subscriptions
        cancellables.removeAll()

        // Remove route line
        removeRouteLine()

        // Reset camera
        mapView.mapboxMap.setCamera(to: CameraOptions(
            center: mapView.location.latestLocation?.coordinate,
            zoom: 14,
            bearing: 0,
            pitch: 0
        ))

        // Re-subscribe to style loaded for home mode
        mapView.mapboxMap.onStyleLoaded.observeNext { [weak self] _ in
            guard let self,
                  let coord = self.mapView.location.latestLocation?.coordinate else { return }
            self.mapView.mapboxMap.setCamera(to: CameraOptions(center: coord, zoom: 14))
        }.store(in: &cancellables)
    }

    // MARK: - Route Line

    private func showRouteLine(_ coordinates: [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty else { return }

        var source = GeoJSONSource(id: "steddi-route-source")
        source.data = .geometry(.lineString(LineString(coordinates)))

        var layer = LineLayer(id: "steddi-route-layer", source: "steddi-route-source")
        layer.lineColor = .constant(StyleColor(UIColor(red: 0.61, green: 0.56, blue: 0.77, alpha: 0.8)))
        layer.lineWidth = .constant(6)
        layer.lineCap = .constant(.round)
        layer.lineJoin = .constant(.round)

        try? mapView.mapboxMap.addSource(source)
        try? mapView.mapboxMap.addLayer(layer)
    }

    private func removeRouteLine() {
        try? mapView.mapboxMap.removeLayer(withId: "steddi-route-layer")
        try? mapView.mapboxMap.removeSource(withId: "steddi-route-source")
    }
}
