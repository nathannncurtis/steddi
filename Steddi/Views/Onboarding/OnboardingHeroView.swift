import SwiftUI
import MapKit

/// Beat 1 of onboarding: a full-bleed dark map with a route line that draws on
/// across it, then settles. The first thing a new user sees — it has to *feel*
/// like quality in a couple of seconds, not teach anything.
///
/// The draw-on reuses the animations pillar's `RouteDrawRenderer` and
/// `RouteDrawGeometry` directly: the same `MKPolylineRenderer` subclass the live
/// nav map uses, driven 0→1 by a `CADisplayLink` over a cinematic ~2.5s (longer
/// than nav's 1.2s on purpose). Reduce Motion jumps straight to the full line
/// and fires `onAnimationComplete` immediately — no display link.
struct OnboardingHeroView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Called once the route finishes drawing (or immediately under Reduce
    /// Motion), so the parent can pop the footer's primary button in on cue.
    var onAnimationComplete: () -> Void

    @State private var copyVisible = false

    var body: some View {
        ZStack {
            OnboardingHeroMap(
                reduceMotion: reduceMotion,
                onAnimationComplete: onAnimationComplete
            )
            .ignoresSafeArea()
            .accessibilityElement()
            .accessibilityLabel("A route draws across the map")

            // Dark scrim for text legibility over the cartography.
            LinearGradient(
                colors: [.black.opacity(0.55), .black.opacity(0.15), .black.opacity(0.45)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                Spacer()
                VStack(spacing: 8) {
                    Text("Your route, your rules")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text("Let's get started")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 60)
                .opacity(copyVisible ? 1 : 0)
                .offset(y: copyVisible ? 0 : 12)
            }
        }
        .onAppear {
            guard !reduceMotion else { copyVisible = true; return }
            withAnimation(.easeOut(duration: 0.6)) { copyVisible = true }
        }
    }
}

/// MapKit bridge that strokes a fixed demo route with the draw-on renderer.
///
/// The route is a short, hand-picked polyline (not the user's data — location
/// isn't granted yet at this beat) shown over a dark, POI-free map. The map is
/// non-interactive so the hero reads as a poster, not a tool.
private struct OnboardingHeroMap: UIViewRepresentable {
    let reduceMotion: Bool
    var onAnimationComplete: () -> Void

    /// Cinematic draw duration — slower than nav's 1.2s for a poster feel.
    private static let heroDrawDuration: CFTimeInterval = 2.5

    /// A gently curving demo route through San Francisco. Coordinate-dense
    /// enough that the eased tip glides rather than snaps between corners.
    private static let demoRoute: [CLLocationCoordinate2D] = [
        .init(latitude: 37.7935, longitude: -122.3960),
        .init(latitude: 37.7918, longitude: -122.4015),
        .init(latitude: 37.7890, longitude: -122.4060),
        .init(latitude: 37.7861, longitude: -122.4098),
        .init(latitude: 37.7825, longitude: -122.4135),
        .init(latitude: 37.7799, longitude: -122.4185),
        .init(latitude: 37.7770, longitude: -122.4232),
        .init(latitude: 37.7742, longitude: -122.4290),
        .init(latitude: 37.7724, longitude: -122.4350),
    ]

    func makeCoordinator() -> Coordinator {
        Coordinator(onAnimationComplete: onAnimationComplete)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.preferredConfiguration = SteddiTheme.mapConfiguration(traffic: false, poiFilter: .excludingAll)
        mapView.overrideUserInterfaceStyle = .dark
        mapView.isZoomEnabled = false
        mapView.isScrollEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsUserLocation = false
        mapView.showsCompass = false
        mapView.showsScale = false

        let polyline = MKPolyline(coordinates: Self.demoRoute, count: Self.demoRoute.count)
        context.coordinator.routePolyline = polyline
        mapView.addOverlay(polyline, level: .aboveRoads)

        let rect = polyline.boundingMapRect
        let insets = UIEdgeInsets(top: 120, left: 60, bottom: 180, right: 60)
        mapView.setVisibleMapRect(rect, edgePadding: insets, animated: false)

        context.coordinator.startDrawOn(reduceMotion: reduceMotion)
        return mapView
    }

    func updateUIView(_ uiViewController: MKMapView, context: Context) {}

    static func dismantleUIView(_ uiView: MKMapView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var routePolyline: MKPolyline?
        private weak var renderer: RouteDrawRenderer?
        private var displayLink: CADisplayLink?
        private var startTime: CFTimeInterval = 0
        private var didComplete = false
        private let onAnimationComplete: () -> Void

        init(onAnimationComplete: @escaping () -> Void) {
            self.onAnimationComplete = onAnimationComplete
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline, polyline === routePolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let r = RouteDrawRenderer(polyline: polyline)
            r.strokeColor = SteddiTheme.accentUIColor
            r.lineWidth = 7
            r.animationProgress = 0
            renderer = r
            return r
        }

        /// Kick off the eased draw-on. Under Reduce Motion the line is shown
        /// whole and completion fires on the next runloop hop so the parent's
        /// state settles before the footer reacts.
        func startDrawOn(reduceMotion: Bool) {
            guard !reduceMotion else {
                renderer?.animationProgress = 1
                finish()
                return
            }
            startTime = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func tick() {
            guard let renderer else { finish(); return }
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(1, elapsed / OnboardingHeroMap.heroDrawDuration)
            renderer.animationProgress = CGFloat(RouteDrawGeometry.easeOut(t))
            if t >= 1 { finish() }
        }

        private func finish() {
            displayLink?.invalidate()
            displayLink = nil
            renderer?.animationProgress = 1
            guard !didComplete else { return }
            didComplete = true
            let cb = onAnimationComplete
            // Hop off the display-link callback before mutating SwiftUI state.
            DispatchQueue.main.async { cb() }
        }

        func tearDown() {
            displayLink?.invalidate()
            displayLink = nil
        }
    }
}
