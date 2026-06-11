import SwiftUI

/// Card for one trip on the home sheet's Trips tab — mirrors the commute
/// card: name header, next-stop row with distance, and a progress badge.
/// Tap begins navigation (or resumes mid-trip); context menu manages the trip.
struct TripCardView: View {
    let trip: Trip
    /// Formatted distance from the current location to the next stop.
    let distanceToNextStop: String?
    let onTap: () -> Void
    var onEdit: () -> Void = {}
    var onArchive: () -> Void = {}
    var onDelete: () -> Void = {}

    private var totalStops: Int { trip.orderedStops.count }

    /// "2/5 stops" while in progress, "5 stops" before starting.
    private var progressBadge: String {
        if trip.isInProgress {
            return "\(trip.currentStopIndex + 1)/\(totalStops) stops"
        }
        return "\(totalStops) stop\(totalStops == 1 ? "" : "s")"
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                // Trip name header + progress badge
                HStack(spacing: 8) {
                    Text(trip.name)
                        .font(SteddiTheme.heading(15))
                        .foregroundStyle(SteddiTheme.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    Text(progressBadge)
                        .font(SteddiTheme.mono(11))
                        .foregroundStyle(trip.isInProgress ? SteddiTheme.accent : SteddiTheme.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (trip.isInProgress ? SteddiTheme.accentSubtle : SteddiTheme.surfaceElevated.opacity(0.6)),
                            in: Capsule()
                        )

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SteddiTheme.textMuted)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

                // Next stop row
                if let nextStop = trip.currentStop {
                    HStack(spacing: 6) {
                        Image(systemName: trip.isInProgress ? "location.fill" : "arrow.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(SteddiTheme.accent)

                        Text(trip.isInProgress ? "Resume to \(nextStop.name)" : nextStop.name)
                            .font(SteddiTheme.body(13))
                            .foregroundStyle(SteddiTheme.textSecondary)
                            .lineLimit(1)

                        Spacer()

                        if let distanceToNextStop {
                            Text(distanceToNextStop)
                                .font(SteddiTheme.mono(13))
                                .foregroundStyle(SteddiTheme.sage)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 3)
                    .padding(.bottom, 10)
                } else {
                    Spacer().frame(height: 10)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                    .fill(SteddiTheme.surfaceSecondary.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                            .stroke(
                                trip.isInProgress
                                    ? SteddiTheme.accent.opacity(0.25)
                                    : SteddiTheme.accent.opacity(0.06),
                                lineWidth: 1
                            )
                    )
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { onEdit() } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button { onArchive() } label: {
                Label("Archive", systemImage: "archivebox")
            }
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
