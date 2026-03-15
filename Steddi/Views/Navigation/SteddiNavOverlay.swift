import SwiftUI
import MapboxNavigationCore
import MapboxDirections
import Combine

/// Custom Steddi turn-by-turn overlay — replaces stock Mapbox NavigationViewController UI.
/// Uses Mapbox NavigationCore for routing brain, but renders its own SwiftUI interface.
struct SteddiNavOverlay: View {
    let provider: MapboxNavigationProvider
    let onEndNavigation: () -> Void

    @State private var instruction: String = ""
    @State private var stepDistance: String = ""
    @State private var etaMinutes: Int = 0
    @State private var distanceRemaining: String = ""
    @State private var arrivalTime: String = ""
    @State private var roadName: String = ""
    @State private var maneuverType: String = "arrow.up"  // SF Symbol
    @State private var hasArrived = false

    var body: some View {
        VStack {
            // Top instruction banner
            topBanner
                .padding(.horizontal, 16)
                .padding(.top, 8)

            Spacer()

            // Road name
            if !roadName.isEmpty {
                Text(roadName)
                    .font(SteddiTheme.body(13))
                    .foregroundStyle(SteddiTheme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background {
                        Capsule()
                            .fill(SteddiTheme.surfacePrimary.opacity(0.85))
                            .overlay(Capsule().stroke(SteddiTheme.accent.opacity(0.1), lineWidth: 1))
                    }
                    .padding(.bottom, 8)
            }

            // Bottom ETA bar
            bottomBar
        }
        .onAppear { startObserving() }
    }

    // MARK: - Top Banner

    private var topBanner: some View {
        HStack(spacing: 14) {
            // Maneuver icon
            Image(systemName: maneuverType)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(SteddiTheme.accent)
                .frame(width: 52, height: 52)
                .background(SteddiTheme.accentSubtle, in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(stepDistance)
                    .font(SteddiTheme.mono(22))
                    .foregroundStyle(SteddiTheme.textPrimary)

                Text(instruction)
                    .font(SteddiTheme.body(15))
                    .foregroundStyle(SteddiTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                .fill(SteddiTheme.surfacePrimary.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                        .stroke(SteddiTheme.accent.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            // ETA info
            VStack(alignment: .leading, spacing: 4) {
                Text("\(etaMinutes) min")
                    .font(SteddiTheme.heading(22))
                    .foregroundStyle(SteddiTheme.textPrimary)

                HStack(spacing: 12) {
                    Text(distanceRemaining)
                        .font(SteddiTheme.mono(14))
                        .foregroundStyle(SteddiTheme.textSecondary)

                    Text(arrivalTime)
                        .font(SteddiTheme.mono(14))
                        .foregroundStyle(SteddiTheme.textMuted)
                }
            }

            Spacer()

            // Steady line accent
            SteadyLine(color: SteddiTheme.accent, height: 2)
                .frame(width: 40)

            Spacer()

            // End button
            Button(action: onEndNavigation) {
                Text("End")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(SteddiTheme.warmRed, in: Capsule())
            }
        }
        .padding(20)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusLarge, topTrailingRadius: SteddiTheme.radiusLarge)
                .fill(SteddiTheme.surfacePrimary.opacity(0.95))
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusLarge, topTrailingRadius: SteddiTheme.radiusLarge)
                        .stroke(SteddiTheme.accent.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 20, y: -5)
        }
    }

    // MARK: - Observation

    private func startObserving() {
        let nav = provider.navigation()

        // Route progress
        Task { @MainActor in
            for await state in nav.routeProgress.values {
                guard let state else { continue }
                let progress = state.routeProgress

                etaMinutes = max(1, Int(ceil(progress.durationRemaining / 60)))
                distanceRemaining = formatDistance(progress.distanceRemaining)
                arrivalTime = formatArrivalTime(progress.durationRemaining)

                // Current step instruction
                let step = progress.currentLegProgress.currentStep
                instruction = step.instructions
                stepDistance = formatDistance(progress.currentLegProgress.currentStepProgress.distanceRemaining)
                maneuverType = sfSymbol(for: step.maneuverType, direction: step.maneuverDirection)
            }
        }

        // Road name
        Task { @MainActor in
            for await state in nav.locationMatching.values {
                roadName = state.roadName?.text ?? ""
            }
        }

        // Arrival
        Task { @MainActor in
            for await arrival in nav.waypointsArrival.values {
                if arrival.event != nil {
                    hasArrived = true
                    onEndNavigation()
                }
            }
        }
    }

    // MARK: - Formatting

    private func formatDistance(_ meters: Double) -> String {
        if meters < 160 { // ~500 ft
            return "\(Int(meters * 3.281)) ft"
        }
        let miles = meters / 1609.34
        if miles < 10 {
            return String(format: "%.1f mi", miles)
        }
        return "\(Int(miles)) mi"
    }

    private func formatArrivalTime(_ secondsRemaining: TimeInterval) -> String {
        let arrival = Date().addingTimeInterval(secondsRemaining)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: arrival)
    }

    private func sfSymbol(for maneuverType: ManeuverType, direction: ManeuverDirection?) -> String {
        switch maneuverType {
        case .turn:
            switch direction {
            case .left, .sharpLeft, .slightLeft: return "arrow.turn.up.left"
            case .right, .sharpRight, .slightRight: return "arrow.turn.up.right"
            case .uTurn: return "arrow.uturn.down"
            default: return "arrow.up"
            }
        case .merge: return "arrow.merge"
        case .takeOnRamp, .takeOffRamp:
            switch direction {
            case .left, .sharpLeft, .slightLeft: return "arrow.up.left"
            case .right, .sharpRight, .slightRight: return "arrow.up.right"
            default: return "arrow.up.right"
            }
        case .reachFork:
            switch direction {
            case .left, .slightLeft: return "arrow.up.left"
            default: return "arrow.up.right"
            }
        case .reachEnd: return "arrow.turn.up.right"
        case .useLane: return "arrow.up"
        case .takeRotary, .takeRoundabout: return "arrow.triangle.2.circlepath"
        case .arrive: return "flag.fill"
        case .depart: return "location.fill"
        default: return "arrow.up"
        }
    }
}
