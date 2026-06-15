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
                .foregroundStyle(coordinator.selectedAccent.color)
            Text("Make it yours")
                .font(.title.weight(.bold))
                .foregroundStyle(SteddiTheme.textPrimary)
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundStyle(SteddiTheme.textPrimary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(SteddiTheme.textSecondary)
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
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(checkmarkColor(for: option))
                            .transition(.opacity)
                    }
                }
                .overlay {
                    Circle()
                        .stroke(option.color, lineWidth: 3)
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
            HStack(spacing: 14) {
                Image(systemName: card.icon)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(isSelected ? coordinator.selectedAccent.color : SteddiTheme.textSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(card.label)
                            .font(.headline)
                            .foregroundStyle(SteddiTheme.textPrimary)
                        if card.recommended {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(coordinator.selectedAccent.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(coordinator.selectedAccent.color.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(card.description)
                        .font(.caption)
                        .foregroundStyle(SteddiTheme.textSecondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(coordinator.selectedAccent.color)
                        .font(.title3)
                        .transition(.opacity)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? coordinator.selectedAccent.color.opacity(0.12) : SteddiTheme.surfaceSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? coordinator.selectedAccent.color : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
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
