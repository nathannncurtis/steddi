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

    /// The showcase/ask beats (routeRules, turnByTurn, permissions, emergency)
    /// draw fixed-WHITE copy + glyphs, sized to read white-on-dark like the hero.
    /// But neutral `.regular` glass over the dark backdrop renders as a LIGHT
    /// frost (~0.73 sRGB), so white copy on it collapsed to ~1.9:1 and the accent
    /// glyphs to ~1.65:1 — the recurring legibility bug. The theme beat is
    /// exempt: its glass is accent-tinted and its inner controls carry their own
    /// dark/white washes.
    ///
    /// Rather than chase the non-deterministic glass luminance, give the
    /// non-theme beats a deterministic DARK interior scrim behind the content, so
    /// the white copy + the surface-aware glyphs sit on a reliably dark surface
    /// (`OnboardingShowcaseFrost.surface` is the conservative composite they're
    /// sized against). The scrim is the same fixed dark tone as the
    /// Reduce-Transparency fallback (`onboardingCardFallbackFill`) at high
    /// opacity, so even over the lightest plausible glass it composites no lighter
    /// than that constant — keeping the card unmistakably a dark glass panel while
    /// every element clears AA (white primary 11.6:1, glyphs 5.7:1).
    private var needsDarkScrim: Bool { beat != .theme }

    var body: some View {
        ZStack {
            backdrop

            // The card is vertically centered when it fits, but a tall beat (the
            // theme picker) under large Dynamic Type can exceed the screen. Wrap
            // the centered column in a ScrollView whose content claims at least
            // the full viewport height: when content fits it reads as centered
            // (and doesn't bounce, per .basedOnSize); when it's taller than the
            // screen it scrolls instead of being clipped by the surrounding
            // Spacers. The glass id/namespace stay on the card itself, so the
            // matchedGeometry morph between beats and into the settle pill is
            // unaffected.
            GeometryReader { geo in
                ScrollView(.vertical) {
                    cardColumn
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The vertically-centered card column: the morphing glass card plus the
    /// optional autoplay hairline, bracketed by flexible spacers so it sits in the
    /// middle of whatever height it's given.
    private var cardColumn: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            GlassEffectContainer(spacing: 24) {
                ZStack {
                    content()
                }
                .frame(maxWidth: 360)
                // Deterministic dark scrim behind the content of the
                // showcase/ask beats so the fixed-white copy + glyphs sit on a
                // reliably dark surface (white-on-dark, like the hero) instead of
                // the LIGHT frost neutral glass renders as — the recurring
                // legibility bug. Drawn *inside* the card shape and in front of
                // the glass material (it's added before `.steddiGlass`), so it
                // darkens the frost while the glass shell still owns the morph,
                // edge highlight, and shape. The theme beat keeps its live
                // accent-tinted glass (no scrim). Same dark tone as the
                // Reduce-Transparency fallback, so the two paths agree.
                .background {
                    if needsDarkScrim {
                        RoundedRectangle(cornerRadius: SteddiTheme.radiusLarge)
                            .fill(SteddiTheme.onboardingCardFallbackFill.opacity(0.94))
                    }
                }
                .steddiGlass(
                    tint: cardTint,
                    in: RoundedRectangle(cornerRadius: SteddiTheme.radiusLarge),
                    // The card floats on a fixed dark backdrop and its copy is
                    // fixed-white, so the Reduce-Transparency fallback must be a
                    // fixed DARK fill — the default `surfaceSecondary` is near-
                    // white in Light and would hide the white text.
                    fallbackFill: SteddiTheme.onboardingCardFallbackFill
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

            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity)
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
