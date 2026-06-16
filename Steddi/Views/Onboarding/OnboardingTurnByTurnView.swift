import SwiftUI

/// The card surface the onboarding *showcase/ask* beats actually sit on.
///
/// HISTORY (the root bug this constant used to embody): the non-theme beats
/// render inside the morphing `OnboardingShowpieceCard`, whose shell is neutral
/// `.regular` Liquid Glass (`cardTint == nil` for everything but the theme
/// beat). Over the dark cinematic backdrop the OS renders that neutral glass as
/// a noticeably LIGHT frost — sampled at ~0.73 sRGB (~0.49 relative luminance)
/// from a real device render. The card *copy* is fixed-WHITE (matching the
/// hero), so white-on-light-frost collapsed to ~1.9:1 and the accent glyphs to
/// ~1.65:1 — both far below the AA floors. This constant was a *guessed* 0.62
/// light surface, and the glyph shift sized against it saturated its cap and
/// never cleared 3:1.
///
/// FIX (dark cards): rather than fight the non-deterministic light glass,
/// `OnboardingShowpieceCard` now paints a deterministic DARK scrim behind the
/// content of every non-theme beat (gated on `needsDarkScrim`), so the copy +
/// glyphs sit on a reliably dark surface — white-on-dark, exactly like the hero. This constant is the *conservative composited* value the
/// content rests on: the dark scrim (`onboardingCardFallbackFill`, ~RGB 0.12)
/// painted at high opacity over the lightest plausible glass composites no
/// lighter than this, so any contrast asserted against this value is a worst-case
/// lower bound that the real render beats. Feeding it to
/// `SteddiTheme.legibleText(_:onSurface:)` LIGHTENS the mid-tone accent (a dark
/// surface has headroom upward), lifting every glyph to 5.7:1 while preserving
/// the brand hue, and the fixed-white copy tiers clear AA with margin
/// (primary 11.6:1, secondary 9.7:1, muted 4.9:1).
enum OnboardingShowcaseFrost {
    static let surface = RGBColor(0.22, 0.22, 0.24)
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
    /// These sit on the card's deterministic DARK scrim (see
    /// `OnboardingShowcaseFrost`): raw mid-tone accents are fine on dark, but the
    /// shared `legibleText` shift LIGHTENS them to a uniform 5.7:1 so every accent
    /// reads identically bright on the dark surface while staying recognisably the
    /// brand hue — well above the 3:1 graphical-object floor.
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
                    // At the largest accessibility text sizes this paragraph would
                    // otherwise rely entirely on the card's outer ScrollView. Let it
                    // shrink modestly so the copy degrades gracefully instead of
                    // forcing the whole card to scroll on first read.
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(28)
        // Cap the beat copy at the app's Dynamic Type ceiling (.accessibility3 ==
        // SteddiTheme.dynamicTypeCeiling/.accessibilityExtraLarge), the same bound
        // the hero's SteddiTheme.heading() applies via UIFontMetrics, so the raw
        // .title2/.body/.headline/.caption styles here don't scale unbounded to
        // AX5 while the hero stays capped. Copy still scales up to the cap.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
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
                // Fixed light-on-dark gauge track. `onboardingTextMuted` (white
                // .66) at .60 reads ~3.2:1 on the dark card scrim — above the 3:1
                // graphical floor, while staying a quiet track behind the
                // brighter accent sweep. (The meaning is carried by the colored
                // sweep + the white "32 mph" label, not the track.)
                .stroke(SteddiTheme.onboardingTextMuted.opacity(0.6),
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
