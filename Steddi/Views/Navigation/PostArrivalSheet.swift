import SwiftUI
import SwiftData

struct PostArrivalSheet: View {
    let destinationName: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var commutes: [Commute]

    @State private var routeName = ""
    @State private var selectedCommute: Commute?
    @State private var saveAsPreferred = false
    @State private var routeWasRecorded = true // TODO: Get from RouteRecordingViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Arrival confirmation
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)

                    Text("You have arrived!")
                        .font(.title2.weight(.bold))

                    Text(destinationName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                if routeWasRecorded {
                    Divider()

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Save this route?")
                            .font(.headline)

                        TextField("Route name (optional)", text: $routeName)
                            .textFieldStyle(.roundedBorder)

                        // Commute picker
                        if !commutes.isEmpty {
                            Picker("Add to commute", selection: $selectedCommute) {
                                Text("None").tag(nil as Commute?)
                                ForEach(commutes) { commute in
                                    Text(commute.name).tag(commute as Commute?)
                                }
                            }
                        }

                        if selectedCommute != nil {
                            Toggle("Set as preferred route", isOn: $saveAsPreferred)
                                .tint(.blue)
                        }
                    }
                    .padding(.horizontal)

                    Spacer()

                    // Action buttons
                    VStack(spacing: 12) {
                        Button {
                            saveRoute()
                            dismiss()
                        } label: {
                            Text("Save Route")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(.blue, in: RoundedRectangle(cornerRadius: 12))
                        }

                        Button("Discard") {
                            dismiss()
                        }
                        .font(.body)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                } else {
                    Spacer()

                    Button("Done") {
                        dismiss()
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func saveRoute() {
        // TODO: Get encoded polyline from RouteRecordingViewModel
        let rank = saveAsPreferred ? 0 : (selectedCommute?.orderedRoutes.count ?? 0)
        let route = Route(
            rank: rank,
            encodedPolyline: "", // Placeholder
            name: routeName.isEmpty ? nil : routeName,
            source: .recorded
        )

        if let commute = selectedCommute {
            route.commute = commute
            // If saving as preferred, bump existing routes
            if saveAsPreferred {
                for existing in commute.orderedRoutes {
                    existing.rank += 1
                }
            }
        }

        modelContext.insert(route)
    }
}

#Preview {
    PostArrivalSheet(destinationName: "Work")
        .modelContainer(for: [Commute.self, Route.self], inMemory: true)
}
