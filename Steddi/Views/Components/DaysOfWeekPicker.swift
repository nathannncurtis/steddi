import SwiftUI

/// Compact day-of-week selector for zone time windows. Binds to a set of
/// `Calendar` weekday numbers (Sun = 1 … Sat = 7) so it lines up directly with
/// `TimeWindow.daysOfWeek` and `Calendar.component(.weekday:)`.
struct DaysOfWeekPicker: View {
    @Binding var selected: Set<Int>

    // index 0 -> weekday 1 (Sunday), … index 6 -> weekday 7 (Saturday)
    private let labels = ["S", "M", "T", "W", "T", "F", "S"]
    // Full weekday names so VoiceOver disambiguates the duplicate single-letter
    // glyphs (two "S" = Sun/Sat, two "T" = Tue/Thu read identically otherwise).
    private let fullNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<7, id: \.self) { index in
                let weekday = index + 1
                let isOn = selected.contains(weekday)
                Button {
                    if isOn { selected.remove(weekday) } else { selected.insert(weekday) }
                } label: {
                    Text(labels[index])
                        .font(SteddiTheme.body(14).weight(.semibold))
                        // On-fill label: pair the brand-hue fill with `onAccent`
                        // (the documented on-fill foreground), which picks
                        // black/white per the accent's luminance and clears AA
                        // on every accent in every theme. The text-safe `accent`
                        // fill + onAccent would collapse to ~3:1 in light mode
                        // (dark-on-darkened-fill) and white would vanish on the
                        // near-white pastel the accent becomes in grey.
                        .foregroundStyle(isOn ? SteddiTheme.onAccent : SteddiTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        // 44pt minimum tap target (was 38) — the cell stays
                        // visually compact but the hit area meets the HIG floor,
                        // matching the IconPickerView convention.
                        .frame(height: 44)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isOn ? SteddiTheme.accentBrand : SteddiTheme.surfaceElevated)
                        )
                }
                .buttonStyle(.plain)
                // Distinct, stateful VoiceOver label — full weekday name plus the
                // on/off trait so a non-sighted user can tell which day they're
                // toggling (the single-letter glyphs are ambiguous).
                .accessibilityLabel(fullNames[index])
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }
}
