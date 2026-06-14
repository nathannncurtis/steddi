import SwiftUI

/// Compact badge describing a no-go zone and, optionally, how a route violates
/// it. Drop into route previews or navigation banners. Violated zones tint red.
struct ZoneBadgeView: View {
    let zone: NoGoZone
    let violationType: ViolationType?

    init(zone: NoGoZone, violationType: ViolationType? = nil) {
        self.zone = zone
        self.violationType = violationType
    }

    private var isViolated: Bool { violationType != nil }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: zoneIcon)
                .font(.caption2)
                .foregroundStyle(isViolated ? SteddiTheme.warmRed : SteddiTheme.textSecondary)
            Text(zone.name ?? "No-go zone")
                .font(SteddiTheme.body(12))
                .foregroundStyle(SteddiTheme.textPrimary)
                .lineLimit(1)
            if isViolated {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(SteddiTheme.warmRed)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isViolated ? SteddiTheme.warmRed.opacity(0.12) : SteddiTheme.surfaceElevated)
        )
    }

    private var zoneIcon: String {
        switch zone.geometry {
        case .circle: return "location.circle.fill"
        case .corridor: return "road.lanes"
        case .polygon: return "pentagon.fill"
        }
    }
}
