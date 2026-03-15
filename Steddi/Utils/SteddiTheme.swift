import SwiftUI

/// Steddi's visual identity — warm, steady, confident.
enum SteddiTheme {

    // MARK: - Signature Colors

    /// Soft Lavender — Steddi's signature. Quiet confidence, calm, different.
    static let accent = Color(red: 0.61, green: 0.56, blue: 0.77)       // #9B8EC4
    static let accentLight = Color(red: 0.73, green: 0.68, blue: 0.87)  // #BAADDE
    static let accentSubtle = Color(red: 0.61, green: 0.56, blue: 0.77).opacity(0.15)

    /// Sage green — "all clear" / "good to go" states.
    static let sage = Color(red: 0.13, green: 0.74, blue: 0.45)         // #22BD73
    static let sageSubtle = Color(red: 0.13, green: 0.74, blue: 0.45).opacity(0.15)

    /// Soft red — warnings, delays, problems. Not alarming.
    static let warmRed = Color(red: 0.91, green: 0.30, blue: 0.24)      // #E84D3D
    static let warmRedSubtle = Color(red: 0.91, green: 0.30, blue: 0.24).opacity(0.15)

    /// Surface colors — adaptive for light/dark mode
    static let surfacePrimary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1) // warm dark
            : UIColor(red: 0.98, green: 0.97, blue: 0.96, alpha: 1) // warm white
    })
    static let surfaceSecondary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.17, green: 0.16, blue: 0.15, alpha: 1)
            : UIColor(red: 0.94, green: 0.93, blue: 0.92, alpha: 1)
    })
    static let surfaceElevated = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.22, green: 0.21, blue: 0.19, alpha: 1)
            : UIColor(red: 0.90, green: 0.89, blue: 0.88, alpha: 1)
    })

    /// Text — adaptive
    static let textPrimary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.97, green: 0.96, blue: 0.95, alpha: 1) // warm white
            : UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1) // warm dark
    })
    static let textSecondary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.66, green: 0.63, blue: 0.60, alpha: 1)
            : UIColor(red: 0.45, green: 0.43, blue: 0.41, alpha: 1)
    })
    static let textMuted = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.46, green: 0.44, blue: 0.42, alpha: 1)
            : UIColor(red: 0.60, green: 0.58, blue: 0.56, alpha: 1)
    })

    // MARK: - Typography

    /// Confident, weighted heading style
    static func heading(_ size: CGFloat = 20) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    /// Body text — clean and readable
    static func body(_ size: CGFloat = 16) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    /// Mono for numbers (ETAs, times, distances)
    static func mono(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    // MARK: - Corner Radii

    static let radiusSmall: CGFloat = 10
    static let radiusMedium: CGFloat = 16
    static let radiusLarge: CGFloat = 24
    static let radiusCard: CGFloat = 20

    // MARK: - Traffic Status

    enum TrafficStatus {
        case clear, moderate, heavy, unknown

        var color: Color {
            switch self {
            case .clear: return SteddiTheme.sage
            case .moderate: return SteddiTheme.accent
            case .heavy: return SteddiTheme.warmRed
            case .unknown: return SteddiTheme.textMuted
            }
        }

        var label: String {
            switch self {
            case .clear: return "Clear"
            case .moderate: return "Moderate"
            case .heavy: return "Heavy"
            case .unknown: return "—"
            }
        }
    }
}

// MARK: - Steady Pulse Motif

/// The signature "steady line" visual — a flat, calm line that subtly pulses.
/// Used as a brand element on cards, headers, dividers.
struct SteadyLine: View {
    var color: Color = SteddiTheme.accent
    var height: CGFloat = 2
    @State private var phase: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [color.opacity(0.0), color, color, color.opacity(0.0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: height)
            .mask(
                Rectangle()
                    .frame(height: height)
            )
    }
}

/// Amber-tinted glass background for Steddi's floating cards
struct SteddiCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                    .fill(SteddiTheme.surfacePrimary.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                            .stroke(SteddiTheme.accent.opacity(0.12), lineWidth: 1)
                    )
            }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 20) {
            SteadyLine()
                .padding(.horizontal, 40)

            SteddiCard {
                HStack {
                    Image(systemName: "house.fill")
                        .foregroundStyle(SteddiTheme.accent)
                    Text("Home")
                        .font(SteddiTheme.heading(16))
                        .foregroundStyle(SteddiTheme.textPrimary)
                    Spacer()
                    Text("12 min")
                        .font(SteddiTheme.mono(14))
                        .foregroundStyle(SteddiTheme.sage)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}
