import Foundation
import CoreLocation
import MapKit

/// Route preference overrides for toll/highway avoidance.
struct RoutePreferences {
    var avoidsTolls: Bool
    var avoidsHighways: Bool

    /// Resolve preferences: per-commute overrides > global defaults.
    static func resolve(commute: Commute? = nil) -> RoutePreferences {
        let globalTolls = UserDefaults.standard.bool(forKey: "steddi.defaultAvoidsTolls")
        let globalHighways = UserDefaults.standard.bool(forKey: "steddi.defaultAvoidsHighways")
        return RoutePreferences(
            avoidsTolls: commute?.avoidsTolls ?? globalTolls,
            avoidsHighways: commute?.avoidsHighways ?? globalHighways
        )
    }

    func apply(to request: MKDirections.Request) {
        request.tollPreference = avoidsTolls ? .avoid : .any
        request.highwayPreference = avoidsHighways ? .avoid : .any
    }
}

/// Wraps Apple MapKit MKDirections for route fetching and ETA estimation,
/// plus OSRM via-routing for multi-point planned routes.
final class DirectionsService {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetch a route between two points.
    func fetchRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        profile: String = "driving",
        preferences: RoutePreferences = .resolve()
    ) async throws -> DirectionsRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = .automobile
        preferences.apply(to: request)

        let directions = MKDirections(request: request)
        let response = try await directions.calculate()

        guard let mkRoute = response.routes.first else {
            throw DirectionsError.noRoute
        }

        return Self.directionsRoute(from: mkRoute)
    }

    /// Get the current ETA from a position to the route's destination.
    /// The `along` polyline parameter is accepted for API compatibility but
    /// the ETA is calculated as a simple origin-to-destination request.
    func fetchETA(
        from origin: CLLocationCoordinate2D,
        along encodedPolyline: String
    ) async throws -> TimeInterval {
        // Decode polyline to get the destination (last coordinate)
        let routeCoords = PolylineEncoder.decode(encodedPolyline, precision: 6)
        guard let destinationCoord = routeCoords.last else {
            throw DirectionsError.noRoute
        }

        return try await fetchDirectETA(from: origin, to: destinationCoord)
    }

    /// Direct origin-to-destination travel time estimate from MKDirections.
    /// Used as a sanity reference for saved route durations.
    func fetchDirectETA(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async throws -> TimeInterval {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = .automobile

        let directions = MKDirections(request: request)
        let eta = try await directions.calculateETA()

        return eta.expectedTravelTime
    }

    // MARK: - Via Routing (OSRM)

    /// One through-route across every plot point. Intermediate coordinates are
    /// pass-through vias — OSRM returns a single distance and duration with no
    /// per-stop dwell and no snap-to-address arrival spurs, unlike chaining one
    /// MKDirections request per leg (which models a complete trip ending at
    /// every tap and inflates the totals).
    func fetchViaRoute(points: [CLLocationCoordinate2D]) async throws -> DirectionsRoute {
        guard points.count >= 2 else {
            throw DirectionsError.noRoute
        }

        let coordinates = points.map { "\($0.longitude),\($0.latitude)" }.joined(separator: ";")
        guard var components = URLComponents(string: "https://router.project-osrm.org/route/v1/driving/\(coordinates)") else {
            throw DirectionsError.apiError
        }
        components.queryItems = [
            URLQueryItem(name: "continue_straight", value: "true"),
            URLQueryItem(name: "geometries", value: "polyline6"),
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "steps", value: "true"),
            URLQueryItem(name: "alternatives", value: "false"),
        ]

        guard let url = components.url else {
            throw DirectionsError.apiError
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Steddi/1.0 (steddi.io)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw DirectionsError.apiError
        }

        let result = try JSONDecoder().decode(ViaRouteResponse.self, from: data)
        guard result.code == "Ok", let route = result.routes?.first else {
            throw DirectionsError.noRoute
        }

        let coords = PolylineEncoder.decode(route.geometry, precision: 6)
        guard coords.count >= 2 else {
            throw DirectionsError.noRoute
        }

        return DirectionsRoute(
            encodedPolyline: route.geometry,
            distance: route.distance,
            duration: route.duration,
            legs: [DirectionsLeg(steps: Self.viaSteps(from: route, fullGeometry: coords))]
        )
    }

    // MARK: - Chained-Leg Fallback Stitching

    /// Stitch chained per-leg routes into one through-route, trimming the
    /// stop artifacts each leg boundary carries: out-and-back spurs at the
    /// junction geometry, the intermediate arrival/departure steps, and the
    /// per-leg duration share of the trimmed spur distance.
    static func stitchTrimmedLegs(_ legs: [DirectionsRoute]) -> DirectionsRoute? {
        guard !legs.isEmpty else { return nil }
        guard legs.count > 1 else { return legs[0] }

        var legCoords = legs.map { PolylineEncoder.decode($0.encodedPolyline, precision: 6) }

        // Trim out-and-back spurs at each junction: a leg routed TO a tap
        // coordinate ends in a spur the next leg immediately retraces.
        for i in 0..<(legCoords.count - 1) {
            var previous = legCoords[i]
            var next = legCoords[i + 1]
            while previous.count >= 2, next.count >= 2,
                  RouteGeometry.haversineDistance(from: previous[previous.count - 2], to: next[1]) < junctionEpsilonMeters {
                previous.removeLast()
                next.removeFirst()
            }
            legCoords[i] = previous
            legCoords[i + 1] = next
        }

        // Collapse any residual out-and-back spikes (snap-to-address spurs
        // that aren't vertex-exact retraces) before measuring trimmed legs,
        // so distance and duration stay consistent.
        legCoords = legCoords.map { RouteGeometry.removeSpikes($0) }

        // Scale each leg's duration to its trimmed geometry at the leg's own
        // average speed: trimmedDistance / (legDistance / legDuration).
        var totalDuration: Double = 0
        for (i, leg) in legs.enumerated() {
            guard leg.duration > 0, leg.distance > 0 else { continue }
            let trimmedDistance = RouteGeometry.cumulativeDistances(legCoords[i]).last ?? 0
            totalDuration += trimmedDistance / (leg.distance / leg.duration)
        }

        // Stitch the trimmed geometry, deduping the shared junction vertex
        var stitched: [CLLocationCoordinate2D] = []
        for coords in legCoords {
            if let last = stitched.last, let first = coords.first,
               RouteGeometry.haversineDistance(from: last, to: first) < junctionEpsilonMeters {
                stitched.append(contentsOf: coords.dropFirst())
            } else {
                stitched.append(contentsOf: coords)
            }
        }
        guard stitched.count >= 2 else { return nil }
        let totalDistance = RouteGeometry.cumulativeDistances(stitched).last ?? 0

        // Drop each intermediate leg's arrival step and the next leg's depart
        // steps — plot points are pass-throughs, not stops.
        var steps: [DirectionsStep] = []
        for (i, leg) in legs.enumerated() {
            var legSteps = leg.legs.flatMap { $0.steps }
            if i > 0 {
                legSteps = Array(legSteps.drop { $0.instructions.isEmpty || isDepartStep($0) })
            }
            if i < legs.count - 1 {
                while let last = legSteps.last, isArrivalStep(last) {
                    legSteps.removeLast()
                }
            }
            steps.append(contentsOf: legSteps)
        }

        return DirectionsRoute(
            encodedPolyline: PolylineEncoder.encode(stitched, precision: 6),
            distance: totalDistance,
            duration: totalDuration,
            legs: [DirectionsLeg(steps: steps)]
        )
    }

    /// Coordinates closer than this are the same junction vertex.
    private static let junctionEpsilonMeters: Double = 3

    /// Evenly sampled via points (endpoints always kept) so a via-route
    /// request follows a saved polyline without exceeding OSRM's coordinate
    /// limit or building an oversized URL.
    static func sampledViaPoints(
        from coords: [CLLocationCoordinate2D],
        maxPoints: Int = 12
    ) -> [CLLocationCoordinate2D] {
        guard maxPoints >= 2, coords.count > maxPoints else { return coords }
        return (0..<maxPoints).map { i in
            coords[Int(round(Double(i) * Double(coords.count - 1) / Double(maxPoints - 1)))]
        }
    }

    static func isArrivalStep(_ step: DirectionsStep) -> Bool {
        step.maneuverType == "flag.fill"
            || NavigationEngine.sfSymbolFromInstruction(step.instructions) == "flag.fill"
    }

    static func isDepartStep(_ step: DirectionsStep) -> Bool {
        step.maneuverType == "location.fill"
            || NavigationEngine.sfSymbolFromInstruction(step.instructions) == "location.fill"
    }

    /// Fetch the best route honoring no-go zones, with its validation result.
    ///
    /// MKDirections can't exclude areas natively, so this requests alternates,
    /// validates each against the active zones with `ZoneValidationEngine`, and
    /// returns the fastest fully-clear route. When every candidate violates a
    /// zone (the all-routes-violate case), it returns the least-violating one
    /// alongside its (non-clear) validation result so the caller can warn the
    /// user instead of stopping — better to drive through a zone than nowhere.
    func fetchRouteWithExclusions(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        excluding noGoZones: [NoGoZone],
        now: Date = Date(),
        preferences: RoutePreferences = .resolve()
    ) async throws -> (route: DirectionsRoute, validation: RouteValidationResult) {
        let candidates = try await fetchRouteCandidates(
            from: origin,
            to: destination,
            preferences: preferences
        )
        guard !candidates.isEmpty else { throw DirectionsError.noRoute }

        let engine = ZoneValidationEngine()
        let validations = candidates.map {
            engine.validateRoute($0.encodedPolyline, againstZones: noGoZones, now: now)
        }

        // Prefer the first fully-clear candidate (candidates arrive
        // fastest-first from MKDirections).
        if let clearIndex = validations.firstIndex(where: { $0.isValid }) {
            return (candidates[clearIndex], validations[clearIndex])
        }

        // All routes violate — fall back to the least-violating candidate.
        var bestIndex = 0
        for i in validations.indices where validations[i].violationCount < validations[bestIndex].violationCount {
            bestIndex = i
        }
        return (candidates[bestIndex], validations[bestIndex])
    }

    /// All MKDirections candidate routes (fastest first), requesting alternates.
    func fetchRouteCandidates(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        preferences: RoutePreferences = .resolve()
    ) async throws -> [DirectionsRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        preferences.apply(to: request)

        let directions = MKDirections(request: request)
        let response = try await directions.calculate()
        return response.routes.map { Self.directionsRoute(from: $0) }
    }

    // MARK: - Private

    /// Convert an MKRoute into a DirectionsRoute.
    private static func directionsRoute(from mkRoute: MKRoute) -> DirectionsRoute {
        let coordinates = polylineCoordinates(from: mkRoute.polyline)
        let encoded = PolylineEncoder.encode(coordinates, precision: 6)

        let steps: [DirectionsStep] = mkRoute.steps.compactMap { step in
            // MKRoute.Step includes empty-instruction entries for route segments;
            // keep them but fall back to empty string.
            let instruction = step.instructions
            return DirectionsStep(
                instructions: instruction,
                distance: step.distance,
                maneuverType: sfSymbol(for: instruction),
                coordinate: step.polyline.coordinate
            )
        }

        return DirectionsRoute(
            encodedPolyline: encoded,
            distance: mkRoute.distance,
            duration: mkRoute.expectedTravelTime,
            legs: [DirectionsLeg(steps: steps)]
        )
    }

    /// Flatten OSRM legs into the app's step model. Intermediate vias are
    /// pass-throughs, so the arrive/depart pair OSRM emits at every waypoint
    /// is dropped — only the first depart and the final arrival survive.
    /// Falls back to geometry-derived steps when OSRM steps are unusable.
    private static func viaSteps(
        from route: ViaRouteResponse.Route,
        fullGeometry: [CLLocationCoordinate2D]
    ) -> [DirectionsStep] {
        var steps: [DirectionsStep] = []
        for (legIndex, leg) in route.legs.enumerated() {
            for step in leg.steps ?? [] {
                if step.maneuver.type == "arrive" && legIndex < route.legs.count - 1 { continue }
                if step.maneuver.type == "depart" && legIndex > 0 { continue }

                let instruction = Self.instruction(for: step)
                steps.append(DirectionsStep(
                    instructions: instruction,
                    distance: step.distance,
                    maneuverType: NavigationEngine.sfSymbolFromInstruction(instruction),
                    coordinate: step.maneuver.coordinate
                ))
            }
        }

        if steps.count < 2 {
            return CustomRouteBuilder.buildSteps(from: fullGeometry).map { navStep in
                DirectionsStep(
                    instructions: navStep.instruction,
                    distance: navStep.distance,
                    maneuverType: navStep.maneuverSymbol,
                    coordinate: navStep.coordinate
                )
            }
        }

        return steps
    }

    /// Map an OSRM maneuver to the app's instruction phrasing — the same
    /// phrases NavigationEngine.sfSymbolFromInstruction classifies.
    private static func instruction(for step: ViaRouteResponse.Step) -> String {
        let road = step.name.trimmingCharacters(in: .whitespaces)
        let onto = road.isEmpty ? "" : " onto \(road)"
        let on = road.isEmpty ? "" : " on \(road)"
        let modifier = step.maneuver.modifier ?? ""

        switch step.maneuver.type {
        case "depart":
            if let bearing = step.maneuver.bearingAfter {
                return "Head \(CustomRouteBuilder.cardinalDirection(Double(bearing)))\(on)"
            }
            return "Head out\(on)"
        case "arrive":
            return "Arrive at your destination"
        case "merge":
            return "Merge\(onto)"
        case "on ramp":
            if modifier.contains("left") { return "Take the ramp on the left\(onto)" }
            if modifier.contains("right") { return "Take the ramp on the right\(onto)" }
            return "Take the ramp\(onto)"
        case "off ramp":
            return "Take the exit\(onto)"
        case "fork":
            if modifier.contains("left") { return "Keep left at the fork\(onto)" }
            if modifier.contains("right") { return "Keep right at the fork\(onto)" }
            return "Continue at the fork\(onto)"
        case "roundabout", "rotary":
            if let exit = step.maneuver.exit {
                return "Enter the roundabout and take exit \(exit)"
            }
            return "Enter the roundabout"
        case "exit roundabout", "exit rotary":
            return "Exit the roundabout\(onto)"
        case "new name", "continue":
            if let phrase = turnPhrase(for: modifier) {
                return road.isEmpty ? phrase : "\(phrase) to stay\(on)"
            }
            return road.isEmpty ? "Continue straight" : "Continue\(on)"
        default:
            if let phrase = turnPhrase(for: modifier) {
                return modifier == "uturn" ? phrase : "\(phrase)\(onto)"
            }
            return road.isEmpty ? "Continue straight" : "Continue\(on)"
        }
    }

    /// Phrase for a turning OSRM modifier. nil for straight/unknown.
    private static func turnPhrase(for modifier: String) -> String? {
        switch modifier {
        case "uturn": return "Make a U-turn"
        case "sharp left": return "Turn sharp left"
        case "sharp right": return "Turn sharp right"
        case "left": return "Turn left"
        case "right": return "Turn right"
        case "slight left": return "Bear left"
        case "slight right": return "Bear right"
        default: return nil
        }
    }

    /// Extract CLLocationCoordinate2D array from an MKPolyline.
    private static func polylineCoordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let count = polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }

    /// Map an instruction string to an SF Symbol name for the maneuver type.
    private static func sfSymbol(for instruction: String) -> String {
        let lower = instruction.lowercased()

        if lower.contains("u-turn") {
            return "arrow.uturn.down"
        }
        if lower.contains("roundabout") {
            return "arrow.triangle.2.circlepath"
        }
        if lower.contains("merge") {
            return "arrow.merge"
        }
        if lower.contains("arrive") || lower.contains("destination") {
            return "flag.fill"
        }
        if lower.contains("ramp") && lower.contains("left") {
            return "arrow.up.left"
        }
        if lower.contains("ramp") && lower.contains("right") {
            return "arrow.up.right"
        }
        if lower.contains("left") {
            return "arrow.turn.up.left"
        }
        if lower.contains("right") {
            return "arrow.turn.up.right"
        }

        return "arrow.up"
    }
}

// MARK: - Route Types

struct DirectionsRoute {
    let encodedPolyline: String
    let distance: Double          // meters
    let duration: TimeInterval    // seconds
    let legs: [DirectionsLeg]
}

struct DirectionsLeg {
    let steps: [DirectionsStep]
}

struct DirectionsStep {
    let instructions: String
    let distance: Double
    let maneuverType: String                 // SF Symbol name
    let coordinate: CLLocationCoordinate2D   // maneuver location
}

// MARK: - OSRM API Response Types

struct ViaRouteResponse: Decodable {
    let code: String
    let routes: [Route]?

    struct Route: Decodable {
        let geometry: String
        let distance: Double
        let duration: Double
        let legs: [Leg]
    }

    struct Leg: Decodable {
        let distance: Double
        let duration: Double
        let steps: [Step]?
    }

    struct Step: Decodable {
        let distance: Double
        let duration: Double
        let name: String
        let maneuver: Maneuver
    }

    struct Maneuver: Decodable {
        let location: [Double]   // [longitude, latitude]
        let type: String
        let modifier: String?
        let bearingAfter: Int?
        let exit: Int?

        enum CodingKeys: String, CodingKey {
            case location, type, modifier, exit
            case bearingAfter = "bearing_after"
        }

        var coordinate: CLLocationCoordinate2D {
            guard location.count >= 2 else { return CLLocationCoordinate2D() }
            return CLLocationCoordinate2D(latitude: location[1], longitude: location[0])
        }
    }
}

// MARK: - Errors

enum DirectionsError: Error, LocalizedError {
    case apiError
    case noRoute

    var errorDescription: String? {
        switch self {
        case .apiError: return "Directions request failed."
        case .noRoute: return "No route found between the given points."
        }
    }
}
