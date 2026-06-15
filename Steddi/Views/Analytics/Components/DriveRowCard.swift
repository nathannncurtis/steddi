import SwiftUI

/// One drive in the analytics list: name, date, duration, and a traffic
/// chip when meaningful. Reads only cached summary fields — tapping it is
/// what triggers the (lazy) GPS decode in DriveDetailView.
struct DriveRowCard: View {
    let record: DriveRecord

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.associatedCommute?.name ?? "Drive")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(SteddiTheme.textPrimary)
                Text(record.startedAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 12))
                    .foregroundStyle(SteddiTheme.textSecondary)
            }

            Spacer(minLength: 8)

            if let traffic = record.trafficDurationSeconds, traffic >= 60 {
                trafficChip(seconds: traffic)
            }

            if let duration = record.totalDurationSeconds {
                Text(AnalyticsFormat.duration(seconds: duration))
                    .font(SteddiTheme.mono(15))
                    .foregroundStyle(SteddiTheme.textPrimary)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                // Tappable affordance — promote to textSecondary under high
                // contrast so it clears the 3:1 non-text floor on near-black.
                .foregroundStyle(SteddiTheme.textMuted(highContrast: DisplayModeService.shared.useHighContrast))
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                .fill(SteddiTheme.surfaceSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                        .stroke(SteddiTheme.accent.opacity(0.08), lineWidth: 1)
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: SteddiTheme.radiusCard))
    }

    private func trafficChip(seconds: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "car.rear.waves.up")
                .font(.system(size: 9, weight: .semibold))
            Text("\(AnalyticsFormat.minutesValue(seconds: seconds))m")
                .font(SteddiTheme.mono(11))
        }
        .foregroundStyle(SteddiTheme.warmRed)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(SteddiTheme.warmRedSubtle))
    }
}
