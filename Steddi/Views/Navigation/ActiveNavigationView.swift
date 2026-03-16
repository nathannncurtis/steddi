import SwiftUI
import SwiftData
import MapboxNavigationUIKit
import MapboxNavigationCore
import MapboxDirections
import CoreLocation

struct ActiveNavigationView: View {
    let destination: PinnedLocation

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationService.self) private var locationService

    @State private var navigationRoutes: NavigationRoutes?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showPostArrival = false
    @State private var recordedPoints: [GPSPoint] = []

    // Shared navigation provider — must be a single instance app-wide
    // In production this would be injected; for now create per-session
    @State private var mapboxNavProvider: MapboxNavigationProvider?

    var body: some View {
        ZStack {
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if let routes = navigationRoutes, let provider = mapboxNavProvider {
                MapboxNavigationView(
                    navigationRoutes: routes,
                    provider: provider,
                    onArrival: {
                        recordedPoints = locationService.stopRecording()
                        showPostArrival = true
                    },
                    onCancelled: {
                        locationService.stopRecording()
                        dismiss()
                    }
                )
                .ignoresSafeArea()
            }
        }
        .task {
            await calculateRoute()
        }
        .sheet(isPresented: $showPostArrival, onDismiss: {
            dismiss()
        }) {
            PostArrivalSheet(
                recordedPoints: recordedPoints,
                commute: nil,
                direction: nil,
                onEditRoute: {}
            )
            .presentationDetents([.large])
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(x: 1.5, y: 1.5)
            Text("Calculating route...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Route Error")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Go Back") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private func calculateRoute() async {
        // Wait for a valid location fix (up to 10 seconds)
        locationService.startUpdating()
        var currentLocation = locationService.currentLocation
        for _ in 0..<20 {
            if currentLocation != nil { break }
            try? await Task.sleep(for: .milliseconds(500))
            currentLocation = locationService.currentLocation
        }

        guard let currentLocation else {
            errorMessage = "Unable to determine your location. Make sure location services are enabled."
            isLoading = false
            return
        }

        let provider = MapboxNavigationProvider(coreConfig: .init())
        self.mapboxNavProvider = provider

        let origin = Waypoint(
            coordinate: currentLocation.coordinate,
            name: "Current Location"
        )
        let dest = Waypoint(
            coordinate: destination.coordinate,
            name: destination.name
        )

        let routeOptions = NavigationRouteOptions(waypoints: [origin, dest])

        do {
            let routes = try await provider.routingProvider().calculateRoutes(options: routeOptions).value
            self.navigationRoutes = routes
            isLoading = false

            // Start GPS recording for potential route save
            locationService.startRecording()
        } catch {
            errorMessage = "Could not find a route to \(destination.name)."
            isLoading = false
        }
    }
}

// MARK: - Mapbox UIKit Bridge

private struct MapboxNavigationView: UIViewControllerRepresentable {
    let navigationRoutes: NavigationRoutes
    let provider: MapboxNavigationProvider
    let onArrival: () -> Void
    let onCancelled: () -> Void

    func makeUIViewController(context: Context) -> NavigationViewController {
        let options = NavigationOptions(
            mapboxNavigation: provider.mapboxNavigation,
            voiceController: provider.routeVoiceController,
            eventsManager: provider.eventsManager()
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
