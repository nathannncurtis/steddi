import SwiftUI

/// Window-level stat card grid: drive count, average, total time, traffic
/// time, and a typical-vs-slow-day split (median / p90).
struct AggregateStatsCards: View {
    let stats: AggregateStats

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                StatCard(value: "\(stats.driveCount)", label: "Drives", icon: "car.fill")
                StatCard(
                    value: AnalyticsFormat.minutesValue(seconds: stats.averageDurationSeconds),
                    label: "Avg drive", unit: "min", icon: "clock"
                )
                StatCard(
                    value: AnalyticsFormat.hoursValue(seconds: stats.totalDrivingSeconds),
                    label: "Time driving", unit: "hrs", icon: "steeringwheel"
                )
                StatCard(
                    value: AnalyticsFormat.hoursValue(seconds: stats.totalTrafficSeconds),
                    label: "In traffic", unit: "hrs", icon: "car.rear.waves.up",
                    tint: stats.totalTrafficSeconds > 0 ? SteddiTheme.warmRedText : SteddiTheme.sageText
                )
            }

            // Median vs p90 only means something once there's a spread of
            // drives to take percentiles over.
            if stats.driveCount >= 5 {
                splitRow
            }
        }
    }

    /// "Typical drive" (median) vs "slow day" (p90) split.
    private var splitRow: some View {
        HStack(spacing: 0) {
            splitCell(
                value: AnalyticsFormat.duration(seconds: stats.medianDurationSeconds),
                label: "Typical drive",
                tint: SteddiTheme.sageText
            )
            Rectangle()
                .fill(SteddiTheme.textMuted.opacity(0.2))
                .frame(width: 1, height: 36)
            splitCell(
                value: AnalyticsFormat.duration(seconds: stats.p90DurationSeconds),
                label: "Slow day (90th)",
                tint: SteddiTheme.warmRedText
            )
        }
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                .fill(SteddiTheme.surfaceSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                        .stroke(SteddiTheme.accent.opacity(0.08), lineWidth: 1)
                )
        }
    }

    private func splitCell(value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(SteddiTheme.mono(17))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SteddiTheme.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    ZStack {
        SteddiTheme.surfacePrimary.ignoresSafeArea()
        AggregateStatsCards(stats: AggregateStats(
            driveCount: 24,
            totalDrivingSeconds: 24 * 32 * 60,
            totalTrafficSeconds: 24 * 7 * 60,
            averageDurationSeconds: 32 * 60,
            medianDurationSeconds: 30 * 60,
            p90DurationSeconds: 44 * 60,
            weekdayAverages: []
        ))
        .padding()
    }
}
