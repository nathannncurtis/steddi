import SwiftUI

/// Beat 2 of onboarding: ask for location, framed in-context — "so Steddi knows
/// which way you're heading" — right after the map hero, where the reason is
/// obvious. Notifications are *not* asked here; those are deferred to the first
/// commute the user creates.
///
/// A centered card slides up with a gently pulsing icon. "Continue" requests
/// When-In-Use authorization through `LocationService`; "Not now" defers without
/// asking. Either choice advances — this beat has no top-level Skip, by design.
struct OnboardingPermissionsView: View {
    /// Triggers the system location prompt.
    var onContinue: () -> Void
    /// Defers the prompt and advances.
    var onNotNow: () -> Void

    @State private var cardVisible = false
    @State private var pulse = false

    var body: some View {
        VStack {
            Spacer()
            card
                .padding(.horizontal, 24)
                .frame(maxWidth: 350)
                .opacity(cardVisible ? 1 : 0)
                .offset(y: cardVisible ? 0 : 100)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { animateIn() }
    }

    private var card: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.fill.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(SteddiTheme.accent)
                .opacity(pulse ? 0.6 : 1.0)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Which way are you heading?")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(SteddiTheme.textPrimary)

                Text("Steddi tracks the route you actually take, not a guess. Your location stays on your device.")
                    .font(.body)
                    .foregroundStyle(SteddiTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button {
                    HapticService.shared.fire(.uiToggle)
                    onContinue()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(SteddiTheme.accent, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.steddiPress)

                Button("Not now") {
                    onNotNow()
                }
                .font(.subheadline)
                .foregroundStyle(SteddiTheme.textSecondary)
            }
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: SteddiTheme.radiusLarge)
                .fill(SteddiTheme.surfaceSecondary)
        )
    }

    private func animateIn() {
        // Card entrance collapses to an instant change under Reduce Motion.
        withAnimation(SteddiMotion.resolve(.spring(response: 0.5, dampingFraction: 0.8))) {
            cardVisible = true
        }
        // The looping icon pulse is purely decorative: never start the
        // `repeatForever` animation under Reduce Motion, and leave `pulse`
        // false so the icon stays at full opacity rather than frozen dimmed.
        guard SteddiMotion.shouldAnimate else { return }
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}
