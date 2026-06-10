import SwiftUI

struct RerouteCardView: View {
    let routeName: String
    let timeSavingsMinutes: Int
    let percentageSavings: Int
    let onSwitch: () -> Void
    let onStay: () -> Void

    @AppStorage("accentColor") private var accentColor = "lavender"
    @State private var isVisible = true

    // Display modes — passenger/accessibility grow text and the Stay/Switch
    // touch targets (the passenger is the one working this card)
    @AppStorage("steddi.passengerMode") private var isPassengerMode: Bool = false
    @AppStorage("steddi.accessibilityMode") private var isAccessibilityMode: Bool = false

    private var textScale: Double { DisplayModeService.shared.textScale }
    private var controlScale: Double { DisplayModeService.shared.iconScale }
    private var highContrast: Bool { DisplayModeService.shared.useHighContrast }

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
        let _ = (isPassengerMode, isAccessibilityMode) // re-render on display mode change
        if isVisible {
            VStack(spacing: 16) {
                // Steady line accent
                SteadyLine(color: SteddiTheme.accent, height: 2)
                    .padding(.horizontal, 20)

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
                    Button("Stay") {
                        hide()
                        onStay()
                    }
                    .font(.system(size: 17 * textScale, weight: .medium))
                    .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14 * controlScale)
                    .background(SteddiTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14))

                    Button("Switch") {
                        hide()
                        onSwitch()
                    }
                    .font(.system(size: 17 * textScale, weight: .semibold))
                    .foregroundStyle(SteddiTheme.surfacePrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14 * controlScale)
                    .background(SteddiTheme.accent, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                    .fill(SteddiTheme.surfacePrimary.opacity(SteddiTheme.navSurfaceOpacity(0.95, highContrast: highContrast)))
                    .overlay(
                        RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                            .stroke(SteddiTheme.accent.opacity(SteddiTheme.navStrokeOpacity(0.12, highContrast: highContrast)), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 4)
            }
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    guard isVisible else { return }
                    hide()
                    onStay()
                }
            }
        }
    }

    private func hide() {
        withAnimation(.easeOut(duration: 0.3)) {
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
