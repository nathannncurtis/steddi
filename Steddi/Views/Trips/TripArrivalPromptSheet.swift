import SwiftUI

/// Manual-mode continuation between trip legs: confirms the next leg, offers
/// a switch to continuous flow for the remaining stops, or ends the trip
/// here. Intermediate stops never route through the commute PostArrivalSheet
/// — leg routes are saved from the trip editor instead.
struct TripArrivalPromptSheet: View {
    let arrivedStopName: String?
    let nextStop: TripStop
    let legIndex: Int     // 1-based ordinal of the next leg
    let totalLegs: Int
    let onNextLeg: () -> Void
    let onSwitchToContinuous: () -> Void
    let onEndTrip: () -> Void

    @AppStorage("accentColor") private var accentColor = "lavender"

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 6) {
                if let arrivedStopName {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(SteddiTheme.sage)
                        Text("Arrived at \(arrivedStopName)")
                            .font(SteddiTheme.body(14))
                            .foregroundStyle(SteddiTheme.textSecondary)
                    }
                }

                Text("Leg \(legIndex) of \(totalLegs)")
                    .font(SteddiTheme.mono(12))
                    .foregroundStyle(SteddiTheme.textMuted)
            }
            .padding(.top, 24)

            // Next stop details
            VStack(spacing: 8) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(SteddiTheme.accent)

                Text(nextStop.name)
                    .font(SteddiTheme.heading(20))
                    .foregroundStyle(SteddiTheme.textPrimary)
                    .multilineTextAlignment(.center)

                if let address = nextStop.address, !address.isEmpty {
                    Text(address)
                        .font(SteddiTheme.body(13))
                        .foregroundStyle(SteddiTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }

                if let notes = nextStop.notes, !notes.isEmpty {
                    Text(notes)
                        .font(SteddiTheme.body(13))
                        .foregroundStyle(SteddiTheme.textMuted)
                        .italic()
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 16)

            Spacer()

            // Actions
            VStack(spacing: 10) {
                Button(action: onNextLeg) {
                    Label("Start Next Leg", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(SteddiTheme.heading(16))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.steddiPrimary)

                Button(action: onSwitchToContinuous) {
                    Text("Continue automatically for remaining stops")
                        .font(SteddiTheme.body(14))
                        .foregroundStyle(SteddiTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }

                Button(action: onEndTrip) {
                    Text("End Trip Here")
                        .font(SteddiTheme.body(14))
                        // Surface-adaptive legible red — raw warmRed as text on
                        // surfacePrimary fails AA in light (3.56:1) and is near-
                        // invisible in grey (1.77:1). Kept as a quiet text action
                        // (not a prominent CTA) to match the sibling above.
                        .foregroundStyle(SteddiTheme.warmRedText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .background(SteddiTheme.surfacePrimary)
    }
}
