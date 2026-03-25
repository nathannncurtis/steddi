import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// Standalone navigation view — currently unused.
/// HomeView uses SteddiMapView + SteddiNavOverlay directly instead.
struct ActiveNavigationView: View {
    let destination: PinnedLocation

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // This view is no longer used. Navigation is handled in HomeView.
        Text("Navigation handled by HomeView")
            .onAppear { dismiss() }
    }
}
