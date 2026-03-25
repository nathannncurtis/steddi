import SwiftUI
import SwiftData
import CoreLocation

/// Reusable location picker — shows pinned locations + search for new ones.
/// Selecting a search result auto-pins it and returns the PinnedLocation.
struct LocationPickerView: View {
    let title: String
    let onSelect: (PinnedLocation) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PinnedLocation.sortOrder) private var pinnedLocations: [PinnedLocation]
    @AppStorage("accentColor") private var accentColor = "lavender"

    @State private var query = ""
    @State private var searchResults: [GeocodingResult] = []
    @State private var searchTask: Task<Void, Never>?

    private let geocodingService = GeocodingService()

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
        NavigationStack {
            List {
                // Search field
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(SteddiTheme.accent)
                        TextField("Search an address", text: $query)
                            .autocorrectionDisabled()
                            .onChange(of: query) { _, newValue in
                                debounceSearch(newValue)
                            }
                        if !query.isEmpty {
                            Button {
                                query = ""
                                searchResults = []
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Search results
                if !searchResults.isEmpty {
                    Section("Results") {
                        ForEach(searchResults) { result in
                            Button {
                                selectSearchResult(result)
                            } label: {
                                HStack {
                                    Image(systemName: "mappin")
                                        .foregroundStyle(SteddiTheme.accent)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
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
                                }
                            }
                        }
                    }
                }

                // Pinned locations
                if !pinnedLocations.isEmpty {
                    Section("Pinned Locations") {
                        ForEach(pinnedLocations) { location in
                            Button {
                                onSelect(location)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: location.icon)
                                        .foregroundStyle(SteddiTheme.accent)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(location.name)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                        if let address = location.address, !address.isEmpty {
                                            Text(address)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func selectSearchResult(_ result: GeocodingResult) {
        // Auto-pin the search result
        let location = PinnedLocation(
            name: result.name,
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude,
            address: result.address
        )
        modelContext.insert(location)
        try? modelContext.save()
        onSelect(location)
        dismiss()
    }

    private func debounceSearch(_ query: String) {
        searchTask?.cancel()
        guard !query.isEmpty else { searchResults = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            do {
                let results = try await geocodingService.search(query: query)
                if !Task.isCancelled { searchResults = results }
            } catch {}
        }
    }
}
