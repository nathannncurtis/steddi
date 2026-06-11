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
        for index in offsets {
            modelContext.delete(visibleTrips[index])
        }
    }
}

#Preview {
    NavigationStack {
        TripListView()
    }
    .modelContainer(for: Trip.self, inMemory: true)
}
