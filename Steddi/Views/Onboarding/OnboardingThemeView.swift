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
    @Bindable var coordinator: OnboardingCoordinator

    /// Swatch diameter scales with Dynamic Type but stays bounded so the row
    /// never balloons off-card. The selected ring is drawn 10pt larger.
    @ScaledMetric(relativeTo: .body) private var swatchSize: CGFloat = 40

    private let accents = SteddiTheme.AccentOption.allCases
    private let themeCards: [(mode: ThemeModeEx, icon: String, label: String, description: String, recommended: Bool)] = [
        (.dynamic, "sun.horizon.fill", "Dynamic", "Light by day, dark by night", true),
        (.dark, "moon.fill", "Dark", "Always dark", false),
        (.light, "sun.max.fill", "Light", "Always light", false),
    ]

    // MARK: - On-surface legible foreground (the theme beat has no dark scrim)
    //
    // The theme beat is the one showcase beat that keeps its glass ACCENT-TINTED
    // (the delight peak — a swatch tap recolors the card live), so it is exempt
    // from the deterministic dark scrim every other beat uses. That left the
    // fixed-white copy sitting directly on a bright accent surface, failing AA on
    // the light accents (gold subtitle 2.26:1; selected 'Light' description
    // 1.92:1 — the worst string in the flow). Instead of forcing the copy white,
    // every label / description / icon / 'Recommended' chip on this beat resolves
    // its color from `SteddiTheme.contrastingForeground(on:)` against the ACTUAL
    // surface it sits on — so on light accents (gold/sage/light) it becomes
    // near-black and clears AA, and on a dark accent it would stay near-white.
    // (`contrastingForeground` flips at WCAG luminance 0.179; every current accent
    // sits well above it, so the copy resolves near-black at ≥5.3:1 on the worst
    // accent. Verified for every accent in `ThemeContrastTests.onboardingTheme*`.)

    /// The card-shell surface the bare copy (header, section titles/subtitles)
    /// sits on: the live accent tint.
    private var cardSurface: RGBColor { ThemeBeatSurface.cardShell(accent: coordinator.selectedAccent.rgb) }

    /// Foreground for copy drawn directly on the accent-tinted card shell.
    private var onCardPrimary: Color { SteddiTheme.contrastingForeground(on: cardSurface) }

    /// Foreground for a theme-selection card row, contrasted against THAT card's
    /// own composited surface. The row draws a white wash over the accent shell
    /// (`.opacity(0.18)` selected / `.opacity(0.08)` deselected), which only
    /// LIGHTENS the surface, so the label/description must contrast with this
    /// composite — not the bare shell, and not a global assumption.
    private func onThemeCard(selected: Bool) -> Color {
        SteddiTheme.contrastingForeground(on: themeCardSurface(selected: selected))
    }

    /// The composited surface of a theme-selection card row.
    private func themeCardSurface(selected: Bool) -> RGBColor {
        ThemeBeatSurface.themeCard(accent: coordinator.selectedAccent.rgb, selected: selected)
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
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 56))
                // On-surface legible, NOT fixed white: the card shell is tinted to
                // the chosen accent, so on the light accents white collapsed to
                // ~2.3:1. `onCardPrimary` resolves near-black on light accents
                // (and would stay white on a dark one), so the glyph reads on every
                // tint — the same on-surface rule the copy below follows.
                .foregroundStyle(onCardPrimary)
            Text("Make it yours")
                .font(.title.weight(.bold))
                // On-surface legible against the accent-tinted shell (see
                // `onCardPrimary`): fixed white failed AA on the light accents.
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
                // The subtitle sits on the same accent shell; resolve it on-surface
                // (was fixed white-.92, the worst bare-glass string — gold 2.26:1).
                // Kept at full opacity, NOT dimmed: a body-size subheadline must
                // clear the 4.5 AA floor, and on the conservative raw-accent model
                // a dimmed near-black would dip below it (ocean/slate ~4.2). The
                // smaller, regular-weight font already ranks it below the headline
                // title.
                .foregroundStyle(onCardPrimary)
        }
    }

    // MARK: - Accent picker

    /// Wrapping, Dynamic-Type-aware accent grid. A fixed six-wide HStack of 40pt
    /// swatches needs ~310pt and overflowed the centered glass card on standard
    /// iPhones (and worse at large text). An adaptive grid wraps to a second row
    /// instead of spilling off-card, and the swatch size is @ScaledMetric-capped
    /// so it grows with text without unbounded growth.
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
                // Fixed light hairline so every swatch is bounded against the
                // accent-tinted theme card — the SELECTED swatch's fill equals
                // the card tint, so without this it dissolves into the card.
                .overlay { Circle().stroke(.white.opacity(0.5), lineWidth: 1.5) }
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(checkmarkColor(for: option))
                            .transition(.opacity)
                    }
                }
                .overlay {
                    // Selected ring in fixed white — the accent ring matched the
                    // recolored card and vanished. White reads on any accent.
                    Circle()
                        .stroke(.white.opacity(0.9), lineWidth: 3)
                        .frame(width: swatchSize + 10, height: swatchSize + 10)
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
            // OWN composited surface (the white wash over the accent shell), so it
            // reads near-black on light accents and would stay near-white on a dark
            // one — see `onThemeCard`. The whole row shares one resolved color.
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
                // A white wash over the accent shell distinguishes the selected row
                // (0.18) from deselected (0.08). The wash LIGHTENS the surface, so
                // the row copy contrasts against this composite via `onThemeCard`
                // (the `themeCardSurface` model is exactly this fill over the
                // accent). Selection is reinforced by the on-surface border below
                // and the checkmark.
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
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

    /// The "Recommended" chip. Its background is SELF-CONTAINED and accent-
    /// independent: the prior `Color.black.opacity(0.35)` capsule was translucent,
    /// so over the bright accent card it stayed light and white text on it fell to
    /// ~2.95:1 (the comment claimed ~8:1, which only held over a dark card — and
    /// the theme beat has no dark card). Instead the capsule is filled with a SOLID
    /// contrasting tone for the card surface (`contrastingForeground(on: surface)`
    /// → near-black on light accents, near-white on dark) and the text is the
    /// contrasting tone for THAT capsule fill — so text-on-chip is a fixed
    /// black/white pairing at ~17:1 on every accent, well clear of AA for the small
    /// caption2 label.
    private func recommendedChip(over surface: RGBColor) -> some View {
        let capsuleFill = SteddiTheme.contrastingForeground(on: surface)
        // The capsule fill is one of the two near-pure endpoints; pick the other
        // for the text. `contrastingForeground` resolves it from the fill's
        // luminance, giving a guaranteed >=17:1 black/white pairing.
        let capsuleFillRGB = ContrastRatio.contrastingForeground(on: surface)
        return Text("Recommended")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(SteddiTheme.contrastingForeground(on: capsuleFillRGB))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(capsuleFill, in: Capsule())
    }
}

/// Deterministic, UIKit-free model of the surfaces the theme beat's copy sits on,
/// so the on-surface foreground choice (`contrastingForeground`) is computed
/// against the same pinned values the unit tests assert — no live-glass guessing.
///
/// The theme beat keeps its glass ACCENT-TINTED (the delight peak), exempt from
/// the dark scrim the other beats use, so its copy must contrast the accent rather
/// than assume a dark card. These pure functions are the single source of truth
/// the view's `cardSurface` / `themeCardSurface` delegate to, and that
/// `ThemeContrastTests.onboardingTheme*` measure the per-accent contrast against.
enum ThemeBeatSurface {
    /// The card-shell surface the bare copy (header, section titles/subtitles)
    /// sits on. Modelled as the RAW accent hue — the DARKEST plausible surface,
    /// since the OS frost only LIGHTENS the live glass, and for the near-black
    /// foreground these light accents resolve to a lighter surface only raises
    /// contrast. So the modelled ratio is a conservative lower bound the real card
    /// beats, the same way the showcase beats pin `OnboardingShowcaseFrost.surface`.
    static func cardShell(accent: RGBColor) -> RGBColor { accent }

    /// The composited surface of a theme-selection card row: white at the row's
    /// wash opacity over the accent shell (`.opacity(0.18)` selected /
    /// `.opacity(0.08)` deselected). Source-over, matching the
    /// `RoundedRectangle.fill(Color.white.opacity(...))` the view draws.
    static func themeCard(accent: RGBColor, selected: Bool) -> RGBColor {
        let a = selected ? 0.18 : 0.08
        let s = cardShell(accent: accent)
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
