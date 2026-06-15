import SwiftUI

struct RerouteCardView: View {
    let routeName: String
    let timeSavingsMinutes: Int
    let percentageSavings: Int
    let onSwitch: () -> Void
    let onStay: () -> Void

    /// Seconds the suggestion lingers before auto-dismissing.
    private static let countdownSeconds = 30

    @AppStorage("accentColor") private var accentColor = "lavender"
    @State private var isVisible = true
    @State private var didSpringIn = false
    @State private var secondsRemaining = RerouteCardView.countdownSeconds

    /// Fires once a second to advance the countdown ring.
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
                            .foregroundStyle(SteddiTheme.textPrimary)

                        if !routeName.isEmpty {
                            Text(routeName)
                                .font(SteddiTheme.body(14 * textScale, highContrast: highContrast))
                                .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
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
                        .foregroundStyle(SteddiTheme.sage)

                    Text("(\(percentageSavings)%)")
                        .font(SteddiTheme.mono(14 * textScale))
                        .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                }

                // Action buttons
                HStack(spacing: 12) {
                    // Secondary: neutral glass.
                    Button("Stay") {
                        hide()
                        onStay()
                    }
                    .font(.system(size: 17 * textScale, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14 * controlScale)
                    .buttonStyle(.glass)

                    // Primary CTA: prominent accent glass.
                    Button("Switch") {
                        hide()
                        onSwitch()
                    }
                    .font(.system(size: 17 * textScale, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14 * controlScale)
                    .buttonStyle(.glassProminent)
                    .tint(SteddiTheme.accent)
                }
            }
            .padding(20)
            // Accent-tinted glass — this is a delight/suggestion moment.
            .steddiGlass(tint: SteddiTheme.accent, interactive: false, in: SteddiGlass.cardShape)
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
                    onStay()
                } else {
                    withAnimation(SteddiMotion.resolve(.linear(duration: 1))) {
                        secondsRemaining -= 1
                    }
                }
            }
        }
    }

    /// Circular countdown — sage ring depletes clockwise, count in the center.
    private var countdownRing: some View {
        ZStack {
            Circle()
                .stroke(SteddiTheme.textMuted.opacity(0.2), lineWidth: 3)

            Circle()
                .trim(from: 0, to: countdownFraction)
                .stroke(SteddiTheme.sage, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text("\(secondsRemaining)")
                .font(SteddiTheme.mono(14 * textScale))
                .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
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
