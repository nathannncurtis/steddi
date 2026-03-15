import SwiftUI

/// Steddi's visual identity — warm, steady, confident.
enum SteddiTheme {

    // MARK: - Signature Colors

    /// Warm amber — Steddi's signature. Used for primary actions, accents, brand moments.
    static let amber = Color(red: 0.79, green: 0.54, blue: 0.02)        // #CA8A04
    static let amberLight = Color(red: 0.96, green: 0.75, blue: 0.03)   // #F5BF03
    static let amberSubtle = Color(red: 0.79, green: 0.54, blue: 0.02).opacity(0.15)

    /// Sage green — "all clear" / "good to go" states.
    static let sage = Color(red: 0.13, green: 0.74, blue: 0.45)         // #22BD73
    static let sageSubtle = Color(red: 0.13, green: 0.74, blue: 0.45).opacity(0.15)

    /// Soft red — warnings, delays, problems. Not alarming.
    static let warmRed = Color(red: 0.91, green: 0.30, blue: 0.24)      // #E84D3D
    static let warmRedSubtle = Color(red: 0.91, green: 0.30, blue: 0.24).opacity(0.15)

    /// Surface colors for dark mode floating elements
    static let surfacePrimary = Color(red: 0.11, green: 0.10, blue: 0.09)    // #1C1917 — warm dark
    static let surfaceSecondary = Color(red: 0.17, green: 0.16, blue: 0.15)  // #2B2826
    static let surfaceElevated = Color(red: 0.22, green: 0.21, blue: 0.19)   // #383532

    /// Text
    static let textPrimary = Color(red: 0.97, green: 0.96, blue: 0.95)  // #F8F5F2 — warm white
    static let textSecondary = Color(red: 0.66, green: 0.63, blue: 0.60) // #A8A199
    static let textMuted = Color(red: 0.46, green: 0.44, blue: 0.42)    // #75706B

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
            case .moderate: return SteddiTheme.amber
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
    var color: Color = SteddiTheme.amber
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
                            .stroke(SteddiTheme.amber.opacity(0.12), lineWidth: 1)
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
                        .foregroundStyle(SteddiTheme.amber)
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
