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

    var body: some View {
        // Force a re-render when the in-flight accent changes so the footer and
        // chrome recolor live during beat 3.
        let _ = coordinator.selectedAccent
        VStack(spacing: 0) {
            beatContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .background(SteddiTheme.surfacePrimary.ignoresSafeArea())
        .sheet(isPresented: $showDonation, onDismiss: completeOnboarding) {
            DonationView()
        }
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

            case .permissions:
                OnboardingPermissionsView(
                    onContinue: requestLocation,
                    onNotNow: { advance() }
                )
                .transition(beatTransition)

            case .theme:
                OnboardingThemeView(coordinator: coordinator)
                    .transition(beatTransition)

            case .emergency:
                OnboardingEmergencyView(coordinator: coordinator)
                    .transition(beatTransition)
            }
        }
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
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(coordinator.selectedAccent.color, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.steddiPress)
                .disabled(coordinator.isTransitioning)
                .transition(.opacity)
            }

            if coordinator.currentBeat.allowsSkip {
                Button("Skip") { skip() }
                    .font(.subheadline)
                    .foregroundStyle(SteddiTheme.textSecondary)
                    .disabled(coordinator.isTransitioning)
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

    // MARK: - Flow control

    /// Advance one beat, or finish the flow when there's no next beat.
    private func advance() {
        guard !coordinator.isTransitioning else { return }
        guard coordinator.hasNextBeat else {
            finishFlow()
            return
        }
        coordinator.isTransitioning = true
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
        finishFlow()
    }

    /// Request location in-context. Advancing happens immediately — the system
    /// prompt floats over beat 3, and any grant flows into the map later.
    private func requestLocation() {
        locationService.requestPermission()
        coordinator.locationGranted = true
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

    private func completeOnboarding() {
        hasCompletedOnboarding = true
    }
}

#Preview {
    OnboardingView()
        .environment(LocationService())
}
