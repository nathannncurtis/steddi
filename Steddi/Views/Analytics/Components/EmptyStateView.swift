import SwiftUI

/// Intentional empty state for analytics surfaces — warm and forward-
/// looking rather than a bare "no data" shrug.
struct AnalyticsEmptyStateView: View {
    var icon: String = "chart.xyaxis.line"
    var title: String = "No drives yet"
    var message: String = "Finish a navigation and your commute story starts here."

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(SteddiTheme.accentSubtle)
                    .frame(width: 84, height: 84)
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(SteddiTheme.accent)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(SteddiTheme.heading(20))
                    .foregroundStyle(SteddiTheme.textPrimary)
                Text(message)
                    .font(SteddiTheme.body(14))
                    .foregroundStyle(SteddiTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SteadyLine()
                .frame(width: 120)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 72)
    }
}

#Preview {
    ZStack {
        SteddiTheme.surfacePrimary.ignoresSafeArea()
        AnalyticsEmptyStateView()
    }
}
