import SwiftUI

struct AdvancedHapticsView: View {
    @State private var intensities: [HapticEvent: Double] = Dictionary(
        uniqueKeysWithValues: HapticEvent.allCases.map { ($0, HapticService.shared.intensity(for: $0)) }
    )

    var body: some View {
        List {
            Section {
                ForEach(HapticEvent.allCases) { event in
                    eventRow(event)
                }
            } header: {
                Text("Event Intensities")
            } footer: {
                Text("Adjust how strong each haptic feels. Tap the hand to try it at the current intensity.")
            }

            Section {
                Button {
                    HapticService.shared.resetIntensitiesToDynamicDefaults()
                    for event in HapticEvent.allCases {
                        intensities[event] = event.dynamicDefault
                    }
                    HapticService.shared.preview(.uiToggle)
                } label: {
                    Label("Reset to Dynamic defaults", systemImage: "arrow.counterclockwise")
                }
            } footer: {
                Text("Dynamic defaults scale each event by how urgent it is — gentle for UI taps, strong for arrival.")
            }
        }
        .navigationTitle("Fine-tune Haptics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func eventRow(_ event: HapticEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: event.sfSymbol)
                    .foregroundStyle(SteddiTheme.accent)
                    .frame(width: 24)

                Text(event.displayName)

                Spacer()

                Text("\(Int((intensities[event] ?? event.dynamicDefault) * 100))%")
                    .foregroundStyle(SteddiTheme.textSecondary)
                    .font(SteddiTheme.mono(14))

                Button {
                    HapticService.shared.preview(event)
                } label: {
                    Image(systemName: "hand.tap.fill")
                        .foregroundStyle(SteddiTheme.accent)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Try \(event.displayName) haptic")
            }

            Slider(
                value: binding(for: event),
                in: 0...1,
                step: 0.05,
                onEditingChanged: { editing in
                    if !editing {
                        HapticService.shared.preview(event)
                    }
                }
            )
            .tint(SteddiTheme.accent)
        }
        .padding(.vertical, 4)
    }

    private func binding(for event: HapticEvent) -> Binding<Double> {
        Binding(
            get: { intensities[event] ?? event.dynamicDefault },
            set: { newValue in
                intensities[event] = newValue
                HapticService.shared.setIntensity(newValue, for: event)
            }
        )
    }
}

private extension HapticEvent {
    var sfSymbol: String {
        switch self {
        case .turnApproaching: return "arrow.turn.up.right"
        case .rerouteSuggestion: return "arrow.triangle.branch"
        case .arrival: return "flag.fill"
        case .uiToggle: return "hand.tap"
        case .alert: return "exclamationmark.triangle.fill"
        }
    }
}

#Preview {
    NavigationStack {
        AdvancedHapticsView()
    }
}
