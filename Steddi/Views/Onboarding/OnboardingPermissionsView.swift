import SwiftUI

/// Beat 2 of onboarding: ask for location, framed in-context — "so Steddi knows
/// which way you're heading" — right after the map hero, where the reason is
/// obvious. Notifications are *not* asked here; those are deferred to the first
/// commute the user creates.
///
/// A gently pulsing icon over framed copy and a Continue/Not-now choice.
/// "Continue" requests When-In-Use authorization through `LocationService`;
/// "Not now" defers without asking. Either choice advances — this beat has no
/// top-level Skip, by design.
///
/// In the showpiece flow the card chrome is supplied by `OnboardingShowpieceCard`
/// (the morphing Liquid Glass shell), so this view renders only its *content*
/// column — no background fill or full-screen centering of its own.
struct OnboardingPermissionsView: View {
    /// Triggers the system location prompt.
    var onContinue: () -> Void
    /// Defers the prompt and advances.
    var onNotNow: () -> Void
    /// Live accent so the in-card primary matches the chosen theme. This is the
    /// IN-FLIGHT pick held on the coordinator (not yet persisted), so it's passed
    /// in rather than read from `SteddiTheme.accentBrand` (which lags a beat).
    /// Used as the Continue button's glass FILL (contrast carried by the fill).
    var accent: SteddiTheme.AccentOption = SteddiTheme.currentAccentOption
    /// Luminance-correct on-fill label color for `accent` (the in-flight accent's
    /// `contrastingGlyph`). A system-white label fails AA on the light accents.
    var onAccentLabel: Color = SteddiTheme.onAccent

    @State private var pulse = false

    /// Frost-legible hue for the 64pt focal icon. Like the showcase beats, the
    /// raw mid-tone accent is lifted to a uniform 5.7:1 on the card's dark scrim
    /// (`OnboardingShowcaseFrost`) — preserving the brand hue while clearing the
    /// 3:1 graphical-object floor with margin. The previous raw accent landed
    /// ~1.1:1 on the old LIGHT frost (the focal point all but vanished).
    private var glyphAccent: Color {
        SteddiTheme.legibleText(accent.rgb, onSurface: OnboardingShowcaseFrost.surface).color
    }

    var body: some View {
        card
            .onAppear { animateIn() }
    }

    private var card: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.fill.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(glyphAccent)
                .opacity(pulse ? 0.6 : 1.0)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Which way are you heading?")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    // Fixed light-on-dark: this card floats on the dark
                    // cinematic backdrop in every theme (theme tokens go
                    // near-black in Light and vanish here).
                    .foregroundStyle(SteddiTheme.onboardingTextPrimary)

                Text("Steddi tracks the route you actually take, not a guess. Your location stays on your device.")
                    .font(.body)
                    .foregroundStyle(SteddiTheme.onboardingTextSecondary)
                    .multilineTextAlignment(.center)
                    // At the largest accessibility text sizes this paragraph would
                    // otherwise rely entirely on the card's outer ScrollView. Let it
                    // shrink modestly so the copy degrades gracefully instead of
                    // forcing the whole card to scroll on first read.
                    .minimumScaleFactor(0.7)
            }

            VStack(spacing: 12) {
                Button {
                    HapticService.shared.fire(.uiToggle)
                    onContinue()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        // On-fill label: a system-white label on the light/mid
                        // brand accents fails WCAG AA; this is the in-flight
                        // accent's luminance-correct on-fill color.
                        .foregroundStyle(onAccentLabel)
                        // 17pt headline + 4pt vpad left the glass capsule ~30pt
                        // tall — under the 44pt HIG floor. Pin a 44pt minimum so
                        // the primary CTA clears it without changing the layout.
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Capsule())
                }
                // In-flight accent glass fill + luminance-correct label instead
                // of `.glassProminent` (which forces an AA-failing white label).
                // The fill stays the RAW accent (contrast is carried by the fill
                // + the on-fill `onAccentLabel`, not the glyph).
                .buttonStyle(.plain)
                // Under Reduce Transparency / Increase Contrast, glass is off:
                // paint a FULLY OPAQUE in-flight-accent capsule (not the default
                // near-white `surfacePrimary` fallback, which would lose the brand
                // accent on the dark card). `fallbackProminent` makes the rendered
                // surface exactly the in-flight accent — the same opaque hue
                // `onAccentLabel` is computed for — so the on-fill label contrast
                // stays correct (6–9:1) and matches the glass state.
                .steddiGlass(
                    tint: accent.color,
                    interactive: true,
                    in: Capsule(),
                    fallbackFill: accent.color,
                    fallbackProminent: true
                )

                Button("Not now") {
                    onNotNow()
                }
                .font(.subheadline)
                .foregroundStyle(SteddiTheme.onboardingTextSecondary)
                // Bare ~22pt text button — expand to the 44pt HIG hit target the
                // rest of the app enforces (visual text unchanged).
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
        }
        .padding(28)
        // Cap the beat copy at the app's Dynamic Type ceiling (.accessibility3 ==
        // SteddiTheme.dynamicTypeCeiling/.accessibilityExtraLarge), the same bound
        // the hero's SteddiTheme.heading() applies via UIFontMetrics, so the raw
        // .title2/.body/.headline/.subheadline styles don't scale unbounded to AX5
        // while the hero stays capped. Copy still scales up to the cap.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private func animateIn() {
        // The looping icon pulse is purely decorative: never start the
        // `repeatForever` animation under Reduce Motion, and leave `pulse`
        // false so the icon stays at full opacity rather than frozen dimmed.
        // (The card's own entrance/morph is owned by the showpiece glass shell.)
        guard SteddiMotion.shouldAnimate else { return }
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}
