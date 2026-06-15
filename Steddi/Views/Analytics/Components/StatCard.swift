import SwiftUI

/// Reusable value/unit/label stat card for analytics surfaces.
struct StatCard: View {
    let value: String
    let label: String
    var unit: String? = nil
    var icon: String? = nil
    var tint: Color = SteddiTheme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SteddiTheme.accent)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(SteddiTheme.mono(12))
                        .foregroundStyle(SteddiTheme.textSecondary)
                }
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SteddiTheme.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                .fill(SteddiTheme.surfaceSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                        .stroke(SteddiTheme.accent.opacity(0.08), lineWidth: 1)
                )
        }
    }
}

// MARK: - Shared Formatting

/// Formatting helpers shared across analytics views.
enum AnalyticsFormat {

    /// "42 min" below an hour, "1h 12m" above.
    static func duration(seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        }
        return "\(totalMinutes / 60)h \(String(format: "%02d", totalMinutes % 60))m"
    }

    /// Compact minutes value without unit, e.g. "42".
    static func minutesValue(seconds: Double) -> String {
        "\(Int((seconds / 60).rounded()))"
    }

    /// Hours with one decimal, e.g. "3.5".
    static func hoursValue(seconds: Double) -> String {
        String(format: "%.1f", seconds / 3600)
    }

    /// Speed in the user's units (mph or km/h), rounded.
    static func speedValue(mps: Double, unit: MeasurementUnit) -> String {
        switch unit {
        case .miles: return "\(Int((mps * 2.23694).rounded()))"
        case .kilometers: return "\(Int((mps * 3.6).rounded()))"
        }
    }

    static func speedUnit(_ unit: MeasurementUnit) -> String {
        switch unit {
        case .miles: return "mph"
        case .kilometers: return "km/h"
        }
    }
}

#Preview {
    ZStack {
        SteddiTheme.surfacePrimary.ignoresSafeArea()
        HStack(spacing: 12) {
            StatCard(value: "42", label: "Duration", unit: "min", icon: "clock")
            StatCard(value: "8", label: "In traffic", unit: "min", icon: "car.rear.waves.up", tint: SteddiTheme.warmRedText)
        }
        .padding()
    }
}
