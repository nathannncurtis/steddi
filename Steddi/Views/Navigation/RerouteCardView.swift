import SwiftUI

struct RerouteCardView: View {
    let routeName: String
    let timeSavingsMinutes: Int
    let percentageSavings: Int
    let onSwitch: () -> Void
    let onStay: () -> Void

    @AppStorage("accentColor") private var accentColor = "lavender"
    @State private var isVisible = true

    var body: some View {
        if isVisible {
            VStack(spacing: 16) {
                // Steady line accent
                SteadyLine(color: SteddiTheme.accent, height: 2)
                    .padding(.horizontal, 20)

                VStack(spacing: 6) {
                    Text("Faster route available")
                        .font(SteddiTheme.heading(17))
                        .foregroundStyle(SteddiTheme.textPrimary)

                    if !routeName.isEmpty {
                        Text(routeName)
                            .font(SteddiTheme.body(14))
                            .foregroundStyle(SteddiTheme.textSecondary)
                    }
                }

                // Time savings — large and glanceable
                HStack(spacing: 6) {
                    Text("Save ~\(timeSavingsMinutes) min")
                        .font(SteddiTheme.heading(22))
                        .foregroundStyle(SteddiTheme.sage)

                    Text("(\(percentageSavings)%)")
                        .font(SteddiTheme.mono(14))
                        .foregroundStyle(SteddiTheme.textSecondary)
                }

                // Action buttons
                HStack(spacing: 12) {
                    Button("Stay") {
                        hide()
                        onStay()
                    }
                    .font(.body.weight(.medium))
                    .foregroundStyle(SteddiTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(SteddiTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14))

                    Button("Switch") {
                        hide()
                        onSwitch()
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(SteddiTheme.surfacePrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(SteddiTheme.accent, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                    .fill(SteddiTheme.surfacePrimary.opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                            .stroke(SteddiTheme.accent.opacity(0.12), lineWidth: 1)
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
