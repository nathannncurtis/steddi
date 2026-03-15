import SwiftUI
import MapboxNavigationUIKit
import MapboxNavigationCore
import MapboxDirections
import CoreLocation

/// SwiftUI wrapper around Mapbox's NavigationViewController for turn-by-turn navigation.
struct MapboxNavigationView: UIViewControllerRepresentable {
    let navigationRoutes: NavigationRoutes
    let provider: MapboxNavigationProvider
    let onArrival: () -> Void
    let onCancelled: () -> Void

    func makeUIViewController(context: Context) -> NavigationViewController {
        let options = NavigationOptions(
            mapboxNavigation: provider.mapboxNavigation,
            voiceController: provider.routeVoiceController,
            eventsManager: provider.eventsManager(),
            styles: [StandardDayStyle(), StandardNightStyle()]
        )
        let vc = NavigationViewController(
            navigationRoutes: navigationRoutes,
            navigationOptions: options
        )
        vc.usesNightStyleInDarkMode = true
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: NavigationViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onArrival: onArrival, onCancelled: onCancelled)
    }

    class Coordinator: NSObject, NavigationViewControllerDelegate {
        let onArrival: () -> Void
        let onCancelled: () -> Void

        init(onArrival: @escaping () -> Void, onCancelled: @escaping () -> Void) {
            self.onArrival = onArrival
            self.onCancelled = onCancelled
        }

        func navigationViewControllerDidDismiss(
            _ navigationViewController: NavigationViewController,
            byCanceling canceled: Bool
        ) {
            if canceled {
                onCancelled()
            } else {
                onArrival()
            }
        }

        func navigationViewController(
            _ navigationViewController: NavigationViewController,
            didArriveAt waypoint: Waypoint
        ) -> Bool {
            onArrival()
            return true
        }
    }
}
