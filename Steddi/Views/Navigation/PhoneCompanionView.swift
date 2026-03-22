import SwiftUI
import MapboxNavigationCore
import CoreLocation

/// Phone companion view shown when CarPlay is handling the map.
/// Displays detailed turn-by-turn info, upcoming steps list, route overview, and speedometer.
struct PhoneCompanionView: View {
    @Environment(NavigationStateManager.self) private var navState

    var body: some View {
        ZStack {
            // Full background
            SteddiTheme.surfacePrimary
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // 1. Header — current instruction
                headerBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                // 2. Upcoming turns list
                upcomingTurnsList
                    .padding(.top, 12)

                // 3. Route overview
                routeOverview
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                // 4. Bottom bar — speedometer + End
                bottomBar
                    .padding(.top, 12)
            }

            // 5. Reroute card overlay
            if let suggestion = navState.rerouteSuggestion {
                VStack {
                    Spacer()
                    RerouteCardView(
                        routeName: suggestion.route.name ?? "Faster route",
                        timeSavingsMinutes: Int(suggestion.savingsMinutes),
                        percentageSavings: Int(suggestion.savingsPercentage * 100),
                        onSwitch: {
                            navState.rerouteSuggestion = nil
                        },
                        onStay: {
                            navState.rerouteSuggestion = nil
                        }
                    )
                    .padding(.bottom, 100)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header Banner

    private var headerBanner: some View {
        HStack(spacing: 14) {
            // Maneuver icon
            Image(systemName: navState.maneuverType)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(SteddiTheme.accent)
                .frame(width: 60, height: 60)
                .background(SteddiTheme.accentSubtle, in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 4) {
                // Distance — large mono
                Text(navState.stepDistance)
                    .font(SteddiTheme.mono(28))
                    .foregroundStyle(SteddiTheme.textPrimary)
                    .minimumScaleFactor(0.7)

                // Instruction
                Text(navState.instruction)
                    .font(SteddiTheme.body(16))
                    .foregroundStyle(SteddiTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                .fill(SteddiTheme.surfaceSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                        .stroke(SteddiTheme.accent.opacity(0.15), lineWidth: 1)
                )
        }
    }

    // MARK: - Upcoming Turns List

    private var upcomingTurnsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(navState.upcomingSteps.enumerated()), id: \.element.id) { index, step in
                    let isFirst = index == 0
                    let isLast = index == navState.upcomingSteps.count - 1
                    let isArrive = step.maneuverSymbol == "flag.fill"

                    HStack(spacing: 12) {
                        // Maneuver icon
                        Image(systemName: step.maneuverSymbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isFirst ? SteddiTheme.accent : SteddiTheme.textMuted)
                            .frame(width: 36, height: 36)
                            .background(
                                isFirst
                                    ? SteddiTheme.accentSubtle
                                    : SteddiTheme.surfaceElevated,
                                in: RoundedRectangle(cornerRadius: 10)
                            )

                        // Distance
                        Text(step.distance)
                            .font(SteddiTheme.mono(14))
                            .foregroundStyle(isFirst ? SteddiTheme.textPrimary : SteddiTheme.textSecondary)
                            .frame(width: 60, alignment: .trailing)

                        // Instruction + road name
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isArrive && isLast ? "Arrive at destination" : step.instruction)
                                .font(SteddiTheme.body(14))
                                .foregroundStyle(isFirst ? SteddiTheme.textPrimary : SteddiTheme.textSecondary)
                                .lineLimit(2)

                            if let road = step.roadName,
                               !road.isEmpty,
                               road != step.instruction {
                                Text(road)
                                    .font(SteddiTheme.body(12))
                                    .foregroundStyle(SteddiTheme.textMuted)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        index.isMultiple(of: 2)
                            ? SteddiTheme.surfacePrimary
                            : SteddiTheme.surfaceSecondary.opacity(0.5)
                    )
                    // Highlight current/next step
                    .overlay(alignment: .leading) {
                        if isFirst {
                            Rectangle()
                                .fill(SteddiTheme.accent)
                                .frame(width: 3)
                        }
                    }
                }

                // Final arrival row if not already in steps
                if navState.upcomingSteps.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(SteddiTheme.sage)
                            .frame(width: 36, height: 36)
                            .background(SteddiTheme.sageSubtle, in: RoundedRectangle(cornerRadius: 10))

                        Text("Arrive at destination")
                            .font(SteddiTheme.body(14))
                            .foregroundStyle(SteddiTheme.textSecondary)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Route Overview

    private var routeOverview: some View {
        HStack(spacing: 0) {
            // ETA minutes
            overviewStat(
                value: "\(navState.etaMinutes)",
                label: "min",
                color: SteddiTheme.textPrimary
            )

            divider

            // Distance remaining
            overviewStat(
                value: navState.distanceRemaining,
                label: "remaining",
                color: SteddiTheme.textSecondary
            )

            divider

            // Arrival time
            overviewStat(
                value: navState.arrivalTime,
                label: "arrival",
                color: SteddiTheme.textSecondary
            )
        }
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                .fill(SteddiTheme.surfaceSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                        .stroke(SteddiTheme.accent.opacity(0.08), lineWidth: 1)
                )
        }
        // Current road name below
        .overlay(alignment: .bottom) {
            if !navState.roadName.isEmpty {
                Text(navState.roadName)
                    .font(SteddiTheme.body(12))
                    .foregroundStyle(SteddiTheme.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(SteddiTheme.surfacePrimary.opacity(0.9), in: Capsule())
                    .offset(y: 14)
            }
        }
        .padding(.bottom, navState.roadName.isEmpty ? 0 : 10)
    }

    private func overviewStat(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(SteddiTheme.mono(18))
                .foregroundStyle(color)
            Text(label)
                .font(SteddiTheme.body(11))
                .foregroundStyle(SteddiTheme.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(SteddiTheme.textMuted.opacity(0.3))
            .frame(width: 1, height: 30)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: 0) {
            // Compact speedometer
            compactSpeedometer
                .padding(.leading, 16)

            Spacer()

            // End Navigation button
            Button {
                navState.isNavigating = false
            } label: {
                Text("End Navigation")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(SteddiTheme.warmRed, in: Capsule())
            }
            .padding(.trailing, 16)
        }
        .padding(.vertical, 14)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusCard, topTrailingRadius: SteddiTheme.radiusCard)
                .fill(SteddiTheme.surfaceSecondary)
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusCard, topTrailingRadius: SteddiTheme.radiusCard)
                        .stroke(SteddiTheme.accent.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 12, y: -4)
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: - Compact Speedometer

    private var compactSpeedometer: some View {
        let overLimit: Double = {
            guard let limit = navState.speedLimitMph else { return 0 }
            return navState.currentSpeedMph - limit
        }()

        let speedColor: Color = {
            if overLimit > 10 { return SteddiTheme.warmRed }
            if overLimit > 0 { return SteddiTheme.accent }
            return SteddiTheme.textPrimary
        }()

        let bgColor: Color = {
            if overLimit > 10 { return SteddiTheme.warmRedSubtle }
            return SteddiTheme.surfaceElevated
        }()

        return ZStack(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .fill(bgColor)
                    .overlay(
                        Circle()
                            .stroke(speedColor.opacity(0.3), lineWidth: 2)
                    )

                // Speed arc
                Circle()
                    .trim(from: 0, to: min(1.0, navState.currentSpeedMph / max(1, (navState.speedLimitMph ?? 65) * 1.3)))
                    .stroke(speedColor.opacity(0.5), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3)

                VStack(spacing: 0) {
                    Text("\(Int(navState.currentSpeedMph))")
                        .font(SteddiTheme.mono(18))
                        .foregroundStyle(speedColor)
                    Text("mph")
                        .font(SteddiTheme.body(8))
                        .foregroundStyle(SteddiTheme.textMuted)
                }
            }
            .frame(width: 52, height: 52)

            // Speed limit badge
            if let limit = navState.speedLimitMph {
                Text("\(Int(limit))")
                    .font(SteddiTheme.mono(8))
                    .foregroundStyle(SteddiTheme.textPrimary)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(SteddiTheme.surfacePrimary)
                            .overlay(Circle().stroke(SteddiTheme.textMuted.opacity(0.5), lineWidth: 1))
                    )
                    .offset(x: 3, y: -3)
            }
        }
        .frame(width: 58, height: 58)
    }
}

#Preview {
    PhoneCompanionView()
        .environment(NavigationStateManager.shared)
}
