import SwiftUI

/// Beat 4 of onboarding: optionally add an emergency contact. Mirrors the
/// `EmergencyView` setup — a phone number saved to the shared
/// `@AppStorage("steddi.emergencyContact")` key — but framed as a calm, skippable
/// invitation rather than a settings form.
///
/// "Add Contact" presents the system contact picker; on a pick we show a "Saved"
/// confirmation with a spring checkmark. "Skip for now" proceeds. Either way the
/// footer's final button reads "Get Started".
struct OnboardingEmergencyView: View {
    // Animations here route through `SteddiMotion.resolve()`, which gates on
    // Reduce Motion globally, so no per-view environment read is needed.
    @Bindable var coordinator: OnboardingCoordinator

    @State private var showPicker = false
    @State private var savedCheckVisible = false

    private var hasContact: Bool { coordinator.emergencyContact != nil }

    var body: some View {
        card
        .sheet(isPresented: $showPicker) {
            OnboardingContactPicker { phone in
                showPicker = false
                guard let phone else { return }
                coordinator.setEmergencyContact(phone)
                HapticService.shared.fire(.arrival)
                withAnimation(SteddiMotion.resolve(TransitionKit.spring(TransitionKit.springArrival))) {
                    savedCheckVisible = true
                }
            }
            .ignoresSafeArea()
        }
    }

    private var card: some View {
        VStack(spacing: 20) {
            Image(systemName: hasContact ? "checkmark.circle.fill" : "person.crop.circle.badge.plus")
                .font(.system(size: 64))
                .foregroundStyle(coordinator.selectedAccent.color)
                .scaleEffect(hasContact && savedCheckVisible ? 1.0 : (hasContact ? 0.6 : 1.0))
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text(hasContact ? "Contact saved" : "In case of emergency")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    // Fixed light-on-dark: this card floats on the dark
                    // cinematic backdrop in every theme (theme tokens go
                    // near-black in Light and vanish here).
                    .foregroundStyle(SteddiTheme.onboardingTextPrimary)

                Text(hasContact
                     ? "We'll be able to help you reach them if something goes wrong."
                     : "Add a contact we can help you reach if something goes wrong. It's optional — you can add this later in Settings.")
                    .font(.body)
                    .foregroundStyle(SteddiTheme.onboardingTextSecondary)
                    .multilineTextAlignment(.center)
            }

            if !hasContact {
                Button {
                    HapticService.shared.fire(.uiToggle)
                    showPicker = true
                } label: {
                    Label("Add Contact", systemImage: "person.crop.circle.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(coordinator.selectedAccent.color)
            } else {
                Button {
                    HapticService.shared.fire(.uiToggle)
                    coordinator.setEmergencyContact(nil)
                    savedCheckVisible = false
                } label: {
                    Text("Choose a different contact")
                        .font(.subheadline)
                        .foregroundStyle(coordinator.selectedAccent.color)
                }
            }
        }
        .padding(28)
    }
}
