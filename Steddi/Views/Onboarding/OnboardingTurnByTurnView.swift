import SwiftUI

/// Representative surface for the onboarding *showcase* beats' affordance glyphs.
///
/// The showcase/route-rules beats render their illustration inside the morphing
/// `OnboardingShowpieceCard`, whose shell is neutral `.regular` Liquid Glass
/// (`cardTint == nil` for everything but the theme beat). Over the dark
/// cinematic backdrop the OS renders that glass as a noticeably LIGHT frost
/// (measured card luminance ~0.5–0.7), so accent glyphs drawn in the raw
/// mid-tone brand hue wash out (~1.2–1.6:1, below the 3:1 graphical-object
/// floor) — the same reason the card *copy* uses the fixed-white onboarding
/// tiers rather than theme tokens.
///
/// Live glass luminance isn't deterministic from code, so we size the legible
/// shift against a fixed light-grey panel near the measured frost (>0.5 so the
/// accent darkens, the worst case for these mid-tone hues). Feeding this to
/// `SteddiTheme.legibleText(_:onSurface:)` lifts the glyph above the floor while
/// preserving the brand hue — mirroring `DonationView`'s accent-on-frost fix.
enum OnboardingShowcaseFrost {
    static let surface = RGBColor(0.62, 0.62, 0.64)
}

/// Showcase beat 3: "Turn-by-turn, done Steddi's way." Communicates that Steddi
/// does its *own* navigation — not a hand-off to another app. Morphs in from the
/// route-rules card (the glass shell is shared); this view supplies only the
/// inner content.
///
/// The graphic is a mini mock of the nav HUD: a maneuver chip (the turn arrow +
/// distance, in an accent-subtle pill) beside the speedometer motif (an arc that
/// gently sweeps to a speed). No new heavy renderer — a `Path`-trimmed arc plus a
/// stock SF Symbol. Reduce-Motion shows the arc filled and static.
struct OnboardingTurnByTurnView: View {
    /// Live accent — the maneuver chip and speedo arc glow the chosen color.
    /// Taken as the `AccentOption` (not a resolved `Color`) so the view can
    /// derive both the raw hue for subtle fills and a surface-aware *legible*
    /// hue for the glyphs that read on the lighter frosted card.
    var accent: SteddiTheme.AccentOption = SteddiTheme.currentAccentOption

    /// The raw brand hue — used only for the subtle chip backing fill, where
    /// contrast is carried by the fill, not the glyph.
    private var accentFill: Color { accent.color }

    /// Glyph color for the affordance illustrations (turn arrow, speedo sweep).
    /// These sit on the `.regular` Liquid Glass card, which the OS renders as a
    /// noticeably LIGHT frost over the dark backdrop — the raw mid-tone accents
    /// wash out there (~1.2–1.6:1, below the 3:1 graphical-object floor). Shift
    /// the accent toward the side the light frost has headroom in so it clears
    /// the floor while staying recognisably the brand hue — the same fix the
    /// donation sheet uses for accent-on-frost (DonationView.sheetPriceColor).
    private var glyphAccent: Color {
        SteddiTheme.legibleText(accent.rgb, onSurface: OnboardingShowcaseFrost.surface).color
    }

    @State private var arcProgress: CGFloat = 0

    var body: some View {
        VStack(spacing: 22) {
            hudMock
                // Decorative mock: let it grow under large Dynamic Type rather
                // than locking a fixed height that the scaling chip text would
                // overflow/misalign against the speedometer. minHeight keeps the
                // default layout; the inner labels also cap their own scale.
                .frame(minHeight: 120)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Turn-by-turn, done Steddi's way")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    // Fixed light-on-dark: this card floats on the dark
                    // cinematic backdrop in every theme (theme tokens go
                    // near-black in Light and vanish here).
                    .foregroundStyle(SteddiTheme.onboardingTextPrimary)

                Text("Steddi runs its own navigation — clear maneuvers, your speed, no hand-off to another app.")
                    .font(.body)
                    .foregroundStyle(SteddiTheme.onboardingTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Turn-by-turn, done Steddi's way. Steddi runs its own navigation — clear maneuvers, your speed, no hand-off to another app.")
        .onAppear {
            guard SteddiMotion.shouldAnimate else { arcProgress = 1; return }
            arcProgress = 0
            withAnimation(.easeOut(duration: 1.3)) { arcProgress = 1 }
        }
    }

    // MARK: - HUD mock

    private var hudMock: some View {
        HStack(spacing: 20) {
            maneuverChip
            speedometer
        }
        .frame(maxWidth: .infinity)
    }

    /// The maneuver chip: a turn arrow + distance in an accent-subtle pill, the
    /// same visual language as the live nav banner.
    private var maneuverChip: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.turn.up.right")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(glyphAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("400 ft")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(SteddiTheme.onboardingTextPrimary)
                Text("Turn right")
                    .font(.caption)
                    .foregroundStyle(SteddiTheme.onboardingTextSecondary)
            }
            // Decorative mock — keep the chip text scaling bounded so it can't
            // overflow the HUD region or overrun the speedometer at AX sizes.
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(accentFill.opacity(0.15), in: RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium))
    }

    /// The speedometer motif: a sweeping arc with the speed at its center —
    /// echoing the in-app speedometer housing.
    private var speedometer: some View {
        ZStack {
            // Track.
            Circle()
                .trim(from: 0.0, to: 0.75)
                // Fixed light-on-dark track: the muted theme token resolves
                // near-black in Light and would disappear on this dark card.
                .stroke(SteddiTheme.onboardingTextMuted.opacity(0.55),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(135))
            // Sweep to ~"60%" of the arc.
            Circle()
                .trim(from: 0.0, to: 0.75 * 0.6 * arcProgress)
                .stroke(glyphAccent,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(135))
            VStack(spacing: 0) {
                Text("32")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(SteddiTheme.onboardingTextPrimary)
                Text("mph")
                    .font(.caption2)
                    .foregroundStyle(SteddiTheme.onboardingTextSecondary)
            }
            // Keep the centered speed label within the fixed gauge housing.
            .lineLimit(1)
            .minimumScaleFactor(0.5)
        }
        .frame(width: 84, height: 84)
    }
}
