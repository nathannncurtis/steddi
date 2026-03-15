import SwiftUI
import SwiftData
import MapboxMaps
import CoreLocation

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationService.self) private var locationService
    @Query(sort: \PinnedLocation.sortOrder) private var pinnedLocations: [PinnedLocation]

    @State private var viewport: Viewport = .followPuck(zoom: 14)
    @State private var showSettings = false
    @State private var showAddLocation = false
    @State private var selectedLocation: PinnedLocation?
    @State private var longPressCoordinate: CLLocationCoordinate2D?

    var body: some View {
        ZStack(alignment: .top) {
            // Mapbox map
            Map(viewport: $viewport) {
                // User location puck
                Puck2D(bearing: .heading)

                // Pin annotations for saved locations
                ForEvery(pinnedLocations) { location in
                    PointAnnotation(coordinate: location.coordinate)
                        .image(.init(image: UIImage(systemName: location.icon)!.withTintColor(.systemBlue, renderingMode: .alwaysOriginal), name: location.icon))
                        .onTapGesture {
                            selectedLocation = location
                        }
                }
            }
            .mapStyle(.standard(lightPreset: .dusk))
            .onMapLongPressGesture { context in
                longPressCoordinate = context.coordinate
                showAddLocation = true
            }
            .ignoresSafeArea()

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
                                    etaMinutes: nil,
                                    delayMinutes: nil,
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
        .onAppear {
            locationService.requestPermission()
            locationService.startUpdating()
        }
        .fullScreenCover(item: $selectedLocation) { location in
            ActiveNavigationView(destination: location)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showAddLocation) {
            AddLocationSheet(coordinate: longPressCoordinate)
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
}

// MARK: - Add Location Sheet

private struct AddLocationSheet: View {
    let coordinate: CLLocationCoordinate2D?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Location name", text: $name)
                }

                if let coord = coordinate {
                    Section {
                        HStack {
                            Text("Latitude")
                            Spacer()
                            Text(String(format: "%.4f", coord.latitude))
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Longitude")
                            Spacer()
                            Text(String(format: "%.4f", coord.longitude))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Pin Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.isEmpty || coordinate == nil)
                }
            }
        }
    }

    private func save() {
        guard let coord = coordinate else { return }
        let location = PinnedLocation(
            name: name,
            latitude: coord.latitude,
            longitude: coord.longitude
        )
        modelContext.insert(location)
    }
}

#Preview {
    HomeView()
        .modelContainer(for: PinnedLocation.self, inMemory: true)
        .environment(LocationService())
}
