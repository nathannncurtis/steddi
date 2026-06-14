import Foundation
import CoreLocation

/// The shape `NavigationEngine.startNavigation(polyline:steps:expectedTravelTime:)`
/// consumes, lifted into a value type so route GENERATION is decoupled from who
/// produced it. Both the MapKit path (`DirectionsService`) and the custom road
/// graph router emit one of these, so the integration seam is a single triple:
/// a polyline, turn-by-turn `NavStep`s, and an expected travel time.
///
/// `GeneratedRoute` deliberately mirrors `DirectionsRoute`'s information so it
/// can be adapted to it (`asDirectionsRoute`) and flow unchanged through every
/// existing call site — `Route.encodeSteps`, `savedNavSteps`, route planning —
/// while also being directly consumable by `startNavigation`.
struct GeneratedRoute: Sendable, Equatable {
    /// Full route geometry, precision-6 encodable.
    let coordinates: [CLLocationCoordinate2D]
    /// Synthesized turn-by-turn steps, in the grammar `NavigationEngine`'s symbol
    /// and voice classifiers already understand.
    let steps: [NavStep]
    /// Total route distance in meters.
    let distanceMeters: Double
    /// Expected travel time in seconds. From edge free-flow speeds for the custom
    /// router (NOT traffic-aware — §6), from MapKit's traffic-aware estimate for
    /// the fallback.
    let expectedTravelTime: TimeInterval
    /// Which engine produced this route, for provenance / A-B comparison (§7.3).
    let source: RouterEngine

    static func == (lhs: GeneratedRoute, rhs: GeneratedRoute) -> Bool {
        lhs.distanceMeters == rhs.distanceMeters
            && lhs.expectedTravelTime == rhs.expectedTravelTime
            && lhs.source == rhs.source
            && lhs.coordinates.count == rhs.coordinates.count
            && zip(lhs.coordinates, rhs.coordinates).allSatisfy {
                $0.latitude == $1.latitude && $0.longitude == $1.longitude
            }
            && lhs.steps.count == rhs.steps.count
            && zip(lhs.steps, rhs.steps).allSatisfy {
                $0.instruction == $1.instruction
                    && $0.distance == $1.distance
                    && $0.maneuverSymbol == $1.maneuverSymbol
            }
    }

    /// Adapt to the existing `DirectionsRoute` so the route flows through every
    /// existing call site (encode/save/plan) untouched. Steps map 1-1 onto
    /// `DirectionsStep`, polyline to a precision-6 encoded string.
    func asDirectionsRoute() -> DirectionsRoute {
        DirectionsRoute(
            encodedPolyline: PolylineEncoder.encode(coordinates, precision: 6),
            distance: distanceMeters,
            duration: expectedTravelTime,
            legs: [DirectionsLeg(steps: steps.map { navStep in
                DirectionsStep(
                    instructions: navStep.instruction,
                    distance: navStep.distance,
                    maneuverType: navStep.maneuverSymbol,
                    coordinate: navStep.coordinate
                )
            })]
        )
    }

    /// Build a `GeneratedRoute` from a `DirectionsRoute` (the MapKit/OSRM path),
    /// decoding its polyline and lifting its steps into `NavStep`s. Falls back to
    /// `CustomRouteBuilder.buildSteps` when the route carries no usable steps so a
    /// bare-geometry route still navigates.
    static func from(directionsRoute route: DirectionsRoute, source: RouterEngine) -> GeneratedRoute {
        let coords = PolylineEncoder.decode(route.encodedPolyline, precision: 6)
        var steps = route.legs.flatMap { $0.steps }.map { step in
            NavStep(
                instruction: step.instructions,
                distance: step.distance,
                coordinate: step.coordinate,
                maneuverSymbol: step.maneuverType.isEmpty
                    ? NavigationEngine.sfSymbolFromInstruction(step.instructions)
                    : step.maneuverType
            )
        }
        if steps.count < 2 {
            steps = CustomRouteBuilder.buildSteps(from: coords)
        }
        return GeneratedRoute(
            coordinates: coords,
            steps: steps,
            distanceMeters: route.distance,
            expectedTravelTime: route.duration,
            source: source
        )
    }
}

/// Which routing engine produced a route. Persisted as provenance on `Route`
/// (§7.3) so saved routes record their origin and the two engines can be A-B'd.
enum RouterEngine: String, Sendable, Equatable, Codable {
    case mapKit
    case custom
}

/// What a route request asks for: endpoints, optional intermediate waypoints, the
/// driver's avoidance preferences, the no-go zones to honor, and the departure
/// time (for the cost model's rush-hour weighting). One value carries everything
/// both providers need so the seam is a single method.
struct RouteRequest: Sendable {
    let origin: CLLocationCoordinate2D
    let destination: CLLocationCoordinate2D
    /// Ordered pass-through points between origin and destination. Empty for a
    /// simple point-to-point request.
    var waypoints: [CLLocationCoordinate2D] = []
    var preferences: RoutePreferences
    /// No-go zones to honor. The custom router bakes these into search cost; the
    /// MapKit fallback validates alternates against them post-hoc.
    var noGoZones: [NoGoZone] = []
    /// When the drive departs — drives time-of-day cost weighting. Defaults to now.
    var departureDate: Date = Date()

    init(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        waypoints: [CLLocationCoordinate2D] = [],
        preferences: RoutePreferences,
        noGoZones: [NoGoZone] = [],
        departureDate: Date = Date()
    ) {
        self.origin = origin
        self.destination = destination
        self.waypoints = waypoints
        self.preferences = preferences
        self.noGoZones = noGoZones
        self.departureDate = departureDate
    }
}

/// Route GENERATION abstracted from its engine. Both `DirectionsService` (the
/// MapKit/OSRM fallback) and `CustomRouter` (the road-graph differentiator)
/// conform, so the app fetches routes through one protocol and a selector decides
/// which engine to use per request (§7.2, §7.3).
///
/// Conformers own ONLY generation. Traffic-aware ETA and the reroute decision
/// stay on `DirectionsService.fetchDirectETA`/`fetchETA` regardless (§6) — those
/// are deliberately NOT part of this protocol.
protocol RouteProvider: Sendable {
    /// Generate a route for the request, or `nil` if this provider cannot (e.g.
    /// the custom router's corridor graph isn't loaded, or no path exists). A nil
    /// return is the fallback signal — never a hard failure.
    func generateRoute(_ request: RouteRequest) async -> GeneratedRoute?
}

// MARK: - DirectionsService as the MapKit RouteProvider (the fallback)

extension DirectionsService: RouteProvider {
    /// Wrap the existing MKDirections path. Waypoints route via OSRM
    /// (`fetchViaRoute`); no-go zones route via the zone-aware candidate filter
    /// (`fetchRouteWithExclusions`); otherwise a plain `fetchRoute`. Any thrown
    /// error becomes `nil` so the selector can fall through cleanly.
    func generateRoute(_ request: RouteRequest) async -> GeneratedRoute? {
        do {
            if !request.waypoints.isEmpty {
                let points = [request.origin] + request.waypoints + [request.destination]
                let route = try await fetchViaRoute(points: points)
                return GeneratedRoute.from(directionsRoute: route, source: .mapKit)
            }
            if !request.noGoZones.isEmpty {
                let result = try await fetchRouteWithExclusions(
                    from: request.origin,
                    to: request.destination,
                    excluding: request.noGoZones,
                    now: request.departureDate,
                    preferences: request.preferences
                )
                return GeneratedRoute.from(directionsRoute: result.route, source: .mapKit)
            }
            let route = try await fetchRoute(
                from: request.origin,
                to: request.destination,
                preferences: request.preferences
            )
            return GeneratedRoute.from(directionsRoute: route, source: .mapKit)
        } catch {
            return nil
        }
    }
}
