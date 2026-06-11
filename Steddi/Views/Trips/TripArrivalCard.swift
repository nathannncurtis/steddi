import SwiftUI

/// Brief arrival moment during continuous-mode trip navigation — floats over
/// the nav overlay for ~3 seconds while the next leg queues up. Tapping it
/// takes manual control (opens the next-leg prompt for a quick stop). With no
/// next stop it reads as the trip-complete card.
struct TripArrivalCard: View {
    let stopName: String
    /// Next leg destination; nil = that was the final stop.
    let nextStopName: String?
    let onTap: () -> Void

    private var isComplete: Bool { nextStopName == nil }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: isComplete ? "flag.checkered" : "checkmark.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(SteddiTheme.sage)

                VStack(alignment: .leading, spacing: 3) {
                    Text(isComplete ? "Trip complete" : "Arrived at \(stopName)")
                        .font(SteddiTheme.heading(16))
                        .foregroundStyle(SteddiTheme.textPrimary)

                    if let nextStopName {
                        Text("Next: \(nextStopName)")
                            .font(SteddiTheme.body(13))
                            .foregroundStyle(SteddiTheme.textSecondary)
                    } else {
                        Text("Arrived at \(stopName)")
                            .font(SteddiTheme.body(13))
                            .foregroundStyle(SteddiTheme.textSecondary)
                    }
                }

                Spacer(minLength: 0)

                if !isComplete {
                    // Hints that tapping pauses the auto-advance
                    Image(systemName: "hand.tap.fill")
                        .font(.body)
                        .foregroundStyle(SteddiTheme.textMuted)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                            .fill(SteddiTheme.surfacePrimary.opacity(0.88))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                            .stroke(SteddiTheme.sage.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}
