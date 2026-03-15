import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<NoGoZone> { $0.isGlobal }) private var globalNoGoZones: [NoGoZone]

    // Use the same keys and decimal format as AppSettings
    @AppStorage("steddi.defaultThresholdPercentage") private var thresholdPercentage: Double = 0.20
    @AppStorage("steddi.defaultHardMinuteFloor") private var hardMinuteFloor: Int = 10
    @AppStorage("steddi.voiceGuidanceEnabled") private var voiceGuidanceEnabled: Bool = true
    @AppStorage("steddi.units") private var units: String = MeasurementUnit.miles.rawValue

    @State private var showNoGoEditor = false
    @State private var showThresholdExplainer = false
    @State private var showDonation = false

    private var useMiles: Binding<Bool> {
        Binding(
            get: { units == MeasurementUnit.miles.rawValue },
            set: { units = $0 ? MeasurementUnit.miles.rawValue : MeasurementUnit.kilometers.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Navigation Defaults
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Reroute threshold")
                            Spacer()
                            Text("\(Int(thresholdPercentage * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $thresholdPercentage, in: 0.05...0.50, step: 0.05)
                            .tint(SteddiTheme.accent)
                    }

                    Stepper("Hard floor: \(hardMinuteFloor) min", value: $hardMinuteFloor, in: 2...30)

                    Button {
                        showThresholdExplainer = true
                    } label: {
                        Label("How thresholds work", systemImage: "questionmark.circle")
                            .font(.subheadline)
                    }

                    Toggle("Voice guidance", isOn: $voiceGuidanceEnabled)
                } header: {
                    Text("Navigation Defaults")
                }

                // MARK: - Commutes
                Section {
                    NavigationLink {
                        CommuteListView()
                    } label: {
                        Label("Manage Commutes", systemImage: "arrow.triangle.swap")
                    }
                } header: {
                    Text("Commutes")
                }

                // MARK: - No-Go Zones
                Section {
                    ForEach(globalNoGoZones) { zone in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(zone.name ?? "Unnamed zone")
                                    .font(.body)
                                Text("\(Int(zone.radiusMeters))m radius")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .onDelete(perform: deleteNoGoZones)

                    Button {
                        showNoGoEditor = true
                    } label: {
                        Label("Add no-go zone", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Global No-Go Zones")
                } footer: {
                    Text("Routes will avoid these areas unless a specific route overrides them.")
                }

                // MARK: - Units
                Section {
                    Picker("Distance units", selection: useMiles) {
                        Text("Miles").tag(true)
                        Text("Kilometers").tag(false)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Units")
                }

                // MARK: - About
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        showDonation = true
                    } label: {
                        Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showNoGoEditor) {
                NoGoZoneEditorView()
            }
            .sheet(isPresented: $showThresholdExplainer) {
                ThresholdExplainerView(
                    thresholdPercentage: thresholdPercentage,
                    hardMinuteFloor: hardMinuteFloor
                )
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showDonation) {
                DonationView()
            }
        }
    }

    private func deleteNoGoZones(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(globalNoGoZones[index])
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: NoGoZone.self, inMemory: true)
}
