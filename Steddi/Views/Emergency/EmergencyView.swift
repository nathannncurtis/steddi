import SwiftUI
import MapKit
import CoreLocation

/// Emergency / Breakdown mode — one tap to share location, find services, call help.
struct EmergencyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationService.self) private var locationService
    @AppStorage("steddi.emergencyContact") private var emergencyContact: String = ""
    @State private var showSetupContact = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Current location display
                    if let loc = locationService.currentLocation {
                        VStack(spacing: 8) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(SteddiTheme.warmRed)
                            Text("Your Location")
                                .font(SteddiTheme.heading(16))
                                .foregroundStyle(SteddiTheme.textPrimary)
                            Text("\(loc.coordinate.latitude, specifier: "%.5f"), \(loc.coordinate.longitude, specifier: "%.5f")")
                                .font(SteddiTheme.mono(13))
                                .foregroundStyle(SteddiTheme.textSecondary)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                        .background(SteddiTheme.surfaceSecondary)
                        .cornerRadius(16)
                    }

                    // Share location
                    Button {
                        shareLocation()
                    } label: {
                        Label("Share My Location", systemImage: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(SteddiTheme.accent, in: RoundedRectangle(cornerRadius: 14))
                    }

                    // Emergency contact
                    if !emergencyContact.isEmpty {
                        Button {
                            callContact()
                        } label: {
                            Label("Call \(emergencyContact)", systemImage: "phone.fill")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(SteddiTheme.warmRed, in: RoundedRectangle(cornerRadius: 14))
                        }
                    } else {
                        Button {
                            showSetupContact = true
                        } label: {
                            Label("Set Emergency Contact", systemImage: "person.crop.circle.badge.plus")
                                .font(.body.weight(.medium))
                                .foregroundStyle(SteddiTheme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(SteddiTheme.accentSubtle, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }

                    // Nearby services
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Nearby Services")
                            .font(SteddiTheme.heading(16))
                            .foregroundStyle(SteddiTheme.textPrimary)

                        serviceButton(icon: "fuelpump.fill", label: "Gas Stations", query: "gas station")
                        serviceButton(icon: "wrench.and.screwdriver.fill", label: "Auto Repair", query: "auto repair")
                        serviceButton(icon: "cross.fill", label: "Hospital", query: "hospital")
                        serviceButton(icon: "cup.and.saucer.fill", label: "Rest Stop", query: "rest area")
                    }
                    .padding(20)
                    .background(SteddiTheme.surfaceSecondary)
                    .cornerRadius(16)

                    // Roadside assistance
                    Button {
                        if let url = URL(string: "tel://1-800-222-4357") { // AAA
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Call Roadside Assistance (AAA)", systemImage: "car.side.fill")
                            .font(.body.weight(.medium))
                            .foregroundStyle(SteddiTheme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(SteddiTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding()
            }
            .background(SteddiTheme.surfacePrimary)
            .navigationTitle("Emergency")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Emergency Contact", isPresented: $showSetupContact) {
                TextField("Phone number", text: $emergencyContact)
                    .keyboardType(.phonePad)
                Button("Save") {}
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a phone number to call in an emergency.")
            }
        }
    }

    private func shareLocation() {
        guard let loc = locationService.currentLocation else { return }
        let text = "I need help. My location: https://maps.apple.com/?ll=\(loc.coordinate.latitude),\(loc.coordinate.longitude)"
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.keyWindow?.rootViewController {
            root.present(av, animated: true)
        }
    }

    private func callContact() {
        let cleaned = emergencyContact.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        if let url = URL(string: "tel://\(cleaned)") {
            UIApplication.shared.open(url)
        }
    }

    private func serviceButton(icon: String, label: String, query: String) -> some View {
        Button {
            if let loc = locationService.currentLocation {
                let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                if let url = URL(string: "maps://?q=\(encodedQuery)&sll=\(loc.coordinate.latitude),\(loc.coordinate.longitude)") {
                    UIApplication.shared.open(url)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(SteddiTheme.accent)
                    .frame(width: 28)
                Text(label)
                    .font(SteddiTheme.body(15))
                    .foregroundStyle(SteddiTheme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(SteddiTheme.textMuted)
            }
            .padding(.vertical, 4)
        }
    }
}
