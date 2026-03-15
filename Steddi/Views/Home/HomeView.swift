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

            // Bottom sheet: pinned locations
            if !showSearch {
                VStack {
                    Spacer()
                    bottomSheet
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Top bar OR expanded search
            VStack {
                if showSearch {
                    ExpandedSearchView(
                        currentLocation: locationService.currentLocation?.coordinate,
                        onSelectResult: { result in
                            withAnimation(.easeInOut(duration: 0.3)) { showSearch = false }
                            navigateToResult = result
                        },
                        onPinResult: { result in
                            withAnimation(.easeInOut(duration: 0.3)) { showSearch = false }
                            pinLocation(from: result)
                        },
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.3)) { showSearch = false }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                } else {
                    topBar
                        .transition(.opacity)
                }
                Spacer()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showSearch)
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
            Button {
                withAnimation(.easeInOut(duration: 0.3)) { showSearch = true }
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
                            onTap: { selectedLocation = location }
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

// MARK: - Expanded Search (grows from search bar)

private struct ExpandedSearchView: View {
    let currentLocation: CLLocationCoordinate2D?
    let onSelectResult: (GeocodingResult) -> Void
    let onPinResult: (GeocodingResult) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var results: [GeocodingResult] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    private let geocodingService = GeocodingService(accessToken: MapboxTokenProvider.accessToken)

    var body: some View {
        VStack(spacing: 0) {
            // Search field — same position as the "Where to?" bar
            HStack(spacing: 10) {
                Button(action: onDismiss) {
                    Image(systemName: "arrow.left")
                        .font(.body.weight(.medium))
                        .foregroundStyle(SteddiTheme.amber)
                }

                TextField("Search an address", text: $query)
                    .font(SteddiTheme.body(17))
                    .foregroundStyle(SteddiTheme.textPrimary)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background {
                Capsule()
                    .fill(SteddiTheme.surfacePrimary)
                    .overlay(
                        Capsule()
                            .stroke(SteddiTheme.amber.opacity(0.25), lineWidth: 1)
                    )
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // Results — grow downward from the search bar
            if !results.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(results) { result in
                            Button {
                                onSelectResult(result)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin")
                                        .font(.body)
                                        .foregroundStyle(SteddiTheme.amber)
                                        .frame(width: 32)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(result.name)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(SteddiTheme.textPrimary)
                                        if !result.address.isEmpty && result.address != result.name {
                                            Text(result.address)
                                                .font(.caption)
                                                .foregroundStyle(SteddiTheme.textSecondary)
                                                .lineLimit(1)
                                        }
                                    }

                                    Spacer()

                                    // Pin button
                                    Button {
                                        onPinResult(result)
                                    } label: {
                                        Image(systemName: "mappin.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(SteddiTheme.amber)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)

                            if result.id != results.last?.id {
                                Divider()
                                    .background(SteddiTheme.surfaceElevated)
                                    .padding(.leading, 60)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .background {
                    RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                        .fill(SteddiTheme.surfacePrimary.opacity(0.95))
                        .overlay(
                            RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                                .stroke(SteddiTheme.amber.opacity(0.08), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .frame(maxHeight: 360)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            } else if !query.isEmpty {
                Text("No results")
                    .font(SteddiTheme.body(14))
                    .foregroundStyle(SteddiTheme.textMuted)
                    .padding(.top, 24)
            }
        }
        .onAppear {
            isSearchFocused = true
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
                    withAnimation(.easeOut(duration: 0.2)) {
                        results = searchResults
                    }
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
