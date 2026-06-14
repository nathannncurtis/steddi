import SwiftUI

/// Reusable 5-column SF Symbol picker for place icons. Extracted from
/// AddLocationSheet so the add / save / (future) edit flows share one
/// implementation. Options are derived from `PlaceCategory.iconOptions(for:)`
/// so the selected category's symbol leads, but any icon stays selectable —
/// category is a grouping hint, not a constraint.
struct PlaceIconPickerView: View {
    @Binding var selectedIcon: String
    var category: PlaceCategory?

    private var options: [(symbol: String, label: String)] {
        PlaceCategory.iconOptions(for: category)
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
            ForEach(options, id: \.symbol) { option in
                let isSelected = selectedIcon == option.symbol
                Button {
                    selectedIcon = option.symbol
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: option.symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isSelected ? .white : SteddiTheme.accent)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(isSelected ? SteddiTheme.accent : SteddiTheme.accentSubtle)
                            )
                        Text(option.label)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? SteddiTheme.textPrimary : SteddiTheme.textMuted)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.label) icon")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    struct Wrapper: View {
        @State private var icon = "house.fill"
        var body: some View {
            Form {
                Section("Icon") {
                    PlaceIconPickerView(selectedIcon: $icon, category: .home)
                }
            }
        }
    }
    return Wrapper()
}
