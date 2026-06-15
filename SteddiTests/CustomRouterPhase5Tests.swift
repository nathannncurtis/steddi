import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - Fixture helpers (mirror AStarSearchTests' Overpass-JSON idiom)

private func p5node(_ id: Int64, _ lat: Double, _ lon: Double, tags: [String: String] = [:]) -> String {
    let tagJSON = tags.map { #""\#($0.key)":"\#($0.value)""# }.joined(separator: ",")
    let tagPart = tags.isEmpty ? "" : #","tags":{\#(tagJSON)}"#
    return #"{"type":"node","id":\#(id),"lat":\#(lat),"lon":\#(lon)\#(tagPart)}"#
}

private func p5way(_ id: Int64, _ nodes: [Int64], tags: [String: String]) -> String {
    let nodeList = nodes.map(String.init).joined(separator: ",")
    let tagJSON = tags.map { #""\#($0.key)":"\#($0.value)""# }.joined(separator: ",")
    return #"{"type":"way","id":\#(id),"nodes":[\#(nodeList)],"tags":{\#(tagJSON)}}"#
}

private func p5graph(_ elements: String...) -> RoadGraph {
    let json = #"{"version":0.6,"elements":[\#(elements.joined(separator: ","))]}"#
    let response = try! JSONDecoder().decode(OverpassGraphResponse.self, from: Data(json.utf8))
    return RoadGraphBuilder.buildGraph(from: response)
}

/// A simple connected grid-ish graph: an L-shaped pair of primary ways so a
/// route has at least one real turn for step synthesis.
///   1 --(100)-- 2 --(101)-- 3
///                            |(102)
///                            4
private func lShapedGraph() -> RoadGraph {
    p5graph(
        p5node(1, 0.0, 0.0),
        p5node(2, 0.0, 0.001, tags: ["highway": "traffic_signals"]),
        p5node(3, 0.0, 0.002),
        p5node(4, -0.001, 0.002),
        p5way(100, [1, 2], tags: ["highway": "primary", "maxspeed": "35 mph"]),
        p5way(101, [2, 3], tags: ["highway": "primary", "maxspeed": "35 mph"]),
        p5way(102, [3, 4], tags: ["highway": "primary", "maxspeed": "35 mph"])
    )
}

// MARK: - GeneratedRoute / RouteProvider conformance

@Suite("Phase5 GeneratedRoute adapter")
struct GeneratedRouteAdapterTests {

    @Test("asDirectionsRoute round-trips coordinates, steps, distance, duration")
    func adapterRoundTrips() {
        let coords = [
            CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0),
            CLLocationCoordinate2D(latitude: 34.001, longitude: -118.001),
            CLLocationCoordinate2D(latitude: 34.002, longitude: -118.0),
        ]
        let steps = [
            NavStep(instruction: "Head north", distance: 120, coordinate: coords[0], maneuverSymbol: "location.fill"),
            NavStep(instruction: "Turn left", distance: 0, coordinate: coords[1], maneuverSymbol: "arrow.turn.up.left"),
            NavStep(instruction: "Arrive at your destination", distance: 0, coordinate: coords[2], maneuverSymbol: "flag.fill"),
        ]
        let generated = GeneratedRoute(
            coordinates: coords, steps: steps,
            distanceMeters: 240, expectedTravelTime: 60, source: .custom
        )

        let directions = generated.asDirectionsRoute()
        #expect(directions.distance == 240)
        #expect(directions.duration == 60)
        let decoded = PolylineEncoder.decode(directions.encodedPolyline, precision: 6)
        #expect(decoded.count == coords.count)
        let flatSteps = directions.legs.flatMap { $0.steps }
        #expect(flatSteps.count == 3)
        #expect(flatSteps[1].instructions == "Turn left")
        #expect(flatSteps[1].maneuverType == "arrow.turn.up.left")
    }

    @Test("from(directionsRoute:) lifts steps and decodes geometry")
    func fromDirectionsRoute() {
        let coords = [
            CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0),
            CLLocationCoordinate2D(latitude: 34.0, longitude: -118.001),
            CLLocationCoordinate2D(latitude: 34.001, longitude: -118.001),
        ]
        let directions = DirectionsRoute(
            encodedPolyline: PolylineEncoder.encode(coords, precision: 6),
            distance: 300, duration: 90,
            legs: [DirectionsLeg(steps: [
                DirectionsStep(instructions: "Head east", distance: 100, maneuverType: "location.fill", coordinate: coords[0]),
                DirectionsStep(instructions: "Turn left", distance: 0, maneuverType: "arrow.turn.up.left", coordinate: coords[1]),
                DirectionsStep(instructions: "Arrive at your destination", distance: 0, maneuverType: "flag.fill", coordinate: coords[2]),
            ])]
        )
        let generated = GeneratedRoute.from(directionsRoute: directions, source: .mapKit)
        #expect(generated.source == .mapKit)
        #expect(generated.distanceMeters == 300)
        #expect(generated.expectedTravelTime == 90)
        #expect(generated.coordinates.count == 3)
        #expect(generated.steps.count == 3)
        #expect(generated.steps[1].instruction == "Turn left")
    }

    @Test("from(directionsRoute:) with empty steps falls back to geometric builder")
    func fromDirectionsRouteFallsBackToBuilder() {
        // A bare polyline with a clear right-angle turn but no steps -> the
        // builder synthesizes steps from geometry rather than leaving it empty.
        let coords = [
            CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0),
            CLLocationCoordinate2D(latitude: 34.0, longitude: -118.003),
            CLLocationCoordinate2D(latitude: 34.003, longitude: -118.003),
        ]
        let directions = DirectionsRoute(
            encodedPolyline: PolylineEncoder.encode(coords, precision: 6),
            distance: 600, duration: 120,
            legs: [DirectionsLeg(steps: [])]
        )
        let generated = GeneratedRoute.from(directionsRoute: directions, source: .mapKit)
        #expect(generated.steps.count >= 2)   // builder produced steps
    }

    @Test("from(directionsRoute:) with a single step also falls back to builder")
    func fromDirectionsRouteSingleStepFallsBack() {
        // The fallback guard is `steps.count < 2`, so a lone step (not just zero)
        // must also trigger geometric synthesis — covers the boundary the
        // empty-legs test leaves open.
        let coords = [
            CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0),
            CLLocationCoordinate2D(latitude: 34.0, longitude: -118.003),
            CLLocationCoordinate2D(latitude: 34.003, longitude: -118.003),
        ]
        let directions = DirectionsRoute(
            encodedPolyline: PolylineEncoder.encode(coords, precision: 6),
            distance: 600, duration: 120,
            legs: [DirectionsLeg(steps: [
                DirectionsStep(instructions: "Head east", distance: 100, maneuverType: "location.fill", coordinate: coords[0]),
            ])]
        )
        let generated = GeneratedRoute.from(directionsRoute: directions, source: .mapKit)
        #expect(generated.steps.count >= 2)
    }

    @Test("from(directionsRoute:) classifies symbol from text when maneuverType empty")
    func fromDirectionsRouteEmptyManeuverTypeClassified() {
        // A two-step route whose steps carry no maneuverType: the adapter must
        // backfill the SF Symbol via sfSymbolFromInstruction rather than ship an
        // empty symbol (which the nav UI/voice layer can't render).
        let coords = [
            CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0),
            CLLocationCoordinate2D(latitude: 34.0, longitude: -118.001),
        ]
        let directions = DirectionsRoute(
            encodedPolyline: PolylineEncoder.encode(coords, precision: 6),
            distance: 100, duration: 30,
            legs: [DirectionsLeg(steps: [
                DirectionsStep(instructions: "Turn left", distance: 100, maneuverType: "", coordinate: coords[0]),
                DirectionsStep(instructions: "Arrive at your destination", distance: 0, maneuverType: "", coordinate: coords[1]),
            ])]
        )
        let generated = GeneratedRoute.from(directionsRoute: directions, source: .mapKit)
        #expect(generated.steps.first?.maneuverSymbol == "arrow.turn.up.left")
        #expect(generated.steps.last?.maneuverSymbol == "flag.fill")
    }
}

// MARK: - RoutePreferences -> RoutingContext mapping

@Suite("Phase5 RoutingContext mapping")
struct RoutingContextMappingTests {

    @Test("preferences map straight onto avoid flags")
    func preferencesMap() {
        let request = RouteRequest(
            origin: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            destination: CLLocationCoordinate2D(latitude: 0, longitude: 0.01),
            preferences: RoutePreferences(avoidsTolls: true, avoidsHighways: false)
        )
        let context = CustomRouter.routingContext(for: request)
        #expect(context.avoidsTolls == true)
        #expect(context.avoidsHighways == false)
    }

    @Test("departure hour is taken from departureDate (drives rush weighting)")
    func departureHourMapped() {
        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = 9
        components.hour = 8; components.minute = 15
        let date = Calendar.current.date(from: components)!
        let request = RouteRequest(
            origin: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            destination: CLLocationCoordinate2D(latitude: 0, longitude: 0.01),
            preferences: RoutePreferences(avoidsTolls: false, avoidsHighways: false),
            departureDate: date
        )
        let context = CustomRouter.routingContext(for: request)
        #expect(context.departureHour == Calendar.current.component(.hour, from: date))
        #expect(context.isRushHour == true)   // 8am is in the default 6...9 window
    }

    @Test("inactive zones are dropped, active zones become hard exclusions")
    func zoneActiveFiltering() {
        // A global circular zone with no time window is always active.
        let activeZone = NoGoZone(
            latitude: 0.0, longitude: 0.005,
            radiusMeters: 150,
            name: "Active",
            isGlobal: true
        )
        let request = RouteRequest(
            origin: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            destination: CLLocationCoordinate2D(latitude: 0, longitude: 0.01),
            preferences: RoutePreferences(avoidsTolls: false, avoidsHighways: false),
            noGoZones: [activeZone]
        )
        let context = CustomRouter.routingContext(for: request)
        #expect(context.hardZones.count == 1)
        #expect(context.softZones.isEmpty)
    }

    @Test("a time-windowed zone inactive at departure is actually dropped")
    func inactiveTimeWindowedZoneDropped() {
        // Departure is a Tuesday (2026-06-09, weekday 3). The zone's window only
        // fires on Sunday (weekday 1), so it is inactive at departure and must
        // NOT become a hard exclusion — guards the isActive(now:) filter in
        // routingContext, which the existing always-active test never exercised.
        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = 9
        components.hour = 8; components.minute = 0
        let tuesday = Calendar.current.date(from: components)!

        let windowedZone = NoGoZone(
            geometry: .circle(
                center: CLLocationCoordinate2D(latitude: 0.0, longitude: 0.005),
                radiusMeters: 150
            ),
            isGlobal: true,
            timeWindow: TimeWindow(daysOfWeek: [1], startHour: 0, endHour: 24)
        )
        // Sanity: the model itself agrees the zone is inactive on this Tuesday.
        #expect(windowedZone.isActive(now: tuesday) == false)

        let request = RouteRequest(
            origin: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            destination: CLLocationCoordinate2D(latitude: 0, longitude: 0.01),
            preferences: RoutePreferences(avoidsTolls: false, avoidsHighways: false),
            noGoZones: [windowedZone],
            departureDate: tuesday
        )
        let context = CustomRouter.routingContext(for: request)
        #expect(context.hardZones.isEmpty)
        #expect(context.softZones.isEmpty)
    }

    @Test("off-rush departure hour yields isRushHour false")
    func offRushHourMapped() {
        // 13:00 is outside both default rush windows (6...9, 16...19), so the
        // mapped context must not flag rush hour — the complement of the
        // departureHourMapped test's 8am case.
        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = 9
        components.hour = 13; components.minute = 0
        let date = Calendar.current.date(from: components)!
        let request = RouteRequest(
            origin: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            destination: CLLocationCoordinate2D(latitude: 0, longitude: 0.01),
            preferences: RoutePreferences(avoidsTolls: false, avoidsHighways: false),
            departureDate: date
        )
        let context = CustomRouter.routingContext(for: request)
        #expect(context.departureHour == 13)
        #expect(context.isRushHour == false)
    }
}

// MARK: - NoGoZone -> RoutedZone conversion

@Suite("Phase5 NoGoZone to RoutedZone")
struct RoutedZoneConversionTests {

    @Test("circle zone converts to circle RoutedZone")
    func circleConversion() {
        let zone = NoGoZone(latitude: 34.0, longitude: -118.0, radiusMeters: 200, name: "Circle", isGlobal: true)
        let routed = CustomRouter.routedZone(from: zone)
        guard case let .circle(center, radius)? = routed?.shape else {
            Issue.record("expected circle"); return
        }
        #expect(abs(center.latitude - 34.0) < 1e-9)
        #expect(abs(center.longitude - (-118.0)) < 1e-9)
        #expect(radius == 200)
    }

    @Test("corridor zone converts to corridor RoutedZone with width")
    func corridorConversion() {
        let coords = [
            CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0),
            CLLocationCoordinate2D(latitude: 34.001, longitude: -118.001),
        ]
        let zone = NoGoZone(geometry: .corridor(encodedPolyline: PolylineEncoder.encode(coords, precision: 6), bufferMeters: 50), isGlobal: true)
        let routed = CustomRouter.routedZone(from: zone)
        guard case let .corridor(polyline, width)? = routed?.shape else {
            Issue.record("expected corridor"); return
        }
        #expect(polyline.count == 2)
        #expect(width == 50)
    }

    @Test("polygon zone converts to polygon RoutedZone vertices")
    func polygonConversion() {
        let coords = [
            CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0),
            CLLocationCoordinate2D(latitude: 34.001, longitude: -118.0),
            CLLocationCoordinate2D(latitude: 34.001, longitude: -118.001),
            CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0),
        ]
        let zone = NoGoZone(geometry: .polygon(encodedPolyline: PolylineEncoder.encode(coords, precision: 6)), isGlobal: true)
        let routed = CustomRouter.routedZone(from: zone)
        guard case let .polygon(vertices)? = routed?.shape else {
            Issue.record("expected polygon"); return
        }
        #expect(vertices.count >= 3)
    }

    @Test("degenerate corridor (single point) yields nil")
    func degenerateCorridorNil() {
        let single = [CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0)]
        let zone = NoGoZone(geometry: .corridor(encodedPolyline: PolylineEncoder.encode(single, precision: 6), bufferMeters: 50), isGlobal: true)
        #expect(CustomRouter.routedZone(from: zone) == nil)
    }

    @Test("degenerate polygon (fewer than 3 vertices) yields nil")
    func degeneratePolygonNil() {
        // routedZone requires >= 3 vertices for a polygon; a 2-point polyline
        // can't bound an area, so it must drop to nil rather than feed the cost
        // model an unintersectable shape.
        let twoPoints = [
            CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0),
            CLLocationCoordinate2D(latitude: 34.001, longitude: -118.0),
        ]
        let zone = NoGoZone(geometry: .polygon(encodedPolyline: PolylineEncoder.encode(twoPoints, precision: 6)), isGlobal: true)
        #expect(CustomRouter.routedZone(from: zone) == nil)
    }
}

// MARK: - CustomRouter end-to-end (search + synthesize on an in-memory graph)

@Suite("Phase5 CustomRouter end-to-end")
struct CustomRouterEndToEndTests {

    @Test("search+synthesize produces a non-empty polyline and steps")
    func endToEndOnInMemoryGraph() {
        let graph = lShapedGraph()
        let origin = graph.nodes[Int(graph.osmToIndex[1]!)].coordinate
        let destination = graph.nodes[Int(graph.osmToIndex[4]!)].coordinate

        let synthesis = CustomRouter.searchAndSynthesize(
            stops: [origin, destination],
            graph: graph,
            search: AStarSearch(),
            cost: DefaultCostModel()
        )
        guard let synthesis else { Issue.record("no synthesis"); return }
        #expect(synthesis.coordinates.count >= 2)
        #expect(synthesis.steps.count >= 2)
        // First step heads out, last step arrives — the existing grammar.
        #expect(synthesis.steps.first?.maneuverSymbol == "location.fill")
        #expect(synthesis.steps.last?.maneuverSymbol == "flag.fill")
        // The L-shape forces at least one turn maneuver between depart and arrive.
        let hasTurn = synthesis.steps.contains { $0.instruction.lowercased().contains("turn") || $0.instruction.lowercased().contains("bear") }
        #expect(hasTurn)
    }

    @Test("waypoint leg stitching drops intermediate arrive/depart pairs")
    func waypointStitching() {
        let graph = lShapedGraph()
        let origin = graph.nodes[Int(graph.osmToIndex[1]!)].coordinate
        let waypoint = graph.nodes[Int(graph.osmToIndex[3]!)].coordinate
        let destination = graph.nodes[Int(graph.osmToIndex[4]!)].coordinate

        let synthesis = CustomRouter.searchAndSynthesize(
            stops: [origin, waypoint, destination],
            graph: graph,
            search: AStarSearch(),
            cost: DefaultCostModel()
        )
        guard let synthesis else { Issue.record("no synthesis"); return }
        // Exactly one arrival (final) and one departure (initial) survive.
        let arrivals = synthesis.steps.filter { $0.maneuverSymbol == "flag.fill" }
        let departures = synthesis.steps.filter { $0.maneuverSymbol == "location.fill" }
        #expect(arrivals.count == 1)
        #expect(departures.count == 1)
    }

    @Test("stripping a non-first leg's departure step preserves its lead-in distance")
    func waypointStitchingPreservesLeadInDistance() {
        // Same endpoints, with and without a pass-through waypoint at node 3. The
        // geometry is identical either way, so the SUM of per-step distances must
        // match: when leg 2's "Head" departure step is stripped, its lead-in
        // distance (waypoint → first maneuver, here the whole straight leg to the
        // destination) must be folded forward, not dropped.
        let graph = lShapedGraph()
        let origin = graph.nodes[Int(graph.osmToIndex[1]!)].coordinate
        let waypoint = graph.nodes[Int(graph.osmToIndex[3]!)].coordinate
        let destination = graph.nodes[Int(graph.osmToIndex[4]!)].coordinate

        let direct = CustomRouter.searchAndSynthesize(
            stops: [origin, destination], graph: graph, search: AStarSearch(), cost: DefaultCostModel()
        )
        let viaWaypoint = CustomRouter.searchAndSynthesize(
            stops: [origin, waypoint, destination], graph: graph, search: AStarSearch(), cost: DefaultCostModel()
        )
        guard let direct, let viaWaypoint else { Issue.record("no synthesis"); return }

        let directStepSum = direct.steps.reduce(0) { $0 + $1.distance }
        let viaStepSum = viaWaypoint.steps.reduce(0) { $0 + $1.distance }
        // Both should also match the actual geometry length (steps account for the
        // whole route, no segment unrepresented).
        let geometryLength = RouteGeometry.cumulativeDistances(viaWaypoint.coordinates).last ?? 0
        #expect(abs(viaStepSum - directStepSum) < 1.0)
        #expect(abs(viaStepSum - geometryLength) < 1.0)
        #expect(viaStepSum > 0)
    }

    @Test("no path through a disconnected graph yields nil (fallback signal)")
    func noPathYieldsNil() {
        // Two disconnected ways: origin near one, destination near the other.
        let graph = p5graph(
            p5node(1, 0.0, 0.0),
            p5node(2, 0.0, 0.001),
            p5node(3, 0.05, 0.05),
            p5node(4, 0.05, 0.051),
            p5way(100, [1, 2], tags: ["highway": "primary"]),
            p5way(101, [3, 4], tags: ["highway": "primary"])
        )
        let origin = CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0005)
        let destination = CLLocationCoordinate2D(latitude: 0.05, longitude: 0.0505)
        let synthesis = CustomRouter.searchAndSynthesize(
            stops: [origin, destination],
            graph: graph,
            search: AStarSearch(),
            cost: DefaultCostModel()
        )
        #expect(synthesis == nil)
    }

    @Test("empty graph yields nil")
    func emptyGraphNil() {
        let empty = RoadGraph(
            nodes: [], edges: [], geometry: [], osmToIndex: [:],
            snapIndex: GraphSpatialIndex(grid: [:]), graphMaxSpeedMPS: 0
        )
        let synthesis = CustomRouter.searchAndSynthesize(
            stops: [
                CLLocationCoordinate2D(latitude: 0, longitude: 0),
                CLLocationCoordinate2D(latitude: 0, longitude: 0.001),
            ],
            graph: empty,
            search: AStarSearch(),
            cost: DefaultCostModel()
        )
        #expect(synthesis == nil)
    }

    @Test("corridor densifies a long straight leg with intermediate vertices")
    func corridorDensification() {
        let origin = CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0)
        // ~3 km east.
        let destination = CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0 + 0.032)
        let corridor = CustomRouter.corridor(
            origin: origin, waypoints: [], destination: destination, spacingMeters: 1000
        )
        // First and last are the endpoints; long leg gains intermediate points.
        #expect(corridor.first?.longitude == origin.longitude)
        #expect(corridor.last?.longitude == destination.longitude)
        #expect(corridor.count > 2)
    }

    @Test("corridor of a short leg keeps just the two endpoints")
    func corridorShortLegNotDensified() {
        // A leg under the spacing threshold gets no intermediate vertices, so the
        // loader isn't handed redundant corridor points for near-trips.
        let origin = CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0)
        let destination = CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0005)  // ~46 m
        let corridor = CustomRouter.corridor(
            origin: origin, waypoints: [], destination: destination, spacingMeters: 1000
        )
        #expect(corridor.count == 2)
    }

    @Test("freeFlowDuration scales distance by the urban free-flow speed")
    func freeFlowDurationScales() {
        // 1340 m at the model's 13.4 m/s baseline == 100 s. Honest, traffic-free
        // (the displayed/reroute ETA stays on MKDirections — §6).
        let duration = CustomRouter.freeFlowDuration(of: [], fallbackDistance: 1340)
        #expect(abs(duration - 100) < 0.001)
    }

    @Test("freeFlowDuration of zero distance is zero (no divide-by-zero)")
    func freeFlowDurationZero() {
        #expect(CustomRouter.freeFlowDuration(of: [], fallbackDistance: 0) == 0)
    }

    @Test("freeFlowDuration falls back to polyline length when no distance given")
    func freeFlowDurationFromPolyline() {
        // fallbackDistance <= 0 forces it to measure the polyline itself.
        let coords = [
            CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0),
            CLLocationCoordinate2D(latitude: 34.0, longitude: -118.001),
        ]
        let measured = RouteGeometry.cumulativeDistances(coords).last ?? 0
        let duration = CustomRouter.freeFlowDuration(of: coords, fallbackDistance: 0)
        #expect(measured > 0)
        #expect(abs(duration - measured / 13.4) < 0.001)
    }

    @Test("freeFlowDuration prefers the edge-speed sum over the flat baseline")
    func freeFlowDurationPrefersEdgeSpeeds() {
        // When the search supplied an edge-speed-based duration, use it verbatim;
        // the flat 13.4 m/s baseline (which here would report ~1000 s for 13.4 km)
        // is only a last resort.
        let coords = [
            CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0),
            CLLocationCoordinate2D(latitude: 34.1, longitude: -118.0),
        ]
        let distance = RouteGeometry.cumulativeDistances(coords).last ?? 0
        #expect(distance > 5000)   // a long leg the flat baseline would over-time
        let duration = CustomRouter.freeFlowDuration(
            edgeFreeFlowSeconds: 200,
            fallbackCoords: coords,
            fallbackDistance: distance
        )
        #expect(duration == 200)
    }

    @Test("freeFlowDuration falls back to the flat baseline when no edge speeds")
    func freeFlowDurationFallsBackWithoutEdgeSpeeds() {
        // edgeFreeFlowSeconds == 0 (no edge carried a usable speed) → flat baseline.
        let duration = CustomRouter.freeFlowDuration(
            edgeFreeFlowSeconds: 0,
            fallbackCoords: [],
            fallbackDistance: 1340
        )
        #expect(abs(duration - 100) < 0.001)   // 1340 m / 13.4 m/s
    }

    @Test("a high-speed edge yields a shorter free-flow duration than a residential one of equal length")
    func edgeSpeedDrivesDuration() {
        // Two single-way graphs over the IDENTICAL geometry (same nodes, so same
        // edge length): one motorway-fast, one residential-slow. The synthesized
        // free-flow duration must scale by the edge's real speed — the motorway
        // leg is faster — rather than collapsing to one flat urban baseline.
        func straightGraph(maxspeed: String, highway: String) -> RoadGraph {
            p5graph(
                p5node(1, 34.0, -118.0),
                p5node(2, 34.0, -118.02),   // ~1.8 km east, same for both graphs
                p5way(100, [1, 2], tags: ["highway": highway, "maxspeed": maxspeed])
            )
        }
        let fast = straightGraph(maxspeed: "65 mph", highway: "motorway")
        let slow = straightGraph(maxspeed: "25 mph", highway: "residential")

        let origin = CLLocationCoordinate2D(latitude: 34.0, longitude: -118.0)
        let destination = CLLocationCoordinate2D(latitude: 34.0, longitude: -118.02)

        let fastSyn = CustomRouter.searchAndSynthesize(
            stops: [origin, destination], graph: fast, search: AStarSearch(), cost: DefaultCostModel()
        )
        let slowSyn = CustomRouter.searchAndSynthesize(
            stops: [origin, destination], graph: slow, search: AStarSearch(), cost: DefaultCostModel()
        )
        guard let fastSyn, let slowSyn else { Issue.record("no synthesis"); return }

        // Same geometry length both ways.
        let fastLen = RouteGeometry.cumulativeDistances(fastSyn.coordinates).last ?? 0
        let slowLen = RouteGeometry.cumulativeDistances(slowSyn.coordinates).last ?? 0
        #expect(abs(fastLen - slowLen) < 1.0)

        // Both edge-speed durations are populated and the fast one is strictly
        // shorter — roughly the 65:25 speed ratio (2.6x), not equal.
        #expect(fastSyn.freeFlowSeconds > 0)
        #expect(slowSyn.freeFlowSeconds > 0)
        #expect(fastSyn.freeFlowSeconds < slowSyn.freeFlowSeconds)
        #expect(slowSyn.freeFlowSeconds / fastSyn.freeFlowSeconds > 2.0)

        // And the duration tracks the real edge speed, not the flat 13.4 m/s
        // baseline: a 65 mph (~29 m/s) leg is far quicker than distance / 13.4.
        let flatBaseline = fastLen / 13.4
        #expect(fastSyn.freeFlowSeconds < flatBaseline)
    }
}

// MARK: - StepSynthesizer phrasing

@Suite("Phase5 StepSynthesizer")
struct StepSynthesizerTests {

    @Test("instruction grammar matches sfSymbolFromInstruction classification")
    func grammarMatchesSymbols() {
        #expect(NavigationEngine.sfSymbolFromInstruction(StepSynthesizer.instruction(for: .left)!) == "arrow.turn.up.left")
        #expect(NavigationEngine.sfSymbolFromInstruction(StepSynthesizer.instruction(for: .right)!) == "arrow.turn.up.right")
        #expect(NavigationEngine.sfSymbolFromInstruction(StepSynthesizer.instruction(for: .slightLeft)!) == "arrow.turn.up.left")
        #expect(NavigationEngine.sfSymbolFromInstruction(StepSynthesizer.instruction(for: .uTurn)!) == "arrow.uturn.down")
        #expect(StepSynthesizer.instruction(for: .straight) == nil)
    }

    @Test("stitched polyline has no large gaps between consecutive edges")
    func stitchedPolylineContiguous() {
        let graph = lShapedGraph()
        let result = AStarSearch().search(
            from: .node(graph.osmToIndex[1]!),
            to: .node(graph.osmToIndex[4]!),
            in: graph,
            cost: DefaultCostModel()
        )
        guard let result else { Issue.record("no path"); return }
        let poly = StepSynthesizer.stitchedPolyline(result, in: graph)
        #expect(poly.count >= 2)
        for i in 0..<(poly.count - 1) {
            #expect(RouteGeometry.haversineDistance(from: poly[i], to: poly[i + 1]) < 500)
        }
    }

    @Test("single-edge route trims the sub-segment [startFraction, endFraction] in one pass")
    func singleEdgeTrimComposesCorrectly() {
        // One straight primary edge from node 1 to node 2. A same-edge route (both
        // endpoints mid-edge) must trim to exactly [startFraction, endFraction] of
        // the FULL edge — NOT compose leading-then-trailing on the shortened length.
        let graph = singleEdgeGraph()
        let edge = graph.osmToIndex[1].flatMap { _ in graph.edges.first }
        guard edge != nil, let edgeIdx = graph.edges.indices.first.map({ EdgeIndex($0) }) else {
            Issue.record("no edge"); return
        }
        let fullLen = Double(graph.edges[Int(edgeIdx)].lengthMeters)
        #expect(fullLen > 50)   // sanity: a measurable edge

        let startFraction = 0.2
        let endFraction = 0.6
        let result = SearchResult(
            nodePath: [graph.edges[Int(edgeIdx)].from, graph.edges[Int(edgeIdx)].to],
            edgePath: [edgeIdx],
            totalCost: 0,
            startFraction: startFraction,
            endFraction: endFraction
        )

        let poly = StepSynthesizer.stitchedPolyline(result, in: graph)
        #expect(poly.count >= 2)
        let polyLen = RouteGeometry.cumulativeDistances(poly).last ?? 0
        // Correct sub-segment length is (end - start) * full = 0.4 * full. The old
        // compose-on-trimmed bug yielded (end - start*end) * full = 0.48 * full.
        let expected = (endFraction - startFraction) * fullLen
        #expect(abs(polyLen - expected) < 0.5)
        #expect(abs(polyLen - 0.48 * fullLen) > 1)   // guard against the old bug

        // The destination must land at endFraction along the FULL edge, not beyond.
        let fullGeom = Array(graph.geometry(of: edgeIdx))
        let fullCumulative = RouteGeometry.cumulativeDistances(fullGeom)
        let expectedEnd = RouteGeometry.coordinate(
            atDistance: endFraction * fullLen, polyline: fullGeom, cumulative: fullCumulative)!
        #expect(RouteGeometry.haversineDistance(from: poly.last!, to: expectedEnd) < 0.5)

        // The start must land at startFraction along the FULL edge.
        let expectedStart = RouteGeometry.coordinate(
            atDistance: startFraction * fullLen, polyline: fullGeom, cumulative: fullCumulative)!
        #expect(RouteGeometry.haversineDistance(from: poly.first!, to: expectedStart) < 0.5)

        // The synthesized departure leg distance must equal the sub-segment length.
        let synth = StepSynthesizer.synthesize(result, in: graph)
        guard let synth else { Issue.record("no synthesis"); return }
        let legDistance = synth.steps.map(\.distance).reduce(0, +)
        #expect(abs(legDistance - expected) < 1)
    }

    @Test("repeated edge index: leading/trailing trim is applied by POSITION, not by value")
    func repeatedEdgeIndexTrimsByPosition() {
        // A path whose FIRST and LAST positions share the same edge index — the
        // block-loop / same-edge case where the start edge seeds the path and the
        // same physical edge is also the trailing edge. The leading copy is trimmed
        // to [startFraction, 1.0]; the trailing copy to [0, endFraction]. With the
        // old value-based test both isFirst and isLast matched the FIRST occurrence,
        // so it was charged the full (untrimmed) length and the summed step distance
        // diverged from the polyline actually drawn.
        let graph = lShapedGraph()
        // Edge indices for ways 100 (1->2) and 101 (2->3), both ~111 m primaries.
        guard let e0 = graph.edges.firstIndex(where: { $0.osmWayID == 100 }).map({ EdgeIndex($0) }),
              let e1 = graph.edges.firstIndex(where: { $0.osmWayID == 101 }).map({ EdgeIndex($0) }) else {
            Issue.record("missing fixture edges"); return
        }
        let startFraction = 0.6   // leading copy of e0 trimmed to [0.6, 1.0]
        let endFraction = 0.4     // trailing copy of e0 trimmed to [0.0, 0.4]

        // edgePath = [e0, e1, e0]: e0 appears at position 0 (leading) AND the last
        // position (trailing). nodePath has count == edgePath.count + 1.
        let n0 = graph.edges[Int(e0)].from
        let n1 = graph.edges[Int(e0)].to
        let n2 = graph.edges[Int(e1)].to
        let result = SearchResult(
            nodePath: [n0, n1, n2, graph.edges[Int(e0)].to],
            edgePath: [e0, e1, e0],
            totalCost: 0,
            startFraction: startFraction,
            endFraction: endFraction
        )

        guard let synth = StepSynthesizer.synthesize(result, in: graph) else {
            Issue.record("no synthesis"); return
        }
        let stepSum = synth.steps.map(\.distance).reduce(0, +)

        // The summed step distance must charge each POSITION its own trimmed length:
        //   position 0 (leading e0)  -> [0.6, 1.0] ≈ 0.4 * e0
        //   position 1 (interior e1) -> full e1
        //   position 2 (trailing e0) -> [0.0, 0.4] ≈ 0.4 * e0
        // The trim fractions are arc-length, so derive the exact expected leg
        // lengths from the same trimmed geometry the synthesizer measures.
        let fullE0 = Double(graph.edges[Int(e0)].lengthMeters)
        let middle = Double(graph.edges[Int(e1)].lengthMeters)
        let leadingLen = (1 - startFraction) * fullE0   // ~0.4 * e0
        let trailingLen = endFraction * fullE0          // ~0.4 * e0
        let expectedTotal = leadingLen + middle + trailingLen
        #expect(abs(stepSum - expectedTotal) < 2.0)

        // Guard against the old value-based bug: BOTH e0 occurrences matched
        // `edgeIndex == first` AND `== last`, so each ran trimSubSegment(from: 0.6,
        // to: 0.4); with from > to its `from < to` guard failed and the FULL
        // untrimmed length was charged for both, overstating the total.
        let buggyTotal = fullE0 + middle + fullE0
        #expect(abs(stepSum - buggyTotal) > 2.0)
    }
}

/// A single straight primary edge (node 1 → node 2) with an interior geometry
/// node so the edge carries real intermediate geometry to trim against.
private func singleEdgeGraph() -> RoadGraph {
    p5graph(
        p5node(1, 0.0, 0.0),
        p5node(2, 0.0, 0.0005),   // interior geometry node (referenced once)
        p5node(3, 0.0, 0.0010),
        p5way(100, [1, 2, 3], tags: ["highway": "primary", "maxspeed": "35 mph"])
    )
}

// MARK: - Selector: feature flag + automatic fallback

/// A test double provider returning a canned route (or nil to simulate failure).
private struct StubProvider: RouteProvider {
    let route: GeneratedRoute?
    func generateRoute(_ request: RouteRequest) async -> GeneratedRoute? { route }
}

private func stubRoute(_ source: RouterEngine) -> GeneratedRoute {
    let coords = [
        CLLocationCoordinate2D(latitude: 0, longitude: 0),
        CLLocationCoordinate2D(latitude: 0, longitude: 0.001),
    ]
    return GeneratedRoute(
        coordinates: coords,
        steps: [NavStep(instruction: "Head east", distance: 100, coordinate: coords[0], maneuverSymbol: "location.fill")],
        distanceMeters: 100, expectedTravelTime: 30, source: source
    )
}

private func sampleRequest() -> RouteRequest {
    RouteRequest(
        origin: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        destination: CLLocationCoordinate2D(latitude: 0, longitude: 0.001),
        preferences: RoutePreferences(avoidsTolls: false, avoidsHighways: false)
    )
}

@Suite("Phase5 RouteProviderSelector")
@MainActor
struct RouteProviderSelectorTests {

    @Test("flag off: always uses MapKit fallback")
    func flagOffUsesFallback() async {
        let selector = RouteProviderSelector(
            custom: StubProvider(route: stubRoute(.custom)),
            fallback: StubProvider(route: stubRoute(.mapKit)),
            isCustomEnabled: { false }
        )
        let route = await selector.generateRoute(sampleRequest())
        #expect(route?.source == .mapKit)
    }

    @Test("flag on + custom succeeds: uses custom route")
    func flagOnUsesCustom() async {
        let selector = RouteProviderSelector(
            custom: StubProvider(route: stubRoute(.custom)),
            fallback: StubProvider(route: stubRoute(.mapKit)),
            isCustomEnabled: { true }
        )
        let route = await selector.generateRoute(sampleRequest())
        #expect(route?.source == .custom)
    }

    @Test("flag on + custom returns nil: automatically falls back to MapKit")
    func flagOnCustomNilFallsBack() async {
        let selector = RouteProviderSelector(
            custom: StubProvider(route: nil),
            fallback: StubProvider(route: stubRoute(.mapKit)),
            isCustomEnabled: { true }
        )
        let route = await selector.generateRoute(sampleRequest())
        #expect(route?.source == .mapKit)
    }

    @Test("flag on + both fail: nil (never strands when MapKit also fails)")
    func bothFailNil() async {
        let selector = RouteProviderSelector(
            custom: StubProvider(route: nil),
            fallback: StubProvider(route: nil),
            isCustomEnabled: { true }
        )
        let route = await selector.generateRoute(sampleRequest())
        #expect(route == nil)
    }

    @Test("flag defaults to false in a clean defaults store")
    func flagDefaultsFalse() {
        let defaults = UserDefaults(suiteName: "phase5.flag.test")!
        defaults.removePersistentDomain(forName: "phase5.flag.test")
        #expect(CustomRoutingFlag.isEnabled(in: defaults) == false)
    }
}
