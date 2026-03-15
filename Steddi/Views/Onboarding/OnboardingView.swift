import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
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
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
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
        .preferredColorScheme(.dark)
    }

    private func completeOnboarding() {
        hasCompletedOnboarding = true
    }
}

#Preview {
    OnboardingView()
}
