import SwiftUI
import CoreLocation
import AVFoundation

/// Custom Steddi turn-by-turn overlay — replaces stock navigation UI.
/// Uses NavigationEngine for routing brain, renders its own SwiftUI interface.
struct SteddiNavOverlay: View {
    @AppStorage("accentColor") private var accentColor = "lavender"
    let engine: NavigationEngine
    let onEndNavigation: () -> Void
    var onToggleVoice: () -> Void = {}
    var onToggleView: (Bool) -> Void = { _ in }
    var onSwitchRoute: ((Route) -> Void)? = nil
    var onReport: ((String, CLLocationCoordinate2D) -> Void)? = nil
    /// Crowdsourced enforcement-camera report. Routed separately from `onReport`
    /// (which writes generic `Report` rows) so cameras persist as `CameraReport`
    /// and feed the speed-camera proximity index.
    var onReportCamera: ((CameraReportKind, CLLocationCoordinate2D) -> Void)? = nil
    var commute: Commute? = nil
    var direction: CommuteDirection? = nil
    /// Set during multi-stop trip navigation — shows the leg counter and
    /// trip-aware remaining summary alongside the maneuver display.
    var tripContext: TripNavContext? = nil

    // Reroute suggestion
    @State private var rerouteSuggestion: (route: Route, savingsMinutes: Double, savingsPercentage: Double)? = nil
    @State private var currentRemainingETA: TimeInterval = 0

    // Toggles
    @AppStorage("steddi.voiceGuidanceEnabled") var isVoiceOn: Bool = true
    @AppStorage("steddi.showNowPlayingBar") private var showNowPlayingBar: Bool = true
    @State var is3DView: Bool = true

    // Now Playing mini-bar — owns its own observation lifecycle (music-ducking).
    @State private var nowPlaying = NowPlayingService.shared

    // Report
    @State private var showReportSheet = false
    @State private var showReportedToast = false
    @State private var reportedType: String = ""

    // Compass — current 45-degree sector (0 = N ... 7 = NW), nil until the
    // engine publishes its first valid travel bearing
    @State private var compassSector: Int? = nil

    // Floating-button spring entrance — flips true a beat after the overlay
    // appears so the buttons spring in behind the sheet/banner.
    @State private var floatingButtonsAppeared = false
    /// Namespace tying the floating glass controls together so they morph/merge
    /// as one glass system during the spring entrance.
    @Namespace private var navGlassNamespace
    /// Namespace for the banner glass column (topBanner / followOn / tripLeg).
    @Namespace private var bannerGlassNamespace
    // Arrival celebration — drives the one-shot maneuver-icon bounce.
    @State private var arrivalCelebrating = false

    // Display modes — stored here so SwiftUI re-renders when Settings toggles
    // them; the derived scales/flags stay owned by DisplayModeService
    @AppStorage("steddi.passengerMode") private var isPassengerMode: Bool = false
    @AppStorage("steddi.accessibilityMode") private var isAccessibilityMode: Bool = false

    private var textScale: Double { DisplayModeService.shared.textScale }
    private var iconScale: Double { DisplayModeService.shared.iconScale }
    private var highContrast: Bool { DisplayModeService.shared.useHighContrast }
    /// Touch-target multiplier for controls the passenger works (report,
    /// reroute, end) — rides the icon scale so both modes grow them.
    private var controlScale: Double { DisplayModeService.shared.iconScale }

    /// Maneuver text shown on screen — simplified to the bare maneuver in
    /// accessibility mode. Voice guidance always speaks the full instruction.
    private var displayInstruction: String {
        DisplayModeService.shared.useSimplifiedInstructions
            ? DisplayModeService.simplifiedInstruction(engine.instruction)
            : engine.instruction
    }

    private var displayFollowOnInstruction: String {
        DisplayModeService.shared.useSimplifiedInstructions
            ? DisplayModeService.simplifiedInstruction(engine.followOnInstruction)
            : engine.followOnInstruction
    }

    /// "Avoiding tolls"/"Avoiding highways" for whichever preference is shaping
    /// this route — resolved per-commute over global, empty when none is active.
    /// Drives the route-preference badge so the driver knows a choice reshaped
    /// where they're being sent.
    private var activePreferenceLabels: [String] {
        RoutePreferences.resolve(commute: commute).activeLabels
    }

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
        let _ = (isPassengerMode, isAccessibilityMode) // re-render on display mode change
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
        .onAppear {
            VoiceGuidanceService.shared.enabled = isVoiceOn
            nowPlaying.startObserving()
            // Spring the floating buttons in behind the sheet/banner.
            withAnimation(TransitionKit.floatingButtonEntrance) {
                floatingButtonsAppeared = true
            }
        }
        .onDisappear {
            nowPlaying.stopObserving()
        }
        .onChange(of: engine.headingDegrees, initial: true) { _, newValue in
            updateCompassSector(for: newValue)
        }
        .onChange(of: engine.hasArrived) { _, arrived in
            if arrived { triggerArrivalCelebration() }
        }
        .task {
            startRerouteLoop()
        }
    }

    // MARK: - Portrait Nav Layout

    private var portraitNavLayout: some View {
        ZStack {
            VStack(spacing: 0) {
                // The stacked instruction banners read as one cohesive glass
                // column rather than separate slabs.
                GlassEffectContainer(spacing: 6) {
                    VStack(spacing: 0) {
                        topBanner
                            .glassEffectID("banner.top", in: bannerGlassNamespace)
                            .padding(.top, 60)

                        if let tripContext {
                            tripLegBanner(tripContext)
                                .glassEffectID("banner.tripLeg", in: bannerGlassNamespace)
                                .padding(.top, 6)
                        }

                        if !engine.followOnInstruction.isEmpty {
                            followOnBanner
                                .glassEffectID("banner.followOn", in: bannerGlassNamespace)
                                .padding(.top, 6)
                        }
                    }
                }
                .padding(.horizontal, 16)

                if !engine.roadName.isEmpty {
                    streetNameCapsule
                        .padding(.top, 10)
                }

                if !activePreferenceLabels.isEmpty {
                    SteddiRoutePrefBadge(
                        labels: activePreferenceLabels,
                        textScale: textScale,
                        iconScale: iconScale,
                        highContrast: highContrast
                    )
                    .padding(.top, 10)
                }

                if showNowPlayingBar && nowPlaying.hasNowPlaying {
                    NowPlayingMiniBar(service: nowPlaying)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                Spacer()

                if let camera = engine.approachingCamera {
                    speedCameraBanner(camera)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

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
            .animation(SteddiMotion.shouldAnimate ? .easeInOut(duration: 0.3) : nil, value: engine.approachingCamera)

            // Floating buttons — right side. Spring in behind the sheet/banner.
            // Grouped in one GlassEffectContainer so the four controls render in
            // a single pass and merge/separate smoothly during the entrance.
            GlassEffectContainer(spacing: 14) {
                VStack(spacing: 12) {
                    compassIndicator
                        .glassEffectID("nav.compass", in: navGlassNamespace)
                    voiceButton
                        .glassEffectID("nav.voice", in: navGlassNamespace)
                    viewToggleButton
                        .glassEffectID("nav.view", in: navGlassNamespace)
                    reportButton
                        .glassEffectID("nav.report", in: navGlassNamespace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, 16)
            .padding(.top, 270)
            .scaleEffect(floatingButtonsAppeared ? 1.0 : 0.6)
            .opacity(floatingButtonsAppeared ? 1.0 : 0.0)
        }
    }

    // MARK: - Landscape Nav Layout

    /// Landscape instruction cards widen with the text scale so larger type
    /// keeps two full lines instead of truncating.
    private var landscapeCardWidth: CGFloat { 300 * textScale }

    private var landscapeNavLayout: some View {
        ZStack {
            // Top-left: instruction card (floating)
            VStack {
                HStack(spacing: 10) {
                    Image(systemName: engine.maneuverType)
                        .font(.system(size: 28 * iconScale, weight: .bold))
                        .foregroundStyle(SteddiTheme.accent)
                        .frame(width: 50 * iconScale, height: 50 * iconScale)
                        .background(SteddiTheme.accentSubtle, in: RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(engine.stepDistance)
                            .font(SteddiTheme.mono(26 * textScale))
                            .foregroundStyle(SteddiTheme.textPrimary)
                        Text(displayInstruction)
                            .font(SteddiTheme.body(15 * textScale, highContrast: highContrast))
                            .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                            .lineLimit(2)
                    }
                }
                .padding(14)
                .frame(width: landscapeCardWidth, alignment: .leading)
                .steddiGlass(tint: nil, interactive: false, in: SteddiGlass.mediumShape)

                // Trip leg context (compact, below instruction)
                if let tripContext {
                    tripLegBanner(tripContext)
                        .frame(width: landscapeCardWidth, alignment: .leading)
                }

                // Next maneuver (compact, below instruction)
                if !engine.followOnInstruction.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: engine.followOnManeuverSymbol)
                            .font(.system(size: 13 * iconScale, weight: .semibold))
                            .foregroundStyle(SteddiTheme.accent.opacity(0.7))
                        Text("Then: \(displayFollowOnInstruction)")
                            .font(SteddiTheme.body(13 * textScale, highContrast: highContrast))
                            .foregroundStyle(SteddiTheme.textMuted(highContrast: highContrast))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(width: landscapeCardWidth, alignment: .leading)
                    .steddiGlass(tint: nil, interactive: false, in: RoundedRectangle(cornerRadius: 12))
                }

                if !activePreferenceLabels.isEmpty {
                    SteddiRoutePrefBadge(
                        labels: activePreferenceLabels,
                        textScale: textScale,
                        iconScale: iconScale,
                        highContrast: highContrast
                    )
                    .frame(width: landscapeCardWidth, alignment: .leading)
                }

                Spacer()
            }
            .padding(.leading, 50) // clear notch
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Bottom-left: buttons row + ETA + speedometer + End
            VStack(spacing: 6) {
                // Buttons — horizontal row above the ETA bar, left aligned.
                // Grouped glass so the row reads as one floating control cluster.
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 10) {
                        landscapeCompassIndicator
                        landscapeButton(isVoiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill", isActive: isVoiceOn) {
                            isVoiceOn.toggle()
                            VoiceGuidanceService.shared.enabled = isVoiceOn
                        }
                        landscapeButton(is3DView ? "cube" : "square", isActive: is3DView) { is3DView.toggle(); onToggleView(is3DView) }
                        landscapeButton("exclamationmark.bubble.fill") { showReportSheet = true }
                    }
                }

                // ETA bar
                HStack(spacing: 12) {
                    speedometer(size: 44 * iconScale)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) {
                            Text("\(engine.etaMinutes)")
                                .font(SteddiTheme.mono(22 * textScale))
                                .foregroundStyle(SteddiTheme.textPrimary)
                            Text("min")
                                .font(SteddiTheme.body(13 * textScale, highContrast: highContrast))
                                .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                        }
                        HStack(spacing: 6) {
                            Text(engine.distanceRemaining)
                                .font(SteddiTheme.mono(12 * textScale))
                                .foregroundStyle(SteddiTheme.textMuted(highContrast: highContrast))
                            Text(engine.arrivalTime)
                                .font(SteddiTheme.mono(12 * textScale))
                                .foregroundStyle(SteddiTheme.textMuted(highContrast: highContrast))
                        }
                    }

                    Button("End", action: onEndNavigation)
                        .font(.system(size: 17 * textScale, weight: .semibold))
                        .padding(.horizontal, 20 * controlScale)
                        .padding(.vertical, 10 * controlScale)
                        .buttonStyle(.glassProminent)
                        .tint(SteddiTheme.warmRed)
                }
                .padding(12)
                .steddiGlass(tint: nil, interactive: false, in: SteddiGlass.mediumShape, fallbackStrokeOpacity: 0.08)
            }
            .padding(.leading, 50) // clear notch
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            // Street name: centered bottom
            if !engine.roadName.isEmpty {
                Text(engine.roadName)
                    .font(SteddiTheme.body(13 * textScale, highContrast: highContrast))
                    .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .steddiGlass(tint: nil, interactive: false, in: Capsule(), fallbackStrokeOpacity: 0.25)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Top Banner

    private var topBanner: some View {
        HStack(spacing: 16) {
            // Maneuver icon — large and prominent. Bounces once on arrival.
            Image(systemName: engine.maneuverType)
                .font(.system(size: 40 * iconScale, weight: .bold))
                .foregroundStyle(SteddiTheme.accent)
                .frame(width: 72 * iconScale, height: 72 * iconScale)
                .background(
                    engine.hasArrived ? SteddiTheme.accent.opacity(0.28) : SteddiTheme.accentSubtle,
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .scaleEffect(arrivalCelebrating ? 1.3 : 1.0)
                .animation(TransitionKit.arrivalBounce, value: arrivalCelebrating)

            VStack(alignment: .leading, spacing: 6) {
                // Distance — LARGE mono for glanceability
                Text(engine.stepDistance)
                    .font(SteddiTheme.mono(34 * textScale))
                    .foregroundStyle(SteddiTheme.textPrimary)
                    .minimumScaleFactor(0.7)

                // Instruction — clear and readable
                Text(displayInstruction)
                    .font(SteddiTheme.body(18 * textScale, highContrast: highContrast))
                    .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.7)
            }

            Spacer()
        }
        .padding(20)
        // Single neutral glass layer replaces the old material+surface double
        // background — legibility over the map matters more than tint here.
        .steddiGlass(tint: nil, interactive: false, in: SteddiGlass.cardShape)
    }

    // MARK: - Trip Leg Banner

    /// Leg counter + next-stop name + trip-aware remaining summary, shown
    /// only during trip navigation.
    private func tripLegBanner(_ trip: TripNavContext) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up.fill")
                .font(.system(size: 12 * iconScale, weight: .semibold))
                .foregroundStyle(SteddiTheme.accent)

            Text("Leg \(trip.legIndex) of \(trip.totalLegs) · \(trip.nextStopName)")
                .font(SteddiTheme.body(13 * textScale, highContrast: highContrast))
                .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                .lineLimit(1)

            Spacer()

            if let summary = trip.remainingSummary {
                Text(summary)
                    .font(SteddiTheme.mono(12 * textScale))
                    .foregroundStyle(SteddiTheme.textMuted(highContrast: highContrast))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .steddiGlass(tint: nil, interactive: false, in: SteddiGlass.mediumShape)
    }

    // MARK: - Follow-On Banner

    private var followOnBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: engine.followOnManeuverSymbol)
                .font(.system(size: 16 * iconScale, weight: .semibold))
                .foregroundStyle(SteddiTheme.accent.opacity(0.7))
                .frame(width: 28 * iconScale, height: 28 * iconScale)

            Text("Then: \(displayFollowOnInstruction)")
                .font(SteddiTheme.body(14 * textScale, highContrast: highContrast))
                .foregroundStyle(SteddiTheme.textMuted(highContrast: highContrast))
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .steddiGlass(tint: nil, interactive: false, in: SteddiGlass.mediumShape, fallbackStrokeOpacity: 0.08)
    }

    // MARK: - Street Name Capsule

    private var streetNameCapsule: some View {
        Text(engine.roadName)
            .font(SteddiTheme.body(14 * textScale, highContrast: highContrast))
            .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .steddiGlass(tint: nil, interactive: false, in: Capsule(), fallbackStrokeOpacity: 0.25)
    }

    // MARK: - Speed Camera Banner

    /// Subtle heads-up for an enforcement camera ahead. Clean and quiet by
    /// design — a single chip with the camera kind and distance, not a flashing
    /// klaxon. The tone/haptic fire once via the engine callback; this banner
    /// just persists while the camera stays in range.
    private func speedCameraBanner(_ camera: SpeedCameraAlert) -> some View {
        HStack(spacing: 12) {
            Image(systemName: camera.kind.icon)
                .font(.system(size: 18 * iconScale, weight: .semibold))
                .foregroundStyle(camera.kind.color)
                .frame(width: 34 * iconScale, height: 34 * iconScale)
                .background(camera.kind.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text("\(camera.kind.displayName) ahead")
                    .font(SteddiTheme.body(15 * textScale, highContrast: highContrast))
                    .foregroundStyle(SteddiTheme.textPrimary)
                Text(formatDistance(camera.distanceMeters))
                    .font(SteddiTheme.mono(13 * textScale))
                    .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        // Single glass layer tinted with the camera's semantic color, keeping
        // the kind's color identity that the old stroke carried.
        .steddiGlass(tint: camera.kind.color, interactive: false, in: SteddiGlass.mediumShape, fallbackStrokeOpacity: 0.35)
    }

    // MARK: - Floating Buttons

    private var compassIndicator: some View {
        Text(compassLabel)
            .font(.system(size: 15 * textScale, weight: .heavy, design: .rounded))
            .foregroundStyle(SteddiTheme.accent.opacity(compassSector == nil ? 0.35 : 1))
            .frame(width: 44 * iconScale, height: 44 * iconScale)
            // Neutral glass readout — not a toggle, so no accent tint.
            .steddiGlass(tint: nil, interactive: false, in: .circle)
    }

    private static let compassLabels = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    /// Cardinal letter for the engine's travel bearing — dimmed dash until the
    /// first valid bearing arrives.
    private var compassLabel: String {
        compassSector.map { Self.compassLabels[$0] } ?? "–"
    }

    /// Update the 45-degree compass sector with hysteresis: the letter only
    /// changes once the bearing is ~9 degrees past a 22.5-degree sector
    /// boundary, so it can't flap between two letters on a wavering bearing.
    private func updateCompassSector(for degrees: Double?) {
        guard let degrees else { return }
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)

        if let current = compassSector {
            let center = Double(current) * 45.0
            var diff = normalized - center
            if diff > 180 { diff -= 360 }
            if diff < -180 { diff += 360 }
            if abs(diff) <= 22.5 + 9 { return }
        }

        compassSector = Int(((normalized + 22.5).truncatingRemainder(dividingBy: 360)) / 45.0) % 8
    }

    /// One-shot arrival celebration: the maneuver icon springs 1.0 → 1.3 → 1.0.
    /// The engine already fires the arrival haptic and swaps the icon to a flag;
    /// this is the visual flourish on top. No-op under Reduce Motion (the spring
    /// resolves to nil), so the icon just settles at full size.
    private func triggerArrivalCelebration() {
        guard SteddiMotion.shouldAnimate else { return }
        withAnimation(TransitionKit.arrivalBounce) { arrivalCelebrating = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + TransitionKit.springArrival.response) {
            withAnimation(TransitionKit.arrivalBounce) { arrivalCelebrating = false }
        }
    }

    private var voiceButton: some View {
        Button {
            isVoiceOn.toggle()
            VoiceGuidanceService.shared.enabled = isVoiceOn
            HapticService.shared.fire(.uiToggle)
        } label: {
            floatingButtonCircle(
                symbol: isVoiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                isActive: isVoiceOn
            )
        }
        .buttonStyle(.steddiPress)
    }

    private var viewToggleButton: some View {
        Button {
            is3DView.toggle()
            onToggleView(is3DView)
            HapticService.shared.fire(.uiToggle)
        } label: {
            floatingButtonCircle(
                symbol: is3DView ? "cube" : "square",
                isActive: is3DView
            )
        }
        .buttonStyle(.steddiPress)
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
        .buttonStyle(.steddiPress)
    }

    private var landscapeCompassIndicator: some View {
        Text(compassLabel)
            .font(.system(size: 16 * textScale, weight: .heavy, design: .rounded))
            .foregroundStyle(SteddiTheme.accent.opacity(compassSector == nil ? 0.35 : 1))
            .frame(width: 50 * iconScale, height: 50 * iconScale)
            .steddiGlass(tint: nil, interactive: false, in: .circle)
    }

    private func landscapeButton(_ symbol: String, isActive: Bool = false, rotationDegrees: Double = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20 * controlScale, weight: .medium))
                .foregroundStyle(SteddiTheme.accent)
                .rotationEffect(.degrees(rotationDegrees))
                .frame(width: 50 * controlScale, height: 50 * controlScale)
                // Glass replaces the solid circle + manual shadow; active
                // toggles (voice on, 3D on) carry the accent tint.
                .steddiGlass(
                    tint: isActive ? SteddiTheme.accent : nil,
                    interactive: true,
                    in: .circle
                )
        }
        .buttonStyle(.steddiPress)
    }

    private func floatingButtonCircle(symbol: String, isActive: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17 * controlScale, weight: .medium))
            .foregroundStyle(isActive ? SteddiTheme.accent : SteddiTheme.textMuted(highContrast: highContrast))
            .frame(width: 44 * controlScale, height: 44 * controlScale)
            // Glass replaces the solid circle + manual shadow; active controls
            // (voice on, 3D on) carry the accent tint, inactive read neutral.
            .steddiGlass(
                tint: isActive ? SteddiTheme.accent : nil,
                interactive: true,
                in: .circle
            )
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: 0) {
            // Speedometer — left
            speedometer(size: 64 * iconScale)

            // ETA block — center
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text("\(engine.etaMinutes)")
                        .font(SteddiTheme.mono(32 * textScale))
                        .foregroundStyle(SteddiTheme.textPrimary)
                    Text("min")
                        .font(SteddiTheme.body(14 * textScale, highContrast: highContrast))
                        .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                        .padding(.top, 8)
                }

                HStack(spacing: 8) {
                    Text(engine.distanceRemaining)
                        .font(SteddiTheme.mono(13 * textScale))
                        .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))

                    Circle()
                        .fill(SteddiTheme.textMuted)
                        .frame(width: 3, height: 3)

                    Text(engine.arrivalTime)
                        .font(SteddiTheme.mono(13 * textScale))
                        .foregroundStyle(SteddiTheme.textMuted(highContrast: highContrast))
                }
            }
            .frame(maxWidth: .infinity)

            // End button — right. Destructive, so warm-red prominent glass.
            Button("End", action: onEndNavigation)
                .font(.system(size: 17 * textScale, weight: .semibold))
                .padding(.horizontal, 24 * controlScale)
                .padding(.vertical, 12 * controlScale)
                .buttonStyle(.glassProminent)
                .tint(SteddiTheme.warmRed)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        // Single neutral glass layer replaces the material+surface double bg.
        .steddiGlass(
            tint: nil,
            interactive: false,
            in: UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusLarge, topTrailingRadius: SteddiTheme.radiusLarge),
            fallbackStrokeOpacity: 0.08
        )
    }

    // MARK: - Speedometer

    private func speedometer(size: CGFloat) -> some View {
        let speedLimitMph: Double? = engine.speedLimitMph
        let overLimit: Double = {
            guard let limit = speedLimitMph else { return 0 }
            return engine.currentSpeedMph - limit
        }()

        let speedColor: Color = {
            if overLimit > 8 { return SteddiTheme.warmRed }
            if overLimit > 0 { return SteddiTheme.warningAmber }
            return SteddiTheme.textPrimary
        }()

        // Over-limit warning stays a SOLID warmRedSubtle fill — a safety readout
        // must never lose contrast to translucency. Otherwise the housing is
        // neutral glass.
        let isWarning = overLimit > 8

        let scale = size / 64.0

        return ZStack(alignment: .topTrailing) {
            ZStack {
                // Background housing: solid in the warning state, glass otherwise.
                Group {
                    if isWarning {
                        Circle().fill(SteddiTheme.warmRedSubtle)
                    } else {
                        Circle().fill(.clear).steddiGlass(tint: nil, interactive: false, in: .circle)
                    }
                }
                .overlay(
                    Circle()
                        .stroke(speedColor.opacity(0.3), lineWidth: 2)
                )

                // Speed arc gauge
                Circle()
                    .trim(from: 0, to: min(1.0, engine.currentSpeedMph / max(1, (speedLimitMph ?? 65) * 1.3)))
                    .stroke(speedColor.opacity(0.5), style: StrokeStyle(lineWidth: max(2, 3 * scale), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3 * scale)

                // Speed value
                VStack(spacing: 0) {
                    Text("\(Int(engine.currentSpeedMph))")
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
                    .foregroundStyle(overLimit > 0 ? SteddiTheme.warmRed
                                     : engine.speedLimitIsEstimated ? SteddiTheme.textMuted
                                     : SteddiTheme.textPrimary)
                    .frame(width: 22 * scale, height: 22 * scale)
                    .background(
                        Circle()
                            .fill(SteddiTheme.surfacePrimary)
                            .overlay(Circle().stroke(
                                overLimit > 0 ? SteddiTheme.warmRed : SteddiTheme.textMuted.opacity(0.5),
                                lineWidth: 1.5))
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
                cameraReportOption(.speedCamera)
                cameraReportOption(.redLightCamera)
                cameraReportOption(.mobileSpeedTrap)
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
    }

    private func reportOption(icon: String, label: String, color: Color) -> some View {
        Button {
            reportedType = label
            showReportSheet = false
            if let coord = engine.currentCoordinate {
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
                    .font(.system(size: 20 * iconScale))
                    .foregroundStyle(color)
                    .frame(width: 32 * iconScale)

                Text(label)
                    .font(SteddiTheme.body(17 * textScale, highContrast: highContrast))
                    .foregroundStyle(SteddiTheme.textPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SteddiTheme.textMuted(highContrast: highContrast))
            }
            .padding(.vertical, 4 * controlScale)
        }
        .listRowBackground(SteddiTheme.surfaceSecondary)
    }

    /// Report option for an enforcement camera — routes to `onReportCamera` so it
    /// persists as a `CameraReport` and feeds the proximity index, then shows the
    /// same confirmation toast as a generic report.
    private func cameraReportOption(_ kind: CameraReportKind) -> some View {
        Button {
            reportedType = kind.displayName
            showReportSheet = false
            if let coord = engine.currentCoordinate {
                onReportCamera?(kind, coord)
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
                Image(systemName: kind.icon)
                    .font(.system(size: 20 * iconScale))
                    .foregroundStyle(kind.color)
                    .frame(width: 32 * iconScale)

                Text(kind.displayName)
                    .font(SteddiTheme.body(17 * textScale, highContrast: highContrast))
                    .foregroundStyle(SteddiTheme.textPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SteddiTheme.textMuted(highContrast: highContrast))
            }
            .padding(.vertical, 4 * controlScale)
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
        // Neutral glass capsule; the sage checkmark icon carries the meaning.
        .steddiGlass(tint: nil, interactive: false, in: Capsule(), fallbackStrokeOpacity: 0.3)
    }

    // MARK: - Reroute Loop

    private func startRerouteLoop() {
        guard let commute, let direction else { return }

        Task { @MainActor in
            let directionsService = DirectionsService()

            while !Task.isCancelled && !engine.hasArrived {
                try? await Task.sleep(for: .seconds(300)) // 5 min safety net poll
                guard !Task.isCancelled, !engine.hasArrived else { break }
                guard rerouteSuggestion == nil else { continue }

                guard let currentCoord = engine.currentCoordinate,
                      engine.isNavigating else { continue }

                let remainingETA = Double(engine.etaMinutes) * 60.0
                currentRemainingETA = remainingETA

                // Check each fallback route
                let fallbacks = commute.orderedRoutes(for: direction).filter { $0.rank > 0 }
                guard !fallbacks.isEmpty else { continue }

                var bestSuggestion: (route: Route, savingsMinutes: Double, savingsPercentage: Double)?
                var bestSavings: TimeInterval = 0

                for fallback in fallbacks {
                    do {
                        let fallbackETA = try await directionsService.fetchETA(
                            from: currentCoord,
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
                                savingsPercentage: remainingETA > 0 ? decision.savingsSeconds / remainingETA : 0
                            )
                        }
                    } catch {
                        continue
                    }
                }

                if let suggestion = bestSuggestion {
                    withAnimation(TransitionKit.rerouteSpringIn) {
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
}

// MARK: - Trip Nav Context

/// Per-leg trip context the overlay (and Live Activity bridge) renders during
/// multi-stop trip navigation.
struct TripNavContext: Equatable {
    let tripName: String
    let legIndex: Int        // 1-based
    let totalLegs: Int
    let nextStopName: String
    /// Trip-aware remaining summary across all legs, e.g. "1h 45m · 3 more stops"
    let remainingSummary: String?
}
