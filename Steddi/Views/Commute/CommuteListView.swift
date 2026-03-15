import SwiftUI
import SwiftData

struct CommuteListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Commute.createdAt, order: .reverse) private var commutes: [Commute]

    @State private var showNewCommute = false

    var body: some View {
        NavigationStack {
            Group {
                if commutes.isEmpty {
                    ContentUnavailableView(
                        "No commutes yet",
                        systemImage: "arrow.triangle.swap",
                        description: Text("Create a commute to link two pinned locations with your preferred routes.")
                    )
                } else {
                    List {
                        ForEach(commutes) { commute in
                            NavigationLink(value: commute) {
                                commuteRow(commute)
                            }
                        }
                        .onDelete(perform: deleteCommutes)
                    }
                }
            }
            .navigationTitle("Commutes")
            .navigationDestination(for: Commute.self) { commute in
                CommuteDetailView(commute: commute)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewCommute = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showNewCommute) {
                NewCommuteSheet()
            }
        }
    }

    private func commuteRow(_ commute: Commute) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(commute.name)
                .font(.body.weight(.semibold))

            HStack(spacing: 4) {
                Text(commute.origin?.name ?? "Origin")
                Image(systemName: "arrow.right")
                    .font(.caption2)
                Text(commute.destination?.name ?? "Destination")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let preferred = commute.preferredRoute {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                    Text(preferred.name ?? "Preferred route")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func deleteCommutes(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(commutes[index])
        }
    }
}

// MARK: - New Commute Sheet

private struct NewCommuteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PinnedLocation.sortOrder) private var locations: [PinnedLocation]

    @State private var name = ""
    @State private var origin: PinnedLocation?
    @State private var destination: PinnedLocation?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Commute name", text: $name)
                }

                Section {
                    Picker("Origin", selection: $origin) {
                        Text("Select").tag(nil as PinnedLocation?)
                        ForEach(locations) { location in
                            Label(location.name, systemImage: location.icon)
                                .tag(location as PinnedLocation?)
                        }
                    }

                    Picker("Destination", selection: $destination) {
                        Text("Select").tag(nil as PinnedLocation?)
                        ForEach(locations) { location in
                            Label(location.name, systemImage: location.icon)
                                .tag(location as PinnedLocation?)
                        }
                    }
                } footer: {
                    Text("Pin locations from the home screen first.")
                }
            }
            .navigationTitle("New Commute")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        createCommute()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.isEmpty || origin == nil || destination == nil)
                }
            }
        }
    }

    private func createCommute() {
        let commute = Commute(
            name: name,
            origin: origin,
            destination: destination
        )
        modelContext.insert(commute)
    }
}

#Preview {
    CommuteListView()
        .modelContainer(for: Commute.self, inMemory: true)
}
