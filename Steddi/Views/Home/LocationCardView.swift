import SwiftUI

struct LocationCardView: View {
    let name: String
    let icon: String
    let etaMinutes: Int?
    let delayMinutes: Int?
    let onTap: () -> Void

    var trafficColor: Color {
        guard let delay = delayMinutes else { return .green }
        if delay <= 2 { return .green }
        if delay <= 8 { return .orange }
        return .red
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    if let eta = etaMinutes {
                        Text("\(eta) min")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                if let delay = delayMinutes, delay > 2 {
                    Text("+\(delay)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(trafficColor, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
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
                etaMinutes: 45,
                delayMinutes: 12,
                onTap: {}
            )
        }
    }
}
