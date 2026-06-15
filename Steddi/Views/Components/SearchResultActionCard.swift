import SwiftUI
import CoreLocation

/// Action card surfaced when a search result is tapped. Shows the place
/// preview (name, address, distance) and three actions: Navigate (go now),
/// Save Place (pin it with a category/icon), Cancel (dismiss). Appears inline
/// below the search input so the search context stays visible.
struct SearchResultActionCard: View {
    let name: String
    let address: String
    /// Pre-formatted distance string (e.g. "1.2 mi"); nil hides the chip.
    let distanceText: String?
    let onNavigate: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Place preview
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .font(.title2)
                    .foregroundStyle(SteddiTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(SteddiTheme.accentSubtle, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(SteddiTheme.heading(16))
                        .foregroundStyle(SteddiTheme.textPrimary)
                        .lineLimit(1)

                    if !address.isEmpty && address != name {
                        Text(address)
                            .font(SteddiTheme.body(13))
                            .foregroundStyle(SteddiTheme.textSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 4)

                if let distanceText {
                    Text(distanceText)
                        .font(SteddiTheme.mono(13))
                        // Surface-adaptive legible green — raw sage as 13pt text
                        // on the near-white card fails AA in light/dynamic-day.
                        .foregroundStyle(SteddiTheme.sageText)
                }
            }

            // Actions
            HStack(spacing: 10) {
                Button(action: onNavigate) {
                    Label("Navigate", systemImage: "location.fill")
                        .font(SteddiTheme.heading(14))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.steddiPrimary)

                Button(action: onSave) {
                    Label("Save Place", systemImage: "bookmark.fill")
                        .font(SteddiTheme.heading(14))
                        .foregroundStyle(SteddiTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(SteddiTheme.accentSubtle, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Button(action: onCancel) {
                Text("Cancel")
                    .font(SteddiTheme.body(14))
                    .foregroundStyle(SteddiTheme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                .fill(SteddiTheme.surfacePrimary.opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                        .stroke(SteddiTheme.accent.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 14, y: 5)
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        SearchResultActionCard(
            name: "Blue Bottle Coffee",
            address: "300 Webster St, Oakland, CA",
            distanceText: "1.2 mi",
            onNavigate: {},
            onSave: {},
            onCancel: {}
        )
        .padding(.horizontal, 16)
    }
}
