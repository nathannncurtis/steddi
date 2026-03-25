import SwiftUI
import SwiftData

struct CommuteDetailView: View {
    @Bindable var commute: Commute
    @AppStorage("accentColor") private var accentColor = "lavender"

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(OfflineCacheService.self) private var offlineCacheService

    @State private var showDeleteConfirmation = false
    @State private var downloadingRouteIDs: Set<UUID> = []
    @State private var showAddRoute = false
    @State private var showOriginPicker = false
    @State private var showDestinationPicker = false

    // Schedule UI state
    @State private var useSchedule = false

    private static let dayAbbreviations = ["S", "M", "T", "W", "T", "F", "S"]
    // weekday components: Sun=1..Sat=7
    private static let weekdayValues = [1, 2, 3, 4, 5, 6, 7]

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
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

            // MARK: - Auto-Direction Schedule
            Section {
                Toggle("Use time-based direction", isOn: $useSchedule)
                    .onChange(of: useSchedule) { _, newValue in
                        if !newValue {
                            commute.scheduleToDestDays = nil
                            commute.scheduleToDestStartHour = nil
                            commute.scheduleToDestEndHour = nil
                            commute.scheduleToOriginDays = nil
                            commute.scheduleToOriginStartHour = nil
                            commute.scheduleToOriginEndHour = nil
                        } else {
                            // Set defaults: Mon-Fri
                            if commute.scheduleToDestDays == nil {
                                commute.scheduleToDestDays = "2,3,4,5,6"
                                commute.scheduleToDestStartHour = 6
                                commute.scheduleToDestEndHour = 10
                            }
                            if commute.scheduleToOriginDays == nil {
                                commute.scheduleToOriginDays = "2,3,4,5,6"
                                commute.scheduleToOriginStartHour = 15
                                commute.scheduleToOriginEndHour = 19
                            }
                        }
                    }

                if useSchedule {
                    // Go to destination schedule
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Go to \(commute.destination?.name ?? "Destination")")
                            .font(.subheadline.weight(.semibold))

                        dayPicker(
                            selectedDays: Binding(
                                get: { parseDays(commute.scheduleToDestDays) },
                                set: { commute.scheduleToDestDays = encodeDays($0) }
                            )
                        )

                        HStack {
                            Text("From")
                                .foregroundStyle(.secondary)
                            Picker("Start", selection: Binding(
                                get: { commute.scheduleToDestStartHour ?? 6 },
                                set: { commute.scheduleToDestStartHour = $0 }
                            )) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(formatHour(h)).tag(h)
                                }
                            }
                            .labelsHidden()

                            Text("to")
                                .foregroundStyle(.secondary)
                            Picker("End", selection: Binding(
                                get: { commute.scheduleToDestEndHour ?? 10 },
                                set: { commute.scheduleToDestEndHour = $0 }
                            )) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(formatHour(h)).tag(h)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    .padding(.vertical, 4)

                    // Go to origin schedule
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Go to \(commute.origin?.name ?? "Origin")")
                            .font(.subheadline.weight(.semibold))

                        dayPicker(
                            selectedDays: Binding(
                                get: { parseDays(commute.scheduleToOriginDays) },
                                set: { commute.scheduleToOriginDays = encodeDays($0) }
                            )
                        )

                        HStack {
                            Text("From")
                                .foregroundStyle(.secondary)
                            Picker("Start", selection: Binding(
                                get: { commute.scheduleToOriginStartHour ?? 15 },
                                set: { commute.scheduleToOriginStartHour = $0 }
                            )) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(formatHour(h)).tag(h)
                                }
                            }
                            .labelsHidden()

                            Text("to")
                                .foregroundStyle(.secondary)
                            Picker("End", selection: Binding(
                                get: { commute.scheduleToOriginEndHour ?? 19 },
                                set: { commute.scheduleToOriginEndHour = $0 }
                            )) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(formatHour(h)).tag(h)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Auto-Direction Schedule")
            } footer: {
                Text("When not near either endpoint, use these rules to pick direction automatically.")
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
        .onAppear {
            useSchedule = commute.scheduleToDestDays != nil || commute.scheduleToOriginDays != nil
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

    // MARK: - Schedule Helpers

    private func dayPicker(selectedDays: Binding<Set<Int>>) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(zip(Self.weekdayValues, Self.dayAbbreviations)), id: \.0) { weekday, abbr in
                Text(abbr)
                    .font(.caption.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(
                        selectedDays.wrappedValue.contains(weekday)
                            ? SteddiTheme.accent
                            : Color(.systemGray5)
                    )
                    .foregroundStyle(selectedDays.wrappedValue.contains(weekday) ? .white : .primary)
                    .clipShape(Circle())
                    .onTapGesture {
                        if selectedDays.wrappedValue.contains(weekday) {
                            selectedDays.wrappedValue.remove(weekday)
                        } else {
                            selectedDays.wrappedValue.insert(weekday)
                        }
                    }
            }
        }
    }

    private func parseDays(_ str: String?) -> Set<Int> {
        guard let str else { return [] }
        return Set(str.split(separator: ",").compactMap { Int($0) })
    }

    private func encodeDays(_ days: Set<Int>) -> String {
        days.sorted().map(String.init).joined(separator: ",")
    }

    private func formatHour(_ hour: Int) -> String {
        if hour == 0 { return "12 AM" }
        if hour < 12 { return "\(hour) AM" }
        if hour == 12 { return "12 PM" }
        return "\(hour - 12) PM"
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

                    if offlineCacheService.downloadedRouteIDs.contains(route.id) {
                        Text("Offline")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(SteddiTheme.accent.opacity(0.6), in: Capsule())
                    }

                    if let duration = route.typicalDurationSeconds {
                        Text("\(Int(duration / 60)) min typical")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if downloadingRouteIDs.contains(route.id) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    toggleDownload(route)
                } label: {
                    let isDownloaded = offlineCacheService.downloadedRouteIDs.contains(route.id)
                    Image(systemName: isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(isDownloaded ? SteddiTheme.accent : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggleDownload(_ route: Route) {
        if offlineCacheService.downloadedRouteIDs.contains(route.id) {
            offlineCacheService.deleteDownloadedRoute(route)
        } else {
            downloadingRouteIDs.insert(route.id)
            Task {
                do {
                    try offlineCacheService.downloadRoute(route)
                } catch {
                    // Download failed silently; the button stays hollow
                }
                downloadingRouteIDs.remove(route.id)
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
