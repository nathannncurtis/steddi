import SwiftUI

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
    var accent: Color = SteddiTheme.accent

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
                .foregroundStyle(accent)
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
        .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium))
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
                .stroke(accent,
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
