import SwiftUI

/// Steddi's first-run flow: a cinematic-but-fast 4-beat experience that
/// communicates quality in seconds rather than teaching a tutorial.
///
/// Beats (driven by `OnboardingCoordinator`):
///   1. hero        — route draws across a dark map (reuses the nav draw-on renderer)
///   2. permissions — location, framed in-context; notifications deferred to first commute
///   3. theme       — accent + theme pick, the delight moment
///   4. emergency   — optional emergency contact (mirrors EmergencyView's storage)
///
/// Coexists with the existing `@AppStorage("hasCompletedOnboarding")` gate and
/// the `steddi://reset-onboarding` hook (both in PhoneSceneDelegate). Theme/accent
/// selections are persisted and their change notifications posted only on
/// completion, so the home screen never flashes a stale palette mid-flow. Skip is
/// available on every beat except permissions, where the user makes an explicit
/// allow/defer choice.
struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("accentColor") private var accentColor = SteddiTheme.AccentOption.lavender.rawValue

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(LocationService.self) private var locationService

    @State private var coordinator = OnboardingCoordinator()
    @State private var showDonation = false

    // MARK: - Autoplay (showcase reel)

    /// The cancellable per-beat autoplay timer. Keyed to `currentBeat`: tapping
    /// Next or Skip cancels it and advances immediately; it's never armed under
    /// Reduce Motion or VoiceOver (the user advances manually). Lives in the view,
    /// not the coordinator, so the coordinator stays a pure, timer-free model.
    @State private var autoplayTask: Task<Void, Never>?
    /// 0→1 dwell progress for the card's autoplay hairline.
    @State private var autoplayProgress: Double = 0
    /// True while an autoplay dwell is running for the current beat.
    @State private var autoplayActive = false

    // MARK: - Fall-into-Home settle

    /// True during the final settle: the beat card collapses into the
    /// "Where to?" search-pill silhouette before the root swaps to Home.
    @State private var settling = false
    /// Shared namespace for the morphing glass id — hoisted here so the same
    /// `glassEffectID("onboarding.beatCard")` can morph from the beat card into
    /// the settle pill (a real matchedGeometry tween in one tree).
    @Namespace private var beatCardNamespace

    var body: some View {
        // Force a re-render when the in-flight accent changes so the footer,
        // chrome, and the glass card's live tint recolor during the delight beat.
        let _ = coordinator.selectedAccent
        VStack(spacing: 0) {
            beatContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !settling { footer }
        }
        .background(beatBackground.ignoresSafeArea())
        .overlay(alignment: .topTrailing) { if !settling { skipIntroButton } }
        .overlay(alignment: .top) { settlePill }
        .sheet(isPresented: $showDonation, onDismiss: beginSettle) {
            DonationView()
        }
        .onChange(of: coordinator.currentBeat) { _, _ in
            armAutoplayIfNeeded()
        }
        .onDisappear { cancelAutoplay() }
    }

    /// The fall-into-Home settle (Option A — visual continuity): the beat card
    /// morphs into a glass "Where to?" pill at the top-bar position, then the root
    /// swaps to Home whose search pill is already glass at the same spot — so the
    /// eye reads the onboarding card as having *become* the search bar. Shares the
    /// beat card's `glassEffectID`/namespace, so it's a true matchedGeometry morph
    /// from card-rect to pill-rect. Skipped under Reduce Motion (instant swap).
    @ViewBuilder
    private var settlePill: some View {
        if settling {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.medium))
                        .foregroundStyle(coordinator.selectedAccent.color)
                    Text("Where to?")
                        .font(SteddiTheme.heading(17))
                        .foregroundStyle(SteddiTheme.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .steddiGlass(tint: nil, interactive: true, in: Capsule(),
                             fallbackFill: SteddiTheme.surfaceSecondary)
                .glassEffectID("onboarding.beatCard", in: beatCardNamespace)
                .glassEffectTransition(.matchedGeometry)
            }
            .padding(.horizontal, 16)
            .padding(.top, 62) // align with Home's top bar (status-bar inset + 8)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
    }

    /// The hero owns its own full-bleed map; the showcase/ask beats float over
    /// the showpiece card's dark cinematic backdrop, so the root only needs the
    /// neutral surface beneath the hero (and as a base for the backdrop).
    private var beatBackground: Color {
        coordinator.currentBeat == .hero ? SteddiTheme.surfacePrimary : .black
    }

    // MARK: - Beats

    @ViewBuilder
    private var beatContent: some View {
        ZStack {
            switch coordinator.currentBeat {
            case .hero:
                OnboardingHeroView {
                    coordinator.heroAnimationComplete = true
                }
                .transition(beatTransition)

            default:
                // Every non-hero beat lives inside the single morphing Liquid
                // Glass card. The shell persists across beats (shared
                // glassEffectID) and morphs its geometry while the inner copy
                // cross-fades. During the settle the card is removed so the same
                // glass id migrates to the "Where to?" pill (matchedGeometry).
                if !settling {
                    OnboardingShowpieceCard(
                        beat: coordinator.currentBeat,
                        accent: coordinator.selectedAccent.color,
                        autoplayProgress: autoplayHairlineProgress,
                        beatCardNamespace: beatCardNamespace
                    ) {
                        innerBeatContent
                            .id(coordinator.currentBeat)
                            .transition(beatTransition)
                    }
                }
            }
        }
    }

    /// The copy/controls inside the morphing card for the current beat. These
    /// cross-fade (via `beatTransition`) while the glass shell morphs around them.
    @ViewBuilder
    private var innerBeatContent: some View {
        switch coordinator.currentBeat {
        case .hero:
            EmptyView() // hero never renders inside the card

        case .routeRules:
            OnboardingRouteRulesView(accent: coordinator.selectedAccent.color)

        case .turnByTurn:
            OnboardingTurnByTurnView(accent: coordinator.selectedAccent.color)

        case .theme:
            OnboardingThemeView(coordinator: coordinator)

        case .permissions:
            OnboardingPermissionsView(
                onContinue: requestLocation,
                onNotNow: { advance() },
                accent: coordinator.selectedAccent.color
            )

        case .emergency:
            OnboardingEmergencyView(coordinator: coordinator)
        }
    }

    /// Progress 0→1 for the card's autoplay hairline, or `nil` when autoplay is
    /// not armed for this beat (so the hairline is hidden). Driven by the per-beat
    /// autoplay `Task` below.
    private var autoplayHairlineProgress: Double? {
        autoplayActive ? autoplayProgress : nil
    }

    /// Asymmetric beat transition: gentle fade-in, scale-and-fade out. Collapses
    /// to instant under Reduce Motion (handled by `SteddiMotion` at the call site
    /// that drives `currentBeat`).
    private var beatTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .scale(scale: 0.96).combined(with: .opacity)
        )
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 16) {
            // The hero's primary button waits for the draw-on to finish; other
            // beats show it immediately.
            if showsPrimaryButton {
                Button {
                    HapticService.shared.fire(.uiToggle)
                    advance()
                } label: {
                    Text(coordinator.currentBeat.primaryLabel)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                // The footer CTA is a genuine system primary — Apple's
                // `.glassProminent`, tinted live to the chosen accent so it glows
                // the user's color from the delight beat onward.
                .buttonStyle(.glassProminent)
                .tint(coordinator.selectedAccent.color)
                .disabled(coordinator.isTransitioning)
                .transition(.opacity)
            }

            // One skip control per beat. The autoplay showcase beats use the
            // top-right "Skip setup" affordance instead (alongside "Next"), so we
            // suppress the footer skip there to avoid two identical controls.
            if coordinator.currentBeat.allowsSkip && !coordinator.currentBeat.autoAdvances {
                Button("Skip setup") { skip() }
                    .font(.subheadline)
                    // The onboarding hero/card backdrop is a fixed dark cinematic
                    // surface, not theme-colored — so the skip must stay light in
                    // every resolved theme. A theme `textSecondary` would resolve
                    // dark in Light and fail AA on the dark backdrop. Match the
                    // hero copy's near-white (mirrors `skipIntroButton`).
                    .foregroundStyle(.white.opacity(0.85))
                    .disabled(coordinator.isTransitioning)
                    .accessibilityHint("Skips the rest of setup and goes to the app")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .padding(.top, 8)
    }

    /// Permissions has its own in-card Continue/Not-now buttons, so the footer's
    /// primary is hidden there. The hero shows it only once its animation lands.
    private var showsPrimaryButton: Bool {
        switch coordinator.currentBeat {
        case .permissions: return false
        case .hero: return coordinator.heroAnimationComplete
        default: return true
        }
    }

    /// The single skip control for the autoplaying showcase beats. Labeled
    /// "Skip setup" (not "Skip intro") because it ends the *entire* onboarding —
    /// not just the showcase reel — so the scope is unambiguous. The footer skip
    /// is suppressed on these beats so this is the only skip affordance shown.
    /// Hidden on the hero (footer skip) and on `permissions` (no skip there).
    @ViewBuilder
    private var skipIntroButton: some View {
        if coordinator.currentBeat.autoAdvances {
            Button("Skip setup") { skip() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .padding(.top, 8)
                .padding(.trailing, 12)
                .disabled(coordinator.isTransitioning)
                .transition(.opacity)
                .accessibilityLabel("Skip setup")
                .accessibilityHint("Skips the rest of setup and goes to the app")
        }
    }

    // MARK: - Autoplay control

    /// Arm the per-beat autoplay dwell if this beat auto-advances and motion is
    /// allowed. Cancels any prior dwell first. The dwell drives `autoplayProgress`
    /// 0→1 over `TransitionKit.onboardingBeatDwell`, then advances. Disabled
    /// entirely under Reduce Motion or VoiceOver — the user advances manually.
    private func armAutoplayIfNeeded() {
        cancelAutoplay()
        guard coordinator.currentBeat.autoAdvances,
              SteddiMotion.shouldAnimate,
              !UIAccessibility.isVoiceOverRunning else {
            return
        }
        autoplayActive = true
        autoplayProgress = 0
        let dwell = TransitionKit.onboardingBeatDwell
        let start = Date()
        autoplayTask = Task { @MainActor in
            // Tick the hairline at ~60fps until the dwell elapses, then advance.
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                autoplayProgress = min(1, elapsed / dwell)
                if elapsed >= dwell { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            guard !Task.isCancelled else { return }
            autoplayActive = false
            advance()
        }
    }

    /// Cancel the current autoplay dwell (on tap-through, skip, or teardown).
    private func cancelAutoplay() {
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplayActive = false
        autoplayProgress = 0
    }

    // MARK: - Flow control

    /// Advance one beat, or finish the flow when there's no next beat. A user tap
    /// (or the autoplay timer firing) cancels any in-flight dwell first.
    private func advance() {
        guard !coordinator.isTransitioning else { return }
        cancelAutoplay()
        guard coordinator.hasNextBeat else {
            finishFlow()
            return
        }
        coordinator.isTransitioning = true
        // The card's glass morph rides this same withAnimation, so it's
        // Reduce-Motion-gated automatically (resolves to nil → instant).
        withAnimation(SteddiMotion.resolve(.easeInOut(duration: 0.35))) {
            _ = coordinator.advance()
        }
        // Re-enable the footer after the transition window (instant under Reduce
        // Motion so it never sticks disabled).
        let delay = reduceMotion ? 0 : 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            coordinator.isTransitioning = false
        }
    }

    /// Skip the rest of onboarding from any skippable beat.
    private func skip() {
        guard !coordinator.isTransitioning else { return }
        cancelAutoplay()
        finishFlow()
    }

    /// Request location in-context. Advancing happens immediately — the system
    /// prompt floats over beat 3, and any grant flows into the map later.
    private func requestLocation() {
        locationService.requestPermission()
        advance()
    }

    /// Persist selections, post deferred theme/accent notifications, then run the
    /// completion path (donation sheet, which flips the gate on dismiss).
    private func finishFlow() {
        persistSelections()
        showDonation = true
    }

    /// Write the in-flight accent/theme picks to their shared stores and notify
    /// observers — only now, so the home screen renders the final palette once.
    private func persistSelections() {
        accentColor = coordinator.selectedAccent.rawValue
        NotificationCenter.default.post(name: .steddiAccentColorChanged, object: nil)

        // Route the theme mode through the engine: it persists, syncs the legacy
        // "themeMode" shadow for map surfaces, and posts .steddiThemeModeChanged.
        ThemeEngine.shared.baseMode = coordinator.selectedTheme

        if let phone = coordinator.emergencyContact {
            UserDefaults.standard.set(phone, forKey: "steddi.emergencyContact")
        }
    }

    /// After the donation sheet dismisses, play the fall-into-Home settle (the
    /// beat card morphs into the "Where to?" pill) and *then* flip the gate so the
    /// root swaps to Home — whose search pill is already glass at the same spot —
    /// reading as one continuous move. Under Reduce Motion the morph is skipped and
    /// the gate flips on the next runloop (an instant cross-dissolve to Home).
    private func beginSettle() {
        guard SteddiMotion.shouldAnimate else {
            completeOnboarding()
            return
        }
        withAnimation(TransitionKit.onboardingMorph) {
            settling = true
        }
        // Hold the morph briefly, then hand off to Home.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            completeOnboarding()
        }
    }

    private func completeOnboarding() {
        hasCompletedOnboarding = true
    }
}

#Preview {
    OnboardingView()
        .environment(LocationService())
}
