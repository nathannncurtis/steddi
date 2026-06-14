import SwiftUI
import UserNotifications

/// Settings section for smart commute notifications: global enable, weather
/// sensitivity, WeatherKit budget display, and the thoughtful permission entry
/// point (we ask here — never at launch).
struct CommuteNotificationsSettingsView: View {
    @AppStorage(CommuteNotificationService.globalEnabledKey) private var globalEnabled = true
    @AppStorage(CommuteNotificationService.weatherSensitivityKey) private var sensitivityRaw = WeatherSensitivity.harsh.rawValue

    /// Budget read straight from a weather service instance (UserDefaults-backed).
    @State private var weatherService = CommuteWeatherService()
    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var showPermissionExplainer = false

    /// Optional orchestrator from the environment — when present we drive the
    /// real permission request and reschedule. When absent (e.g. previews) we
    /// degrade to status display + a bare permission request.
    @Environment(CommuteNotificationService.self) private var service: CommuteNotificationService?

    private var sensitivity: Binding<WeatherSensitivity> {
        Binding(
            get: { WeatherSensitivity(rawValue: sensitivityRaw) ?? .harsh },
            set: { sensitivityRaw = $0.rawValue }
        )
    }

    var body: some View {
        Section {
            switch authStatus {
            case .denied:
                permissionDeniedRow
            case .notDetermined:
                enablePermissionRow
            default:
                Toggle("Commute alerts", isOn: $globalEnabled)
                    .onChange(of: globalEnabled) { _, _ in
                        service?.scheduleBackgroundRefresh()
                    }

                if globalEnabled {
                    Picker("Weather sensitivity", selection: sensitivity) {
                        ForEach(WeatherSensitivity.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }

                    weatherBudgetRow
                }
            }
        } header: {
            Text("Commute Notifications")
        } footer: {
            Text("Alerts you to leave early when traffic builds or harsh weather is on the way. All processing happens on your device.")
        }
        .task {
            await refreshStatus()
        }
        .sheet(isPresented: $showPermissionExplainer) {
            permissionExplainerSheet
        }
    }

    // MARK: - Rows

    private var enablePermissionRow: some View {
        Button {
            showPermissionExplainer = true
        } label: {
            Label("Turn on commute alerts", systemImage: "bell.badge")
                .foregroundStyle(SteddiTheme.accent)
        }
    }

    private var permissionDeniedRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Notifications disabled", systemImage: "bell.slash")
                .font(.body.weight(.medium))
                .foregroundStyle(SteddiTheme.warmRed)
            Text("Enable notifications for Steddi in the Settings app to get commute alerts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.subheadline)
            .padding(.top, 2)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var weatherBudgetRow: some View {
        let used = weatherService.budgetUsedFraction
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Weather data budget")
                    .font(.subheadline)
                Spacer()
                Text("\(Int((1 - used) * 100))% left")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: min(max(used, 0), 1))
                .tint(used > 0.9 ? SteddiTheme.warmRed : SteddiTheme.accent)
            if !weatherService.hasBudget {
                Text("Monthly weather limit reached — alerts use traffic only until next month.")
                    .font(.caption)
                    .foregroundStyle(SteddiTheme.warmRed)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Permission Explainer

    private var permissionExplainerSheet: some View {
        VStack(spacing: 20) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 48))
                .foregroundStyle(SteddiTheme.accent)
                .padding(.top, 40)

            Text("Stay ahead of your commute")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            Text("Steddi can alert you to leave a few minutes early when traffic builds up or rough weather is on the way. Everything runs on your device — nothing leaves your phone.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer()

            Button {
                Task {
                    if let service {
                        _ = await service.requestAuthorization()
                    } else {
                        _ = try? await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound, .badge])
                    }
                    await refreshStatus()
                    showPermissionExplainer = false
                }
            } label: {
                Text("Enable Notifications")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(SteddiTheme.accent, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)

            Button("Not now") {
                showPermissionExplainer = false
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.bottom, 32)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Helpers

    private func refreshStatus() async {
        if let service {
            await service.refreshAuthorizationStatus()
            authStatus = service.authorizationStatus
        } else {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            authStatus = settings.authorizationStatus
        }
    }
}
