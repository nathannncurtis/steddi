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

    private let accents = SteddiTheme.AccentOption.allCases
    private let themeCards: [(mode: ThemeModeEx, icon: String, label: String, description: String, recommended: Bool)] = [
        (.dynamic, "sun.horizon.fill", "Dynamic", "Light by day, dark by night", true),
        (.dark, "moon.fill", "Dark", "Always dark", false),
        (.light, "sun.max.fill", "Light", "Always light", false),
    ]

    var body: some View {
        ScrollView {
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

    private var accentPicker: some View {
        HStack(spacing: 14) {
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
                .frame(width: 40, height: 40)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .transition(.opacity)
                    }
                }
                .overlay {
                    Circle()
                        .stroke(option.color, lineWidth: 3)
                        .frame(width: 50, height: 50)
                        .opacity(isSelected ? 1 : 0)
                }
                .scaleEffect(isSelected ? 1.0 : 0.97)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
