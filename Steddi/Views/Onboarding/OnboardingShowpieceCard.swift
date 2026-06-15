import SwiftUI

/// The showpiece's centerpiece: a **single** Liquid Glass card that *morphs* its
/// shape and size between beats instead of cross-fading separate cards in and
/// out. As `OnboardingView` advances the beat, the inner copy/controls swap with
/// a gentle cross-fade while the glass shell itself springs between geometries —
/// short copy card → tall theme picker → permission card → emergency card.
///
/// The morph is driven entirely by Apple's official Liquid Glass:
/// `GlassEffectContainer` + a single shared `glassEffectID("onboarding.beatCard")`
/// in one `@Namespace` + `.glassEffectTransition(.matchedGeometry)`. Because the
/// id is *shared* across beats, Liquid Glass animates the shape between the
/// card's intrinsic geometries rather than dissolving one card for another.
///
/// The card also owns two pieces of cinematic chrome that travel with it across
/// every showcase/ask beat:
///   - the **backdrop parallax** (the hero's dark map, dimmed, nudged + scaled
///     a touch per beat so depth reads without motion sickness), and
///   - the **autoplay progress hairline** (`SteadyLine`, the brand motif) that
///     fills over the dwell so the viewer senses the autoplay rhythm.
///
/// All motion is Reduce-Motion-aware: the driving `withAnimation` in
/// `OnboardingView.advance()` resolves to `nil` under Reduce Motion (so the morph
/// is instant), the parallax is gated on `SteddiMotion.shouldAnimate`, and the
/// progress hairline only appears while autoplay is actually armed. When glass is
/// unavailable (Reduce Transparency / high-contrast), `steddiGlass` falls back to
/// the solid `surfaceSecondary` look the existing onboarding cards already use.
struct OnboardingShowpieceCard<Content: View>: View {

    /// The beat currently on screen — drives the live tint and the parallax depth.
    let beat: OnboardingCoordinator.OnboardingBeat

    /// The accent the user has picked so far; the theme beat tints the glass to it.
    let accent: Color

    /// Autoplay progress 0→1 for the hairline, or `nil` when autoplay isn't armed
    /// for this beat (no hairline shown).
    let autoplayProgress: Double?

    /// The shared namespace for the morphing glass id. Hoisted from
    /// `OnboardingView` so the final fall-into-Home settle can morph this same
    /// card into the "Where to?" pill (one namespace, one id → real
    /// matchedGeometry tween). One id, one namespace, so the glass treats every
    /// beat's card *and* the settle pill as the same element and tweens between
    /// their geometries.
    let beatCardNamespace: Namespace.ID

    /// The inner copy/controls for the current beat. Cross-fades on beat change
    /// (the caller applies the per-beat `.transition`); the shell morphs around it.
    @ViewBuilder let content: () -> Content

    /// Index of the current beat, used to drive the small per-beat parallax nudge.
    private var beatIndex: Int {
        OnboardingCoordinator.OnboardingBeat.allCases.firstIndex(of: beat) ?? 0
    }

    /// The theme beat is the delight peak: the glass shell itself takes the live
    /// accent tint so a swatch tap recolors the glass in real time. Every other
    /// beat uses neutral `.regular` glass (an ask/showcase, not delight).
    private var cardTint: Color? {
        beat == .theme ? accent : nil
    }

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: 0) {
                GlassEffectContainer(spacing: 24) {
                    ZStack {
                        content()
                    }
                    .frame(maxWidth: 360)
                    .steddiGlass(
                        tint: cardTint,
                        in: RoundedRectangle(cornerRadius: SteddiTheme.radiusLarge),
                        fallbackFill: SteddiTheme.surfaceSecondary
                    )
                    .glassEffectID("onboarding.beatCard", in: beatCardNamespace)
                    .glassEffectTransition(.matchedGeometry)
                }
                .padding(.horizontal, 24)

                // Autoplay rhythm: the steady-line motif fills under the card so
                // the viewer feels the reel advancing. Only shown when autoplay is
                // armed (never under Reduce Motion / VoiceOver — the caller passes
                // `nil` then).
                if let autoplayProgress {
                    progressHairline(autoplayProgress)
                        .padding(.horizontal, 48)
                        .padding(.top, 16)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Backdrop parallax

    /// The calm dark backdrop the glass cards float over — a dimmed echo of the
    /// hero's map, nudged up and scaled a hair per beat so the cards read as
    /// floating in depth. Static under Reduce Motion.
    private var backdrop: some View {
        let animate = SteddiMotion.shouldAnimate
        // Each advance nudges the backdrop up ~6pt and scales 1.0→~1.02, capped so
        // late beats don't drift off-screen.
        let depth = min(Double(beatIndex), 5)
        let offsetY: CGFloat = animate ? CGFloat(-6 * depth) : 0
        let scale: CGFloat = animate ? 1.0 + CGFloat(0.004 * depth) : 1.0

        return LinearGradient(
            colors: [
                Color.black.opacity(0.92),
                accent.opacity(0.10),
                Color.black.opacity(0.96)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(
            // A soft radial glow in the chosen accent — the backdrop quietly
            // shares the delight tint without competing with the glass card.
            RadialGradient(
                colors: [accent.opacity(0.18), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 420
            )
            .blendMode(.plusLighter)
        )
        .scaleEffect(scale)
        .offset(y: offsetY)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Autoplay progress hairline

    private func progressHairline(_ progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(accent)
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, progress))))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}
