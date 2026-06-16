import ActivityKit
import WidgetKit
import SwiftUI

/// Deep link that returns the driver to the live turn-by-turn UI when they tap
/// the navigation Live Activity. The bare `navigate` host (no params) just
/// foregrounds the app — HomeView already shows the nav overlay while a session
/// is active — and is routed by `PhoneSceneDelegate.handleURL`, matching the
/// CarPlay dashboard's `DashboardLink.showNavigation`.
private let navReentryURL = URL(string: "steddi://navigate")

/// The user's chosen accent, resolved from the shared App Group so the Live
/// Activity tints its accent elements (maneuver glyph, trip-leg label) to match
/// the in-app HUD instead of a hardcoded lavender.
///
/// This extension target can't import `SteddiTheme` (it compiles only
/// `SteddiLiveActivity/*` + `Shared/NavigationAttributes.swift`), so the accent
/// raw values are mirrored here — kept byte-for-byte in sync with
/// `SteddiTheme.AccentOption.rgb`. The app mirrors the selected accent's raw
/// name into the App Group under `accentColor` at every nav-session start
/// (`LiveActivityService.startActivity`); we map that name to its brand hue.
/// Falls back to lavender when the key is missing or unrecognized.
private var liveActivityAccent: Color {
    let raw = UserDefaults(suiteName: "group.to.nathancurtis.steddi")?
        .string(forKey: "accentColor")
    switch raw {
    case "ocean": return Color(red: 0.29, green: 0.56, blue: 0.85)
    case "sage":  return Color(red: 0.42, green: 0.61, blue: 0.49)
    case "coral": return Color(red: 0.83, green: 0.45, blue: 0.42)
    case "gold":  return Color(red: 0.77, green: 0.64, blue: 0.31)
    case "slate": return Color(red: 0.48, green: 0.55, blue: 0.60)
    case "lavender": return Color(red: 0.61, green: 0.56, blue: 0.77)
    default:      return Color(red: 0.61, green: 0.56, blue: 0.77) // lavender fallback
    }
}

/// The Live Activity widget for active navigation.
/// Shows on the Lock Screen and Dynamic Island.
struct SteddiNavigationActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavigationAttributes.self) { context in
            // Lock Screen presentation — tap returns to the live nav UI.
            LockScreenView(state: context.state, attributes: context.attributes)
                .widgetURL(navReentryURL)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded view
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.maneuverSymbol)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(context.state.etaMinutes) min")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                        Text(context.state.distanceRemaining)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.stepDistance)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                        Text(context.state.instruction)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    // Tapping the expanded island returns to the live nav UI.
                    .widgetURL(navReentryURL)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if let legIndex = context.state.legIndex, let totalLegs = context.state.totalLegs {
                            // Trip context: "Leg 2 of 5 → Stop name"
                            Text("Leg \(legIndex) of \(totalLegs) → \(context.attributes.destinationName)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(liveActivityAccent)
                                .lineLimit(1)
                        } else if !context.state.roadName.isEmpty {
                            Text(context.state.roadName)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer()
                        Text("Arrive \(context.state.arrivalTime)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.maneuverSymbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(liveActivityAccent)
                    .widgetURL(navReentryURL)
            } compactTrailing: {
                Text("\(context.state.etaMinutes)m")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: context.state.maneuverSymbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(liveActivityAccent)
                    .widgetURL(navReentryURL)
            }
        }
    }
}

/// Lock Screen Live Activity view
struct LockScreenView: View {
    let state: NavigationAttributes.ContentState
    let attributes: NavigationAttributes

    var body: some View {
        HStack(spacing: 16) {
            // Maneuver icon
            Image(systemName: state.maneuverSymbol)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(liveActivityAccent)
                .frame(width: 50)

            // Instruction
            VStack(alignment: .leading, spacing: 4) {
                if let tripName = state.tripName, let legIndex = state.legIndex, let totalLegs = state.totalLegs {
                    Text("\(tripName) · Leg \(legIndex) of \(totalLegs)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(liveActivityAccent)
                        .lineLimit(1)
                }
                Text(state.stepDistance)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(state.instruction)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                if !state.roadName.isEmpty {
                    Text(state.roadName)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer()

            // ETA
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(state.etaMinutes)")
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("min")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                Text(state.distanceRemaining)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(16)
        .background(Color(red: 0.055, green: 0.051, blue: 0.071)) // matches --bg
    }
}
