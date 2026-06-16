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
    @AppStorage(ThemeModeEx.defaultsKey) private var themeModeEx: String = ThemeModeEx.dynamic.rawValue

    /// A presented sheet gets its own presentation context and does not reliably
    /// inherit the presenter's `.preferredColorScheme`, so pin the app theme here
    /// too — otherwise this sheet renders in the device appearance and mismatches
    /// the rest of Steddi when the chosen theme differs from the device.
    private var resolvedColorScheme: ColorScheme? {
        (ThemeModeEx(rawValue: themeModeEx) ?? .dynamic).colorScheme
    }

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
        // The header + next-stop block scrolls (a long stop name + 2-line address
        // + notes at large Dynamic Type can't all fit the .medium detent) while the
        // 3 action buttons stay pinned in a bottom safe-area inset so they never
        // collide with the content or get clipped below the detent edge.
        ScrollView {
            VStack(spacing: 0) {
            // Header
            VStack(spacing: 6) {
                if let arrivedStopName {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            // Surface-adaptive legible green — raw sage as a small
                            // meaning-bearing glyph on surfacePrimary is only
                            // 2.30:1 (light), below the 3:1 floor. Matches the
                            // "visited" checkmark fix in TripEditorView.
                            .font(SteddiTheme.body(14))
                            .foregroundStyle(SteddiTheme.sageText)
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
            .padding(.bottom, 20)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Actions — pinned below the scroll so the 3 buttons stay reachable
            // and never collide with the content at large Dynamic Type sizes.
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
                        // Bare ~37pt text button — expand to the 44pt HIG hit
                        // target the rest of the app enforces (matches the
                        // sibling text buttons in OnboardingPermissionsView /
                        // OnboardingEmergencyView / HomeView). Visual unchanged;
                        // only the tappable area grows.
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }

                Button(action: onEndTrip) {
                    Text("End Trip Here")
                        .font(SteddiTheme.body(14))
                        // Surface-adaptive legible red — raw warmRed as text on
                        // surfacePrimary fails AA in light (3.56:1) and is near-
                        // invisible in grey (1.77:1). Kept as a quiet text action
                        // (not a prominent CTA) to match the sibling above.
                        .foregroundStyle(SteddiTheme.warmRedText)
                        // Same 44pt HIG hit target as the sibling above.
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .background(SteddiTheme.surfacePrimary)
        }
        .background(SteddiTheme.surfacePrimary)
        .preferredColorScheme(resolvedColorScheme)
    }
}
