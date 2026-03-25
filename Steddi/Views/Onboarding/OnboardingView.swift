import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("accentColor") private var accentColor = "lavender"
    @AppStorage("themeMode") private var themeMode = "dynamic"
    @State private var currentPage = 0
    @State private var showDonation = false

    private let pages: [(icon: String, title: String, subtitle: String, body: String)] = [
        (
            "road.lanes",
            "Welcome to Steddi",
            "Your route, your rules",
            "Steddi learns how you drive and only suggests changes when they actually matter."
        ),
        (
            "mappin.and.ellipse",
            "Pin your places",
            "Two taps to driving",
            "Save the locations you commute between. Tap a pin and go."
        ),
        (
            "car.fill",
            "Drive to learn",
            "Just drive normally",
            "Steddi records your routes so it knows YOUR preferred way, not what an algorithm guesses."
        ),
        (
            "lock.shield.fill",
            "Your data stays yours",
            "Private by design",
            "All your routes, locations, and driving data are stored on your device. Nothing is sold, shared, or sent to any server. Ever."
        ),
        (
            "slider.horizontal.3",
            "Set your threshold",
            "No nagging, ever",
            "Tell Steddi when a reroute is worth your attention. Small delays get ignored."
        ),
        (
            "circle.lefthalf.filled",
            "Choose your look",
            "Light, dark, or match your device",
            ""
        )
    ]

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
        VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    if index == themePageIndex {
                        themeSelectionPage
                            .tag(index)
                    } else {
                        VStack(spacing: 24) {
                            Spacer()

                            Image(systemName: page.icon)
                                .font(.system(size: 64))
                                .foregroundStyle(SteddiTheme.accent)
                                .padding(.bottom, 8)

                            VStack(spacing: 8) {
                                Text(page.title)
                                    .font(.title.weight(.bold))

                                Text(page.subtitle)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }

                            Text(page.body)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)

                            Spacer()
                            Spacer()
                        }
                        .tag(index)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            // Bottom button area
            VStack(spacing: 16) {
                if currentPage == pages.count - 1 {
                    Button {
                        completeOnboarding()
                    } label: {
                        Text("Get Started")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(SteddiTheme.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                } else {
                    Button {
                        withAnimation {
                            currentPage += 1
                        }
                    } label: {
                        Text("Next")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(SteddiTheme.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                }

                if currentPage < pages.count - 1 {
                    Button("Skip") {
                        completeOnboarding()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .sheet(isPresented: $showDonation, onDismiss: {
            hasCompletedOnboarding = true
        }) {
            DonationView()
        }
    }

    private var themePageIndex: Int { pages.count - 1 }

    private var themeSelectionPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 64))
                .foregroundStyle(SteddiTheme.accent)
                .padding(.bottom, 8)

            VStack(spacing: 8) {
                Text("Choose your look")
                    .font(.title.weight(.bold))

                Text("Light, dark, or match your device")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                themeCard(mode: "dynamic", icon: "iphone", label: "Dynamic", description: "Follows your device — recommended", recommended: true)
                themeCard(mode: "dark", icon: "moon.fill", label: "Dark", description: "Always dark")
                themeCard(mode: "light", icon: "sun.max.fill", label: "Light", description: "Always light")
            }
            .padding(.horizontal, 32)

            Spacer()
            Spacer()
        }
    }

    private func themeCard(mode: String, icon: String, label: String, description: String, recommended: Bool = false) -> some View {
        let isSelected = themeMode == mode
        return Button {
            themeMode = mode
            NotificationCenter.default.post(name: .steddiThemeModeChanged, object: nil)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(isSelected ? SteddiTheme.accent : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(label)
                            .font(.headline)
                        if recommended {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(SteddiTheme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(SteddiTheme.accentSubtle, in: Capsule())
                        }
                    }
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(SteddiTheme.accent)
                        .font(.title3)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? SteddiTheme.accent.opacity(0.12) : SteddiTheme.surfaceSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? SteddiTheme.accent : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private func completeOnboarding() {
        hasCompletedOnboarding = true
    }
}

#Preview {
    OnboardingView()
}
