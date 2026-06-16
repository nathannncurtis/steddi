import SwiftUI

/// Glanceable nav-overlay indicator that a route preference is actively
/// shaping the live route ("Avoiding tolls" / "Avoiding highways"). Rendered
/// only when a preference is active, so the driver knows a choice — global or
/// per-commute — reshaped where they're being sent.
///
/// Deliberately quiet: a small capsule in the nav surface idiom, sized off the
/// display-mode scales and dimmed under high contrast like the other banners.
/// Type is unit-prefixed to avoid cross-pillar name collisions.
struct SteddiRoutePrefBadge: View {
    /// One per active avoidance, tolls first (see `RoutePreferences.activeLabels`).
    let labels: [String]
    var textScale: Double = 1
    var iconScale: Double = 1
    var highContrast: Bool = false

    var body: some View {
        if !labels.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    if index > 0 {
                        Circle()
                            .fill(SteddiTheme.textMuted(highContrast: highContrast))
                            .frame(width: 3, height: 3)
                    }
                    pill(label)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private func pill(_ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 11 * iconScale, weight: .semibold))
                .foregroundStyle(SteddiTheme.accent)
            Text(label)
                .font(SteddiTheme.body(12 * textScale, highContrast: highContrast))
                .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                .lineLimit(1)
        }
        // This badge rides translucent nav glass over the moving map like every
        // sibling readout — the soft per-glyph shadow keeps the icon + label off
        // the tiles (textSecondary's AA is only proven on solid surfaces).
        .legibleOverMap()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Match the street-name capsule's over-map hardening: a faint scrim under
        // the glass so the readout holds against bright/varied cartography, then
        // the centralized glass surface (Reduce Transparency / high contrast goes
        // opaque like the rest of the nav chrome). The accent hairline — the
        // badge's "preference active" identity — stays as an overlay on top.
        .mapGlassScrim(in: Capsule())
        .steddiGlass(tint: nil, interactive: false, in: Capsule(), fallbackStrokeOpacity: 0.25)
        .overlay(
            Capsule()
                .stroke(SteddiTheme.accent.opacity(SteddiTheme.navStrokeOpacity(0.18, highContrast: highContrast)), lineWidth: 1)
        )
    }

    /// Spoken as a single phrase so VoiceOver doesn't read each pill separately.
    private var accessibilityLabel: String {
        "Route preference active. " + labels.joined(separator: ", ")
    }
}
