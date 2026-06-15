import SwiftUI

/// Pill button style for the no-go zone editor's drawing-mode picker. Selected
/// modes fill with the accent color; unselected modes use an elevated surface.
struct ModeButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SteddiTheme.body(12).weight(.semibold))
            .foregroundStyle(isSelected ? SteddiTheme.onAccent : SteddiTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? SteddiTheme.accent : SteddiTheme.surfaceElevated)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
