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
    @State private var showSearch = false
    @State private var selectedLocation: PinnedLocation?
    @State private var navigateToResult: GeocodingResult?

    // Long press pin flow
    @State private var showAddLocation = false
    @State private var longPressCoordinate: CLLocationCoordinate2D?

    var body: some View {
        ZStack {
            // Mapbox map
            Map(viewport: $viewport) {
                Puck2D(bearing: .heading)

                ForEvery(pinnedLocations) { location in
                    PointAnnotation(coordinate: location.coordinate)
                        .image(.init(image: UIImage(systemName: location.icon)!.withTintColor(.systemBlue, renderingMode: .alwaysOriginal), name: location.icon))
                }
            }
            .mapStyle(.standard(lightPreset: .dusk))
            .onMapLongPressGesture { context in
                longPressCoordinate = context.coordinate
                showAddLocation = true
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar: search + settings
                HStack(spacing: 12) {
                    // Search bar
                    Button {
                        showSearch = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.primary)
                            Text("Where to?")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .glassEffect(.regular, in: .capsule)

                    // Settings gear
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title3)
                            .padding(12)
                    }
                    .glassEffect(.regular, in: .circle)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                // Bottom: pinned locations or empty state
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
        .fullScreenCover(item: $navigateToResult) { result in
            ActiveNavigationView(
                destination: PinnedLocation(
                    name: result.name,
                    latitude: result.coordinate.latitude,
                    longitude: result.coordinate.longitude,
                    address: result.address
                )
            )
        }
        .sheet(isPresented: $showSearch) {
            SearchView(
                currentLocation: locationService.currentLocation?.coordinate,
                onSelectResult: { result in
                    showSearch = false
                    navigateToResult = result
                },
                onPinResult: { result in
                    showSearch = false
                    pinLocation(from: result)
                }
            )
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
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 40)
    }

    private func pinLocation(from result: GeocodingResult) {
        let location = PinnedLocation(
            name: result.name,
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude,
            address: result.address
        )
        modelContext.insert(location)
    }
}

// MARK: - Search View

struct SearchView: View {
    let currentLocation: CLLocationCoordinate2D?
    let onSelectResult: (GeocodingResult) -> Void
    let onPinResult: (GeocodingResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [GeocodingResult] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    private let geocodingService = GeocodingService(accessToken: MapboxTokenProvider.accessToken)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search for a place", text: $query)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .autocorrectionDisabled()
                        .onChange(of: query) { _, newValue in
                            debounceSearch(newValue)
                        }
                    if !query.isEmpty {
                        Button {
                            query = ""
                            results = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // Results
                if results.isEmpty && !query.isEmpty {
                    ContentUnavailableView("No results", systemImage: "magnifyingglass", description: Text("Try a different search"))
                        .frame(maxHeight: .infinity)
                } else {
                    List(results) { result in
                        Button {
                            onSelectResult(result)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    if !result.address.isEmpty && result.address != result.name {
                                        Text(result.address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                // Pin button
                                Button {
                                    onPinResult(result)
                                } label: {
                                    Image(systemName: "mappin.circle")
                                        .font(.title3)
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                isSearchFocused = true
            }
        }
    }

    private func debounceSearch(_ query: String) {
        searchTask?.cancel()
        guard !query.isEmpty else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let searchResults = try await geocodingService.search(
                    query: query,
                    proximity: currentLocation
                )
                if !Task.isCancelled {
                    results = searchResults
                }
            } catch {
                // Silently fail — results just stay empty
            }
        }
    }
}

// MARK: - Add Location Sheet (from long press)

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
