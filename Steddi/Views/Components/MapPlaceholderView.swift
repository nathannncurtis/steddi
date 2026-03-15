import SwiftUI

// TODO: Replace with actual Mapbox MapView once Xcode integration is ready
struct MapPlaceholderView<Overlay: View>: View {
    let overlay: Overlay

    init(@ViewBuilder overlay: () -> Overlay) {
        self.overlay = overlay()
    }

    init() where Overlay == EmptyView {
        self.overlay = EmptyView()
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(.systemGray6))
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "map")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Map View")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Mapbox integration pending")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

            overlay
        }
    }
}

#Preview {
    MapPlaceholderView()
        .ignoresSafeArea()
}
