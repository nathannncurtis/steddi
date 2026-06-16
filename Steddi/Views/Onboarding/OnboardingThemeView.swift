import SwiftUI

/// Beat 3 of onboarding: pick an accent color and a theme mode — the delight
/// moment. Tapping a swatch or card recolors the flow live, so the user sees
/// their choice take effect immediately.
///
/// Selections are held on the `OnboardingCoordinator` (not written to defaults
/// yet); `OnboardingView` persists them and posts the theme/accent change
/// notifications only on completion, so the home screen never flashes a stale
/// palette mid-flow.
struct OnboardingThemeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Dependency-only: read so the on-surface foreground re-resolves in lockstep
    /// with `OnboardingShowpieceCard`'s glass surface when Reduce Transparency /
    /// Increase Contrast toggles. `SteddiGlass.isAvailable` is an imperative read
    /// (no SwiftUI dependency), so without touching the revision the copy color
    /// would not flip from near-black (bright accent glass) to near-white (dark
    /// fallback). The app root bumps this on those notifications — same machinery
    /// as `SteddiGlassModifier`.
    @Environment(\.glassRevision) private var glassRevision
    @Bindable var coordinator: OnboardingCoordinator

    /// Swatch diameter scales with Dynamic Type but stays bounded so the row
    /// never balloons off-card. `@ScaledMetric` has no ceiling of its own; the
    /// `.dynamicTypeSize(...accessibility3)` cap on this view's root (matching
    /// `SteddiTheme.dynamicTypeCeiling`) is what bounds it — past AX3 the swatch
    /// stops growing. The selected ring is drawn 10pt larger.
    @ScaledMetric(relativeTo: .body) private var swatchSize: CGFloat = 40

    private let accents = SteddiTheme.AccentOption.allCases
    private let themeCards: [(mode: ThemeModeEx, icon: String, label: String, description: String, recommended: Bool)] = [
        (.dynamic, "sun.horizon.fill", "Dynamic", "Light by day, dark by night", true),
        (.dark, "moon.fill", "Dark", "Always dark", false),
        (.light, "sun.max.fill", "Light", "Always light", false),
    ]

    // MARK: - On-surface legible foreground (the theme beat now has a partial scrim)
    //
    // The theme beat keeps its glass ACCENT-TINTED (the delight peak — a swatch tap
    // recolors the card live), but it is NO LONGER exempt from a dark scrim. It used
    // to be: the card was the bare accent-tinted glass, and the copy resolved near-
    // black on the assumed-bright accent. But the REAL tinted glass composites
    // DARKER than the raw accent over the dark cinematic backdrop, so the near-black
    // copy landed at only ~4.2–4.5:1 (AT/below the AA floor) on the default lavender
    // and worse on the darker accents — the composited tinted surface sits in the
    // worst luminance band where no fixed copy color clears a 5:1 margin.
    //
    // THE FIX — `OnboardingShowpieceCard` now paints a PARTIAL dark scrim
    // (`ThemeBeatSurface.themeScrimOpacity`) behind the theme beat too, so the
    // accent tint still glows through (~35%, delight preserved) while the surface
    // goes reliably DARK. The copy therefore resolves near-WHITE on that dark
    // surface in BOTH glass states and clears AA with MARGIN (≥5:1 body) for every
    // accent. Each label / description / icon / 'Recommended' chip / ring still
    // resolves its color from `contrastingForeground(on:)` against the ACTUAL
    // (now dark) surface it sits on — robust if the tint is ever retuned.
    //
    // The model still BRANCHES on glass availability so the surface stays faithful:
    // scrim-over-tinted-glass when glass is on, the solid dark fallback fill when
    // it's off (Reduce Transparency OR Increase Contrast — `SteddiGlass.isAvailable`,
    // discarding the accent). Both surfaces are dark → near-white copy either way.
    // `glassAvailable` is the single seam; `ThemeContrastTests.onboardingTheme*`
    // assert ≥5:1 in BOTH states and `OnboardingFrostMeasurementTests` confirm the
    // rendered composite is no lighter than the model.

    /// The card-shell surface the bare copy (header, section titles/subtitles)
    /// sits on, branched on glass availability: the partial scrim over the accent-
    /// tinted glass when glass renders, the dark Reduce-Transparency fallback fill
    /// when it doesn't. Dark in both states → near-white copy either way.
    private var cardSurface: RGBColor {
        ThemeBeatSurface.cardShell(accent: coordinator.selectedAccent.rgb,
                                   glassAvailable: glassAvailable)
    }

    /// Foreground for copy drawn directly on the (effective) card shell.
    private var onCardPrimary: Color { SteddiTheme.contrastingForeground(on: cardSurface) }

    /// Foreground for a theme-selection card row, contrasted against THAT card's
    /// own composited surface. The row draws a small white wash over the (scrimmed,
    /// dark) shell (`.opacity(0.12)` selected / `.opacity(0.05)` deselected) which
    /// only lightens it a little, so the surface stays dark and the foreground
    /// resolves near-white in both glass states.
    private func onThemeCard(selected: Bool) -> Color {
        SteddiTheme.contrastingForeground(on: themeCardSurface(selected: selected))
    }

    /// The composited surface of a theme-selection card row, branched on glass.
    private func themeCardSurface(selected: Bool) -> RGBColor {
        ThemeBeatSurface.themeCard(accent: coordinator.selectedAccent.rgb,
                                   selected: selected,
                                   glassAvailable: glassAvailable)
    }

    /// Whether Liquid Glass renders for this card. Read imperatively (touching
    /// `glassRevision` above keeps SwiftUI re-resolving on a Reduce-Transparency /
    /// Increase-Contrast toggle), matching `OnboardingShowpieceCard`'s shell so
    /// the copy color and the card surface can never disagree.
    private var glassAvailable: Bool {
        _ = glassRevision
        return SteddiGlass.isAvailable
    }

    var body: some View {
        // No inner ScrollView: the showpiece card (OnboardingShowpieceCard) now
        // hosts a single outer ScrollView that scrolls the whole card when its
        // content exceeds the screen at large Dynamic Type. Nesting a second
        // vertical scroll here would conflict with it and break the matched-
        // geometry glass sizing — so this beat just lays out its column and lets
        // the shell grow / the outer scroll take over.
        VStack(spacing: 28) {
            header

            VStack(spacing: 14) {
                sectionTitle("Pick your accent", subtitle: "Choose the color that feels right")
                accentPicker
            }

            VStack(spacing: 14) {
                sectionTitle("Choose your look", subtitle: "Light, dark, or match your device")
                VStack(spacing: 12) {
                    ForEach(themeCards, id: \.mode) { card in
                        themeCard(card)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .padding(.bottom, 24)
        // Cap the beat copy AND the @ScaledMetric swatch at the app's Dynamic Type
        // ceiling (.accessibility3 == SteddiTheme.dynamicTypeCeiling/
        // .accessibilityExtraLarge), the same bound the hero's SteddiTheme.heading()
        // applies via UIFontMetrics. The raw .title/.headline/.subheadline/.caption
        // styles — and @ScaledMetric(relativeTo: .body) swatchSize, which has no
        // ceiling of its own — would otherwise scale unbounded to AX5; this is the
        // bound that makes swatchSize genuinely "capped" as documented below. Copy
        // and swatches still scale up to the cap.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 56))
                // On-surface legible: the card shell is the partial dark scrim over
                // the accent-tinted glass, so `onCardPrimary` resolves near-white
                // and the glyph reads on every accent in both glass states — the
                // same on-surface rule the copy below follows.
                .foregroundStyle(onCardPrimary)
            Text("Make it yours")
                .font(.title.weight(.bold))
                // On-surface legible against the scrimmed (dark) shell (see
                // `onCardPrimary`): resolves near-white, clears AA with margin.
                .foregroundStyle(onCardPrimary)
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundStyle(onCardPrimary)
            Text(subtitle)
                .font(.subheadline)
                // The subtitle sits on the same scrimmed (dark) shell; resolve it
                // on-surface (near-white). Kept at full opacity, NOT dimmed: a
                // body-size subheadline must clear the 4.5 AA floor with margin, and
                // a dimmed near-white would eat into the headroom. The smaller,
                // regular-weight font already ranks it below the headline title.
                .foregroundStyle(onCardPrimary)
        }
    }

    // MARK: - Accent picker

    /// Wrapping, Dynamic-Type-aware accent grid. A fixed six-wide HStack of 40pt
    /// swatches needs ~310pt and overflowed the centered glass card on standard
    /// iPhones (and worse at large text). An adaptive grid wraps to a second row
    /// instead of spilling off-card, and the swatch size grows with text but is
    /// bounded by the view-root `.dynamicTypeSize(...accessibility3)` cap, so it
    /// scales without unbounded growth.
    private var accentPicker: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: swatchSize + 16), spacing: 14)],
            spacing: 14
        ) {
            ForEach(accents, id: \.self) { option in
                accentSwatch(option)
            }
        }
    }

    private func accentSwatch(_ option: SteddiTheme.AccentOption) -> some View {
        let isSelected = coordinator.selectedAccent == option
        return Button {
            HapticService.shared.fire(.uiToggle)
            withAnimation(SteddiMotion.resolve(TransitionKit.spring(TransitionKit.springButton))) {
                coordinator.selectedAccent = option
            }
        } label: {
            Circle()
                .fill(option.color)
                .frame(width: swatchSize, height: swatchSize)
                // Hairline bounding the swatch against the card. Drawn in the
                // swatch's OWN contrasting glyph (near-black on these light
                // pastels) rather than fixed white — a white hairline lands
                // ~1.3–2.0:1 on the light swatches and the SELECTED swatch's fill
                // equals the card tint, so the white edge dissolved. The dark
                // hairline gives every swatch a crisp edge on the light accent card
                // AND on the dark Reduce-Transparency fallback. At 0.75 opacity it
                // clears the 3:1 graphical floor on the fill for every accent
                // (worst slate 3.70:1; fixed white was ~1.5–1.9:1).
                .overlay { Circle().stroke(option.contrastingGlyph.opacity(0.75), lineWidth: 1.5) }
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(checkmarkColor(for: option))
                            .transition(.opacity)
                    }
                }
                .overlay {
                    // Selected ring as a DUAL stroke so it holds on BOTH card
                    // surfaces: a fixed-white ring lands ~1.6–2.2:1 on the light
                    // accent card (glass on), and a fixed-dark ring would vanish on
                    // the dark fallback (glass off / Reduce Transparency). The outer
                    // stroke is `selectionRing` — the card's contrasting foreground
                    // (near-black on light accents, near-white on the dark
                    // fallback), re-resolving with glass state like the copy — and a
                    // thin inner companion stroke in the OPPOSITE endpoint anchors it
                    // where it crosses the accent swatch fill, so the ring reads on
                    // every accent in either state.
                    ZStack {
                        Circle()
                            .stroke(selectionRing.color, lineWidth: 3)
                            .frame(width: swatchSize + 10, height: swatchSize + 10)
                        Circle()
                            .stroke(selectionRingCompanion, lineWidth: 1)
                            .frame(width: swatchSize + 6, height: swatchSize + 6)
                    }
                    .opacity(isSelected ? 1 : 0)
                }
                .scaleEffect(isSelected ? 1.0 : 0.97)
                // Reserve the selected ring's footprint so wrapping/spacing don't
                // shift when selection moves between swatches.
                .frame(width: swatchSize + 10, height: swatchSize + 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Contrasting checkmark glyph for the selected swatch. All six accents are
    /// light pastels (luminance > 0.5), so white-on-fill is illegible (gold the
    /// worst). Pick a dark glyph on light accents, white on dark ones, by the
    /// accent's relative luminance.
    private func checkmarkColor(for option: SteddiTheme.AccentOption) -> Color {
        option.contrastingGlyph
    }

    /// The selected-swatch ring's primary stroke: the card's contrasting
    /// foreground (near-white on the scrimmed dark shell in both glass states), so
    /// the ring clears the 3:1 graphical floor on the card — a fixed white ring fell
    /// to ~1.6–2.2:1 on the old bare light-accent card (the bug). Same surface model
    /// the copy resolves against.
    private var selectionRing: RGBColor {
        ContrastRatio.contrastingForeground(on: cardSurface)
    }

    /// The thin companion stroke just inside the ring, in the opposite near-pure
    /// endpoint, so the ring keeps an edge where it crosses the accent swatch fill
    /// (which can match the primary stroke's tone). Low opacity — it's only a
    /// separator, not the primary affordance.
    private var selectionRingCompanion: Color {
        let opposite = selectionRing == ContrastRatio.near.black
            ? ContrastRatio.near.white : ContrastRatio.near.black
        return opposite.color.opacity(0.5)
    }

    // MARK: - Theme cards

    private func themeCard(_ card: (mode: ThemeModeEx, icon: String, label: String, description: String, recommended: Bool)) -> some View {
        let isSelected = coordinator.selectedTheme == card.mode
        return Button {
            HapticService.shared.fire(.uiToggle)
            withAnimation(SteddiMotion.resolve(TransitionKit.spring(TransitionKit.springButton))) {
                coordinator.selectedTheme = card.mode
            }
        } label: {
            // Foreground for everything in this row, contrasted against the row's
            // OWN composited surface (the small white wash over the scrimmed dark
            // shell), so it resolves near-white in both glass states — see
            // `onThemeCard`. The whole row shares one resolved color.
            let rowForeground = onThemeCard(selected: isSelected)
            HStack(spacing: 14) {
                Image(systemName: card.icon)
                    .font(.title2)
                    .frame(width: 32)
                    // On-surface legible glyph regardless of selection. Fixed white
                    // failed AA on the light accents; an accent glyph on the tinted
                    // card was accent-on-accent and near-invisible. Selection is
                    // signaled by the wash + border + checkmark, so the icon just
                    // needs to read: full strength selected, dimmed deselected.
                    .foregroundStyle(isSelected ? rowForeground : rowForeground.opacity(0.7))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(card.label)
                            .font(.headline)
                            .foregroundStyle(rowForeground)
                            // At the largest Dynamic Type sizes the headline + the
                            // "Recommended" chip can exceed the label column. Let
                            // the label shrink-to-fit on one line (mirroring the
                            // HUD-mock guard in OnboardingTurnByTurnView) so the row
                            // never clips or pushes the chip into an overflow — the
                            // chip itself stays fixed-size (below) so its pill never
                            // wraps internally.
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if card.recommended {
                            recommendedChip(over: themeCardSurface(selected: isSelected))
                        }
                    }
                    Text(card.description)
                        .font(.caption)
                        .foregroundStyle(rowForeground)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(rowForeground)
                        .font(.title3)
                        .transition(.opacity)
                }
            }
            .padding(14)
            .background(
                // A white wash over the (scrimmed, dark) card shell distinguishes
                // the selected row (0.12) from deselected (0.05). The wash LIGHTENS
                // the surface, so the row copy contrasts against this composite via
                // `onThemeCard` (the `themeCardSurface` model is exactly this fill
                // over the scrimmed shell). Kept low so even the selected row stays
                // dark enough for near-white copy to clear ≥5:1 on every accent (a
                // 0.18 wash dipped gold to ~4.4:1). Selection is reinforced by the
                // on-surface border below and the checkmark.
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
            )
            .overlay(
                // Selected border in the row's on-surface foreground (near-black on
                // light accents, near-white on dark) so the affordance reads on
                // every tint — a fixed-white border washed out on the light accents.
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? onThemeCard(selected: true).opacity(0.8) : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    /// The "Recommended" chip. Its background is SELF-CONTAINED and surface-
    /// independent: the prior `Color.black.opacity(0.35)` capsule was translucent,
    /// so over the bright accent card it stayed light and white text on it fell to
    /// ~2.95:1. Instead the capsule is filled with a SOLID contrasting tone for the
    /// EFFECTIVE card surface (the `surface` passed in branches on glass
    /// availability and is DARK in both states, so `contrastingForeground(on:)` →
    /// near-white) and the text is the contrasting tone for THAT capsule fill — so
    /// text-on-chip is a fixed black/white pairing at ~17:1 on every accent in both
    /// glass states, well clear of AA for the small caption2 label.
    private func recommendedChip(over surface: RGBColor) -> some View {
        let capsuleFill = SteddiTheme.contrastingForeground(on: surface)
        // The capsule fill is one of the two near-pure endpoints; pick the other
        // for the text. `contrastingForeground` resolves it from the fill's
        // luminance, giving a guaranteed >=17:1 black/white pairing.
        let capsuleFillRGB = ContrastRatio.contrastingForeground(on: surface)
        return Text("Recommended")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(SteddiTheme.contrastingForeground(on: capsuleFillRGB))
            // Keep the chip on one line at its natural width so its pill never
            // wraps into a broken two-line capsule at large Dynamic Type. The
            // adjacent label shrink-to-fits to make room (see `themeCard`); the
            // chip stays crisp.
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(capsuleFill, in: Capsule())
    }
}

/// Deterministic, UIKit-free model of the surfaces the theme beat's copy sits on,
/// so the on-surface foreground choice (`contrastingForeground`) is computed
/// against the same pinned values the unit tests assert — no live-glass guessing.
///
/// HISTORY — the 4th-time-recurring theme-beat bug. The theme beat used to keep
/// its glass accent-tinted with NO scrim, and modelled the glass-on surface as the
/// RAW accent ("the OS frost only lightens, so raw accent is a conservative dark
/// bound"). That premise was FALSE: measured on device, the accent-tinted glass
/// composites DARKER than the raw accent over the dark cinematic backdrop (default
/// lavender renders ~L0.19–0.21 vs the modelled raw L0.31). The composited tinted
/// surface sits in the worst luminance band (~0.15–0.25) where NEITHER near-black
/// nor near-white clears a 5:1 margin, so the near-black copy the old model chose
/// landed at only ~4.2–4.5:1 (AT/below the AA floor) — and worse on the darker
/// accents. No fixed copy color can rescue the bare tinted card.
///
/// THE DEFINITIVE FIX — the theme beat now gets a PARTIAL dark scrim
/// (`themeScrimOpacity`) behind its content too (`OnboardingShowpieceCard`), so the
/// accent tint still glows through (the delight peak) while the surface goes
/// reliably DARK in BOTH glass states. The copy resolves near-WHITE on that dark
/// surface either way, clearing AA with MARGIN (≥5:1 body) for every accent:
///   - glass AVAILABLE: the partial scrim over the (lightest-plausible) tinted
///     glass — modelled conservatively LIGHT so the asserted near-white ratio is a
///     lower bound the real, darker render beats.
///   - glass UNAVAILABLE (Reduce Transparency / Increase Contrast): `steddiGlass`
///     paints the solid dark `onboardingCardFallbackFill` (the accent tint is
///     discarded); the scrim over it stays dark, copy stays near-white.
///
/// These pure functions are the single source of truth the view's `cardSurface` /
/// `themeCardSurface` delegate to, that `ThemeContrastTests.onboardingTheme*`
/// measure the per-accent contrast against in BOTH glass states, and that
/// `OnboardingFrostMeasurementTests` confirm an ImageRenderer composite is no
/// lighter than.
enum ThemeBeatSurface {
    /// Opacity of the partial dark scrim painted behind the theme beat's content
    /// (the showcase/ask beats use 0.94). Tuned so the surface — over even the
    /// LIGHTEST plausible tinted glass — is dark enough that near-white copy clears
    /// ≥5:1 with margin on every accent, while the accent tint still reads through
    /// at ~35% so the delight peak survives. Shared by the view's scrim and the
    /// surface model so they can never disagree.
    static let themeScrimOpacity: Double = 0.65

    /// The LIGHTEST plausible accent-tinted glass surface (no scrim): the accent
    /// hue mixed halfway toward a light neutral frost. The live OS glass can render
    /// the tint anywhere between the dark-composited tint and a lightened frost;
    /// this is the LIGHT extreme. Modelling the scrim over THIS (rather than the
    /// dark-composited tint) is the conservative choice for near-white copy — a
    /// lighter pre-scrim surface yields a lighter post-scrim surface, so the
    /// asserted near-white ratio is the worst case the real render beats.
    static func tintedGlassLightest(accent: RGBColor) -> RGBColor {
        let frost = RGBColor(0.80, 0.80, 0.82)
        return RGBColor((accent.r + frost.r) / 2,
                        (accent.g + frost.g) / 2,
                        (accent.b + frost.b) / 2)
    }

    /// `top` source-over `bottom` at `opacity`.
    private static func over(_ top: RGBColor, _ bottom: RGBColor, opacity a: Double) -> RGBColor {
        RGBColor(top.r * a + bottom.r * (1 - a),
                 top.g * a + bottom.g * (1 - a),
                 top.b * a + bottom.b * (1 - a))
    }

    /// The card-shell surface the bare copy (header, section titles/subtitles)
    /// sits on. DARK in both glass states (so the copy is always near-white):
    ///   - glass ON: the partial dark scrim (`themeScrimOpacity`) over the
    ///     lightest-plausible tinted glass — conservatively light so the model is a
    ///     lower bound the (darker) real render beats.
    ///   - glass OFF: the solid dark `onboardingCardFallbackFill` `steddiGlass`
    ///     paints (its composite over the even-darker backdrop is darker still, so
    ///     the bare fill is again the conservative bound).
    static func cardShell(accent: RGBColor, glassAvailable: Bool) -> RGBColor {
        guard glassAvailable else { return SteddiTheme.onboardingCardFallbackFillRGB }
        return over(SteddiTheme.onboardingCardFallbackFillRGB,
                    tintedGlassLightest(accent: accent),
                    opacity: themeScrimOpacity)
    }

    /// The composited surface of a theme-selection card row: the row's white wash
    /// (`.opacity(0.12)` selected / `.opacity(0.05)` deselected) source-over the
    /// effective (scrimmed) card shell, matching the `RoundedRectangle.fill(.white
    /// .opacity)` the view draws. The wash lightens the dark surface a little; the
    /// opacities are tuned so even the selected row stays dark enough for near-white
    /// copy to clear ≥5:1 on every accent (a 0.18 wash dipped gold to ~4.4:1).
    static func themeCard(accent: RGBColor, selected: Bool, glassAvailable: Bool) -> RGBColor {
        let a = selected ? 0.12 : 0.05
        let s = cardShell(accent: accent, glassAvailable: glassAvailable)
        return RGBColor(1 * a + s.r * (1 - a),
                        1 * a + s.g * (1 - a),
                        1 * a + s.b * (1 - a))
    }
}

extension SteddiTheme.AccentOption {
    /// A checkmark/glyph color that contrasts the accent fill. Steddi's accents
    /// are all light pastels, so a hard-coded white check is illegible on them
    /// (gold ~2.4:1, worst). Choose a near-black glyph on light accents and white
    /// on dark ones, keyed off the accent's relative luminance (Rec. 709). A dark
    /// glyph gives 6–9:1 across the whole palette. Shared by the onboarding and
    /// Settings accent pickers.
    var contrastingGlyph: Color {
        let c = uiColor
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        // Near-black (not pure black) on light accents reads as a deliberate glyph
        // rather than a hole; white on the (currently none) dark accents.
        return luminance > 0.5 ? Color(red: 0.10, green: 0.09, blue: 0.08) : .white
    }
}
