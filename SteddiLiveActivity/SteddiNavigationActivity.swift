import ActivityKit
import WidgetKit
import SwiftUI

/// The Live Activity widget for active navigation.
/// Shows on the Lock Screen and Dynamic Island.
struct SteddiNavigationActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavigationAttributes.self) { context in
            // Lock Screen presentation
            LockScreenView(state: context.state, attributes: context.attributes)
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
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if !context.state.roadName.isEmpty {
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
                    .foregroundStyle(Color(red: 0.608, green: 0.557, blue: 0.769)) // lavender
            } compactTrailing: {
                Text("\(context.state.etaMinutes)m")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: context.state.maneuverSymbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.608, green: 0.557, blue: 0.769))
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
                .foregroundStyle(Color(red: 0.608, green: 0.557, blue: 0.769))
                .frame(width: 50)

            // Instruction
            VStack(alignment: .leading, spacing: 4) {
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
