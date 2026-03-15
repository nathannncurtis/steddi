import SwiftUI

/// Temporary preview for picking Steddi's signature color.
/// Delete this file once a color is chosen.
struct ColorSwatchPreview: View {
    private let swatches: [(name: String, color: Color, description: String)] = [
        ("Copper",       Color(hex: "#C47A5A"), "Warm, grounded, earthy"),
        ("Dusty Rose",   Color(hex: "#C27185"), "Soft, approachable, human"),
        ("Terracotta",   Color(hex: "#C2714F"), "Honest, reliable, warm"),
        ("Slate Teal",   Color(hex: "#5B8A8A"), "Calm, steady, trustworthy"),
        ("Muted Mint",   Color(hex: "#6BAF92"), "Fresh, easy, reassuring"),
        ("Soft Lavender", Color(hex: "#9B8EC4"), "Quiet confidence, different"),
        ("Storm Blue",   Color(hex: "#5A7FA0"), "Dependable, not corporate"),
        ("Burnt Sienna", Color(hex: "#A0522D"), "Grounded, gutsy, real"),
        ("Dusk Purple",  Color(hex: "#7E6B9B"), "Calm, evening commute vibe"),
        ("Desert Sand",  Color(hex: "#C4A882"), "Neutral, warm, understated"),
        ("Faded Denim",  Color(hex: "#6E89A4"), "Everyday, familiar, worn-in"),
        ("Moss",         Color(hex: "#6B8E5A"), "Natural, steady, organic"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Pick Steddi's color")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 20)

                ForEach(swatches, id: \.name) { swatch in
                    swatchCard(swatch)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .background(Color(hex: "#1C1917").ignoresSafeArea())
    }

    private func swatchCard(_ swatch: (name: String, color: Color, description: String)) -> some View {
        HStack(spacing: 16) {
            // Color circle
            Circle()
                .fill(swatch.color)
                .frame(width: 48, height: 48)
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(swatch.name)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(swatch.description)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            // Mini UI preview
            VStack(spacing: 4) {
                // Fake search bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 8))
                        .foregroundStyle(swatch.color)
                    Text("Where to?")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .overlay(Capsule().stroke(swatch.color.opacity(0.3), lineWidth: 0.5))
                )

                // Fake location card
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(swatch.color.opacity(0.2))
                        .frame(width: 14, height: 14)
                        .overlay(
                            Image(systemName: "house.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(swatch.color)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Home")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                        Text("12 min")
                            .font(.system(size: 6, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(hex: "#22BD73"))
                    }
                    Spacer()
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(swatch.color.opacity(0.15), lineWidth: 0.5))
                )
            }
            .frame(width: 90)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(swatch.color.opacity(0.15), lineWidth: 1)
                )
        )
    }
}

// MARK: - Hex Color Helper

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        r = Double((int >> 16) & 0xFF) / 255.0
        g = Double((int >> 8) & 0xFF) / 255.0
        b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

#Preview {
    ColorSwatchPreview()
}
