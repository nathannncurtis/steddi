import SwiftUI
import SwiftData

/// Full-screen trip management — mirrors CommuteListView. Active and archived
/// trips, create via the map planner, tap to edit.
struct TripListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Trip.createdAt, order: .reverse) private var trips: [Trip]
    @AppStorage("accentColor") private var accentColor = "lavender"

    @State private var showPlanner = false
    @State private var showArchived = false

    /// Trips a swipe-delete targeted that are mid-navigation — held until the
    /// confirmation alert resolves so deleting them can't orphan nav state.
    @State private var pendingInProgressDeletes: [Trip] = []

    private var visibleTrips: [Trip] {
        trips.filter { $0.isArchived == showArchived }
    }

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
        Group {
            if trips.isEmpty {
                ContentUnavailableView(
                    "No trips yet",
                    systemImage: "map",
                    description: Text("Plan a multi-stop journey — tap stops on the map in the order you want to visit them.")
                )
            } else {
                List {
                    Section {
                        Picker("Filter", selection: $showArchived) {
                            Text("Active").tag(false)
                            Text("Archived").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }

                    ForEach(visibleTrips) { trip in
                        NavigationLink {
                            TripEditorView(trip: trip)
                        } label: {
                            tripRow(trip)
                        }
                    }
                    .onDelete(perform: deleteTrips)
                }
            }
        }
        .navigationTitle("Trips")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showPlanner = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fullScreenCover(isPresented: $showPlanner) {
            TripPlannerView()
        }
        .alert(
            "Delete trip in progress?",
            isPresented: Binding(
                get: { !pendingInProgressDeletes.isEmpty },
                set: { if !$0 { pendingInProgressDeletes = [] } }
            )
        ) {
            Button("Delete", role: .destructive) {
                for trip in pendingInProgressDeletes { delete(trip) }
                pendingInProgressDeletes = []
            }
            Button("Cancel", role: .cancel) { pendingInProgressDeletes = [] }
        } message: {
            Text("This trip is being navigated. Deleting it will end the active trip session.")
        }
    }

    private func tripRow(_ trip: Trip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(trip.name)
                    .font(.body.weight(.semibold))
                if trip.isInProgress {
                    Text("\(trip.currentStopIndex + 1)/\(trip.orderedStops.count)")
                        .font(.caption2.weight(.semibold).monospaced())
                        .foregroundStyle(SteddiTheme.accent)
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.caption2)
                Text("\(trip.orderedStops.count) stop\(trip.orderedStops.count == 1 ? "" : "s")")
                Text("·")
                Text(trip.flowMode == .continuous ? "Continuous" : "Manual")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let completedAt = trip.completedAt {
                Text("Completed \(completedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func deleteTrips(at offsets: IndexSet) {
        // Delete idle trips immediately; defer any in-progress trip to a
        // confirmation alert so its active nav session is ended cleanly first.
        let targets = offsets.map { visibleTrips[$0] }
        var deferred: [Trip] = []
        for trip in targets {
            if trip.isInProgress {
                deferred.append(trip)
            } else {
                delete(trip)
            }
        }
        if !deferred.isEmpty {
            pendingInProgressDeletes = deferred
        }
    }

    /// Delete one trip, tearing down the active trip session first when this is
    /// the trip currently being navigated — leaving no dangling nav state.
    private func delete(_ trip: Trip) {
        let navState = NavigationStateManager.shared
        if navState.activeTrip?.id == trip.id {
            navState.endActiveTripSession()
        }
        modelContext.delete(trip)
    }
}

#Preview {
    NavigationStack {
        TripListView()
    }
    .modelContainer(for: Trip.self, inMemory: true)
}
