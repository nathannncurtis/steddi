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
    @AppStorage(ThemeModeEx.defaultsKey) private var themeModeEx: String = ThemeModeEx.dynamic.rawValue
    @State private var selectedRoute: MKRoute?

    private var activeRoute: MKRoute { selectedRoute ?? route }

    /// A presented cover gets its own presentation context and does not reliably
    /// inherit the presenter's `.preferredColorScheme`, so pin the app theme here
    /// too — otherwise this cover renders in the device appearance and mismatches
    /// the rest of Steddi when the chosen theme differs from the device.
    private var resolvedColorScheme: ColorScheme? {
        (ThemeModeEx(rawValue: themeModeEx) ?? .dynamic).colorScheme
    }

    var body: some View {
        let _ = accentColor // force SwiftUI re-render on accent change
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
                    // Destination name — wrap to 2 lines then shrink rather than
                    // pushing the fixed card up under the map controls at large
                    // Dynamic Type.
                    Text(destinationName)
                        .font(SteddiTheme.body(16))
                        .foregroundStyle(SteddiTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)

                    // ETA and distance — the two big mono values shrink-to-fit
                    // (mirroring the in-nav speedometer digits) so they don't
                    // collide across the divider at accessibility text sizes.
                    HStack(spacing: 24) {
                        VStack(spacing: 4) {
                            Text("\(Int(ceil(activeRoute.expectedTravelTime / 60)))")
                                .font(SteddiTheme.mono(36))
                                .foregroundStyle(SteddiTheme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            Text("min")
                                .font(SteddiTheme.body(14))
                                .foregroundStyle(SteddiTheme.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }

                        Rectangle()
                            .fill(SteddiTheme.textMuted.opacity(0.3))
                            .frame(width: 1, height: 40)

                        VStack(spacing: 4) {
                            Text(NavigationEngine.formatDistance(activeRoute.distance))
                                .font(SteddiTheme.mono(36))
                                .foregroundStyle(SteddiTheme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            Text("distance")
                                .font(SteddiTheme.body(14))
                                .foregroundStyle(SteddiTheme.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
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
                        // Secondary: neutral glass.
                        Button("Cancel", action: onCancel)
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .buttonStyle(.glass)

                        // Primary CTA: canonical accent glass — fill + AA-legible
                        // on-fill label supplied by the style (no .tint/.glassProminent).
                        Button("Start") {
                            onStart(activeRoute)
                        }
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .buttonStyle(.steddiPrimary)
                    }
                }
                .padding(24)
                // Single neutral glass layer replaces the material+surface double
                // background — the card is information-dense, so no tint.
                .steddiGlass(
                    tint: nil,
                    interactive: false,
                    in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)
                )
            }
        }
        .preferredColorScheme(resolvedColorScheme)
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
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        // Active chip's label+icon sit on accentSubtle (accent@15%); raw accent
        // as text there fails AA in every theme (1.4–4.6:1, same as the route
        // chip), so use textPrimary — the accent identity stays in the fill +
        // stroke. Mirrors routeChip's treatment.
        .foregroundStyle(isActive ? SteddiTheme.textPrimary : SteddiTheme.textSecondary)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(Int(ceil(route.expectedTravelTime / 60))) min")
                    .font(SteddiTheme.mono(14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            // Selected label sits on accentSubtle (accent@15%); accent-on-accent
            // fails AA in every theme (1.4–4.6:1), so use textPrimary which
            // clears it everywhere. The accent identity stays in the fill + stroke.
            .foregroundStyle(isSelected ? SteddiTheme.textPrimary : SteddiTheme.textMuted)
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
                // Contrasting casing under each route line so the colored stroke
                // stays legible over varied map tiles (the raw brand accent washes
                // out over light cartography / park-green fills otherwise).
                let renderer = CasedPolylineRenderer(polyline: polyline)
                if polyline === primaryPolyline {
                    renderer.strokeColor = SteddiTheme.accentUIColor
                    renderer.lineWidth = 6
                } else {
                    // Dimmed alternates carry a softer casing so the outline
                    // doesn't overpower the faint line.
                    renderer.strokeColor = SteddiTheme.accentUIColor.withAlphaComponent(0.25)
                    renderer.lineWidth = 4
                    renderer.casingColor = RouteCasing.current.withAlphaComponent(0.35)
                }
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
