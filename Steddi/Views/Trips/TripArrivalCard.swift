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

    /// Dependency-only: touching this re-resolves `glassAvailable` (and therefore
    /// every contrast-adaptive foreground) when Reduce Transparency / Increase
    /// Contrast toggles, exactly like `steddiGlass` / `mapGlassScrim`.
    @Environment(\.glassRevision) private var glassRevision

    /// Same display-mode source as the nav HUD / reroute card so this over-map
    /// card grows (textScale) and thickens/promotes (highContrast) in
    /// accessibility / passenger mode alongside the rest of the floating chrome.
    private var textScale: Double { DisplayModeService.shared.textScale }
    private var highContrast: Bool { DisplayModeService.shared.useHighContrast }

    /// Whether Liquid Glass renders for the card (vs. the solid fallback). Read
    /// imperatively — the `glassRevision` dependency above keeps it re-resolving on
    /// a Reduce-Transparency / Increase-Contrast toggle so the foreground and the
    /// actual card surface can never disagree.
    private var glassAvailable: Bool {
        _ = glassRevision
        return SteddiGlass.isAvailable
    }

    /// AA-correct foreground for the subtitle + status glyph, contrasted against
    /// the ACTUAL sage-tinted card surface — not the surface-token
    /// `textSecondary`/raw `sage`, which were sized against `surfacePrimary` and
    /// wash out on the sage tint in LIGHT theme. The card's surface composition
    /// (sage-tinted `.regular` glass + the over-map `mapGlassScrim`) is identical
    /// to the speed-camera banner's, so `cameraBannerForeground(kind: sageRGB)`
    /// is the matching token: near-black on the light sage tint (LIGHT theme),
    /// near-white on the dark scrim-over-sage composite (DARK theme), the solid
    /// fallback when glass is off — ≥4.5:1 in both themes, mirroring the reroute
    /// card / camera banner fix the heading's `legibleOverMap` shadow only assists.
    private var onSage: Color {
        SteddiTheme.cameraBannerForeground(kind: SteddiTheme.sageRGB, glassAvailable: glassAvailable)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: isComplete ? "flag.checkered" : "checkmark.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    // Contrast-adaptive against the ACTUAL sage-tinted surface, not
                    // raw `sage` — a mid-tone green that composites ~1.5-1.9:1 on its
                    // own light sage tint in LIGHT theme (same washout the reroute
                    // card / camera banner hardened). `onSage` resolves near-black on
                    // the light tint and near-white on the dark composite.
                    .foregroundStyle(onSage)
                    .legibleOverMap()

                VStack(alignment: .leading, spacing: 3) {
                    Text(isComplete ? "Trip complete" : "Arrived at \(stopName)")
                        .font(SteddiTheme.heading(16 * textScale))
                        .foregroundStyle(SteddiTheme.textPrimary)
                        .legibleOverMap()

                    if let nextStopName {
                        Text("Next: \(nextStopName)")
                            .font(SteddiTheme.body(13 * textScale, highContrast: highContrast))
                            // Contrast-adaptive on-card foreground (NOT `textSecondary`,
                            // sized against `surfacePrimary`) so the subtitle clears AA
                            // on the sage tint in both themes, matching the heading row.
                            .foregroundStyle(onSage)
                            .legibleOverMap()
                    } else {
                        Text("Arrived at \(stopName)")
                            .font(SteddiTheme.body(13 * textScale, highContrast: highContrast))
                            .foregroundStyle(onSage)
                            .legibleOverMap()
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
            // Route through the centralized glass modifier so Reduce Transparency /
            // high-contrast goes opaque (matching the rest of the floating nav
            // chrome) instead of letting "Arrived at … / Next: …" fight the map.
            // Sage tint keeps the existing "all-clear" green hairline border.
            // Scrim lifts the glass off bright cartography (same shape as the glass),
            // matching the sibling nav banners' over-map hardening.
            .mapGlassScrim(in: RoundedRectangle(cornerRadius: SteddiTheme.radiusCard))
            .steddiGlass(
                tint: SteddiTheme.sage,
                in: RoundedRectangle(cornerRadius: SteddiTheme.radiusCard),
                fallbackStrokeOpacity: 0.3
            )
            .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}
