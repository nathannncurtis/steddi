import SwiftUI
import SwiftData

struct CommuteDetailView: View {
    @Bindable var commute: Commute

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirmation = false
    @State private var showAddRoute = false
    @State private var showOriginPicker = false
    @State private var showDestinationPicker = false

    var body: some View {
        Form {
            // MARK: - Basic Info
            Section {
                TextField("Name", text: $commute.name)

                Button {
                    showOriginPicker = true
                } label: {
                    HStack {
                        Text("Origin")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(commute.origin?.name ?? "Select")
                            .foregroundStyle(commute.origin != nil ? SteddiTheme.accent : .secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    showDestinationPicker = true
                } label: {
                    HStack {
                        Text("Destination")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(commute.destination?.name ?? "Select")
                            .foregroundStyle(commute.destination != nil ? SteddiTheme.accent : .secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // MARK: - Routes
            Section {
                if commute.orderedRoutes.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "road.lanes")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("No routes yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button {
                            showAddRoute = true
                        } label: {
                            Label("Plan a route", systemImage: "map")
                                .font(.body.weight(.medium))
                                .foregroundStyle(SteddiTheme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(SteddiTheme.accentSubtle, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.vertical, 12)
                } else {
                    ForEach(commute.orderedRoutes) { route in
                        routeRow(route)
                    }
                    .onMove(perform: reorderRoutes)
                    .onDelete(perform: deleteRoutes)
                }

                Button {
                    showAddRoute = true
                } label: {
                    Label("Add another route", systemImage: "plus.circle")
                }
            } header: {
                HStack {
                    Text("Routes")
                    Spacer()
                    if !commute.orderedRoutes.isEmpty {
                        Text("Drag to reorder")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } footer: {
                Text("The top route is preferred. Fallback routes are used for reroute suggestions.")
            }

            // MARK: - Threshold Settings
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Reroute threshold")
                        Spacer()
                        Text("\(Int(commute.thresholdPercentage * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $commute.thresholdPercentage, in: 0.05...0.50, step: 0.05)
                        .tint(SteddiTheme.accent)
                }

                Stepper(
                    "Hard floor: \(commute.hardMinuteFloor ?? 10) min",
                    value: Binding(
                        get: { commute.hardMinuteFloor ?? 10 },
                        set: { commute.hardMinuteFloor = $0 }
                    ),
                    in: 2...30
                )
            } header: {
                Text("Reroute Sensitivity")
            } footer: {
                Text("Override the global defaults for this commute.")
            }

            // MARK: - Active Toggle
            Section {
                Toggle("Active", isOn: $commute.isActive)
            } footer: {
                Text("Inactive commutes will not trigger reroute checks.")
            }

            // MARK: - Delete
            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Delete Commute")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle(commute.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this commute?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                modelContext.delete(commute)
                dismiss()
            }
        } message: {
            Text("This will also delete all routes associated with this commute.")
        }
        .sheet(isPresented: $showAddRoute) {
            RoutePlannerView(commute: commute)
        }
        .sheet(isPresented: $showOriginPicker) {
            LocationPickerView(title: "Pick Origin") { location in
                commute.origin = location
            }
        }
        .sheet(isPresented: $showDestinationPicker) {
            LocationPickerView(title: "Pick Destination") { location in
                commute.destination = location
            }
        }
    }

    private func routeRow(_ route: Route) -> some View {
        HStack {
            if route.rank == 0 {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            } else {
                Text("#\(route.rank + 1)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(route.name ?? "Route \(route.rank + 1)")
                    .font(.body)

                HStack(spacing: 8) {
                    Text(route.source.rawValue.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(route.source == .recorded ? SteddiTheme.sage : SteddiTheme.accent, in: Capsule())

                    if let duration = route.typicalDurationSeconds {
                        Text("\(Int(duration / 60)) min typical")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func reorderRoutes(_ source: IndexSet, _ destination: Int) {
        var routes = commute.orderedRoutes
        routes.move(fromOffsets: source, toOffset: destination)
        for (index, route) in routes.enumerated() {
            route.rank = index
        }
    }

    private func deleteRoutes(at offsets: IndexSet) {
        let routes = commute.orderedRoutes
        for index in offsets {
            modelContext.delete(routes[index])
        }
        // Re-rank remaining routes
        let remaining = commute.orderedRoutes
        for (index, route) in remaining.enumerated() {
            route.rank = index
        }
    }
}

#Preview {
    NavigationStack {
        CommuteDetailView(
            commute: Commute(name: "Work Commute")
        )
    }
    .modelContainer(for: Commute.self, inMemory: true)
}
