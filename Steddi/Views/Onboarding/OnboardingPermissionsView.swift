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
    var accent: Color = SteddiTheme.accentBrand
    /// Luminance-correct on-fill label color for `accent` (the in-flight accent's
    /// `contrastingGlyph`). A system-white label fails AA on the light accents.
    var onAccentLabel: Color = SteddiTheme.onAccent

    @State private var pulse = false

    var body: some View {
        card
            .onAppear { animateIn() }
    }

    private var card: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.fill.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(accent)
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
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                // In-flight accent glass fill + luminance-correct label instead
                // of `.glassProminent` (which forces an AA-failing white label).
                .buttonStyle(.plain)
                .steddiGlass(tint: accent, interactive: true, in: Capsule())

                Button("Not now") {
                    onNotNow()
                }
                .font(.subheadline)
                .foregroundStyle(SteddiTheme.onboardingTextSecondary)
            }
        }
        .padding(28)
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
