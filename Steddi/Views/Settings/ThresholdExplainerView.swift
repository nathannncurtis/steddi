import SwiftUI

struct ThresholdExplainerView: View {
    /// Decimal percentage (e.g. 0.20 = 20%)
    let thresholdPercentage: Double
    let hardMinuteFloor: Int

    @Environment(\.dismiss) private var dismiss
    @AppStorage("accentColor") private var accentColor = "lavender"
    @AppStorage(ThemeModeEx.defaultsKey) private var themeModeEx: String = ThemeModeEx.dynamic.rawValue

    /// A presented sheet gets its own presentation context and does not reliably
    /// inherit the presenter's `.preferredColorScheme`, so pin the app theme here
    /// too — otherwise this sheet renders in the device appearance and mismatches
    /// the rest of Steddi when the chosen theme differs from the device.
    private var resolvedColorScheme: ColorScheme? {
        (ThemeModeEx(rawValue: themeModeEx) ?? .dynamic).colorScheme
    }

    /// Display percentage as whole number
    private var displayPercentage: Int { Int(thresholdPercentage * 100) }

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.largeTitle)
                            .foregroundStyle(SteddiTheme.accent)

                        Text("How reroute thresholds work")
                            .font(.title2.weight(.bold))

                        Text("Steddi only suggests a new route when it saves enough time to matter. No nagging over 1-minute differences.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    // Example scenario
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Example")
                            .font(.headline)

                        exampleCard(
                            remaining: 30,
                            savings: exampleSavings(remainingMinutes: 30),
                            wouldNotify: wouldNotify(remainingMinutes: 30, savingsMinutes: exampleSavings(remainingMinutes: 30))
                        )

                        exampleCard(
                            remaining: 15,
                            savings: exampleSavings(remainingMinutes: 15),
                            wouldNotify: wouldNotify(remainingMinutes: 15, savingsMinutes: exampleSavings(remainingMinutes: 15))
                        )

                        exampleCard(
                            remaining: 45,
                            savings: 3,
                            wouldNotify: wouldNotify(remainingMinutes: 45, savingsMinutes: 3)
                        )
                    }

                    Divider()

                    // Current settings summary
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your current settings")
                            .font(.headline)

                        HStack {
                            Label("Threshold", systemImage: "percent")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(displayPercentage)%")
                                .fontWeight(.semibold)
                        }

                        HStack {
                            Label("Hard floor", systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(hardMinuteFloor) min")
                                .fontWeight(.semibold)
                        }

                        Text("A reroute must save at least \(displayPercentage)% of your remaining time. For long drives, it must also save at least \(hardMinuteFloor) minutes.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(resolvedColorScheme)
    }

    private func exampleCard(remaining: Int, savings: Int, wouldNotify: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(remaining) min remaining")
                    .font(.subheadline.weight(.medium))
                Text("Faster route saves \(savings) min (\(remaining > 0 ? Int(Double(savings) / Double(remaining) * 100) : 0)%)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: wouldNotify ? "bell.fill" : "bell.slash")
                .foregroundStyle(wouldNotify ? SteddiTheme.accent : .secondary)
                .font(.title3)
        }
        .padding(12)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func exampleSavings(remainingMinutes: Int) -> Int {
        max(1, Int(Double(remainingMinutes) * thresholdPercentage))
    }

    private func wouldNotify(remainingMinutes: Int, savingsMinutes: Int) -> Bool {
        guard remainingMinutes > 0 else { return false }
        let percentSaved = Double(savingsMinutes) / Double(remainingMinutes)
        return percentSaved >= thresholdPercentage && savingsMinutes >= hardMinuteFloor
    }
}

#Preview {
    ThresholdExplainerView(thresholdPercentage: 0.20, hardMinuteFloor: 10)
}
