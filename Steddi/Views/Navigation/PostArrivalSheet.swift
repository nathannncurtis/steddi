import SwiftUI
import SwiftData

struct PostArrivalSheet: View {
    let destinationName: String
    let recordedPoints: [GPSPoint]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var commutes: [Commute]

    @State private var routeName = ""
    @State private var selectedCommute: Commute?
    @State private var saveAsPreferred = false
    @State private var isSaving = false

    private var hasRecordedRoute: Bool { recordedPoints.count >= 2 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Arrival confirmation
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)

                    Text("You've arrived!")
                        .font(.title2.weight(.bold))

                    Text(destinationName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                if hasRecordedRoute {
                    Divider()

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Save this route?")
                            .font(.headline)

                        TextField("Route name (optional)", text: $routeName)
                            .textFieldStyle(.roundedBorder)

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
                                .tint(SteddiTheme.accent)
                        }
                    }
                    .padding(.horizontal)

                    Spacer()

                    VStack(spacing: 12) {
                        Button {
                            Task { await saveRoute() }
                        } label: {
                            if isSaving {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            } else {
                                Text("Save Route")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(SteddiTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .disabled(isSaving)

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
                    .background(SteddiTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func saveRoute() async {
        isSaving = true

        let service = MapMatchingService(accessToken: MapboxTokenProvider.accessToken)

        do {
            let matched = try await service.matchTrace(recordedPoints)

            let rank: Int
            if saveAsPreferred {
                // Bump existing routes
                if let commute = selectedCommute {
                    for existing in commute.orderedRoutes {
                        existing.rank += 1
                    }
                }
                rank = 0
            } else {
                rank = selectedCommute?.orderedRoutes.count ?? 0
            }

            let route = Route(
                rank: rank,
                encodedPolyline: matched.encodedPolyline,
                name: routeName.isEmpty ? nil : routeName,
                distanceMeters: matched.distanceMeters,
                source: .recorded
            )

            if let commute = selectedCommute {
                route.commute = commute
                if commute.routes == nil {
                    commute.routes = []
                }
                commute.routes?.append(route)
            }

            modelContext.insert(route)

            // Save drive record
            let record = DriveRecord()
            record.rawGPSPoints = recordedPoints
            record.matchedPolyline = matched.encodedPolyline
            record.associatedCommute = selectedCommute
            record.wasConverted = true
            record.endedAt = Date()
            modelContext.insert(record)

            try? modelContext.save()
        } catch {
            // If map matching fails, still save the raw points
            let record = DriveRecord()
            record.rawGPSPoints = recordedPoints
            record.wasConverted = false
            record.endedAt = Date()
            modelContext.insert(record)
            try? modelContext.save()
        }

        isSaving = false
        dismiss()
    }
}

#Preview {
    PostArrivalSheet(destinationName: "Work", recordedPoints: [])
        .modelContainer(for: [Commute.self, Route.self, DriveRecord.self], inMemory: true)
}
