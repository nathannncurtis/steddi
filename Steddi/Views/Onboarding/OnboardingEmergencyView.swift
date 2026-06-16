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

    /// Frost-legible hue for the 64pt focal icon. Like the showcase beats, the
    /// raw mid-tone accent is lifted to a uniform 5.7:1 on the card's dark scrim
    /// (`OnboardingShowcaseFrost`) — preserving the brand hue while clearing the
    /// 3:1 graphical-object floor with margin. The previous raw accent landed
    /// ~1.1:1 on the old LIGHT frost (the focal point all but vanished).
    private var glyphAccent: Color {
        SteddiTheme.legibleText(coordinator.selectedAccent.rgb,
                                onSurface: OnboardingShowcaseFrost.surface).color
    }

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
                .foregroundStyle(glyphAccent)
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
                    // At the largest accessibility text sizes this paragraph would
                    // otherwise rely entirely on the card's outer ScrollView. Let it
                    // shrink modestly so the copy degrades gracefully instead of
                    // forcing the whole card to scroll on first read.
                    .minimumScaleFactor(0.7)
            }

            if !hasContact {
                Button {
                    HapticService.shared.fire(.uiToggle)
                    showPicker = true
                } label: {
                    Label("Add Contact", systemImage: "person.crop.circle.badge.plus")
                        .font(.headline)
                        // On-fill label: a system-white label on the light/mid
                        // brand accents fails WCAG AA; `contrastingGlyph` is the
                        // in-flight accent's luminance-correct on-fill color.
                        .foregroundStyle(coordinator.selectedAccent.contrastingGlyph)
                        // 17pt headline + 4pt vpad left the glass capsule ~30pt
                        // tall — under the 44pt HIG floor. Pin a 44pt minimum so
                        // the primary CTA clears it without changing the layout.
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Capsule())
                }
                // In-flight accent glass fill + luminance-correct label instead
                // of `.glassProminent` (which forces an AA-failing white label).
                .buttonStyle(.plain)
                // Under Reduce Transparency / Increase Contrast, glass is off:
                // paint a FULLY OPAQUE in-flight-accent capsule (not the default
                // near-white `surfacePrimary` fallback, which would lose the brand
                // accent on the dark card). `fallbackProminent` makes the rendered
                // surface exactly the in-flight accent — the same opaque hue
                // `contrastingGlyph` above is computed for — so the on-fill label
                // contrast stays correct (6–9:1) and matches the glass state.
                .steddiGlass(
                    tint: coordinator.selectedAccent.color,
                    interactive: true,
                    in: Capsule(),
                    fallbackFill: coordinator.selectedAccent.color,
                    fallbackProminent: true
                )
            } else {
                Button {
                    HapticService.shared.fire(.uiToggle)
                    coordinator.setEmergencyContact(nil)
                    savedCheckVisible = false
                } label: {
                    Text("Choose a different contact")
                        .font(.subheadline)
                        // Secondary "go back" link on the card. The raw brand
                        // accent reads as itself but with low contrast; use the
                        // fixed-white secondary tier the rest of the card copy
                        // uses — on the card's dark scrim it clears AA at 9.7:1,
                        // matching the "Not now" secondary in
                        // OnboardingPermissionsView.
                        .foregroundStyle(SteddiTheme.onboardingTextSecondary)
                        // Bare ~22pt text button — expand to the 44pt HIG hit
                        // target the rest of the app enforces (text unchanged).
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(28)
        // Cap the beat copy at the app's Dynamic Type ceiling (.accessibility3 ==
        // SteddiTheme.dynamicTypeCeiling/.accessibilityExtraLarge), the same bound
        // the hero's SteddiTheme.heading() applies via UIFontMetrics, so the raw
        // .title2/.body/.headline/.subheadline styles don't scale unbounded to AX5
        // while the hero stays capped. Copy still scales up to the cap.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }
}
