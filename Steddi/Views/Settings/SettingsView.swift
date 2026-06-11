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
    @AppStorage("steddi.defaultAvoidsTolls") private var avoidsTolls: Bool = false
    @AppStorage("steddi.defaultAvoidsHighways") private var avoidsHighways: Bool = false
    @AppStorage("steddi.hapticLevel") private var hapticLevel: String = HapticLevel.dynamic.rawValue
    @AppStorage("accentColor") private var accentColor: String = SteddiTheme.AccentOption.lavender.rawValue
    @AppStorage(ThemeModeEx.defaultsKey) private var themeModeEx: String = ThemeModeEx.dynamic.rawValue
    @State private var dynamicComponents = DynamicThemeComponents.load()
    @AppStorage("steddi.passengerMode") private var passengerMode: Bool = false
    @AppStorage("steddi.accessibilityMode") private var accessibilityMode: Bool = false

    @State private var showNoGoEditor = false
    @State private var showThresholdExplainer = false
    @State private var showDonation = false
    @State private var showDeleteAllConfirmation = false

    private static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var useMiles: Binding<Bool> {
        Binding(
            get: { units == MeasurementUnit.miles.rawValue },
            set: { units = $0 ? MeasurementUnit.miles.rawValue : MeasurementUnit.kilometers.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Appearance
                Section {
                    HStack(spacing: 12) {
                        Spacer()
                        ForEach(SteddiTheme.AccentOption.allCases, id: \.self) { option in
                            let isSelected = accentColor == option.rawValue
                            Button {
                                accentColor = option.rawValue
                                NotificationCenter.default.post(name: .steddiAccentColorChanged, object: nil)
                            } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .overlay {
                                        if isSelected {
                                            Circle()
                                                .stroke(option.color, lineWidth: 3)
                                                .frame(width: 44, height: 44)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.displayName)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Theme")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker("Theme", selection: $themeModeEx) {
                            ForEach(ThemeModeEx.allCases, id: \.rawValue) { mode in
                                Text(mode.displayName).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .onChange(of: themeModeEx) {
                        // The engine persists the mode, keeps the legacy
                        // "themeMode" shadow in sync for map surfaces, and
                        // posts .steddiThemeModeChanged itself.
                        ThemeEngine.shared.baseMode = ThemeModeEx(rawValue: themeModeEx) ?? .dynamic
                    }

                    if themeModeEx == ThemeModeEx.dynamic.rawValue {
                        Toggle("Solar cycle", isOn: $dynamicComponents.solarCycle)
                        Toggle("Weather response", isOn: $dynamicComponents.weatherResponse)
                        Toggle("Temperature tinting", isOn: $dynamicComponents.temperatureTinting)
                        Toggle("Tunnel detection", isOn: $dynamicComponents.tunnelDetection)
                        Toggle("Grey mode", isOn: $dynamicComponents.greyMode)
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    if themeModeEx == ThemeModeEx.dynamic.rawValue {
                        Text("Dynamic theming shifts colors with sunrise and sunset, weather, temperature, and tunnels. Grey mode blends through a neutral grey between dark and light.")
                    }
                }
                .onChange(of: dynamicComponents) {
                    ThemeEngine.shared.dynamicComponents = dynamicComponents
                }

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

                    if voiceGuidanceEnabled {
                        VoicePicker()
                    }

                    Toggle("Avoid tolls", isOn: $avoidsTolls)
                    Toggle("Avoid highways", isOn: $avoidsHighways)

                    Picker("Haptic feedback", selection: $hapticLevel) {
                        ForEach(HapticLevel.allCases) { level in
                            Text(level.displayName).tag(level.rawValue)
                        }
                    }

                    if hapticLevel == HapticLevel.advanced.rawValue {
                        NavigationLink {
                            AdvancedHapticsView()
                        } label: {
                            Label("Fine-tune haptics", systemImage: "slider.horizontal.3")
                        }
                    }
                } header: {
                    Text("Navigation Defaults")
                }

                // MARK: - Display Modes
                Section {
                    Toggle("Passenger mode", isOn: $passengerMode)
                    Toggle("Accessibility mode", isOn: $accessibilityMode)
                } header: {
                    Text("Display")
                } footer: {
                    Text("Passenger mode enlarges text and simplifies controls. Accessibility mode adds high contrast and larger icons. Both can be active together.")
                }

                // MARK: - Commutes
                Section {
                    NavigationLink {
                        CommuteListView()
                    } label: {
                        Label("Manage Commutes", systemImage: "arrow.triangle.swap")
                    }
                    NavigationLink {
                        CommuteAnalyticsView()
                    } label: {
                        Label("Commute Analytics", systemImage: "chart.bar.fill")
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
                        Text(Self.appVersion)
                            .foregroundStyle(SteddiTheme.textSecondary)
                            .font(SteddiTheme.mono(14))
                    }

                    Button {
                        showDonation = true
                    } label: {
                        Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                    }
                } header: {
                    Text("About")
                }

                // MARK: - Danger Zone
                Section {
                    Button(role: .destructive) {
                        showDeleteAllConfirmation = true
                    } label: {
                        Label("Delete All Data", systemImage: "trash.fill")
                            .foregroundStyle(SteddiTheme.warmRed)
                    }
                } header: {
                    Text("Danger Zone")
                } footer: {
                    Text("Permanently removes all commutes, routes, pinned locations, drive records, no-go zones, and commute trips.")
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
            .confirmationDialog(
                "Delete All Data",
                isPresented: $showDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    deleteAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all commutes, routes, pinned locations, drive records, no-go zones, and commute trips. This action cannot be undone.")
            }
            .preferredColorScheme(resolvedColorScheme)
        }
    }

    private var resolvedColorScheme: ColorScheme? {
        (ThemeModeEx(rawValue: themeModeEx) ?? .dynamic).colorScheme
    }

    private func deleteNoGoZones(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(globalNoGoZones[index])
        }
    }

    private func deleteAllData() {
        do {
            try modelContext.delete(model: PinnedLocation.self)
            try modelContext.delete(model: Commute.self)
            try modelContext.delete(model: Route.self)
            try modelContext.delete(model: DriveRecord.self)
            try modelContext.delete(model: NoGoZone.self)
            try modelContext.delete(model: CommuteTrip.self)
        } catch {
            print("Failed to delete all data: \(error)")
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: NoGoZone.self, inMemory: true)
}
