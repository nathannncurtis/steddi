import SwiftUI

struct ThresholdExplainerView: View {
    let thresholdPercentage: Double
    let hardMinuteFloor: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.largeTitle)
                            .foregroundStyle(.blue)

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
                            Text("\(Int(thresholdPercentage))%")
                                .fontWeight(.semibold)
                        }

                        HStack {
                            Label("Hard floor", systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(hardMinuteFloor) min")
                                .fontWeight(.semibold)
                        }

                        Text("A reroute must save at least \(Int(thresholdPercentage))% of your remaining time AND at least \(hardMinuteFloor) minutes before Steddi will suggest it.")
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
    }

    private func exampleCard(remaining: Int, savings: Int, wouldNotify: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(remaining) min remaining")
                    .font(.subheadline.weight(.medium))
                Text("Faster route saves \(savings) min (\(Int(Double(savings) / Double(remaining) * 100))%)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: wouldNotify ? "bell.fill" : "bell.slash")
                .foregroundStyle(wouldNotify ? .blue : .secondary)
                .font(.title3)
        }
        .padding(12)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func exampleSavings(remainingMinutes: Int) -> Int {
        max(1, Int(Double(remainingMinutes) * thresholdPercentage / 100))
    }

    private func wouldNotify(remainingMinutes: Int, savingsMinutes: Int) -> Bool {
        let percentSaved = Double(savingsMinutes) / Double(remainingMinutes) * 100
        return percentSaved >= thresholdPercentage && savingsMinutes >= hardMinuteFloor
    }
}

#Preview {
    ThresholdExplainerView(thresholdPercentage: 20, hardMinuteFloor: 10)
}
