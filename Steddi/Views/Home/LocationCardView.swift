import SwiftUI

struct LocationCardView<Menu: View>: View {
    let name: String
    let icon: String
    let etaMinutes: Int?
    let delayMinutes: Int?
    /// Optional category for the color/label chip. nil hides the chip.
    var category: PlaceCategory? = nil
    let onTap: () -> Void
    /// Optional trailing overflow menu (review links, delete, etc.).
    @ViewBuilder var trailingMenu: () -> Menu
    @AppStorage("accentColor") private var accentColor = "lavender"

    private var trafficStatus: SteddiTheme.TrafficStatus {
        guard let delay = delayMinutes else { return .unknown }
        if delay <= 2 { return .clear }
        if delay <= 8 { return .moderate }
        return .heavy
    }

    /// Legible foreground for the "+N" badge, drawn on the `trafficStatus.color`
    /// FILL. White fails AA/3:1 on the amber (`.moderate`) and sage (`.clear`)
    /// fills, so pick black/white per WCAG against each status's underlying fill
    /// hue (`.moderate` defers to the accent-aware `onAccent`, since its fill is
    /// the live accent brand). `.unknown` never reaches the badge (it only shows
    /// when `delay > 2`, where `trafficStatus` is `.clear`/`.moderate`/`.heavy`),
    /// so it falls back to the accent-aware on-fill color for completeness.
    private var badgeForeground: Color {
        switch trafficStatus {
        case .clear: return SteddiTheme.contrastingForeground(on: SteddiTheme.sageRGB)
        case .moderate: return SteddiTheme.onAccent
        case .heavy: return SteddiTheme.contrastingForeground(on: SteddiTheme.warmRedRGB)
        case .unknown: return SteddiTheme.onAccent
        }
    }

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon with amber accent background
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(SteddiTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(SteddiTheme.accentSubtle, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(SteddiTheme.heading(15))
                            .foregroundStyle(SteddiTheme.textPrimary)

                        if let category, category != .other {
                            Text(category.displayName)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(category.labelColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(category.themeColor.opacity(0.15), in: Capsule())
                        }
                    }

                    if let eta = etaMinutes {
                        HStack(spacing: 6) {
                            Text("\(eta) min")
                                .font(SteddiTheme.mono(13))
                                .foregroundStyle(trafficStatus.color)

                            if let delay = delayMinutes, delay > 2 {
                                Text("+\(delay)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(badgeForeground)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(trafficStatus.color, in: Capsule())
                            }
                        }
                    }
                }

                Spacer(minLength: 4)

                // Trailing overflow menu (review links, delete) or a chevron.
                if Menu.self != EmptyView.self {
                    SwiftUI.Menu {
                        trailingMenu()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(SteddiTheme.textMuted)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel("More options")
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SteddiTheme.textMuted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                    .fill(SteddiTheme.surfacePrimary.opacity(0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                            .stroke(SteddiTheme.accent.opacity(0.08), lineWidth: 1)
                    )
            }
        }
        .buttonStyle(.plain)
    }
}

extension LocationCardView where Menu == EmptyView {
    /// Convenience initializer for cards without a trailing menu — keeps the
    /// existing chevron-only call sites unchanged.
    init(
        name: String,
        icon: String,
        etaMinutes: Int?,
        delayMinutes: Int?,
        category: PlaceCategory? = nil,
        onTap: @escaping () -> Void
    ) {
        self.init(
            name: name,
            icon: icon,
            etaMinutes: etaMinutes,
            delayMinutes: delayMinutes,
            category: category,
            onTap: onTap,
            trailingMenu: { EmptyView() }
        )
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack(spacing: 12) {
            LocationCardView(
                name: "Work",
                icon: "building.2.fill",
                etaMinutes: 24,
                delayMinutes: 0,
                onTap: {}
            )
            LocationCardView(
                name: "Home",
                icon: "house.fill",
                etaMinutes: 32,
                delayMinutes: 6,
                onTap: {}
            )
            LocationCardView(
                name: "Gym",
                icon: "figure.run",
                etaMinutes: nil,
                delayMinutes: nil,
                onTap: {}
            )
        }
        .padding(.horizontal, 20)
    }
}
