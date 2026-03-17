import SwiftUI
import MapboxNavigationCore
import MapboxDirections
import Combine
import AVFoundation
import CoreLocation

/// Custom Steddi turn-by-turn overlay — replaces stock Mapbox NavigationViewController UI.
/// Uses Mapbox NavigationCore for routing brain, but renders its own SwiftUI interface.
struct SteddiNavOverlay: View {
    let provider: MapboxNavigationProvider
    let onEndNavigation: () -> Void
    var onToggleVoice: () -> Void = {}
    var onToggleView: (Bool) -> Void = { _ in }
    var onSwitchRoute: ((Route) -> Void)? = nil
    var onReport: ((String, CLLocationCoordinate2D) -> Void)? = nil
    var commute: Commute? = nil
    var direction: CommuteDirection? = nil

    // Reroute suggestion
    @State private var rerouteSuggestion: (route: Route, savingsMinutes: Double, savingsPercentage: Double)? = nil
    @State private var currentRemainingETA: TimeInterval = 0

    @State private var instruction: String = ""
    @State private var stepDistance: String = ""
    @State private var stepDistanceRaw: Double = 0
    @State private var etaMinutes: Int = 0
    @State private var distanceRemaining: String = ""
    @State private var arrivalTime: String = ""
    @State private var roadName: String = ""
    @State private var maneuverType: String = "arrow.up"
    @State private var hasArrived = false

    // Speed
    @State private var currentSpeedMph: Double = 0
    @State private var speedLimitMph: Double? = nil

    // Compass
    @State private var headingDegrees: Double = 0

    // Current coordinate for reports
    @State private var currentCoordinate: CLLocationCoordinate2D?

    // Next maneuver preview
    @State private var followOnInstruction: String = ""
    @State private var followOnManeuverSymbol: String = ""

    // Toggles
    @State var isVoiceOn: Bool = true
    @State var is3DView: Bool = true

    // Report
    @State private var showReportSheet = false
    @State private var showReportedToast = false
    @State private var reportedType: String = ""

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        ZStack {
            if isLandscape {
                landscapeNavLayout
            } else {
                portraitNavLayout
            }

            // Reported toast
            if showReportedToast {
                reportedToast
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 60)
            }
        }
        .sheet(isPresented: $showReportSheet) {
            reportSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .onAppear { startObserving() }
    }

    // MARK: - Portrait Nav Layout

    private var portraitNavLayout: some View {
        ZStack {
            VStack(spacing: 0) {
                topBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 60)

                if !followOnInstruction.isEmpty {
                    followOnBanner
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }

                if !roadName.isEmpty {
                    streetNameCapsule
                        .padding(.top, 10)
                }

                Spacer()

                if let suggestion = rerouteSuggestion {
                    RerouteCardView(
                        routeName: suggestion.route.name ?? "Faster route",
                        timeSavingsMinutes: Int(suggestion.savingsMinutes),
                        percentageSavings: Int(suggestion.savingsPercentage * 100),
                        onSwitch: {
                            onSwitchRoute?(suggestion.route)
                            rerouteSuggestion = nil
                        },
                        onStay: { rerouteSuggestion = nil }
                    )
                    .padding(.bottom, 8)
                }

                bottomBar
            }

            // Floating buttons — right side
            VStack(spacing: 12) {
                compassIndicator
                voiceButton
                viewToggleButton
                reportButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, 16)
            .padding(.top, 240)
        }
    }

    // MARK: - Landscape Nav Layout

    private var landscapeNavLayout: some View {
        ZStack {
            // Top-left: instruction card (floating)
            VStack {
                HStack(spacing: 10) {
                    Image(systemName: maneuverType)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(SteddiTheme.accent)
                        .frame(width: 44, height: 44)
                        .background(SteddiTheme.accentSubtle, in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(stepDistance)
                            .font(SteddiTheme.mono(22))
                            .foregroundStyle(SteddiTheme.textPrimary)
                        Text(instruction)
                            .font(SteddiTheme.body(13))
                            .foregroundStyle(SteddiTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(12)
                .frame(width: 260, alignment: .leading)
                .background(SteddiTheme.surfacePrimary.opacity(0.95), in: RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)

                // Next maneuver (compact, below instruction)
                if !followOnInstruction.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: followOnManeuverSymbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SteddiTheme.accent.opacity(0.7))
                        Text("Then: \(followOnInstruction)")
                            .font(SteddiTheme.body(11))
                            .foregroundStyle(SteddiTheme.textMuted)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 260, alignment: .leading)
                    .background(SteddiTheme.surfacePrimary.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                }

                Spacer()
            }
            .padding(.leading, 50) // clear notch
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Bottom-left: ETA + speedometer + End (floating)
            HStack(spacing: 10) {
                speedometer(size: 38)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        Text("\(etaMinutes)")
                            .font(SteddiTheme.mono(20))
                            .foregroundStyle(SteddiTheme.textPrimary)
                        Text("min")
                            .font(SteddiTheme.body(11))
                            .foregroundStyle(SteddiTheme.textSecondary)
                    }
                    HStack(spacing: 6) {
                        Text(distanceRemaining)
                            .font(SteddiTheme.mono(11))
                            .foregroundStyle(SteddiTheme.textMuted)
                        Text(arrivalTime)
                            .font(SteddiTheme.mono(11))
                            .foregroundStyle(SteddiTheme.textMuted)
                    }
                }

                Button(action: onEndNavigation) {
                    Text("End")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(SteddiTheme.warmRed, in: Capsule())
                }
            }
            .padding(10)
            .background(SteddiTheme.surfacePrimary.opacity(0.95), in: RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium))
            .shadow(color: .black.opacity(0.3), radius: 8, y: -2)
            .padding(.leading, 50) // clear notch
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            // Left side: buttons vertically between the two cards
            VStack(spacing: 4) {
                landscapeCompassIndicator
                landscapeButton(isVoiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill") {
                    isVoiceOn.toggle()
                    if isVoiceOn {
                        try? AVAudioSession.sharedInstance().setActive(true)
                    } else {
                        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    }
                }
                landscapeButton(is3DView ? "cube" : "square") { is3DView.toggle(); onToggleView(is3DView) }
                landscapeButton("exclamationmark.bubble.fill") { showReportSheet = true }
            }
            .padding(.leading, 50)
            .padding(.top, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            // Street name: centered bottom
            if !roadName.isEmpty {
                Text(roadName)
                    .font(SteddiTheme.body(11))
                    .foregroundStyle(SteddiTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(SteddiTheme.surfacePrimary.opacity(0.85), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Top Banner

    private var topBanner: some View {
        HStack(spacing: 16) {
            // Maneuver icon — large and prominent
            Image(systemName: maneuverType)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(SteddiTheme.accent)
                .frame(width: 72, height: 72)
                .background(SteddiTheme.accentSubtle, in: RoundedRectangle(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 6) {
                // Distance — LARGE mono for glanceability
                Text(stepDistance)
                    .font(SteddiTheme.mono(34))
                    .foregroundStyle(SteddiTheme.textPrimary)
                    .minimumScaleFactor(0.7)

                // Instruction — clear and readable
                Text(instruction)
                    .font(SteddiTheme.body(18))
                    .foregroundStyle(SteddiTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                        .fill(SteddiTheme.surfacePrimary.opacity(0.82))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                        .stroke(SteddiTheme.accent.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        }
    }

    // MARK: - Follow-On Banner

    private var followOnBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: followOnManeuverSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SteddiTheme.accent.opacity(0.7))
                .frame(width: 28, height: 28)

            Text("Then: \(followOnInstruction)")
                .font(SteddiTheme.body(14))
                .foregroundStyle(SteddiTheme.textMuted)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                .fill(SteddiTheme.surfacePrimary.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                        .stroke(SteddiTheme.accent.opacity(0.08), lineWidth: 1)
                )
        }
    }

    // MARK: - Street Name Capsule

    private var streetNameCapsule: some View {
        Text(roadName)
            .font(SteddiTheme.body(14))
            .foregroundStyle(SteddiTheme.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background {
                Capsule()
                    .fill(SteddiTheme.surfacePrimary.opacity(0.85))
                    .overlay(
                        Capsule()
                            .stroke(SteddiTheme.accent.opacity(0.25), lineWidth: 1)
                    )
            }
    }

    // MARK: - Floating Buttons

    private var compassIndicator: some View {
        ZStack {
            Circle()
                .fill(SteddiTheme.surfacePrimary.opacity(0.88))
                .overlay(Circle().stroke(SteddiTheme.accent.opacity(0.12), lineWidth: 1))
                .frame(width: 44, height: 44)

            Text("N")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(SteddiTheme.warmRed)
                .rotationEffect(.degrees(-headingDegrees))
                .offset(y: -6)

            // Small triangle pointer
            Triangle()
                .fill(SteddiTheme.warmRed)
                .frame(width: 6, height: 5)
                .rotationEffect(.degrees(-headingDegrees))
                .offset(y: 4)
        }
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }

    private var voiceButton: some View {
        Button {
            isVoiceOn.toggle()
            if isVoiceOn {
                try? AVAudioSession.sharedInstance().setActive(true)
            } else {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        } label: {
            floatingButtonCircle(
                symbol: isVoiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                isActive: isVoiceOn
            )
        }
    }

    private var viewToggleButton: some View {
        Button {
            is3DView.toggle()
            onToggleView(is3DView)
        } label: {
            floatingButtonCircle(
                symbol: is3DView ? "cube" : "square",
                isActive: is3DView
            )
        }
    }

    private var reportButton: some View {
        Button {
            showReportSheet = true
        } label: {
            floatingButtonCircle(
                symbol: "exclamationmark.bubble.fill",
                isActive: false
            )
        }
    }

    private var landscapeCompassIndicator: some View {
        ZStack {
            Circle()
                .fill(SteddiTheme.surfacePrimary.opacity(0.88))
                .overlay(Circle().stroke(SteddiTheme.accent.opacity(0.15), lineWidth: 1))
                .frame(width: 44, height: 44)

            Text("N")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(SteddiTheme.warmRed)
                .rotationEffect(.degrees(-headingDegrees))
                .offset(y: -5)

            Triangle()
                .fill(SteddiTheme.warmRed)
                .frame(width: 5, height: 4)
                .rotationEffect(.degrees(-headingDegrees))
                .offset(y: 3)
        }
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }

    /// Slightly smaller button for landscape — 36x36 instead of 44x44
    private func landscapeButton(_ symbol: String, rotationDegrees: Double = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(SteddiTheme.accent)
                .rotationEffect(.degrees(rotationDegrees))
                .frame(width: 44, height: 44)
                .background {
                    Circle()
                        .fill(SteddiTheme.surfacePrimary.opacity(0.88))
                        .overlay(Circle().stroke(SteddiTheme.accent.opacity(0.15), lineWidth: 1))
                }
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        }
    }

    private func floatingButtonCircle(symbol: String, isActive: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(isActive ? SteddiTheme.accent : SteddiTheme.textMuted)
            .frame(width: 44, height: 44)
            .background {
                Circle()
                    .fill(SteddiTheme.surfacePrimary.opacity(0.88))
                    .overlay(
                        Circle()
                            .stroke(isActive ? SteddiTheme.accent.opacity(0.2) : SteddiTheme.textMuted.opacity(0.1), lineWidth: 1)
                    )
            }
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: 0) {
            // Speedometer — left
            speedometer(size: 64)

            // ETA block — center
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text("\(etaMinutes)")
                        .font(SteddiTheme.mono(32))
                        .foregroundStyle(SteddiTheme.textPrimary)
                    Text("min")
                        .font(SteddiTheme.body(14))
                        .foregroundStyle(SteddiTheme.textSecondary)
                        .padding(.top, 8)
                }

                HStack(spacing: 8) {
                    Text(distanceRemaining)
                        .font(SteddiTheme.mono(13))
                        .foregroundStyle(SteddiTheme.textSecondary)

                    Circle()
                        .fill(SteddiTheme.textMuted)
                        .frame(width: 3, height: 3)

                    Text(arrivalTime)
                        .font(SteddiTheme.mono(13))
                        .foregroundStyle(SteddiTheme.textMuted)
                }
            }
            .frame(maxWidth: .infinity)

            // End button — right
            Button(action: onEndNavigation) {
                Text("End")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(SteddiTheme.warmRed, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusLarge, topTrailingRadius: SteddiTheme.radiusLarge)
                .fill(.ultraThinMaterial)
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusLarge, topTrailingRadius: SteddiTheme.radiusLarge)
                        .fill(SteddiTheme.surfacePrimary.opacity(0.82))
                )
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusLarge, topTrailingRadius: SteddiTheme.radiusLarge)
                        .stroke(SteddiTheme.accent.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 20, y: -5)
        }
    }

    // MARK: - Speedometer

    private func speedometer(size: CGFloat) -> some View {
        let overLimit: Double = {
            guard let limit = speedLimitMph else { return 0 }
            return currentSpeedMph - limit
        }()

        let speedColor: Color = {
            if overLimit > 10 { return SteddiTheme.warmRed }
            if overLimit > 0 { return SteddiTheme.accent }
            return SteddiTheme.textPrimary
        }()

        let bgColor: Color = {
            if overLimit > 10 { return SteddiTheme.warmRedSubtle }
            return SteddiTheme.surfaceSecondary
        }()

        let scale = size / 64.0

        return ZStack(alignment: .topTrailing) {
            ZStack {
                // Background circle
                Circle()
                    .fill(bgColor)
                    .overlay(
                        Circle()
                            .stroke(speedColor.opacity(0.3), lineWidth: 2)
                    )

                // Speed arc gauge
                Circle()
                    .trim(from: 0, to: min(1.0, currentSpeedMph / max(1, (speedLimitMph ?? 65) * 1.3)))
                    .stroke(speedColor.opacity(0.5), style: StrokeStyle(lineWidth: max(2, 3 * scale), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3 * scale)

                // Speed value
                VStack(spacing: 0) {
                    Text("\(Int(currentSpeedMph))")
                        .font(SteddiTheme.mono(22 * scale))
                        .foregroundStyle(speedColor)

                    Text("mph")
                        .font(SteddiTheme.body(9 * scale))
                        .foregroundStyle(SteddiTheme.textMuted)
                }
            }
            .frame(width: size, height: size)

            // Speed limit badge — small bordered circle when limit is available
            if let limit = speedLimitMph {
                Text("\(Int(limit))")
                    .font(SteddiTheme.mono(10 * scale))
                    .foregroundStyle(SteddiTheme.textPrimary)
                    .frame(width: 22 * scale, height: 22 * scale)
                    .background(
                        Circle()
                            .fill(SteddiTheme.surfacePrimary)
                            .overlay(Circle().stroke(SteddiTheme.textMuted.opacity(0.5), lineWidth: 1.5))
                    )
                    .offset(x: 4 * scale, y: -4 * scale)
            }
        }
        .frame(width: size + 8, height: size + 8)
    }

    // MARK: - Report Sheet

    private var reportSheet: some View {
        NavigationStack {
            List {
                reportOption(icon: "exclamationmark.triangle.fill", label: "Hazard", color: SteddiTheme.accent)
                reportOption(icon: "shield.fill", label: "Police", color: SteddiTheme.accent)
                reportOption(icon: "car.side.fill", label: "Accident", color: SteddiTheme.warmRed)
                reportOption(icon: "road.lanes", label: "Road Closure", color: SteddiTheme.warmRed)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(SteddiTheme.surfacePrimary)
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showReportSheet = false }
                        .foregroundStyle(SteddiTheme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func reportOption(icon: String, label: String, color: Color) -> some View {
        Button {
            reportedType = label
            showReportSheet = false
            if let coord = currentCoordinate {
                onReport?(label, coord)
            }
            withAnimation(.easeInOut(duration: 0.3)) {
                showReportedToast = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showReportedToast = false
                }
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(color)
                    .frame(width: 32)

                Text(label)
                    .font(SteddiTheme.body(17))
                    .foregroundStyle(SteddiTheme.textPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SteddiTheme.textMuted)
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(SteddiTheme.surfaceSecondary)
    }

    // MARK: - Reported Toast

    private var reportedToast: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(SteddiTheme.sage)
            Text("\(reportedType) Reported")
                .font(SteddiTheme.body(15))
                .foregroundStyle(SteddiTheme.textPrimary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            Capsule()
                .fill(SteddiTheme.surfacePrimary.opacity(0.95))
                .overlay(Capsule().stroke(SteddiTheme.sage.opacity(0.3), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
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
                stepDistanceRaw = progress.currentLegProgress.currentStepProgress.distanceRemaining
                stepDistance = formatDistance(stepDistanceRaw)
                maneuverType = sfSymbol(for: step.maneuverType, direction: step.maneuverDirection)

                // Follow-on step (next maneuver preview)
                if let followOn = progress.currentLegProgress.followOnStep {
                    followOnInstruction = followOn.instructions
                    followOnManeuverSymbol = sfSymbol(for: followOn.maneuverType, direction: followOn.maneuverDirection)
                } else {
                    followOnInstruction = ""
                    followOnManeuverSymbol = ""
                }
            }
        }

        // Location matching — road name, speed, heading
        Task { @MainActor in
            for await state in nav.locationMatching.values {
                roadName = state.roadName?.text ?? ""

                // Current speed (m/s -> mph)
                let speedMS = state.currentSpeed.converted(to: .metersPerSecond).value
                currentSpeedMph = max(0, speedMS * 2.23694)

                // Speed limit
                if let limitValue = state.speedLimit.value {
                    speedLimitMph = limitValue.converted(to: .milesPerHour).value
                } else {
                    speedLimitMph = nil
                }

                // Heading for compass
                headingDegrees = state.location.course

                // Track coordinate for reports
                currentCoordinate = state.location.coordinate
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

        // Reroute engine — periodic fallback check (every 5 minutes)
        if let commute, let direction {
            Task { @MainActor in
                let directionsService = DirectionsService(accessToken: MapboxTokenProvider.accessToken)

                while !Task.isCancelled && !hasArrived {
                    try? await Task.sleep(for: .seconds(300)) // 5 min safety net poll
                    guard !Task.isCancelled, !hasArrived else { break }
                    guard rerouteSuggestion == nil else { continue } // don't stack suggestions

                    guard let currentLocation = nav.currentLocationMatching?.enhancedLocation,
                          let currentProgress = nav.currentRouteProgress else { continue }

                    let remainingETA = currentProgress.routeProgress.durationRemaining
                    currentRemainingETA = remainingETA

                    // Check each fallback route
                    let fallbacks = commute.orderedRoutes(for: direction).filter { $0.rank > 0 }
                    guard !fallbacks.isEmpty else { continue }

                    var bestSuggestion: (route: Route, savingsMinutes: Double, savingsPercentage: Double)?
                    var bestSavings: TimeInterval = 0

                    for fallback in fallbacks {
                        do {
                            let fallbackETA = try await directionsService.fetchETA(
                                from: currentLocation.coordinate,
                                along: fallback.encodedPolyline
                            )

                            let decision = RerouteEngine.evaluate(
                                remainingETASeconds: remainingETA,
                                fallbackETASeconds: fallbackETA,
                                basePercentage: commute.thresholdPercentage,
                                hardMinuteFloor: commute.hardMinuteFloor
                            )

                            if decision.shouldReroute, decision.savingsSeconds > bestSavings {
                                bestSavings = decision.savingsSeconds
                                bestSuggestion = (
                                    route: fallback,
                                    savingsMinutes: decision.savingsMinutes,
                                    savingsPercentage: decision.savingsSeconds / remainingETA
                                )
                            }
                        } catch {
                            continue
                        }
                    }

                    if let suggestion = bestSuggestion {
                        rerouteSuggestion = suggestion
                    }
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

// MARK: - Triangle Shape

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
