import SwiftUI
import CoreLocation
import AVFoundation

/// Custom Steddi turn-by-turn overlay — replaces stock navigation UI.
/// Uses NavigationEngine for routing brain, renders its own SwiftUI interface.
struct SteddiNavOverlay: View {
    @AppStorage("accentColor") private var accentColor = "lavender"
    @AppStorage(ThemeModeEx.defaultsKey) private var themeModeEx: String = ThemeModeEx.dynamic.rawValue

    /// A presented sheet gets its own presentation context and does not reliably
    /// inherit the presenter's `.preferredColorScheme`, so pin the app theme on
    /// the report sheet too — otherwise its grouped List chrome renders in the
    /// device appearance and mismatches Steddi when the chosen theme differs from
    /// the device.
    private var resolvedColorScheme: ColorScheme? {
        (ThemeModeEx(rawValue: themeModeEx) ?? .dynamic).colorScheme
    }

    let engine: NavigationEngine
    let onEndNavigation: () -> Void
    var onToggleVoice: () -> Void = {}
    var onToggleView: (Bool) -> Void = { _ in }
    /// The driver tapped "Switch" on a reroute suggestion. Carries the suggested
    /// route's `id` (a value), NOT a live `@Model Route`: the card holds only a
    /// detached snapshot, and HomeView re-resolves the live `Route` by id at this
    /// moment (gracefully dismissing if it was deleted mid-display).
    var onSwitchRoute: ((UUID) -> Void)? = nil
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

    // Reroute suggestion — read from the shared manager, which owns the single
    // periodic reroute-evaluation loop (NavigationStateManager.rerouteTask). The
    // overlay and the CarPlay companion both read/clear this one source so a
    // dismissed suggestion actually unblocks the manager's re-evaluation guard.
    @State private var navState = NavigationStateManager.shared

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

    /// Dependency-only: touching this re-resolves `glassAvailable` (and therefore
    /// the speed-camera banner's foreground) when Reduce Transparency / Increase
    /// Contrast toggles mid-drive, exactly like `steddiGlass` / `mapGlassScrim`.
    @Environment(\.glassRevision) private var glassRevision

    /// Whether Liquid Glass renders (vs. the solid fallback). Read imperatively —
    /// the `glassRevision` dependency above keeps it re-resolving on a
    /// Reduce-Transparency / Increase-Contrast toggle so the camera-banner
    /// foreground and the actual banner surface can never disagree.
    private var glassAvailable: Bool {
        _ = glassRevision
        return SteddiGlass.isAvailable
    }

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
                    NowPlayingMiniBar(service: nowPlaying, textScale: textScale, highContrast: highContrast)
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

                if let suggestion = navState.rerouteSuggestion {
                    RerouteCardView(
                        // Value snapshot — reads only the detached name/savings, never
                        // a live @Model, so a mid-display deletion can't trap a render.
                        routeName: suggestion.routeName ?? "Faster route",
                        // The engine only surfaces a suggestion it has already
                        // vetted as worthwhile, so a sub-minute saving must never
                        // render "Save ~0 min". Round (not floor) and clamp to ≥1.
                        timeSavingsMinutes: max(1, Int(suggestion.savingsMinutes.rounded())),
                        percentageSavings: Int(suggestion.savingsPercentage * 100),
                        onSwitch: {
                            onSwitchRoute?(suggestion.routeID)
                            navState.rerouteSuggestion = nil
                        },
                        onStay: { navState.dismissRerouteSuggestion() },
                        // Countdown timeout is not a decline: clear without
                        // arming the 10-minute suppression.
                        onAutoDismiss: { navState.expireRerouteSuggestion() }
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
            // Anchor the cluster below the (scaling) banner column rather than a
            // fixed offset, so it never overlaps the banners under large Dynamic
            // Type / accessibility icon scale.
            .padding(.top, floatingClusterTopOffset)
            .scaleEffect(floatingButtonsAppeared ? 1.0 : 0.6)
            .opacity(floatingButtonsAppeared ? 1.0 : 0.0)
        }
    }

    /// Top offset for the portrait floating-control cluster, derived from the
    /// FULL stacked column's actual scaled height so the controls always start
    /// below the tallest stack. The elements scale with iconScale/textScale; a
    /// fixed offset (the old hardcoded 270) overlapped them once the type grew.
    /// Mirrors the portrait stack geometry exactly (lines 146-185): top inset
    /// (60) + top banner + the optional trip-leg / follow-on banners + the
    /// optional street-name capsule, route-preference badge, and the full-width
    /// NowPlaying mini-bar — each only when actually present, with its own top
    /// spacing — plus a small gap, so the right cluster never lands on top of the
    /// mini-bar / badge / capsule when those are showing.
    private var floatingClusterTopOffset: CGFloat {
        let topInset: CGFloat = 60
        // Top banner: 72*iconScale icon framed inside 20pt padding all round.
        let topBannerHeight = max(72 * iconScale, 34 * textScale * 2) + 40
        var height = topInset + topBannerHeight
        if tripContext != nil {
            // Leg banner: ~13pt label in 9pt vertical padding, +6 spacing above.
            height += 6 + (13 * textScale + 18)
        }
        if !engine.followOnInstruction.isEmpty {
            // Follow-on banner: 28*iconScale icon frame in 10pt vertical padding,
            // +6 spacing above.
            height += 6 + (28 * iconScale + 20)
        }
        if !engine.roadName.isEmpty {
            // Street-name capsule: 14pt label in 7pt vertical padding, +10 above.
            height += 10 + (14 * textScale + 14)
        }
        if !activePreferenceLabels.isEmpty {
            // Route-pref badge: 12pt label in 6pt vertical padding, +10 above.
            height += 10 + (12 * textScale + 12)
        }
        if showNowPlayingBar && nowPlaying.hasNowPlaying {
            // NowPlaying mini-bar: fixed 52pt full-width card, +8 spacing above.
            // Full-width, so its right edge sits directly under the cluster —
            // the decisive element this offset must clear.
            height += 8 + 52
        }
        // Small gap below the stacked column before the controls begin. Never sit
        // higher than the original hand-tuned 270 in the unscaled default state.
        return max(270, height + 12)
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
                            .legibleOverMap()
                        // Safety-critical maneuver — must be as protected in
                        // landscape as portrait. Match the portrait top banner:
                        // textPrimary at semibold + the shared soft shadow, never
                        // the mid-grey textSecondary that is only AA-proven on
                        // solid surfaces, not glass over a moving map.
                        Text(displayInstruction)
                            .font(SteddiTheme.body(15 * textScale, highContrast: highContrast).weight(.semibold))
                            .foregroundStyle(SteddiTheme.textPrimary)
                            .legibleOverMap()
                            .lineLimit(2)
                    }
                }
                .padding(14)
                .frame(width: landscapeCardWidth, alignment: .leading)
                // Faint scrim under the glass, exactly like the portrait top
                // banner, so the maneuver holds against bright/varied cartography.
                .mapGlassScrim(in: SteddiGlass.mediumShape)
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
                        // Follow-on is real driving info over the moving map —
                        // promote to textSecondary (textMuted's AA holds only on
                        // solid surfaces) + the shared soft shadow, matching the
                        // portrait follow-on banner.
                        Text("Then: \(displayFollowOnInstruction)")
                            .font(SteddiTheme.body(13 * textScale, highContrast: highContrast).weight(.medium))
                            .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                            .legibleOverMap()
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(width: landscapeCardWidth, alignment: .leading)
                    // Faint scrim under the glass, matching the portrait
                    // follow-on banner, so the next-maneuver readout holds
                    // against bright/varied cartography.
                    .mapGlassScrim(in: RoundedRectangle(cornerRadius: 12))
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
                        landscapeButton(
                            isVoiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                            isActive: isVoiceOn,
                            accessibilityLabel: "Voice guidance",
                            accessibilityValue: isVoiceOn ? "On" : "Off"
                        ) {
                            isVoiceOn.toggle()
                            VoiceGuidanceService.shared.enabled = isVoiceOn
                        }
                        landscapeButton(
                            is3DView ? "cube" : "square",
                            isActive: is3DView,
                            accessibilityLabel: "Map perspective",
                            accessibilityValue: is3DView ? "3D" : "2D",
                            accessibilityHint: "Switches between a 3D and overhead 2D map"
                        ) { is3DView.toggle(); onToggleView(is3DView) }
                        landscapeButton(
                            "exclamationmark.bubble.fill",
                            accessibilityLabel: "Report",
                            accessibilityHint: "Report a hazard, police, camera, or closure ahead"
                        ) { showReportSheet = true }
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
                                .legibleOverMap()
                            Text("min")
                                .font(SteddiTheme.body(13 * textScale, highContrast: highContrast))
                                .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                                .legibleOverMap()
                        }
                        // Meaningful readouts over translucent nav glass on a
                        // moving map — textSecondary, not textMuted (whose AA
                        // guarantee is only against the solid surface tokens) —
                        // plus the shared soft shadow so they hold against any tile.
                        HStack(spacing: 6) {
                            Text(engine.distanceRemaining)
                                .font(SteddiTheme.mono(12 * textScale))
                                .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                                .legibleOverMap()
                            Text(engine.arrivalTime)
                                .font(SteddiTheme.mono(12 * textScale))
                                .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                                .legibleOverMap()
                        }
                    }

                    // Destructive CTA: warmRed glass fill + the AA-correct
                    // on-fill label from the style. Was `.glassProminent
                    // .tint(warmRed)` — the forced-white-label path the codebase
                    // bans (white-on-warmRed only clears the 3:1 large floor and
                    // silently drops below AA if warmRed lightens or the label
                    // shrinks under Dynamic Type).
                    Button("End", action: onEndNavigation)
                        .font(.system(size: 17 * textScale, weight: .semibold))
                        .padding(.horizontal, 20 * controlScale)
                        .padding(.vertical, 10 * controlScale)
                        .buttonStyle(.steddiDestructive)
                }
                .padding(12)
                // Faint scrim under the glass (same shape) like the bottom bar,
                // so the ETA / distance / arrival readouts hold against any tile.
                .mapGlassScrim(in: SteddiGlass.mediumShape)
                .steddiGlass(tint: nil, interactive: false, in: SteddiGlass.mediumShape, fallbackStrokeOpacity: 0.08)
            }
            .padding(.leading, 50) // clear notch
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            // Street name: centered bottom
            if !engine.roadName.isEmpty {
                Text(engine.roadName)
                    .font(SteddiTheme.body(13 * textScale, highContrast: highContrast).weight(.medium))
                    .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                    // Street name rides neutral glass over the moving map — the
                    // shared soft shadow so it holds against any tile, matching
                    // the portrait street-name capsule.
                    .legibleOverMap()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    // Faint scrim under the glass, matching the portrait
                    // street-name capsule, so the current-street name holds
                    // against bright/varied cartography.
                    .mapGlassScrim(in: Capsule())
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
                    // The shared soft per-glyph shadow every other HUD readout over
                    // the map carries (the sibling instruction below, the landscape
                    // distance twin) — this large distance value was the only one
                    // missing it, so it now matches.
                    .legibleOverMap()
                    .minimumScaleFactor(0.7)

                // Instruction — the safety-critical maneuver words. This is the
                // single most important readout in the HUD, so it gets the
                // strongest treatment: textPrimary (near-black in LIGHT theme,
                // near-white in DARK) at semibold weight plus the soft shadow the
                // compass uses. Its legibility against the glass over a moving map
                // is carried by the over-map scrim below — a near-opaque fixed-
                // dark fill in DARK theme (so this near-white text reads white-on-
                // dark) and the faint approved wash in LIGHT theme.
                Text(displayInstruction)
                    .font(SteddiTheme.body(18 * textScale, highContrast: highContrast).weight(.semibold))
                    .foregroundStyle(SteddiTheme.textPrimary)
                    .legibleOverMap()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.7)
            }

            Spacer()
        }
        .padding(20)
        // Neutral glass with the shared faint scrim underneath. The scrim lifts
        // the glass off bright/varied cartography so the safety-critical
        // instruction never washes out, while keeping the Liquid Glass aesthetic
        // on top (skipped when glass is off — the fallback is already opaque).
        .mapGlassScrim(in: SteddiGlass.cardShape)
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
                .font(SteddiTheme.body(13 * textScale, highContrast: highContrast).weight(.medium))
                .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                .legibleOverMap()
                .lineLimit(1)

            Spacer()

            if let summary = trip.remainingSummary {
                // Meaningful readout over translucent nav glass — textSecondary
                // (not textMuted, AA-guaranteed only on solid surfaces) with the
                // compass's soft shadow so it holds against any tile.
                Text(summary)
                    .font(SteddiTheme.mono(12 * textScale))
                    .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                    .legibleOverMap()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // Faint scrim under the glass, like the top banner / bottom bar, so the
        // leg-context readout holds against bright/varied cartography — the soft
        // shadow alone leaves textSecondary washing out on light tiles.
        .mapGlassScrim(in: SteddiGlass.mediumShape)
        .steddiGlass(tint: nil, interactive: false, in: SteddiGlass.mediumShape)
    }

    // MARK: - Follow-On Banner

    private var followOnBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: engine.followOnManeuverSymbol)
                .font(.system(size: 16 * iconScale, weight: .semibold))
                .foregroundStyle(SteddiTheme.accent.opacity(0.7))
                .frame(width: 28 * iconScale, height: 28 * iconScale)

            // The follow-on maneuver is real driving info over translucent nav
            // glass. Secondary to the main instruction, so it stays on the
            // textSecondary tier — but at medium weight + the compass's soft
            // shadow so the words separate from any tile (textSecondary's AA is
            // only proven on solid surfaces, not glass over a moving map).
            Text("Then: \(displayFollowOnInstruction)")
                .font(SteddiTheme.body(14 * textScale, highContrast: highContrast).weight(.medium))
                .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                .legibleOverMap()
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Faint scrim under the glass, like the top banner / bottom bar, so the
        // next-maneuver readout holds against bright/varied cartography — the
        // soft shadow alone leaves textSecondary washing out on light tiles.
        .mapGlassScrim(in: SteddiGlass.mediumShape)
        .steddiGlass(tint: nil, interactive: false, in: SteddiGlass.mediumShape, fallbackStrokeOpacity: 0.08)
    }

    // MARK: - Street Name Capsule

    private var streetNameCapsule: some View {
        Text(engine.roadName)
            // The current street name rides neutral glass over the moving map —
            // medium weight + the compass's soft shadow so it holds against any
            // tile (textSecondary's AA is only proven on solid surfaces).
            .font(SteddiTheme.body(14 * textScale, highContrast: highContrast).weight(.medium))
            .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
            .legibleOverMap()
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            // Faint scrim under the glass, like the top banner / bottom bar, so
            // the current-street name holds against bright/varied cartography —
            // the soft shadow alone leaves textSecondary washing out on light
            // tiles.
            .mapGlassScrim(in: Capsule())
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
                // The glyph sits ON a chip filled with the kind's own color, so it
                // must contrast that FILL — drawing it in the same color family
                // washed it out on a same-hue fill in light/dynamic-day themes
                // (~1.2:1 amber, ~2.0:1 warmRed). `contrastingForeground(on:)`
                // picks the legible near-black/white per fill, clearing the 3:1
                // glyph floor in every theme — the established on-fill rule (see
                // RoadConditionKind.selectedChipForeground). The chip carries the
                // full kind color so contrast is carried by the fill, and the
                // soft shadow matches the banner's sibling labels.
                .foregroundStyle(SteddiTheme.contrastingForeground(on: camera.kind.kindRGB))
                .frame(width: 34 * iconScale, height: 34 * iconScale)
                .background(camera.kind.color, in: RoundedRectangle(cornerRadius: 10))
                .legibleOverMap()

            VStack(alignment: .leading, spacing: 2) {
                // The glass is tinted with the camera's KIND color, so the title +
                // distance sit on a semantically-COLORED surface. Drawing them in
                // `contrastingForeground(on: kind.kindRGB)` (contrasting the RAW kind
                // hue) was correct in LIGHT theme but WRONG in DARK: the ACTUAL
                // rendered surface there is the kind tint composited over the
                // near-opaque dark `mapGlassScrim`, a DARK surface — so the near-black
                // the raw hue resolved to measured ~1.3:1 (the recurring
                // tinted-glass-over-dark-scrim mismatch). `cameraBannerForeground`
                // contrasts the REAL composite surface per theme (keeping the kind
                // tint), resolving near-black on the light tint and near-white on the
                // dark composite — ≥4.5:1 body in both themes for every kind. The
                // glyph chip above is unchanged: it sits on the SOLID kind fill, so
                // `contrastingForeground(on: kind.kindRGB)` is the right surface there.
                Text("\(camera.kind.displayName) ahead")
                    .font(SteddiTheme.body(15 * textScale, highContrast: highContrast))
                    .foregroundStyle(SteddiTheme.cameraBannerForeground(kind: camera.kind.kindRGB, glassAvailable: glassAvailable))
                    .legibleOverMap()
                Text(formatDistance(camera.distanceMeters))
                    .font(SteddiTheme.mono(13 * textScale))
                    .foregroundStyle(SteddiTheme.cameraBannerForeground(kind: camera.kind.kindRGB, glassAvailable: glassAvailable))
                    .legibleOverMap()
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        // Faint scrim under the glass, like the top banner / bottom bar, so this
        // safety heads-up holds against bright/varied cartography — the camera
        // tint alone is a semantic-identity overlay, not the contrast backing the
        // rest of the nav glass relies on (textSecondary's AA is only proven on
        // solid surfaces, not Liquid Glass over a moving map).
        .mapGlassScrim(in: SteddiGlass.mediumShape)
        // Glass layer tinted with the camera's semantic color, keeping the
        // kind's color identity that the old stroke carried.
        .steddiGlass(tint: camera.kind.color, interactive: false, in: SteddiGlass.mediumShape, fallbackStrokeOpacity: 0.35)
    }

    // MARK: - Floating Buttons

    private var compassIndicator: some View {
        Text(compassLabel)
            .font(.system(size: 15 * textScale, weight: .heavy, design: .rounded))
            // The compass letter is a READOUT riding neutral nav glass over a
            // moving map, so it needs a treatment that holds against any tile —
            // not the surface-sized text-safe accent (AA only proven on the solid
            // surface). Use textPrimary (the strongest surface-adaptive token,
            // promoted like the sibling nav readouts) plus a soft shadow so it
            // separates from bright/varied cartography on every theme.
            .foregroundStyle(SteddiTheme.textPrimary.opacity(compassSector == nil ? 0.35 : 1))
            .legibleOverMap()
            .frame(width: 44 * iconScale, height: 44 * iconScale)
            // Neutral glass readout — not a toggle, so no accent tint.
            .steddiGlass(tint: nil, interactive: false, in: .circle)
            // A bare letter ("N"/"NE") is cryptic to VoiceOver — speak the full
            // cardinal direction as a heading readout instead.
            .accessibilityLabel("Heading")
            .accessibilityValue(compassSpokenValue)
    }

    private static let compassLabels = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    private static let compassSpokenLabels = [
        "North", "Northeast", "East", "Southeast",
        "South", "Southwest", "West", "Northwest"
    ]

    /// Cardinal letter for the engine's travel bearing — dimmed dash until the
    /// first valid bearing arrives.
    private var compassLabel: String {
        compassSector.map { Self.compassLabels[$0] } ?? "–"
    }

    /// Spoken cardinal direction for VoiceOver — full word, or "Unavailable"
    /// until the first valid bearing arrives.
    private var compassSpokenValue: String {
        compassSector.map { Self.compassSpokenLabels[$0] } ?? "Unavailable"
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
        .accessibilityLabel("Voice guidance")
        .accessibilityValue(isVoiceOn ? "On" : "Off")
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
        .accessibilityLabel("Map perspective")
        .accessibilityValue(is3DView ? "3D" : "2D")
        .accessibilityHint("Switches between a 3D and overhead 2D map")
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
        .accessibilityLabel("Report")
        .accessibilityHint("Report a hazard, police, camera, or closure ahead")
    }

    private var landscapeCompassIndicator: some View {
        Text(compassLabel)
            .font(.system(size: 16 * textScale, weight: .heavy, design: .rounded))
            // See compassIndicator: textPrimary + soft shadow guarantees the
            // readout over a moving map, rather than the surface-sized accent.
            .foregroundStyle(SteddiTheme.textPrimary.opacity(compassSector == nil ? 0.35 : 1))
            .legibleOverMap()
            .frame(width: 50 * iconScale, height: 50 * iconScale)
            .steddiGlass(tint: nil, interactive: false, in: .circle)
            // See compassIndicator: speak the full cardinal direction rather than
            // a cryptic single letter.
            .accessibilityLabel("Heading")
            .accessibilityValue(compassSpokenValue)
    }

    /// Landscape glass control button. A bare SF Symbol derives no meaningful
    /// VoiceOver name, so the label (and optional on/off value for toggles) is
    /// threaded in here and applied to the button, mirroring the portrait
    /// `voiceButton` / `viewToggleButton` / `reportButton` treatment.
    private func landscapeButton(_ symbol: String, isActive: Bool = false, rotationDegrees: Double = 0, accessibilityLabel: String, accessibilityValue: String? = nil, accessibilityHint: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20 * controlScale, weight: .medium))
                // Inactive glyph rides neutral glass over the moving map — use
                // textSecondary (not raw textMuted, AA-proven only on solid
                // surfaces) + the shared soft shadow so it stays above the 3:1
                // non-text floor on any tile, while accent still marks active.
                .foregroundStyle(isActive ? SteddiTheme.accent : SteddiTheme.textSecondary(highContrast: highContrast))
                .legibleOverMap()
                .rotationEffect(.degrees(rotationDegrees))
                .frame(width: 50 * controlScale, height: 50 * controlScale)
                // Always-neutral glass so the glyph never sits accent-on-accent
                // and vanishes — active state reads through the accent glyph and
                // its shape, matching the portrait floating controls.
                .steddiGlass(
                    tint: nil,
                    interactive: true,
                    in: .circle
                )
        }
        .buttonStyle(.steddiPress)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "")
        .accessibilityHint(accessibilityHint ?? "")
    }

    private func floatingButtonCircle(symbol: String, isActive: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17 * controlScale, weight: .medium))
            // Inactive glyph rides neutral glass over the moving map — textSecondary
            // (not raw textMuted, AA-proven only on solid surfaces) + the shared
            // soft shadow so it holds above the 3:1 non-text floor on any tile,
            // while accent still marks the active state.
            .foregroundStyle(isActive ? SteddiTheme.accent : SteddiTheme.textSecondary(highContrast: highContrast))
            .legibleOverMap()
            .frame(width: 44 * controlScale, height: 44 * controlScale)
            // Always-neutral glass so the glyph never sits accent-on-accent and
            // vanishes — the active state reads through the glyph color (accent)
            // and its shape (e.g. speaker.wave vs speaker.slash), matching the
            // compass and report controls in the same cluster.
            .steddiGlass(
                tint: nil,
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
                // Baseline-align "min" to the ETA number via `.firstTextBaseline`
                // so it tracks the digits' baseline as both scale under Dynamic
                // Type. The old hardcoded `.padding(.top, 8)` was hand-tuned for the
                // default size and drifted/misaligned once the type grew.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(engine.etaMinutes)")
                        .font(SteddiTheme.mono(32 * textScale))
                        .foregroundStyle(SteddiTheme.textPrimary)
                        .legibleOverMap()
                    Text("min")
                        .font(SteddiTheme.body(14 * textScale, highContrast: highContrast))
                        .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                        .legibleOverMap()
                }

                HStack(spacing: 8) {
                    Text(engine.distanceRemaining)
                        .font(SteddiTheme.mono(13 * textScale))
                        .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                        .legibleOverMap()

                    Circle()
                        // Match the textSecondary readouts it sits between and
                        // pick up the high-contrast promotion: raw textMuted's AA
                        // guarantee is only against solid surfaces, not nav glass.
                        .fill(SteddiTheme.textSecondary(highContrast: highContrast))
                        .frame(width: 3, height: 3)
                        .legibleOverMap()

                    // Arrival time is a meaningful readout over translucent glass —
                    // textSecondary to match its distance sibling above (textMuted's
                    // AA guarantee is only against solid surfaces, not nav glass).
                    Text(engine.arrivalTime)
                        .font(SteddiTheme.mono(13 * textScale))
                        .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                        .legibleOverMap()
                }
            }
            .frame(maxWidth: .infinity)

            // End button — right. Destructive CTA: warmRed glass fill + the
            // AA-correct on-fill label from the style (was `.glassProminent
            // .tint(warmRed)`, the forced-white-label path the codebase bans).
            Button("End", action: onEndNavigation)
                .font(.system(size: 17 * textScale, weight: .semibold))
                .padding(.horizontal, 24 * controlScale)
                .padding(.vertical, 12 * controlScale)
                .buttonStyle(.steddiDestructive)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        // Faint scrim under the glass (same shape), exactly like the top banner,
        // so the ETA / distance / arrival readouts hold against bright cartography.
        .mapGlassScrim(in: UnevenRoundedRectangle(topLeadingRadius: SteddiTheme.radiusLarge, topTrailingRadius: SteddiTheme.radiusLarge))
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

        // The digit needs to stay legible *on its housing*, where a raw
        // warningAmber/warmRed goes near-invisible in light/dynamic-day — exactly
        // when the over-limit readout matters. Use the surface-adaptive text
        // tokens for both over-limit states (amberText for 0–8 over, warmRedText
        // for >8 over) so the digit clears AA on every theme. Arc/ring hue
        // (speedColor) keeps the raw saturated gauge color.
        let speedTextColor: Color = {
            if overLimit > 8 { return SteddiTheme.warmRedText }
            if overLimit > 0 { return SteddiTheme.amberText }
            return SteddiTheme.textPrimary
        }()

        // Over-limit warning housing must be a genuinely SOLID fill — a safety
        // readout can't lose contrast to translucency. warmRedSubtle is a 15%
        // wash, so composite it over surfacePrimary to get an opaque warm-red
        // tint. Otherwise the housing is neutral glass.
        let isWarning = overLimit > 8

        let scale = size / 64.0

        return ZStack(alignment: .topTrailing) {
            ZStack {
                // Background housing: solid in the warning state, glass otherwise.
                Group {
                    if isWarning {
                        // Opaque warm-red tint: surfacePrimary base + the 15%
                        // warmRed wash on top, so the digit sits on a solid fill
                        // (not a translucent wash that lets the map bleed through).
                        Circle().fill(SteddiTheme.surfacePrimary)
                            .overlay(Circle().fill(SteddiTheme.warmRedSubtle))
                    } else {
                        // Neutral glass housing. In DARK theme the over-map scrim
                        // keeps the speed digit (textPrimary, near-white) legible:
                        // without it, the light frost over a dark map washed the
                        // at/under-limit digit to ~1.8:1. Same scrim the banners
                        // use; light theme stays the faint approved wash.
                        Circle().fill(.clear)
                            .mapGlassScrim(in: .circle)
                            .steddiGlass(tint: nil, interactive: false, in: .circle)
                    }
                }
                .overlay(
                    // Over-limit thickens the housing ring as a NON-color cue
                    // (perceivable without hue discrimination, WCAG 1.4.1) in
                    // addition to the warm hue shift below.
                    Circle()
                        .stroke(speedColor.opacity(overLimit > 0 ? 0.5 : 0.3),
                                lineWidth: overLimit > 0 ? 3 : 2)
                )

                // Speed arc gauge — thickens when over the limit so the gauge
                // reads as "alert" by weight, not color alone.
                Circle()
                    .trim(from: 0, to: min(1.0, engine.currentSpeedMph / max(1, (speedLimitMph ?? 65) * 1.3)))
                    .stroke(speedColor.opacity(overLimit > 0 ? 0.7 : 0.5),
                            style: StrokeStyle(lineWidth: max(2, (overLimit > 0 ? 4 : 3) * scale), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3 * scale)

                // Speed value
                VStack(spacing: 0) {
                    // Unit-aware display value (mph or km/h per the user's setting);
                    // the gauge math below stays mph-canonical to match OSM maxspeed.
                    Text("\(engine.currentSpeedValue)")
                        .font(SteddiTheme.mono(22 * scale))
                        .foregroundStyle(speedTextColor)
                        // The digit rides the translucent glass housing in the
                        // common at/under-limit state (textPrimary, no solid
                        // backing) — the shared soft shadow keeps it legible on
                        // any tile, independent of the warning color state.
                        .legibleOverMap()
                        // The font scales with OS Dynamic Type but the housing is
                        // fixed (64*iconScale), so shrink-to-fit rather than clip:
                        // a 3-digit speed at the accessibility ceiling must stay
                        // inside the circle (safety readout — never spill/clip).
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)

                    Text(engine.speedUnitLabel)
                        // Floor the unit caption so it stays legible: at the
                        // landscape/floating speedometer (size 44, scale ~0.69)
                        // an unfloored 9*scale renders ~6pt — unreadable on glass
                        // in a moving vehicle. Keep it scaling above the floor.
                        .font(SteddiTheme.body(max(11, 9 * scale)))
                        // Sits on the same translucent neutral glass housing as
                        // the sibling readouts — textSecondary, not textMuted,
                        // whose AA guarantee holds only against solid surfaces.
                        .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                        .legibleOverMap()
                }
            }
            .frame(width: size, height: size)

            // Speed limit badge — small bordered circle when limit is available
            if let limit = speedLimitMph {
                Text("\(engine.speedLimitValue ?? Int(limit))")
                    .font(SteddiTheme.mono(10 * scale))
                    // Small 10pt value on a solid surfacePrimary fill — raw warmRed
                    // fails AA here (1.77:1 grey, 3.56:1 light), so use the
                    // surface-adaptive warmRedText when over the limit. The muted
                    // branch picks up the high-contrast promotion like its siblings.
                    .foregroundStyle(overLimit > 0 ? SteddiTheme.warmRedText
                                     : engine.speedLimitIsEstimated ? SteddiTheme.textMuted(highContrast: highContrast)
                                     : SteddiTheme.textPrimary)
                    // Same fixed badge circle (22*scale) vs Dynamic-Type-scaled
                    // font: shrink a 3-digit limit to fit instead of clipping.
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: 22 * scale, height: 22 * scale)
                    .background(
                        Circle()
                            .fill(SteddiTheme.surfacePrimary)
                            .overlay(Circle().stroke(
                                overLimit > 0 ? SteddiTheme.warmRedText : SteddiTheme.textMuted(highContrast: highContrast).opacity(0.5),
                                lineWidth: 1.5))
                    )
                    // NON-color over-limit cue: a warning glyph pinned to the
                    // limit badge so "you are speeding" is perceivable by shape,
                    // not just by amber/red hue (WCAG 1.4.1 / color-blind drivers).
                    .overlay(alignment: .topTrailing) {
                        if overLimit > 0 {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 11 * scale, weight: .bold))
                                .foregroundStyle(SteddiTheme.warmRedText)
                                .background(Circle().fill(SteddiTheme.surfacePrimary).padding(1))
                                .offset(x: 5 * scale, y: -5 * scale)
                        }
                    }
                    .offset(x: 4 * scale, y: -4 * scale)
            }
        }
        .frame(width: size + 8, height: size + 8)
        // The gauge reads as fragmented numbers ("65", "mph", "55") to VoiceOver
        // — combine the children into a single spoken phrase covering current
        // speed, the limit, and an over-limit warning.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(speedometerAccessibilityLabel(speedLimitMph: speedLimitMph, overLimit: overLimit))
    }

    /// Single spoken phrase for the speedometer gauge, e.g.
    /// "Current speed 65 miles per hour. Speed limit 55. Over the limit."
    private func speedometerAccessibilityLabel(speedLimitMph: Double?, overLimit: Double) -> String {
        var phrase = "Current speed \(engine.currentSpeedValue) \(engine.spokenSpeedUnit)."
        if let limit = speedLimitMph {
            let qualifier = engine.speedLimitIsEstimated ? "Estimated speed limit" : "Speed limit"
            phrase += " \(qualifier) \(engine.speedLimitValue ?? Int(limit))."
        }
        if overLimit > 0 {
            phrase += " Over the limit."
        }
        return phrase
    }

    // MARK: - Report Sheet

    private var reportSheet: some View {
        NavigationStack {
            List {
                // Glyph colors are drawn ON the near-white `surfaceSecondary` list
                // row, so they use the surface-adaptive *text* tokens, not the raw
                // fill hues: `accent` is already text-safe, and `warmRedText`
                // darkens warmRed (raw ~1.77:1 on grey) the direction the surface
                // has headroom in so the icon clears WCAG's 3:1 non-text floor
                // while still reading red.
                reportOption(icon: "exclamationmark.triangle.fill", label: "Hazard", color: SteddiTheme.accent)
                reportOption(icon: "shield.fill", label: "Police", color: SteddiTheme.accent)
                reportOption(icon: "car.side.fill", label: "Accident", color: SteddiTheme.warmRedText)
                reportOption(icon: "road.lanes", label: "Road Closure", color: SteddiTheme.warmRedText)
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
        .preferredColorScheme(resolvedColorScheme)
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
                    // List-row glyph on the near-white `surfaceSecondary`, not a
                    // filled badge — use the surface-adaptive `listGlyphColor`
                    // (amberText/warmRedText/text-safe accent), not the raw fill
                    // `kind.color`, so the icon clears the 3:1 non-text floor in
                    // light/dynamic-day while keeping its amber/red identity.
                    .foregroundStyle(kind.listGlyphColor)
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
                // Thread highContrast + textScale like every other nav banner so
                // the label thickens and grows for accessibility users instead of
                // staying thin, fixed-size while the rest of the chrome promotes.
                .font(SteddiTheme.body(15 * textScale, highContrast: highContrast))
                .foregroundStyle(SteddiTheme.textPrimary)
                // Rides neutral glass over the map — the shared soft shadow keeps
                // the confirmation legible on any tile, like the sibling readouts.
                .legibleOverMap()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        // Neutral glass capsule; the sage checkmark icon carries the meaning.
        .steddiGlass(tint: nil, interactive: false, in: Capsule(), fallbackStrokeOpacity: 0.3)
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

// MARK: - Legible-over-map treatment

/// The single, shared protection every nav readout that rides translucent nav
/// glass over the moving map gets, so the treatment can never drift between
/// sites and any future readout inherits it by adopting these two modifiers.
///
/// The portrait top banner — the safety-critical maneuver — established this
/// pattern (textPrimary/textSecondary + soft shadow + a faint scrim under the
/// glass), precisely because the surface-token AA guarantee holds only against
/// the *solid* surfaces, NOT against Liquid Glass over bright/varied cartography
/// where the map tile bleeds through. These two modifiers are that pattern,
/// extracted verbatim so the bottom bar, speedometer, landscape instruction
/// card, and floating-control glyphs all share exactly the same hardening.
extension View {
    /// Soft drop shadow that separates a glass-borne readout from any map tile.
    /// Matches the compass / top-banner / street-name shadow used across the HUD.
    func legibleOverMap() -> some View {
        self.shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
    }

    /// Back a translucent-glass panel with the over-map scrim, lifting the glass
    /// off the cartography so the readouts on it never wash out. Skipped when
    /// glass is off (the fallback is already opaque), and drawn *behind* the glass
    /// so the Liquid Glass aesthetic stays on top. Apply this immediately before
    /// `.steddiGlass(…)` with the SAME shape.
    ///
    /// In DARK theme the scrim is a near-opaque luminance-FIXED dark fill (the
    /// dark-theme washout fix — see `SteddiTheme.mapGlassScrimOpacity`); in light
    /// theme it stays the original faint adaptive wash so the approved light HUD
    /// is unchanged.
    func mapGlassScrim(in shape: some Shape) -> some View {
        modifier(MapGlassScrimModifier(shape: shape))
    }
}

/// Backs `mapGlassScrim`. Reads `\.glassRevision` for the same reason
/// ``SteddiGlassModifier`` does: `SteddiGlass.isAvailable` is an imperative read,
/// so the scrim's presence must re-resolve in lockstep with the glass surface
/// when Reduce Transparency / Increase Contrast toggles — otherwise a mid-drive
/// toggle could leave the faint scrim showing behind the now-solid fallback.
private struct MapGlassScrimModifier<ClipShape: Shape>: ViewModifier {
    let shape: ClipShape
    @Environment(\.glassRevision) private var glassRevision

    @ViewBuilder
    func body(content: Content) -> some View {
        let _ = glassRevision
        content.background {
            if SteddiGlass.isAvailable {
                // DARK theme: a near-opaque luminance-fixed dark fill so the
                // adaptive glass renders DARK and near-white readouts read
                // white-on-dark (the washout fix). LIGHT theme: the original faint
                // adaptive wash, so the approved light HUD is byte-for-byte
                // unchanged. High contrast forces opaque glass, so the scrim is
                // suppressed there (it would never show).
                let highContrast = DisplayModeService.shared.useHighContrast
                shape.fill(
                    SteddiTheme.mapGlassScrimFill
                        .opacity(SteddiTheme.mapGlassScrimOpacity(highContrast: highContrast))
                )
            }
        }
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
