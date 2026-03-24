#if DEBUG
import SwiftUI
import SwiftData

// MARK: - CarPlay Preview View

/// Simulates the CarPlay UI in pure SwiftUI for debugging on the iOS Simulator.
/// No CarPlay framework imports required.
struct CarPlayPreviewView: View {
    @State private var selectedTab: CarPlayTab = .commutes
    @State private var navigationState: CarPlayNavState? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Status bar
                CarPlayStatusBar()

                if let nav = navigationState {
                    CarPlayNavigationView(state: nav) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            navigationState = nil
                        }
                    }
                } else {
                    // Content area
                    Group {
                        switch selectedTab {
                        case .commutes:
                            CarPlayCommutesTab { commuteName, subtitle in
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    navigationState = CarPlayNavState(commuteName: commuteName, subtitle: subtitle)
                                }
                            }
                        case .recents:
                            CarPlayRecentsTab()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Tab bar
                    CarPlayTabBar(selectedTab: $selectedTab)
                }
            }
        }
        .aspectRatio(800.0 / 480.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(12)
        .background(Color(white: 0.08))
        .navigationTitle("CarPlay Preview")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Data Types

private enum CarPlayTab: String {
    case commutes, recents
}

private struct CarPlayNavState {
    let commuteName: String
    let subtitle: String

    // Mock navigation data
    let maneuverIcon: String = "arrow.turn.up.right"
    let maneuverDistance: String = "0.3 mi"
    let maneuverInstruction: String = "Turn right onto Main St"
    let followOnIcon: String = "arrow.turn.up.left"
    let followOnInstruction: String = "Then turn left onto Oak Ave"
    let etaMinutes: Int = 12
    let distanceRemaining: String = "4.7 mi"
    let arrivalTime: String = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: Date().addingTimeInterval(12 * 60))
    }()
    let roadName: String = "Elm Street"
    let speedMph: Int = 34
    let speedLimitMph: Int = 35
}

// MARK: - Status Bar

private struct CarPlayStatusBar: View {
    var body: some View {
        HStack {
            Image(systemName: "car.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SteddiTheme.accent)
            Text("Steddi")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            Text("CarPlay Preview")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(white: 0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(white: 0.06))
    }
}

// MARK: - Tab Bar

private struct CarPlayTabBar: View {
    @Binding var selectedTab: CarPlayTab

    var body: some View {
        HStack(spacing: 0) {
            tabButton(tab: .commutes, icon: "arrow.triangle.swap", label: "Commutes")
            tabButton(tab: .recents, icon: "clock", label: "Recents")
        }
        .frame(height: 56)
        .background(Color(white: 0.08))
    }

    private func tabButton(tab: CarPlayTab, icon: String, label: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selectedTab == tab ? SteddiTheme.accent : Color(white: 0.45))
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Commutes Tab

private struct CarPlayCommutesTab: View {
    @Query(filter: #Predicate<Commute> { $0.isActive }, sort: \Commute.createdAt)
    private var commutes: [Commute]

    var onCommuteTap: (String, String) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if commutes.isEmpty {
                    carPlayEmptyState(
                        icon: "arrow.triangle.swap",
                        title: "No commutes",
                        detail: "Add commutes in the Steddi app"
                    )
                } else {
                    ForEach(commutes) { commute in
                        let originName = commute.origin?.name ?? "?"
                        let destName = commute.destination?.name ?? "?"
                        let subtitle = "\(originName) \u{2192} \(destName)"

                        Button {
                            onCommuteTap(commute.name, subtitle)
                        } label: {
                            CarPlayListRow(
                                title: commute.name,
                                detail: subtitle,
                                icon: "arrow.triangle.swap"
                            )
                        }
                    }
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Recents Tab

private struct CarPlayRecentsTab: View {
    @Query(sort: \PinnedLocation.createdAt, order: .reverse)
    private var locations: [PinnedLocation]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if locations.isEmpty {
                    carPlayEmptyState(
                        icon: "clock",
                        title: "No places",
                        detail: "Add places in the Steddi app"
                    )
                } else {
                    ForEach(locations.prefix(12)) { location in
                        CarPlayListRow(
                            title: location.name,
                            detail: location.address ?? "",
                            icon: location.icon
                        )
                    }
                }
            }
            .padding(12)
        }
    }
}

// MARK: - List Row

private struct CarPlayListRow: View {
    let title: String
    let detail: String
    let icon: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(SteddiTheme.accent)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color(white: 0.55))
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(white: 0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(white: 0.12))
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Navigation View

private struct CarPlayNavigationView: View {
    let state: CarPlayNavState
    var onBack: () -> Void

    @State private var showRerouteBanner = false

    var body: some View {
        ZStack {
            // Mock map background
            ZStack {
                Color(red: 0.08, green: 0.10, blue: 0.12)

                // Simulated road grid
                VStack(spacing: 40) {
                    ForEach(0..<4, id: \.self) { _ in
                        Rectangle()
                            .fill(Color(white: 0.15))
                            .frame(height: 1)
                    }
                }

                HStack(spacing: 60) {
                    ForEach(0..<5, id: \.self) { _ in
                        Rectangle()
                            .fill(Color(white: 0.15))
                            .frame(width: 1)
                    }
                }
                .frame(maxHeight: .infinity)

                // Route line
                Path { path in
                    path.move(to: CGPoint(x: 200, y: 300))
                    path.addCurve(
                        to: CGPoint(x: 280, y: 40),
                        control1: CGPoint(x: 200, y: 200),
                        control2: CGPoint(x: 260, y: 100)
                    )
                }
                .stroke(SteddiTheme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))

                // Position dot
                Circle()
                    .fill(Color.blue)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle().stroke(.white, lineWidth: 2)
                    )
                    .position(x: 200, y: 300)

                // Road name label
                VStack {
                    Spacer()
                    HStack {
                        Text(state.roadName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(white: 0.6))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color(white: 0.12)))
                        Spacer()
                    }
                    .padding(.leading, 12)
                    .padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Overlays
            VStack(spacing: 0) {
                // Maneuver banner
                maneuverBanner
                    .padding(.horizontal, 10)
                    .padding(.top, 6)

                Spacer()

                // Reroute banner
                if showRerouteBanner {
                    rerouteBanner
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // ETA bar
                etaBar
            }

            // Back button
            VStack {
                HStack {
                    Spacer()
                    Button(action: onBack) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color(white: 0.2)))
                    }
                    .padding(.trailing, 10)
                    .padding(.top, 62)
                }
                Spacer()
            }

            // Speed indicator
            VStack {
                Spacer()
                HStack {
                    speedIndicator
                        .padding(.leading, 10)
                        .padding(.bottom, 56)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Maneuver Banner

    private var maneuverBanner: some View {
        VStack(spacing: 0) {
            // Current maneuver
            HStack(spacing: 14) {
                Image(systemName: state.maneuverIcon)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.maneuverDistance)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Text(state.maneuverInstruction)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(white: 0.75))
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(white: 0.13))
            )

            // Follow-on maneuver
            HStack(spacing: 10) {
                Text("Then")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(white: 0.45))
                Image(systemName: state.followOnIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SteddiTheme.accent)
                Text(state.followOnInstruction)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(white: 0.55))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(white: 0.09))
            )
            .padding(.top, 2)
        }
    }

    // MARK: - Reroute Banner

    private var rerouteBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(SteddiTheme.sage)

            VStack(alignment: .leading, spacing: 2) {
                Text("Faster Route Available")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Text("Save ~3 min via Highway 101")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SteddiTheme.sage)
            }

            Spacer()

            Button {
                withAnimation { showRerouteBanner = false }
            } label: {
                Text("Switch")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(SteddiTheme.sage))
            }

            Button {
                withAnimation { showRerouteBanner = false }
            } label: {
                Text("Stay")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(white: 0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(white: 0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(SteddiTheme.sage.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - ETA Bar

    private var etaBar: some View {
        HStack {
            // ETA minutes
            VStack(spacing: 1) {
                Text("\(state.etaMinutes)")
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(SteddiTheme.sage)
                Text("min")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(white: 0.5))
            }
            .frame(width: 70)

            Divider()
                .frame(height: 30)
                .overlay(Color(white: 0.25))

            // Distance
            VStack(spacing: 1) {
                Text(state.distanceRemaining)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("remaining")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(white: 0.5))
            }
            .frame(width: 80)

            Spacer()

            // Reroute toggle button
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showRerouteBanner.toggle()
                }
            } label: {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(showRerouteBanner ? SteddiTheme.sage : Color(white: 0.4))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(white: 0.15)))
            }

            // Arrival time
            VStack(spacing: 1) {
                Text(state.arrivalTime)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("arrival")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(white: 0.5))
            }
            .frame(width: 80)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(white: 0.08).opacity(0.95))
    }

    // MARK: - Speed Indicator

    private var speedIndicator: some View {
        VStack(spacing: 2) {
            Text("\(state.speedMph)")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
            Text("mph")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(white: 0.5))

            // Speed limit
            ZStack {
                Circle()
                    .stroke(Color(white: 0.4), lineWidth: 1.5)
                    .frame(width: 26, height: 26)
                Text("\(state.speedLimitMph)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.7))
            }
            .padding(.top, 4)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.10).opacity(0.9))
        )
    }
}

// MARK: - Empty State Helper

private func carPlayEmptyState(icon: String, title: String, detail: String) -> some View {
    VStack(spacing: 12) {
        Spacer()
        Image(systemName: icon)
            .font(.system(size: 36, weight: .light))
            .foregroundStyle(Color(white: 0.3))
        Text(title)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(white: 0.5))
        Text(detail)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Color(white: 0.35))
        Spacer()
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        CarPlayPreviewView()
    }
    .modelContainer(for: [Commute.self, PinnedLocation.self], inMemory: true)
}
#endif
