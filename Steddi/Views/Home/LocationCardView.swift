import SwiftUI

struct LocationCardView: View {
    let name: String
    let icon: String
    let etaMinutes: Int?
    let delayMinutes: Int?
    let onTap: () -> Void

    private var trafficStatus: SteddiTheme.TrafficStatus {
        guard let delay = delayMinutes else { return .unknown }
        if delay <= 2 { return .clear }
        if delay <= 8 { return .moderate }
        return .heavy
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon with amber accent background
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(SteddiTheme.amber)
                    .frame(width: 36, height: 36)
                    .background(SteddiTheme.amberSubtle, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(SteddiTheme.heading(15))
                        .foregroundStyle(SteddiTheme.textPrimary)

                    if let eta = etaMinutes {
                        HStack(spacing: 6) {
                            Text("\(eta) min")
                                .font(SteddiTheme.mono(13))
                                .foregroundStyle(trafficStatus.color)

                            if let delay = delayMinutes, delay > 2 {
                                Text("+\(delay)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(trafficStatus.color, in: Capsule())
                            }
                        }
                    }
                }

                Spacer(minLength: 4)

                // Subtle chevron
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SteddiTheme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                    .fill(SteddiTheme.surfacePrimary.opacity(0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium)
                            .stroke(SteddiTheme.amber.opacity(0.08), lineWidth: 1)
                    )
            }
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
                etaMinutes: nil,
                delayMinutes: nil,
                onTap: {}
            )
        }
        .padding(.horizontal, 20)
    }
}
