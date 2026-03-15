import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<NoGoZone> { $0.isGlobal }) private var globalNoGoZones: [NoGoZone]

    @AppStorage("thresholdPercentage") private var thresholdPercentage: Double = 20
    @AppStorage("hardMinuteFloor") private var hardMinuteFloor: Int = 10
    @AppStorage("voiceGuidanceEnabled") private var voiceGuidanceEnabled: Bool = true
    @AppStorage("useMiles") private var useMiles: Bool = true

    @State private var showNoGoEditor = false
    @State private var showThresholdExplainer = false
    @State private var showDonation = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Navigation Defaults
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Reroute threshold")
                            Spacer()
                            Text("\(Int(thresholdPercentage))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $thresholdPercentage, in: 5...50, step: 5)
                            .tint(.blue)
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
                    Picker("Distance units", selection: $useMiles) {
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
