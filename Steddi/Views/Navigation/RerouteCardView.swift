import SwiftUI

struct RerouteCardView: View {
    let routeName: String
    let timeSavingsMinutes: Int
    let percentageSavings: Int
    let onSwitch: () -> Void
    let onStay: () -> Void

    @State private var isVisible = true

    var body: some View {
        if isVisible {
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text("Faster route available")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if !routeName.isEmpty {
                        Text(routeName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                // Time savings — large and glanceable
                HStack(spacing: 4) {
                    Text("Save ~\(timeSavingsMinutes) min")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.green)

                    Text("(\(percentageSavings)%)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // Action buttons
                HStack(spacing: 16) {
                    Button("Stay") {
                        hide()
                        onStay()
                    }
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 12))

                    Button("Switch") {
                        hide()
                        onSwitch()
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                // Auto-dismiss after 30 seconds if ignored — counts as "stay"
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    guard isVisible else { return }
                    hide()
                    onStay()
                }
            }
        }
    }

    private func hide() {
        withAnimation(.easeOut(duration: 0.3)) {
            isVisible = false
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack {
            Spacer()
            RerouteCardView(
                routeName: "Via I-10 East",
                timeSavingsMinutes: 7,
                percentageSavings: 23,
                onSwitch: {},
                onStay: {}
            )
            .padding(.bottom, 40)
        }
    }
}
