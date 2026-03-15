import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PinnedLocation.sortOrder) private var pinnedLocations: [PinnedLocation]

    @State private var showSettings = false
    @State private var showAddLocation = false
    @State private var selectedLocation: PinnedLocation?
    @State private var longPressCoordinate: (Double, Double)?

    var body: some View {
        ZStack(alignment: .top) {
            // TODO: Replace with Mapbox MapView — long press gesture will come from map delegate
            MapPlaceholderView()
                .ignoresSafeArea()
                .onLongPressGesture {
                    // Placeholder: in real implementation, this captures the map coordinate
                    showAddLocation = true
                }

            // Settings gear
            HStack {
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(.trailing, 16)
                .padding(.top, 8)
            }

            // Bottom pinned locations strip
            VStack {
                Spacer()

                if pinnedLocations.isEmpty {
                    emptyStateCard
                        .padding(.bottom, 40)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(pinnedLocations) { location in
                                LocationCardView(
                                    name: location.name,
                                    icon: location.icon,
                                    etaMinutes: estimatedETA(for: location),
                                    delayMinutes: estimatedDelay(for: location),
                                    onTap: {
                                        selectedLocation = location
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .fullScreenCover(item: $selectedLocation) { location in
            ActiveNavigationView(destination: location)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showAddLocation) {
            // TODO: Add location flow with map coordinate from long press
            Text("Add pinned location")
                .presentationDetents([.medium])
        }
    }

    private var emptyStateCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "mappin.and.ellipse")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Long press the map to pin a location")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 40)
    }

    // MARK: - Placeholder helpers
    // TODO: Replace with real ETA from NavigationViewModel / Mapbox Directions API

    private func estimatedETA(for location: PinnedLocation) -> Int? {
        // Placeholder — will come from live traffic data
        nil
    }

    private func estimatedDelay(for location: PinnedLocation) -> Int? {
        // Placeholder — will come from comparing current vs typical duration
        nil
    }
}

#Preview {
    HomeView()
        .modelContainer(for: PinnedLocation.self, inMemory: true)
}
