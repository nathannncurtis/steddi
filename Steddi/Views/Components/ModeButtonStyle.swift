import SwiftUI

/// Pill button style for the no-go zone editor's drawing-mode picker. Selected
/// modes fill with the accent color; unselected modes use an elevated surface.
struct ModeButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SteddiTheme.body(12).weight(.semibold))
            // Keep the ~5-char mode labels ("Route"/"Shape") readable in the
            // fixed screen-fifth-wide pill at large Dynamic Type: hold one line
            // and shrink-to-fit rather than truncating, matching the
            // OnboardingThemeView theme-card label shrink pattern.
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            // On-fill label: pair the brand-hue fill with `onAccent` (the
            // documented on-fill foreground). Filling with the text-safe `accent`
            // collapsed onAccent-on-fill to ~3:1 in light mode (dark-on-darkened);
            // accentBrand + onAccent clears AA on every accent in every theme.
            .foregroundStyle(isSelected ? SteddiTheme.onAccent : SteddiTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? SteddiTheme.accentBrand : SteddiTheme.surfaceElevated)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
