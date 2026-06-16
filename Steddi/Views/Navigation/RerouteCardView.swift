import SwiftUI

struct RerouteCardView: View {
    let routeName: String
    let timeSavingsMinutes: Int
    let percentageSavings: Int
    let onSwitch: () -> Void
    /// The driver DELIBERATELY tapped "Stay" — a real decline. Records the
    /// dismissal so the route is suppressed for the cooldown window.
    let onStay: () -> Void
    /// The countdown elapsed with no driver input — NOT a decision. Just clears
    /// the suggestion (no decline recorded, no suppression): a driver keeping
    /// eyes on the road for 30s must not be treated as having rejected the route.
    /// Optional; when nil the timeout falls back to `onStay` so an un-updated
    /// call site keeps the old behavior rather than leaving the suggestion stuck.
    var onAutoDismiss: (() -> Void)? = nil

    /// Seconds the suggestion lingers before auto-dismissing.
    private static let countdownSeconds = 30

    @AppStorage("accentColor") private var accentColor = "lavender"
    @State private var isVisible = true
    @State private var didSpringIn = false
    @State private var secondsRemaining = RerouteCardView.countdownSeconds

    /// Dependency-only: touching this re-resolves `glassAvailable` (and therefore
    /// every readout's foreground) when Reduce Transparency / Increase Contrast
    /// toggles, exactly like `steddiGlass` / `mapGlassScrim`.
    @Environment(\.glassRevision) private var glassRevision

    /// Fires once a second to advance the countdown ring.
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Whether Liquid Glass renders for the card (vs. the solid fallback). Read
    /// imperatively — the `glassRevision` dependency above keeps it re-resolving on
    /// a Reduce-Transparency / Increase-Contrast toggle so the foreground and the
    /// actual card surface can never disagree.
    private var glassAvailable: Bool {
        _ = glassRevision
        return SteddiGlass.isAvailable
    }

    /// AA-correct foreground for EVERY text/value/digit on the card, contrasted
    /// against the ACTUAL card surface (the accent-tinted glass in LIGHT theme, the
    /// dark scrim in DARK theme, the solid fallback when glass is off). Replaces the
    /// surface-adaptive `sageText`/`textSecondary` tokens, which were sized against
    /// `surfacePrimary` and washed out on the lavender tint. See
    /// `SteddiTheme.rerouteCardSurface`.
    private var onCard: Color { SteddiTheme.rerouteCardForeground(glassAvailable: glassAvailable) }

    // Display modes — passenger/accessibility grow text and the Stay/Switch
    // touch targets (the passenger is the one working this card)
    @AppStorage("steddi.passengerMode") private var isPassengerMode: Bool = false
    @AppStorage("steddi.accessibilityMode") private var isAccessibilityMode: Bool = false

    private var textScale: Double { DisplayModeService.shared.textScale }
    private var controlScale: Double { DisplayModeService.shared.iconScale }
    private var highContrast: Bool { DisplayModeService.shared.useHighContrast }

    /// 1 → 0 as the countdown elapses; drives the ring trim.
    private var countdownFraction: Double {
        Double(secondsRemaining) / Double(Self.countdownSeconds)
    }

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
        let _ = (isPassengerMode, isAccessibilityMode) // re-render on display mode change
        if isVisible {
            VStack(spacing: 16) {
                // Steady line accent
                SteadyLine(color: SteddiTheme.accent, height: 2)
                    .padding(.horizontal, 20)

                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 6) {
                        Text("Faster route available")
                            .font(SteddiTheme.heading(17 * textScale))
                            // Contrast-adaptive against the ACTUAL card surface
                            // (accent-tinted glass in light, dark scrim in dark) —
                            // not the surface-token `textPrimary`, which the
                            // lavender tint washed out in light theme.
                            .foregroundStyle(onCard)
                            // Rides accent-tinted translucent glass over the
                            // moving map — same soft per-glyph shadow the nav
                            // banners use so the heading holds against any tile.
                            .legibleOverMap()

                        if !routeName.isEmpty {
                            Text(routeName)
                                .font(SteddiTheme.body(14 * textScale, highContrast: highContrast))
                                .foregroundStyle(onCard)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Auto-dismiss countdown ring — visible deadline feedback.
                    countdownRing
                }

                // Time savings — large and glanceable
                HStack(spacing: 6) {
                    Text("Save ~\(timeSavingsMinutes) min")
                        .font(SteddiTheme.heading(22 * textScale))
                        // The single most glanceable value on the card. Drawn in
                        // the contrast-adaptive on-card foreground (NOT `sageText`):
                        // sage is a mid-tone green that washes out to ~2–3:1 on the
                        // lavender/gold tint and can't be hue-shifted to AA there
                        // (no luminance headroom). The on-card color guarantees
                        // ≥4.5:1 on the actual tinted surface in both themes.
                        .foregroundStyle(onCard)
                        // The glanceable value over the moving map gets the shared
                        // soft shadow too, like the sibling nav readouts.
                        .legibleOverMap()

                    Text("(\(percentageSavings)%)")
                        .font(SteddiTheme.mono(14 * textScale))
                        .foregroundStyle(onCard)
                }

                // Action buttons
                HStack(spacing: 12) {
                    // Secondary: Steddi's neutral interactive glass — keeps the
                    // Reduce-Motion press-scale + over-map fallback the primary CTA
                    // and the rest of the nav chrome use (stock `.glass` drops them).
                    Button("Stay") {
                        hide()
                        onStay()
                    }
                    .font(.system(size: 17 * textScale, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14 * controlScale)
                    .buttonStyle(.steddiGlass)

                    // Primary CTA: canonical accent glass — fill + AA-legible
                    // on-fill label supplied by the style (no .tint/.glassProminent).
                    Button("Switch") {
                        hide()
                        onSwitch()
                    }
                    .font(.system(size: 17 * textScale, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14 * controlScale)
                    .buttonStyle(.steddiPrimary)
                }
            }
            .padding(20)
            // Scrim under the glass — the shared over-map protection the nav
            // banners use, so this mid-drive card's text holds against the
            // cartography (same shape as the glass; skipped when glass is off —
            // the fallback is already opaque). In DARK theme this is a near-opaque
            // luminance-fixed dark fill that makes the adaptive glass render dark.
            .mapGlassScrim(in: SteddiGlass.cardShape)
            // Glass tint. In LIGHT theme: the accent FILL (`accentBrand`, the
            // unshifted brand hue) — a delight/suggestion moment. The tint stays;
            // every readout instead draws in `onCard`
            // (`rerouteCardForeground`), which contrasts the ACTUAL tinted surface
            // and resolves near-BLACK on the light accent (5.3–7.6:1 across the
            // palette). In DARK theme: NEUTRAL glass (no tint), so the dark scrim
            // above dominates and `onCard` resolves near-WHITE (~15.6:1),
            // white-on-dark — preserving the prior dark-theme fix. (The earlier
            // comment claimed the surface tokens had ~9:1 headroom on the lavender
            // frost; they did NOT — sageText/textSecondary are sized on
            // `surfacePrimary` and washed to ~1.7–3.1:1 here. `onCard` fixes that.)
            .steddiGlass(
                tint: SteddiTheme.prefersDarkChrome ? nil : SteddiTheme.accentBrand,
                interactive: false,
                in: SteddiGlass.cardShape
            )
            .padding(.horizontal, 16)
            // Slight Y overshoot on entrance for delight (gated by Reduce Motion).
            .scaleEffect(didSpringIn ? 1.0 : 0.92)
            .offset(y: didSpringIn ? 0 : 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                withAnimation(TransitionKit.rerouteSpringIn) { didSpringIn = true }
            }
            .onReceive(ticker) { _ in
                guard isVisible else { return }
                if secondsRemaining <= 1 {
                    hide()
                    // Timeout is NOT a deliberate decline: take the auto-dismiss
                    // path (clear-only, no suppression). Fall back to onStay only
                    // when no auto-dismiss handler was supplied.
                    (onAutoDismiss ?? onStay)()
                } else {
                    withAnimation(SteddiMotion.resolve(.linear(duration: 1))) {
                        secondsRemaining -= 1
                    }
                }
            }
        }
    }

    /// Circular countdown — the depleting ring draws clockwise, count in the
    /// center. The arc uses the same contrast-adaptive on-card foreground as every
    /// other card readout (NOT `SteddiTheme.sage`): sage is a mid-tone green that
    /// washes to ~2–3:1 on the lavender/gold accent tint and can't be hue-shifted
    /// to AA there, so the arc was low-contrast on the tinted glass. `onCard`
    /// (`rerouteCardForeground`) contrasts the ACTUAL tinted surface — near-black
    /// on the light accent in LIGHT theme, near-white on the dark scrim in DARK —
    /// so the ring reads against every accent and both themes. The countdown
    /// semantics (trim from 1 → 0) are unchanged.
    private var countdownRing: some View {
        ZStack {
            Circle()
                .stroke(onCard.opacity(0.2), lineWidth: 3)

            Circle()
                .trim(from: 0, to: countdownFraction)
                .stroke(onCard, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text("\(secondsRemaining)")
                .font(SteddiTheme.mono(14 * textScale))
                // On-card contrast-adaptive, like every other card readout — the
                // grey `textSecondary` washed out on the lavender tint in light.
                .foregroundStyle(onCard)
                .monospacedDigit()
        }
        .frame(width: 38 * controlScale, height: 38 * controlScale)
        .accessibilityLabel("Auto-dismiss in \(secondsRemaining) seconds")
    }

    private func hide() {
        withAnimation(SteddiMotion.resolve(.easeOut(duration: TransitionKit.durationStandard))) {
            isVisible = false
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack {
            Spacer()
            RerouteCardView(
                routeName: "Via I-10 East",
                timeSavingsMinutes: 7,
                percentageSavings: 23,
                onSwitch: {},
                onStay: {}
            )
            .padding(.bottom, 40)
        }
    }
}
