import Foundation
import CoreLocation

/// Tunable weights for `DefaultCostModel`. Every value is INJECTED DATA, never a
/// magic literal in the cost logic, so routing behaviour is configured (and,
/// in Phase 7, learned per driver) rather than hard-coded.
///
/// INVARIANT — admissibility: all road-class/preference multipliers are >= 1 and
/// all additive penalties are >= 0. The A* heuristic is the pure free-flow time
/// lower bound (`haversine / graphMaxSpeed`); because no cost here ever discounts
/// an edge below its free-flow travel time, that heuristic never overestimates
/// and A* stays optimal. Do not introduce a multiplier < 1.
struct CostWeights: Sendable, Equatable {
    // Turn penalties (seconds-equivalent), charged at the maneuver node.
    var straightPenalty: Double = 0
    var rightTurnPenalty: Double = 4
    var protectedLeftPenalty: Double = 6
    /// Unprotected left = a left across oncoming traffic with no protected phase.
    /// Total = base + perOncomingLane × oncomingLanes — this is the "UPS, but more"
    /// signal: a busy unprotected left is expensive enough that a right-turn
    /// detour wins.
    var unprotectedLeftBase: Double = 25
    var unprotectedLeftPerOncomingLane: Double = 9
    var uTurnPenalty: Double = 140
    /// Added when the maneuver node carries a stop sign (lost time decelerating).
    var stopSignPenalty: Double = 5
    /// Added when the maneuver node is signalized (expected wait), any direction.
    var trafficSignalPenalty: Double = 8

    // Edge multipliers (>= 1) and additive edge costs.
    /// Per-RoadClass comfort multiplier, indexed by RoadClass.rawValue (0...9).
    /// Unknown roads are filtered at graph-build time, so only classes 0-9 ever
    /// reach the cost model. Residential/service cost a little more per second so
    /// the router prefers through-roads when time is equal.
    var roadClassMultiplier: [Double] = [
        1.0,  // 0 motorway
        1.0,  // 1 trunk
        1.0,  // 2 primary
        1.02, // 3 secondary
        1.05, // 4 tertiary
        1.08, // 5 unclassified
        1.12, // 6 residential
        1.25, // 7 livingStreet
        1.4,  // 8 service
        1.0,  // 9 link
    ]
    /// Multiplier applied to motorway/trunk/link edges when the driver opted to
    /// avoid highways. Large but finite so a highway is used only if unavoidable.
    var avoidHighwayMultiplier: Double = 4
    /// Flat penalty added once per tolled edge when the driver opted to avoid
    /// tolls (finite — a toll is taken only if it's the sole way through).
    var tollPenalty: Double = 600
    /// Flat penalty added once per `access=destination` edge. Large but FINITE so
    /// a destination-only road (a private alley/driveway usable only to reach a
    /// property on it) is never chosen as a through-route, yet stays reachable when
    /// it is the sole way to the snapped origin/destination — the cost model can't
    /// see endpoints, so a finite penalty leaves that decision to A*. (`access=no`/
    /// `private` is hard-excluded outright, not penalized; see `edgeCost`.)
    var destinationOnlyPenalty: Double = 1200
    /// Rush-hour edge-time multiplier, applied during the configured rush windows.
    var rushHourMultiplier: Double = 1.35
    /// Soft no-go zone penalty per second of edge time spent inside the zone — a
    /// graduated "rather avoid" the hard exclusion lacks (MapKit can't do this).
    var softZoneTimeMultiplier: Double = 6

    static let `default` = CostWeights()
}

/// A no-go zone resolved to plain geometry for the pure router — no SwiftData.
/// Phase 5's facade converts each `NoGoZone` into one of these (circle/polygon/
/// corridor) so the cost model stays a pure value computation.
struct RoutedZone: Sendable, Equatable {
    enum Shape: Sendable {
        case circle(center: CLLocationCoordinate2D, radiusMeters: Double)
        case polygon(vertices: [CLLocationCoordinate2D])
        case corridor(polyline: [CLLocationCoordinate2D], widthMeters: Double)
    }
    let shape: Shape

    static func == (lhs: RoutedZone, rhs: RoutedZone) -> Bool {
        switch (lhs.shape, rhs.shape) {
        case let (.circle(c1, r1), .circle(c2, r2)):
            return c1.latitude == c2.latitude && c1.longitude == c2.longitude && r1 == r2
        case let (.polygon(v1), .polygon(v2)):
            return v1.count == v2.count && zip(v1, v2).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
        case let (.corridor(p1, w1), .corridor(p2, w2)):
            return w1 == w2 && p1.count == p2.count && zip(p1, p2).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
        default:
            return false
        }
    }

    /// Whether any part of an edge's geometry falls inside the zone. Checks
    /// vertices and, for every shape, the segments between them so an edge that
    /// passes through without a vertex landing inside is still caught.
    func intersects(_ coords: ArraySlice<CLLocationCoordinate2D>) -> Bool {
        let pts = Array(coords)
        guard !pts.isEmpty else { return false }
        switch shape {
        case let .circle(center, radius):
            for i in 0..<pts.count {
                if RouteGeometry.haversineDistance(from: pts[i], to: center) <= radius { return true }
                if i + 1 < pts.count {
                    let d = RouteGeometry.projectOntoSegment(point: center, segStart: pts[i], segEnd: pts[i + 1]).distance
                    if d <= radius { return true }
                }
            }
            return false
        case let .polygon(vertices):
            // A route VERTEX inside the polygon (covers a route that starts/ends
            // or turns inside the zone).
            if pts.contains(where: { RoutedZone.polygonContains(vertices, $0) }) { return true }
            guard vertices.count >= 3 else { return false }
            // A route SEGMENT that crosses a polygon boundary edge — catches the
            // straight 2-vertex road that runs through a zone smaller than the
            // block, with neither endpoint inside.
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                var k = vertices.count - 1
                for j in 0..<vertices.count {
                    if RoutedZone.segmentsIntersect(a, b, vertices[k], vertices[j]) { return true }
                    k = j
                }
            }
            // A polygon entirely contained within a single route segment crosses
            // no boundary edge and contains no route vertex, so also test whether
            // any polygon vertex lies on/near a route segment.
            if pts.count >= 2 {
                for v in vertices {
                    for i in 0..<(pts.count - 1) {
                        let proj = RouteGeometry.projectOntoSegment(point: v, segStart: pts[i], segEnd: pts[i + 1])
                        if proj.distance <= RoutedZone.containedVertexToleranceMeters { return true }
                    }
                }
            }
            return false
        case let .corridor(polyline, width):
            guard polyline.count >= 2 else { return false }
            for p in pts {
                for j in 0..<(polyline.count - 1) {
                    if RouteGeometry.projectOntoSegment(point: p, segStart: polyline[j], segEnd: polyline[j + 1]).distance <= width {
                        return true
                    }
                }
            }
            return false
        }
    }

    /// Ray-casting point-in-polygon (even-odd rule), planar — fine at street scale.
    static func polygonContains(_ vertices: [CLLocationCoordinate2D], _ p: CLLocationCoordinate2D) -> Bool {
        guard vertices.count >= 3 else { return false }
        var inside = false
        var j = vertices.count - 1
        for i in 0..<vertices.count {
            let vi = vertices[i], vj = vertices[j]
            if (vi.longitude > p.longitude) != (vj.longitude > p.longitude) {
                let slope = (p.longitude - vi.longitude) / (vj.longitude - vi.longitude)
                let latAtCrossing = vi.latitude + slope * (vj.latitude - vi.latitude)
                if p.latitude < latAtCrossing { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// A polygon wholly inside one route segment crosses no boundary edge; we
    /// catch it by polygon-vertex-to-route-segment distance. Sized small (~1 m)
    /// so it only fires when a polygon vertex genuinely sits on the road, not for
    /// a polygon merely near a parallel road.
    static let containedVertexToleranceMeters: Double = 1.0

    /// Whether segment p1-p2 intersects segment p3-p4 (proper or improper, i.e.
    /// including touching/collinear-overlap), using the standard orientation
    /// (signed-area) predicate in planar lon/lat space — fine at street scale.
    static func segmentsIntersect(
        _ p1: CLLocationCoordinate2D, _ p2: CLLocationCoordinate2D,
        _ p3: CLLocationCoordinate2D, _ p4: CLLocationCoordinate2D
    ) -> Bool {
        let d1 = orientation(p3, p4, p1)
        let d2 = orientation(p3, p4, p2)
        let d3 = orientation(p1, p2, p3)
        let d4 = orientation(p1, p2, p4)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
           ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return true
        }
        // Collinear / touching endpoints: the third point lies on the segment.
        if d1 == 0 && onSegment(p3, p4, p1) { return true }
        if d2 == 0 && onSegment(p3, p4, p2) { return true }
        if d3 == 0 && onSegment(p1, p2, p3) { return true }
        if d4 == 0 && onSegment(p1, p2, p4) { return true }
        return false
    }

    /// Signed area of triangle (a, b, c): >0 counter-clockwise, <0 clockwise,
    /// 0 collinear. Uses lon as x, lat as y.
    private static func orientation(
        _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ c: CLLocationCoordinate2D
    ) -> Double {
        (b.longitude - a.longitude) * (c.latitude - a.latitude)
            - (b.latitude - a.latitude) * (c.longitude - a.longitude)
    }

    /// Whether point `p`, known collinear with segment a-b, lies within its bounds.
    private static func onSegment(
        _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ p: CLLocationCoordinate2D
    ) -> Bool {
        p.longitude >= min(a.longitude, b.longitude) && p.longitude <= max(a.longitude, b.longitude)
            && p.latitude >= min(a.latitude, b.latitude) && p.latitude <= max(a.latitude, b.latitude)
    }
}

/// Everything route generation needs beyond the graph: the driver's preferences,
/// the departure time (for rush weighting), and resolved no-go zones split into
/// hard exclusions and soft "rather avoid" penalties.
struct RoutingContext: Sendable, Equatable {
    var avoidsTolls: Bool = false
    var avoidsHighways: Bool = false
    /// Local hour-of-day (0...23) at departure, or nil to skip rush weighting.
    var departureHour: Int?
    /// Inclusive local-hour rush windows, e.g. [6...9, 16...19].
    var rushWindows: [ClosedRange<Int>] = [6...9, 16...19]
    var hardZones: [RoutedZone] = []
    var softZones: [RoutedZone] = []

    var isRushHour: Bool {
        guard let h = departureHour else { return false }
        return rushWindows.contains { $0.contains(h) }
    }
}

/// The maneuver category at an intersection, from the heading change between the
/// incoming and outgoing edges.
enum TurnDirection: Sendable, Equatable {
    case straight, slightLeft, slightRight, left, right, uTurn
}

/// Steddi's production cost model — the differentiator. Conforms to the Phase-3
/// `SearchCost` so it drops into the existing A* unchanged. Pure: no I/O, fully
/// unit-tested. Weights and context are injected.
struct DefaultCostModel: SearchCost {
    let weights: CostWeights
    let context: RoutingContext

    init(weights: CostWeights = .default, context: RoutingContext = RoutingContext()) {
        self.weights = weights
        self.context = context
    }

    // MARK: - Edge cost

    func edgeCost(_ edge: GraphEdge, in graph: RoadGraph) -> Double {
        let speed = Double(edge.freeFlowSpeedMPS)
        guard speed > 0 else { return .infinity }

        // Access: `access=no`/`private` is hard-excluded from the driving profile
        // (same impassable treatment as a hard no-go zone) — a gated/no-access road
        // must never be a through-route. Checked before any geometry resolution
        // since it short-circuits the whole edge. `access=destination` is handled
        // below with a large finite penalty (usable only to reach an endpoint).
        if edge.attrs.contains(.privateAccess) { return .infinity }

        var time = Double(edge.lengthMeters) / speed   // free-flow seconds (the floor)

        // Hard/soft no-go zones need the edge's geometry, which costs an O(fan-out)
        // edge-index resolution + slice. In the common path (no zones configured)
        // skip it entirely — edgeCost is the single hottest function in A*, and
        // resolving geometry only to discard it would scale search latency with
        // node degree, undoing the dense-CSR design. Resolved once and shared by
        // the hard- and soft-zone checks below.
        let geom: ArraySlice<CLLocationCoordinate2D>?
        if !context.hardZones.isEmpty || !context.softZones.isEmpty {
            geom = graph.geometry(of: edgeIndexForCost(edge, in: graph))
        } else {
            geom = nil
        }

        // Hard no-go: an excluded edge is impassable.
        if let geom {
            for zone in context.hardZones where zone.intersects(geom) { return .infinity }
        }

        // Road-class comfort multiplier (>= 1).
        let rc = Int(edge.roadClass.rawValue)
        if rc >= 0 && rc < weights.roadClassMultiplier.count {
            time *= weights.roadClassMultiplier[rc]
        }

        // Avoid-highways: penalize motorway/trunk/link.
        if context.avoidsHighways &&
            (edge.attrs.contains(.isMotorway) || edge.roadClass == .motorway || edge.roadClass == .trunk || edge.attrs.contains(.link)) {
            time *= weights.avoidHighwayMultiplier
        }

        // Rush-hour time inflation.
        if context.isRushHour { time *= weights.rushHourMultiplier }

        // Soft no-go: graduated penalty proportional to time spent in the zone.
        if !context.softZones.isEmpty, let geom {
            let baseTime = Double(edge.lengthMeters) / speed
            for zone in context.softZones where zone.intersects(geom) {
                time += baseTime * weights.softZoneTimeMultiplier
            }
        }

        // Avoid-tolls: flat additive penalty.
        if context.avoidsTolls && edge.attrs.contains(.toll) {
            time += weights.tollPenalty
        }

        // Destination-only access: large finite penalty so the edge is used only
        // when it is the sole way to reach the snapped origin/destination on it,
        // never as a through-route. Additive and >= 0, so admissibility holds.
        if edge.attrs.contains(.destinationOnly) {
            time += weights.destinationOnlyPenalty
        }

        return time
    }

    // MARK: - Turn cost

    func turnCost(from incoming: GraphEdge?, to outgoing: GraphEdge, at node: GraphNode, in graph: RoadGraph) -> Double {
        guard let incoming else { return 0 }   // origin: no maneuver
        let turn = Self.classifyTurn(from: incoming, to: outgoing, in: graph)

        var cost: Double
        switch turn {
        case .straight:
            cost = weights.straightPenalty
        case .slightRight, .right:
            cost = weights.rightTurnPenalty
        case .slightLeft, .left:
            cost = leftTurnCost(outgoing: outgoing, node: node)
        case .uTurn:
            cost = weights.uTurnPenalty
        }

        // Node controls cost time regardless of direction (waiting to proceed).
        if node.hasTrafficSignal {
            cost += weights.trafficSignalPenalty
        } else if node.hasStopSign {
            cost += weights.stopSignPenalty
        }
        return cost
    }

    /// A left is "protected" when the maneuver is signalized AND the outgoing way
    /// has a dedicated left-turn pocket (a left-only `turn:lanes` cell) — in US
    /// signal practice that pairing implies a protected left phase. Otherwise the
    /// left is unprotected and scales with the oncoming lanes that must be crossed.
    private func leftTurnCost(outgoing: GraphEdge, node: GraphNode) -> Double {
        let protectedLeft = node.hasTrafficSignal && outgoing.attrs.contains(.dedicatedLeftLane)
        if protectedLeft {
            return weights.protectedLeftPenalty
        }
        return weights.unprotectedLeftBase
            + weights.unprotectedLeftPerOncomingLane * Double(outgoing.oncomingLanes)
    }

    // MARK: - Heuristic (admissible: pure free-flow time lower bound)

    func heuristic(from coordinate: CLLocationCoordinate2D, to target: CLLocationCoordinate2D, in graph: RoadGraph) -> Double {
        let maxSpeed = Double(graph.graphMaxSpeedMPS)
        guard maxSpeed > 0 else { return 0 }
        return RouteGeometry.haversineDistance(from: coordinate, to: target) / maxSpeed
    }

    // MARK: - Turn classification

    /// Heading change from the incoming edge's approach bearing (into the node) to
    /// the outgoing edge's departure bearing (out of the node), normalized to
    /// (-180, 180]. Positive = clockwise = right; negative = left.
    static func signedTurnAngle(from incoming: GraphEdge, to outgoing: GraphEdge, in graph: RoadGraph) -> Double {
        let approach = approachBearing(of: incoming, in: graph)
        let depart = departureBearing(of: outgoing, in: graph)
        var delta = depart - approach
        while delta > 180 { delta -= 360 }
        while delta <= -180 { delta += 360 }
        return delta
    }

    static func classifyTurn(from incoming: GraphEdge, to outgoing: GraphEdge, in graph: RoadGraph) -> TurnDirection {
        let a = signedTurnAngle(from: incoming, to: outgoing, in: graph)
        let m = abs(a)
        if m >= 150 { return .uTurn }
        if m <= 12 { return .straight }
        if a > 0 { return m < 40 ? .slightRight : .right }
        return m < 40 ? .slightLeft : .left
    }

    /// Bearing over the last geometry segment of `edge` (direction of travel into
    /// the destination node).
    static func approachBearing(of edge: GraphEdge, in graph: RoadGraph) -> Double {
        let coords = graph.geometry(of: edgeIndex(of: edge, in: graph))
        let pts = Array(coords)
        guard pts.count >= 2 else { return 0 }
        return RouteGeometry.bearing(from: pts[pts.count - 2], to: pts[pts.count - 1])
    }

    /// Bearing over the first geometry segment of `edge` (direction of travel out
    /// of the origin node).
    static func departureBearing(of edge: GraphEdge, in graph: RoadGraph) -> Double {
        let coords = graph.geometry(of: edgeIndex(of: edge, in: graph))
        let pts = Array(coords)
        guard pts.count >= 2 else { return 0 }
        return RouteGeometry.bearing(from: pts[0], to: pts[1])
    }

    // MARK: - Edge geometry resolution

    /// Locate an edge's index so its geometry slice can be read. Edges don't carry
    /// their own index, so resolve by the (from, to, geometryRange) identity over
    /// the from-node's out-edges (CSR adjacency, small fan-out).
    private static func edgeIndex(of edge: GraphEdge, in graph: RoadGraph) -> EdgeIndex {
        let range = graph.outEdgeRange(of: edge.from)
        for e in range {
            let candidate = graph.edges[Int(e)]
            if candidate.to == edge.to && candidate.geometryRange == edge.geometryRange {
                return e
            }
        }
        // Fallback: first out-edge (degenerate; geometry lookups tolerate it).
        return range.lowerBound
    }

    private func edgeIndexForCost(_ edge: GraphEdge, in graph: RoadGraph) -> EdgeIndex {
        Self.edgeIndex(of: edge, in: graph)
    }
}
