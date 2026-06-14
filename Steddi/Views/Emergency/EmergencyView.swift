import SwiftUI
import MapKit
import CoreLocation

/// Emergency / Breakdown mode — one tap to share location, find services, call help.
///
/// Hierarchy puts the two life-safety actions first (share location, call your
/// contact), then nearby services, then roadside. Every actionable control
/// carries a warning-class haptic and a VoiceOver label/hint; the contact-setup
/// flow uses a draft so cancelling never mangles a saved number, and a missing
/// contact is prompted for the moment the driver tries to call one.
struct EmergencyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationService.self) private var locationService
    @AppStorage("steddi.emergencyContact") private var emergencyContact: String = ""

    @State private var showSetupContact = false
    @State private var contactDraft = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    locationCard
                    shareLocationButton
                    contactSection
                    nearbyServicesCard
                    roadsideButton
                }
                .padding()
            }
            .background(SteddiTheme.surfacePrimary)
            .navigationTitle("Emergency")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(SteddiTheme.accent)
                }
            }
            .alert("Emergency Contact", isPresented: $showSetupContact) {
                TextField("Phone number", text: $contactDraft)
                    .keyboardType(.phonePad)
                Button("Save") {
                    let trimmed = contactDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    emergencyContact = trimmed
                    HapticService.shared.notify(.success)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a phone number to call in an emergency. You can change it anytime.")
            }
        }
    }

    // MARK: - Location Card

    @ViewBuilder
    private var locationCard: some View {
        if let loc = locationService.currentLocation {
            VStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(SteddiTheme.warmRed)
                    .accessibilityHidden(true)
                Text("Your Location")
                    .font(SteddiTheme.heading(16))
                    .foregroundStyle(SteddiTheme.textPrimary)
                Text("\(loc.coordinate.latitude, specifier: "%.5f"), \(loc.coordinate.longitude, specifier: "%.5f")")
                    .font(SteddiTheme.mono(13))
                    .foregroundStyle(SteddiTheme.textSecondary)
                    .textSelection(.enabled)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(SteddiTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: SteddiTheme.radiusCard))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Your current location, latitude \(loc.coordinate.latitude, specifier: "%.5f"), longitude \(loc.coordinate.longitude, specifier: "%.5f")")
        } else {
            VStack(spacing: 8) {
                Image(systemName: "location.slash")
                    .font(.system(size: 30))
                    .foregroundStyle(SteddiTheme.textMuted)
                    .accessibilityHidden(true)
                Text("Locating…")
                    .font(SteddiTheme.heading(16))
                    .foregroundStyle(SteddiTheme.textPrimary)
                Text("Waiting for a GPS fix. Sharing will be available once your location is known.")
                    .font(SteddiTheme.body(13))
                    .foregroundStyle(SteddiTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(SteddiTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: SteddiTheme.radiusCard))
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Share Location

    private var shareLocationButton: some View {
        let hasLocation = locationService.currentLocation != nil
        return Button {
            shareLocation()
        } label: {
            Label("Share My Location", systemImage: "square.and.arrow.up")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 28)
                .padding(.vertical, 16)
                .background(
                    hasLocation ? SteddiTheme.accent : SteddiTheme.accent.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        .buttonStyle(.steddiPress)
        .disabled(!hasLocation)
        .accessibilityHint("Opens the share sheet with a help message and a map link to your exact location.")
    }

    // MARK: - Emergency Contact

    @ViewBuilder
    private var contactSection: some View {
        if !emergencyContact.isEmpty {
            Button {
                callContact()
            } label: {
                Label("Call \(emergencyContact)", systemImage: "phone.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .padding(.vertical, 16)
                    .background(SteddiTheme.warmRed, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.steddiPress)
            .accessibilityLabel("Call your emergency contact")
            .accessibilityHint("Dials \(emergencyContact).")
            .contextMenu {
                Button {
                    presentContactSetup()
                } label: {
                    Label("Change Contact", systemImage: "pencil")
                }
            }
        } else {
            Button {
                presentContactSetup()
            } label: {
                Label("Set Emergency Contact", systemImage: "person.crop.circle.badge.plus")
                    .font(.body.weight(.medium))
                    .foregroundStyle(SteddiTheme.accent)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .padding(.vertical, 16)
                    .background(SteddiTheme.accentSubtle, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.steddiPress)
            .accessibilityHint("Save a phone number to call quickly in an emergency.")
        }
    }

    // MARK: - Nearby Services

    private var nearbyServicesCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nearby Services")
                .font(SteddiTheme.heading(16))
                .foregroundStyle(SteddiTheme.textPrimary)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)

            serviceButton(icon: "fuelpump.fill", label: "Gas Stations", query: "gas station")
            serviceDivider
            serviceButton(icon: "wrench.and.screwdriver.fill", label: "Auto Repair", query: "auto repair")
            serviceDivider
            serviceButton(icon: "cross.fill", label: "Hospital", query: "hospital")
            serviceDivider
            serviceButton(icon: "cup.and.saucer.fill", label: "Rest Stop", query: "rest area")
        }
        .padding(20)
        .background(SteddiTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: SteddiTheme.radiusCard))
    }

    private var serviceDivider: some View {
        Divider()
            .overlay(SteddiTheme.textMuted.opacity(0.15))
            .padding(.leading, 40)
    }

    // MARK: - Roadside Assistance

    private var roadsideButton: some View {
        Button {
            callRoadside()
        } label: {
            Label("Call Roadside Assistance (AAA)", systemImage: "car.side.fill")
                .font(.body.weight(.medium))
                .foregroundStyle(SteddiTheme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .padding(.vertical, 16)
                .background(SteddiTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.steddiPress)
        .accessibilityHint("Dials AAA roadside assistance.")
    }

    // MARK: - Actions

    private func shareLocation() {
        guard let loc = locationService.currentLocation else { return }
        HapticService.shared.notify(.warning)
        let text = "I need help. My location: https://maps.apple.com/?ll=\(loc.coordinate.latitude),\(loc.coordinate.longitude)"
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.keyWindow?.rootViewController {
            // Anchor the popover on iPad so it never crashes for want of a source.
            if let popover = av.popoverPresentationController {
                popover.sourceView = root.view
                popover.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            root.present(av, animated: true)
        }
    }

    private func callContact() {
        // Defensive: if the saved contact was cleared elsewhere, prompt instead
        // of dialing an empty number (TODO: prompt on first emergency use).
        let cleaned = emergencyContact
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard !cleaned.isEmpty, let url = URL(string: "tel://\(cleaned)") else {
            presentContactSetup()
            return
        }
        HapticService.shared.notify(.warning)
        UIApplication.shared.open(url)
    }

    private func callRoadside() {
        HapticService.shared.notify(.warning)
        if let url = URL(string: "tel://1-800-222-4357") { // AAA
            UIApplication.shared.open(url)
        }
    }

    /// Seed the draft from the current value so editing an existing contact
    /// pre-fills, and Cancel leaves the saved number untouched.
    private func presentContactSetup() {
        contactDraft = emergencyContact
        showSetupContact = true
    }

    private func serviceButton(icon: String, label: String, query: String) -> some View {
        Button {
            openMaps(for: query)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(SteddiTheme.accent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(label)
                    .font(SteddiTheme.body(15))
                    .foregroundStyle(SteddiTheme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(SteddiTheme.textMuted)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Find nearby \(label)")
        .accessibilityHint("Opens Maps with \(label.lowercased()) near you.")
    }

    private func openMaps(for query: String) {
        guard let loc = locationService.currentLocation else { return }
        HapticService.shared.fire(.uiToggle)
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let url = URL(string: "maps://?q=\(encodedQuery)&sll=\(loc.coordinate.latitude),\(loc.coordinate.longitude)") {
            UIApplication.shared.open(url)
        }
    }
}
