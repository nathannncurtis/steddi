import SwiftUI
import SwiftData

struct CommuteListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Commute.createdAt, order: .reverse) private var commutes: [Commute]
    @AppStorage("accentColor") private var accentColor = "lavender"
    @AppStorage(ThemeModeEx.defaultsKey) private var themeModeEx = ThemeModeEx.dynamic.rawValue

    @State private var showNewCommute = false

    /// Pin system chrome (List background, NewCommuteSheet Form, keyboards,
    /// pickers) to the active Steddi theme. This sheet is presented from
    /// HomeView, which does not re-pin across the .sheet boundary, so without
    /// this the Form can render in the device appearance while the rest of the
    /// app tracks the Steddi theme — a visible light-form-on-dark-app seam (and
    /// near-white accent text on a light grouped background in Grey mode).
    /// Mirrors SettingsView.resolvedColorScheme.
    private var resolvedColorScheme: ColorScheme? {
        (ThemeModeEx(rawValue: themeModeEx) ?? .dynamic).colorScheme
    }

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
        Group {
            if commutes.isEmpty {
                ContentUnavailableView(
                    "No commutes yet",
                    systemImage: "arrow.triangle.swap",
                    description: Text("Create a commute to link two locations with your preferred routes.")
                )
            } else {
                List {
                    ForEach(commutes) { commute in
                        NavigationLink {
                            CommuteDetailView(commute: commute)
                        } label: {
                            commuteRow(commute)
                        }
                    }
                    .onDelete(perform: deleteCommutes)
                }
            }
        }
        .navigationTitle("Commutes")
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
        .preferredColorScheme(resolvedColorScheme)
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
    @AppStorage(ThemeModeEx.defaultsKey) private var themeModeEx = ThemeModeEx.dynamic.rawValue

    @State private var name = ""
    @State private var origin: PinnedLocation?
    @State private var destination: PinnedLocation?
    @State private var showOriginPicker = false
    @State private var showDestinationPicker = false

    /// A presented sheet gets its own presentation context and does not reliably
    /// inherit the presenter's `.preferredColorScheme`, so pin it here too — the
    /// Form, keyboard, and pickers must track the active Steddi theme.
    private var resolvedColorScheme: ColorScheme? {
        (ThemeModeEx(rawValue: themeModeEx) ?? .dynamic).colorScheme
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Commute name", text: $name)
                }

                Section {
                    // Origin
                    Button {
                        showOriginPicker = true
                    } label: {
                        HStack {
                            Text("Origin")
                                .foregroundStyle(.primary)
                            Spacer()
                            if let origin {
                                Text(origin.name)
                                    .foregroundStyle(SteddiTheme.accent)
                            } else {
                                Text("Search or pick")
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Destination
                    Button {
                        showDestinationPicker = true
                    } label: {
                        HStack {
                            Text("Destination")
                                .foregroundStyle(.primary)
                            Spacer()
                            if let destination {
                                Text(destination.name)
                                    .foregroundStyle(SteddiTheme.accent)
                            } else {
                                Text("Search or pick")
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
            .sheet(isPresented: $showOriginPicker) {
                LocationPickerView(title: "Pick Origin") { location in
                    origin = location
                }
            }
            .sheet(isPresented: $showDestinationPicker) {
                LocationPickerView(title: "Pick Destination") { location in
                    destination = location
                }
            }
        }
        .preferredColorScheme(resolvedColorScheme)
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
    NavigationStack {
        CommuteListView()
    }
    .modelContainer(for: Commute.self, inMemory: true)
}
