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
        ZStack(alignment: .bottom) {
            // Full-screen Mapbox map
            Map(viewport: $viewport) {
                Puck2D(bearing: .heading)

                ForEvery(pinnedLocations) { location in
                    PointAnnotation(coordinate: location.coordinate)
                        .image(.init(image: UIImage(systemName: location.icon)!.withTintColor(.systemOrange, renderingMode: .alwaysOriginal), name: location.icon))
                }
            }
            .mapStyle(.standard(lightPreset: .dusk))
            .onMapLongPressGesture { context in
                longPressCoordinate = context.coordinate
                showAddLocation = true
            }
            .ignoresSafeArea()

            // Top bar: search + settings
            VStack {
                topBar
                Spacer()
            }

            // Bottom sheet: pinned locations
            bottomSheet
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

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // Search bar
            Button {
                showSearch = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.medium))
                        .foregroundStyle(SteddiTheme.amber)
                    Text("Where to?")
                        .font(SteddiTheme.heading(17))
                        .foregroundStyle(SteddiTheme.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background {
                    Capsule()
                        .fill(SteddiTheme.surfacePrimary.opacity(0.9))
                        .overlay(
                            Capsule()
                                .stroke(SteddiTheme.amber.opacity(0.15), lineWidth: 1)
                        )
                }
            }

            // Settings
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(SteddiTheme.textSecondary)
                    .frame(width: 44, height: 44)
                    .background {
                        Circle()
                            .fill(SteddiTheme.surfacePrimary.opacity(0.9))
                            .overlay(
                                Circle()
                                    .stroke(SteddiTheme.amber.opacity(0.08), lineWidth: 1)
                            )
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Bottom Sheet

    private var bottomSheet: some View {
        VStack(spacing: 0) {
            // Drag indicator + steady line
            VStack(spacing: 8) {
                Capsule()
                    .fill(SteddiTheme.textMuted.opacity(0.4))
                    .frame(width: 36, height: 4)

                SteadyLine(color: SteddiTheme.amber, height: 1)
                    .padding(.horizontal, 40)
            }
            .padding(.top, 12)

            if pinnedLocations.isEmpty {
                emptyState
                    .padding(.vertical, 24)
                    .padding(.horizontal, 20)
            } else {
                VStack(spacing: 8) {
                    ForEach(pinnedLocations.prefix(4)) { location in
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
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .background {
            UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusLarge, topTrailingRadius: SteddiTheme.radiusLarge)
                .fill(SteddiTheme.surfacePrimary.opacity(0.95))
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusLarge, topTrailingRadius: SteddiTheme.radiusLarge)
                        .stroke(SteddiTheme.amber.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 20, y: -5)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .font(.title2)
                .foregroundStyle(SteddiTheme.amber)

            Text("No pinned locations yet")
                .font(SteddiTheme.heading(16))
                .foregroundStyle(SteddiTheme.textPrimary)

            Text("Long press the map or search to save a place")
                .font(SteddiTheme.body(14))
                .foregroundStyle(SteddiTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
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
                // Search field with amber accent
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(SteddiTheme.amber)
                    TextField("Search an address", text: $query)
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
                                .foregroundStyle(SteddiTheme.textMuted)
                        }
                    }
                }
                .padding(14)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: SteddiTheme.radiusSmall))
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if results.isEmpty && !query.isEmpty {
                    ContentUnavailableView("No results", systemImage: "magnifyingglass", description: Text("Try a different address"))
                        .frame(maxHeight: .infinity)
                } else {
                    List(results) { result in
                        Button {
                            onSelectResult(result)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.name)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if !result.address.isEmpty && result.address != result.name {
                                        Text(result.address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                Button {
                                    onPinResult(result)
                                } label: {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(SteddiTheme.amber)
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
            } catch {}
        }
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
