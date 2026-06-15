import SwiftUI
import SwiftData

/// Edit an existing trip: rename, reorder stops (drag handle), edit or delete
/// stops, toggle flow mode and route preferences. Mid-trip edits stay safe —
/// deleting the current stop rolls the position back via Trip.removeStop, and
/// reorders preserve the current stop by UUID identity.
struct TripEditorView: View {
    @Bindable var trip: Trip
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("accentColor") private var accentColor = "lavender"
    @AppStorage(ThemeModeEx.defaultsKey) private var themeModeEx: String = ThemeModeEx.dynamic.rawValue

    @State private var showDeleteInProgressConfirm = false

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
        Form {
            Section("Trip") {
                TextField("Trip name", text: $trip.name)

                Picker("Between stops", selection: $trip.flowMode) {
                    Text("Continuous — auto-start next leg").tag(TripFlowMode.continuous)
                    Text("Manual — confirm each leg").tag(TripFlowMode.manual)
                }
                .pickerStyle(.menu)
            }

            Section("Stops") {
                ForEach(trip.orderedStops) { stop in
                    NavigationLink {
                        TripStopEditorView(stop: stop)
                    } label: {
                        stopRow(stop)
                    }
                }
                .onMove(perform: moveStops)
                .onDelete(perform: deleteStops)
            }

            Section("Route Preferences") {
                Toggle("Avoid tolls", isOn: optionalToggle($trip.avoidsTolls))
                    .tint(SteddiTheme.accent)
                Toggle("Avoid highways", isOn: optionalToggle($trip.avoidsHighways))
                    .tint(SteddiTheme.accent)
                Text("Off = use your global Settings defaults")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if trip.isInProgress {
                    Button("Start Over") {
                        trip.resetProgress()
                    }
                }
                Button(trip.isArchived ? "Unarchive Trip" : "Archive Trip") {
                    trip.isArchived.toggle()
                    if !trip.isArchived { trip.completedAt = nil }
                }
                Button("Delete Trip", role: .destructive) {
                    if trip.isInProgress {
                        // Deleting mid-trip would orphan navigation state — confirm
                        // first, then end the active session before removing.
                        showDeleteInProgressConfirm = true
                    } else {
                        deleteTrip()
                    }
                }
            }
        }
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .alert("Delete trip in progress?", isPresented: $showDeleteInProgressConfirm) {
            Button("Delete", role: .destructive) { deleteTrip() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This trip is being navigated. Deleting it will end the active trip session.")
        }
        .preferredColorScheme(resolvedColorScheme)
    }

    private var resolvedColorScheme: ColorScheme? {
        (ThemeModeEx(rawValue: themeModeEx) ?? .dynamic).colorScheme
    }

    /// Remove the trip, first tearing down the active trip session if this is
    /// the one being navigated — so no dangling activeTrip or nav state remains.
    private func deleteTrip() {
        let navState = NavigationStateManager.shared
        if navState.activeTrip?.id == trip.id {
            navState.endActiveTripSession()
        }
        modelContext.delete(trip)
        dismiss()
    }

    private func stopRow(_ stop: TripStop) -> some View {
        let isCurrent = stop.id == trip.currentStopId
        return HStack(spacing: 10) {
            Text("\(stop.order + 1)")
                .font(.caption.weight(.bold).monospaced())
                // Contrast with whichever fill: accent for the current stop,
                // textMuted otherwise. White-on-textMuted is invisible in the
                // light grey theme and weak elsewhere, so pick per-fill.
                .foregroundStyle(isCurrent
                    ? SteddiTheme.onAccent
                    : SteddiTheme.contrastingForeground(on: ThemeEngine.snapshot.textMuted))
                .frame(width: 22, height: 22)
                .background(
                    isCurrent ? SteddiTheme.accent : SteddiTheme.textMuted,
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .font(.body)
                if let notes = stop.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if stop.arrivalTime != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(SteddiTheme.sage)
            }
        }
    }

    private func moveStops(from source: IndexSet, to destination: Int) {
        var ordered = trip.orderedStops
        ordered.move(fromOffsets: source, toOffset: destination)
        trip.reorderStops(ordered)
    }

    private func deleteStops(at offsets: IndexSet) {
        let ordered = trip.orderedStops
        for index in offsets {
            let stop = ordered[index]
            trip.removeStop(stop)       // rolls back mid-trip position if needed
            modelContext.delete(stop)
        }
    }

    /// Bridge an optional Bool preference to a Toggle: nil reads as false
    /// (inherit global), turning the toggle off restores inherit.
    private func optionalToggle(_ binding: Binding<Bool?>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue ?? false },
            set: { binding.wrappedValue = $0 ? true : nil }
        )
    }
}

// MARK: - Stop Editor

/// Edit one stop: name, address, notes, and per-leg toll/highway overrides.
struct TripStopEditorView: View {
    @Bindable var stop: TripStop

    var body: some View {
        Form {
            Section("Stop") {
                TextField("Name", text: $stop.name)
                TextField("Address", text: Binding(
                    get: { stop.address ?? "" },
                    set: { stop.address = $0.isEmpty ? nil : $0 }
                ))
                TextField("Notes (e.g. lunch spot, photo op)", text: Binding(
                    get: { stop.notes ?? "" },
                    set: { stop.notes = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
            }

            Section("This Leg") {
                Toggle("Avoid tolls", isOn: optionalToggle($stop.avoidsTolls))
                    .tint(SteddiTheme.accent)
                Toggle("Avoid highways", isOn: optionalToggle($stop.avoidsHighways))
                    .tint(SteddiTheme.accent)

                if let route = stop.savedRoute {
                    HStack {
                        Label(route.name ?? "Saved route", systemImage: "road.lanes")
                        Spacer()
                        Button("Remove", role: .destructive) {
                            stop.savedRoute = nil
                        }
                        .font(.caption)
                    }
                } else {
                    Text("No saved route — live routing is used for this leg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let arrivalTime = stop.arrivalTime {
                Section {
                    Text("Arrived \(arrivalTime.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(stop.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func optionalToggle(_ binding: Binding<Bool?>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue ?? false },
            set: { binding.wrappedValue = $0 ? true : nil }
        )
    }
}
