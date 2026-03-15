import SwiftUI

struct ActiveNavigationView: View {
    let destination: PinnedLocation

    @Environment(\.dismiss) private var dismiss

    // TODO: Replace with @Environment NavigationViewModel when ready
    @State private var etaMinutes: Int = 0
    @State private var remainingDistance: Double = 0
    @State private var routeName: String = ""
    @State private var showRerouteCard = false
    @State private var showPostArrival = false

    var body: some View {
        ZStack {
            // TODO: Replace with Mapbox navigation view
            MapPlaceholderView()
                .ignoresSafeArea()

            VStack {
                // Top info bar
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(routeName.isEmpty ? destination.name : routeName)
                            .font(.headline)
                            .foregroundStyle(.white)

                        HStack(spacing: 12) {
                            Label("\(etaMinutes) min", systemImage: "clock")
                            Label(formattedDistance, systemImage: "road.lanes")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                    }

                    Spacer()
                }
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                // Reroute suggestion overlay
                if showRerouteCard {
                    RerouteCardView(
                        routeName: "Via I-10 East",
                        timeSavingsMinutes: 7,
                        percentageSavings: 23,
                        onSwitch: {
                            // TODO: Accept reroute via NavigationViewModel
                            showRerouteCard = false
                        },
                        onStay: {
                            showRerouteCard = false
                        }
                    )
                }

                // End navigation button
                Button {
                    showPostArrival = true
                } label: {
                    Label("End", systemImage: "xmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                        .background(.red, in: Capsule())
                }
                .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $showPostArrival, onDismiss: {
            dismiss()
        }) {
            PostArrivalSheet(destinationName: destination.name)
                .presentationDetents([.medium, .large])
        }
    }

    private var formattedDistance: String {
        if remainingDistance < 1000 {
            return "\(Int(remainingDistance)) m"
        }
        return String(format: "%.1f mi", remainingDistance / 1609.34)
    }
}

#Preview {
    ActiveNavigationView(
        destination: PinnedLocation(
            name: "Work",
            latitude: 34.0522,
            longitude: -118.2437,
            icon: "building.2.fill"
        )
    )
}
