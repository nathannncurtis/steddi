import SwiftUI
import SwiftData

struct NoGoZoneEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var radiusMeters: Double = 200
    // TODO: Get coordinates from map tap — placeholder for now
    @State private var selectedLatitude: Double = 0
    @State private var selectedLongitude: Double = 0
    @State private var hasSelectedLocation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Map picker area
                MapPlaceholderView {
                    if hasSelectedLocation {
                        Circle()
                            .stroke(.red.opacity(0.6), lineWidth: 2)
                            .fill(.red.opacity(0.15))
                            .frame(width: radiusPreviewSize, height: radiusPreviewSize)
                    }

                    VStack {
                        Spacer()
                        Text("Tap to select location")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 12)
                    }
                }
                .frame(height: 280)
                .onTapGesture {
                    // TODO: Capture actual map coordinates
                    hasSelectedLocation = true
                    selectedLatitude = 34.0522
                    selectedLongitude = -118.2437
                }

                // Configuration
                Form {
                    Section {
                        TextField("Zone name", text: $name)
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Radius")
                                Spacer()
                                Text("\(Int(radiusMeters))m")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $radiusMeters, in: 100...2000, step: 50)
                                .tint(.red)
                        }
                    } footer: {
                        Text("Routes will avoid this circular area.")
                    }
                }
            }
            .navigationTitle("New No-Go Zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!hasSelectedLocation)
                }
            }
        }
    }

    // Approximate visual radius for the preview circle
    private var radiusPreviewSize: CGFloat {
        CGFloat(radiusMeters / 2000 * 120 + 30)
    }

    private func save() {
        let zone = NoGoZone(
            latitude: selectedLatitude,
            longitude: selectedLongitude,
            radiusMeters: radiusMeters,
            name: name.isEmpty ? nil : name,
            isGlobal: true
        )
        modelContext.insert(zone)
    }
}

#Preview {
    NoGoZoneEditorView()
        .modelContainer(for: NoGoZone.self, inMemory: true)
}
