import SwiftUI
import MapKit

/// Route preview screen shown before navigation starts.
/// Shows the full route on the map with ETA, distance, and route options.
struct RoutePreviewView: View {
    let route: MKRoute
    let destinationName: String
    let alternateRoutes: [MKRoute]
    /// The toll/highway avoidance shaping these routes — surfaced as an
    /// "Avoiding…" indicator so the preview matches the in-nav badge.
    var preferences = RoutePreferences(avoidsTolls: false, avoidsHighways: false)
    let onStart: (MKRoute) -> Void
    let onCancel: () -> Void

    @AppStorage("accentColor") private var accentColor = "lavender"
    @State private var selectedRoute: MKRoute?

    private var activeRoute: MKRoute { selectedRoute ?? route }

    var body: some View {
        ZStack {
            // Map showing the route
            NavigationPreviewMap(
                route: activeRoute,
                alternateRoutes: alternateRoutes.filter { $0 !== activeRoute }
            )
            .ignoresSafeArea()

            // Bottom card with route info and controls
            VStack {
                Spacer()

                VStack(spacing: 16) {
                    // Destination name
                    Text(destinationName)
                        .font(SteddiTheme.body(16))
                        .foregroundStyle(SteddiTheme.textSecondary)

                    // ETA and distance
                    HStack(spacing: 24) {
                        VStack(spacing: 4) {
                            Text("\(Int(ceil(activeRoute.expectedTravelTime / 60)))")
                                .font(SteddiTheme.mono(36))
                                .foregroundStyle(SteddiTheme.textPrimary)
                            Text("min")
                                .font(SteddiTheme.body(14))
                                .foregroundStyle(SteddiTheme.textSecondary)
                        }

                        Rectangle()
                            .fill(SteddiTheme.textMuted.opacity(0.3))
                            .frame(width: 1, height: 40)

                        VStack(spacing: 4) {
                            Text(NavigationEngine.formatDistance(activeRoute.distance))
                                .font(SteddiTheme.mono(36))
                                .foregroundStyle(SteddiTheme.textPrimary)
                            Text("distance")
                                .font(SteddiTheme.body(14))
                                .foregroundStyle(SteddiTheme.textSecondary)
                        }
                    }

                    // Route-content + active-preference indicators
                    if !routeIndicators.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(routeIndicators) { indicator in
                                indicatorChip(indicator)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // Route options (if alternates exist)
                    if !alternateRoutes.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                routeChip(route, label: "Primary", isSelected: activeRoute === route)
                                ForEach(Array(alternateRoutes.enumerated()), id: \.offset) { index, alt in
                                    routeChip(alt, label: "Alt \(index + 1)", isSelected: activeRoute === alt)
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                    }

                    // Action buttons
                    HStack(spacing: 12) {
                        Button(action: onCancel) {
                            Text("Cancel")
                                .font(.body.weight(.medium))
                                .foregroundStyle(SteddiTheme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(SteddiTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
                        }

                        Button {
                            onStart(activeRoute)
                        } label: {
                            Text("Start")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(SteddiTheme.accent, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                .padding(24)
                .background {
                    UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)
                                .fill(SteddiTheme.surfacePrimary.opacity(0.85))
                        )
                        .shadow(color: .black.opacity(0.4), radius: 20, y: -5)
                }
            }
        }
    }

    // MARK: - Route Indicators

    /// One badge for the preview: route-content presence (this route has tolls
    /// or highways) plus, when a preference is shaping the route, the matching
    /// "Avoiding…" indicator. Active-avoidance indicators lead — they're the
    /// driver's own choice — and a content badge is suppressed when its
    /// avoidance is on (the route can't both avoid tolls and carry them).
    private var routeIndicators: [RoutePreviewIndicator] {
        var indicators: [RoutePreviewIndicator] = []

        if preferences.avoidsTolls {
            indicators.append(.init(symbol: "checkmark.shield.fill", label: "Avoiding tolls", tone: .active))
        } else if activeRoute.hasTolls {
            indicators.append(.init(symbol: "dollarsign.circle.fill", label: "Tolls", tone: .content))
        }

        if preferences.avoidsHighways {
            indicators.append(.init(symbol: "checkmark.shield.fill", label: "Avoiding highways", tone: .active))
        } else if activeRoute.hasHighways {
            indicators.append(.init(symbol: "road.lanes", label: "Highways", tone: .content))
        }

        return indicators
    }

    private func indicatorChip(_ indicator: RoutePreviewIndicator) -> some View {
        let isActive = indicator.tone == .active
        return HStack(spacing: 6) {
            Image(systemName: indicator.symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(indicator.label)
                .font(SteddiTheme.body(13))
        }
        .foregroundStyle(isActive ? SteddiTheme.accent : SteddiTheme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(isActive ? SteddiTheme.accentSubtle : SteddiTheme.surfaceSecondary)
        )
        .overlay(
            Capsule()
                .stroke(isActive ? SteddiTheme.accent.opacity(0.25) : .clear, lineWidth: 1)
        )
    }

    private func routeChip(_ route: MKRoute, label: String, isSelected: Bool) -> some View {
        Button {
            selectedRoute = route
        } label: {
            VStack(spacing: 4) {
                Text(label)
                    .font(SteddiTheme.body(12))
                Text("\(Int(ceil(route.expectedTravelTime / 60))) min")
                    .font(SteddiTheme.mono(14))
            }
            .foregroundStyle(isSelected ? SteddiTheme.accent : SteddiTheme.textMuted)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? SteddiTheme.accentSubtle : SteddiTheme.surfaceSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? SteddiTheme.accent.opacity(0.3) : .clear, lineWidth: 1)
            )
        }
    }
}

/// A single toll/highway badge in the route preview — either route content
/// ("Tolls"/"Highways") or an active avoidance ("Avoiding…"). Unit-prefixed to
/// avoid cross-pillar collisions.
private struct RoutePreviewIndicator: Identifiable {
    enum Tone: Equatable { case content, active }

    let symbol: String
    let label: String
    let tone: Tone

    var id: String { "\(label)-\(tone)" }
}

/// Map view for route preview — shows the full route fitted to screen.
struct NavigationPreviewMap: UIViewRepresentable {
    let route: MKRoute
    let alternateRoutes: [MKRoute]

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.preferredConfiguration = SteddiTheme.mapConfiguration(traffic: true, poiFilter: .excludingAll)
        mapView.showsUserLocation = true
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.overrideUserInterfaceStyle = SteddiTheme.currentThemeMode.mapInterfaceStyle
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Remove old overlays
        mapView.removeOverlays(mapView.overlays)

        // Identify the primary BEFORE adding overlays: MapKit can request the
        // renderer synchronously inside addOverlay, so if primaryPolyline isn't
        // set yet the primary fails its identity check and renders in the dimmed
        // alternate style — invisible at a wide zoom. (This was the missing-route-
        // line bug in preview.)
        context.coordinator.primaryPolyline = route.polyline

        // Add alternate routes (dimmed)
        for alt in alternateRoutes {
            mapView.addOverlay(alt.polyline, level: .aboveRoads)
        }
        // Add primary route on top
        mapView.addOverlay(route.polyline, level: .aboveRoads)

        // Fit map to show entire route with padding
        let rect = route.polyline.boundingMapRect
        let insets = UIEdgeInsets(top: 80, left: 40, bottom: 280, right: 40)
        mapView.setVisibleMapRect(rect, edgePadding: insets, animated: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MKMapViewDelegate {
        var primaryPolyline: MKPolyline?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                if polyline === primaryPolyline {
                    renderer.strokeColor = SteddiTheme.accentUIColor
                    renderer.lineWidth = 6
                } else {
                    renderer.strokeColor = SteddiTheme.accentUIColor.withAlphaComponent(0.25)
                    renderer.lineWidth = 4
                }
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
