import Foundation
import CoreLocation

/// Compact OSM node id. OSM node ids are `Int64`; the graph keeps them for
/// diagnostics/learning but routes against dense `NodeIndex`/`EdgeIndex` for
/// cache locality during search.
typealias OSMNodeID = Int64
/// Dense index into `RoadGraph.nodes`.
typealias NodeIndex = Int32
/// Dense index into `RoadGraph.edges`.
typealias EdgeIndex = Int32

/// Road classification, shared with `OSMTagParsing` so the loader and the cost
/// model agree on a single coarse class enum. Kept as a typealias rather than a
/// second declaration to avoid a divergent copy.
typealias RoadClass = OSMTagParsing.RoadClass

/// Packed routing-relevant boolean tags. A struct of bit flags, not a
/// `[String: String]` dictionary — the search reads these millions of times, so
/// they live inline in the dense edge record.
struct EdgeAttributes: OptionSet, Sendable, Hashable, Codable {
    let rawValue: UInt16

    init(rawValue: UInt16) { self.rawValue = rawValue }

    static let oneway          = EdgeAttributes(rawValue: 1 << 0)
    static let tunnel          = EdgeAttributes(rawValue: 1 << 1)
    static let bridge          = EdgeAttributes(rawValue: 1 << 2)
    static let toll            = EdgeAttributes(rawValue: 1 << 3)
    static let roundabout      = EdgeAttributes(rawValue: 1 << 4)
    static let link            = EdgeAttributes(rawValue: 1 << 5)   // *_link ramp
    static let isMotorway      = EdgeAttributes(rawValue: 1 << 6)
    static let isResidential   = EdgeAttributes(rawValue: 1 << 7)
    static let isService       = EdgeAttributes(rawValue: 1 << 8)
    static let privateAccess   = EdgeAttributes(rawValue: 1 << 9)   // access=private/no
    static let destinationOnly = EdgeAttributes(rawValue: 1 << 10)  // access=destination
    /// The way carries a dedicated left-turn lane (a `turn:lanes` cell that is
    /// left-only). A left-turn pocket implies a protected left phase in most US
    /// signals, so the Phase-4 cost model treats a signalized left off such an
    /// edge as protected (§5.1).
    static let dedicatedLeftLane = EdgeAttributes(rawValue: 1 << 11)
    // Bits 12..15 reserved for future flags.
}

/// A graph node — an OSM intersection or way endpoint. Through-points (degree-2
/// nodes interior to a single way) are NOT graph nodes; they become edge
/// geometry instead (see `RoadGraphBuilder`).
struct GraphNode: Sendable, Equatable {
    let osmID: OSMNodeID
    let coordinate: CLLocationCoordinate2D
    /// CSR adjacency: the node's out-edges are `edges[firstEdge ..< firstEdge + edgeCount]`.
    let firstEdge: EdgeIndex
    let edgeCount: Int32
    /// Precomputed at build time so the cost model never recomputes degree:
    /// a node where >2 distinct ways meet is an intersection.
    let isIntersection: Bool
    /// `traffic_signals` tagged on this node (OSM tags signals on the NODE).
    let hasTrafficSignal: Bool
    /// `highway=stop` (or `give_way`) tagged on this node.
    let hasStopSign: Bool

    static func == (lhs: GraphNode, rhs: GraphNode) -> Bool {
        lhs.osmID == rhs.osmID
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.firstEdge == rhs.firstEdge
            && lhs.edgeCount == rhs.edgeCount
            && lhs.isIntersection == rhs.isIntersection
            && lhs.hasTrafficSignal == rhs.hasTrafficSignal
            && lhs.hasStopSign == rhs.hasStopSign
    }
}

/// A directed, routable segment between two graph nodes. One physical OSM way
/// segment yields one edge in each permitted direction; a reverse edge reuses
/// the same geometry, reversed.
struct GraphEdge: Sendable, Equatable {
    let from: NodeIndex
    let to: NodeIndex
    /// Slice into `RoadGraph.geometry` (the flat coord pool), already in travel
    /// direction. The step synthesizer stitches these into the route polyline.
    /// The slice includes both endpoint coordinates, so a straight edge is 2
    /// coords and `geometryRange.count >= 2` always holds.
    let geometryRange: Range<Int32>
    /// Edge arc length in meters. `Double` end-to-end: snapping accumulates
    /// full-precision haversine segment lengths and divides by this total, so a
    /// `Float`-truncated length could read slightly short and push the projected
    /// fraction past 1.0 (silently clamped), corrupting partial-edge cost scaling.
    let lengthMeters: Double
    /// Free-flow speed in m/s from `maxspeed`, or the highway-class default.
    let freeFlowSpeedMPS: Float
    /// Source OSM way id — stable identity for learning (§5.4) and diagnostics.
    let osmWayID: OSMNodeID
    let roadClass: RoadClass
    let attrs: EdgeAttributes
    /// Estimated count of oncoming lanes a driver crossing INTO this edge's
    /// `from` node would face, precomputed from `lanes`/`lanes:forward`/`oneway`
    /// (§5.1). 0 for a oneway edge (no oncoming). The Phase-4 cost model scales
    /// the unprotected-left penalty by this. Capped at 255 (one byte).
    let oncomingLanes: UInt8
}

/// Spatial-hash index over edge geometry, mirroring `OSMSpeedLimitService`'s
/// grid: a coordinate snaps to the nearest point on the nearest edge.
struct GraphSpatialIndex: Sendable {
    /// Cell size in degrees (~110 m latitude), matching the speed-limit grid.
    static let cellSizeDegrees = 0.001
    /// A segment spanning more than this many cells on one axis is corrupt data
    /// or an antimeridian crossing; skip it rather than enumerate ~360k cells.
    static let maxCellSpanPerSegment = 1000

    struct Cell: Hashable, Sendable {
        let lat: Int
        let lon: Int
    }

    /// cell -> edge indices whose geometry passes through that cell.
    let grid: [Cell: [EdgeIndex]]

    static func cellIndex(_ degrees: Double) -> Int {
        Int(floor(degrees / cellSizeDegrees))
    }

    static func cellRange(_ a: Double, _ b: Double) -> ClosedRange<Int> {
        cellIndex(min(a, b))...cellIndex(max(a, b))
    }

    /// The neighbor-cell ring radius needed for `snap` to cover `maxDistanceMeters`
    /// at `latitude`. A query point can sit anywhere in its cell, so the closest
    /// guaranteed distance from the point to the outer edge of a radius-`r` ring is
    /// `r` whole cells (worst case: the point sits on the near boundary). To never
    /// miss an edge inside the snap radius the ring must therefore span at least
    /// `ceil(maxDistanceMeters / metersPerCell)` cells. Cells are narrowest in
    /// longitude (`cos(lat)` shrinks east-west spacing), so we size against that
    /// conservative axis. Always ≥ 1 to preserve the original 3×3 behavior.
    static func cellSearchRadius(forMaxDistanceMeters maxDistanceMeters: Double, atLatitude latitude: Double) -> Int {
        guard maxDistanceMeters > 0 else { return 1 }
        let metersPerDegreeLat = 111_320.0
        // Longitude meters-per-degree shrink with latitude; clamp the cosine to a
        // small floor so an extreme/garbage latitude can't blow the radius up.
        let cosLat = max(0.1, cos(latitude * .pi / 180))
        let metersPerCell = cellSizeDegrees * metersPerDegreeLat * cosLat
        guard metersPerCell > 0 else { return 1 }
        return max(1, Int(ceil(maxDistanceMeters / metersPerCell)))
    }
}

/// The result of snapping an arbitrary coordinate onto the graph: which edge,
/// where along it, the snapped coordinate, and the perpendicular distance.
/// Shaped like `RouteProjection` so the search overlay can splice mid-edge.
struct GraphSnap: Sendable, Equatable {
    let edge: EdgeIndex
    /// Fractional position along the edge geometry (0...1) by arc length.
    let fraction: Double
    let snapped: CLLocationCoordinate2D
    let distanceMeters: Double

    static func == (lhs: GraphSnap, rhs: GraphSnap) -> Bool {
        lhs.edge == rhs.edge
            && lhs.fraction == rhs.fraction
            && lhs.snapped.latitude == rhs.snapped.latitude
            && lhs.snapped.longitude == rhs.snapped.longitude
            && lhs.distanceMeters == rhs.distanceMeters
    }
}

/// The road graph: dense, value-typed, CSR adjacency. Built off-main by
/// `RoadGraphBuilder`, cached as a binary blob by `RoadGraphSerializer`, and
/// searched by Phase 3's A*. Immutable and `Sendable` so it can be shared.
struct RoadGraph: Sendable {
    /// Dense — `NodeIndex` is the position.
    let nodes: [GraphNode]
    /// Dense, sorted so each node's out-edges are contiguous (CSR).
    let edges: [GraphEdge]
    /// Flat coord pool; edges slice into it via `geometryRange`.
    let geometry: [CLLocationCoordinate2D]
    /// Build/diagnostic-time map; kept resident for snap diagnostics and the
    /// learner's edge identity. Droppable post-build if memory bites (§3.9).
    let osmToIndex: [OSMNodeID: NodeIndex]
    let snapIndex: GraphSpatialIndex
    /// Max `freeFlowSpeedMPS` over all edges, precomputed for the A* heuristic
    /// (`h = haversine / graphMaxSpeedMPS`). 0 for an empty graph.
    let graphMaxSpeedMPS: Float

    /// The out-edges of a node, as a half-open index range into `edges`.
    func outEdgeRange(of node: NodeIndex) -> Range<EdgeIndex> {
        let n = nodes[Int(node)]
        return n.firstEdge ..< (n.firstEdge + EdgeIndex(n.edgeCount))
    }

    /// The geometry coordinates of an edge, in travel direction. Returns an
    /// empty slice for an out-of-bounds edge index — `RoadGraphSerializer`
    /// validates indices on load, so this guard only fires on programmer error,
    /// but it keeps the access defensively crash-free.
    func geometry(of edge: EdgeIndex) -> ArraySlice<CLLocationCoordinate2D> {
        guard edge >= 0, Int(edge) < edges.count else { return ArraySlice() }
        let range = edges[Int(edge)].geometryRange
        guard range.lowerBound >= 0, range.upperBound <= Int32(geometry.count),
              range.lowerBound <= range.upperBound else { return ArraySlice() }
        return geometry[Int(range.lowerBound)..<Int(range.upperBound)]
    }

    /// Snap a coordinate to the nearest point on the nearest edge. Scans the
    /// cell containing `coord` plus a square ring of neighbors sized to cover
    /// `maxDistanceMeters`, gated to `maxDistanceMeters`. `heading`, when given,
    /// prefers edges whose local bearing aligns (mod 180) within
    /// `headingToleranceDegrees`.
    ///
    /// The ring radius is derived from `maxDistanceMeters` rather than fixed at a
    /// 3×3 block: with `cellSizeDegrees = 0.001` one cell is only ~78–111 m wide
    /// (smallest in longitude at high US latitudes), so a fixed 3×3 window cannot
    /// reach the 200 m snap radius the router uses for an origin/destination "a
    /// parking lot away" from the nearest edge — valid snaps two or more cells out
    /// would be silently missed. We size the ring so the GUARANTEED search window
    /// (≥ one cell from the query point to the ring edge) covers the full snap
    /// radius across US latitudes, using the conservative (smallest) meters-per-
    /// cell on the longitude axis via `cos(lat)`.
    func snap(
        _ coord: CLLocationCoordinate2D,
        heading: Double? = nil,
        maxDistanceMeters: Double = 50,
        headingToleranceDegrees: Double = 50
    ) -> GraphSnap? {
        guard !edges.isEmpty else { return nil }
        let centerLat = GraphSpatialIndex.cellIndex(coord.latitude)
        let centerLon = GraphSpatialIndex.cellIndex(coord.longitude)
        let radius = GraphSpatialIndex.cellSearchRadius(
            forMaxDistanceMeters: maxDistanceMeters,
            atLatitude: coord.latitude
        )

        var candidates = Set<EdgeIndex>()
        for dLat in -radius...radius {
            for dLon in -radius...radius {
                if let cell = snapIndex.grid[GraphSpatialIndex.Cell(lat: centerLat + dLat, lon: centerLon + dLon)] {
                    candidates.formUnion(cell)
                }
            }
        }

        var best: GraphSnap?
        for edgeIndex in candidates {
            let coords = geometry(of: edgeIndex)
            guard coords.count >= 2 else { continue }
            let base = coords.startIndex
            var cumulative: Double = 0
            for i in 0..<(coords.count - 1) {
                let a = coords[base + i]
                let b = coords[base + i + 1]
                if let heading {
                    let segBearing = RouteGeometry.bearing(from: a, to: b)
                    if OSMSpeedLimitService.bearingDelta(segBearing, heading) > headingToleranceDegrees {
                        cumulative += RouteGeometry.haversineDistance(from: a, to: b)
                        continue
                    }
                }
                let (snapped, t, perp) = Self.projectOntoSegment(coord, a, b)
                guard perp <= maxDistanceMeters else {
                    cumulative += RouteGeometry.haversineDistance(from: a, to: b)
                    continue
                }
                // Deterministic tie-break: strictly closer wins; on a near-tie
                // (candidates iterate from a Set, so order is otherwise
                // nondeterministic), prefer the lower edge index so routes are
                // reproducible run-to-run.
                let currentBest = best?.distanceMeters ?? .infinity
                let strictlyCloser = perp < currentBest - 1e-6
                let tiedButLowerIndex = abs(perp - currentBest) <= 1e-6 && (best.map { edgeIndex < $0.edge } ?? true)
                if strictlyCloser || tiedButLowerIndex {
                    let segLen = RouteGeometry.haversineDistance(from: a, to: b)
                    let along = cumulative + segLen * t
                    let total = edges[Int(edgeIndex)].lengthMeters
                    let fraction = total > 0 ? min(1, max(0, along / total)) : 0
                    best = GraphSnap(edge: edgeIndex, fraction: fraction, snapped: snapped, distanceMeters: perp)
                }
                cumulative += RouteGeometry.haversineDistance(from: a, to: b)
            }
        }
        return best
    }

    /// Project a point onto a segment, returning the snapped coordinate, the
    /// fractional position t (0...1), and the perpendicular distance in meters.
    /// Equirectangular at street scale, identical to the speed service's math.
    static func projectOntoSegment(
        _ point: CLLocationCoordinate2D,
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> (snapped: CLLocationCoordinate2D, t: Double, distanceMeters: Double) {
        let cosLat = cos(point.latitude * .pi / 180)
        let px = (point.longitude - a.longitude) * cosLat
        let py = point.latitude - a.latitude
        let dx = (b.longitude - a.longitude) * cosLat
        let dy = b.latitude - a.latitude
        let segLenSq = dx * dx + dy * dy
        var t: Double = 0
        if segLenSq > 0 { t = max(0, min(1, (px * dx + py * dy) / segLenSq)) }
        let snapped = CLLocationCoordinate2D(
            latitude: a.latitude + t * (b.latitude - a.latitude),
            longitude: a.longitude + t * (b.longitude - a.longitude)
        )
        return (snapped, t, RouteGeometry.haversineDistance(from: point, to: snapped))
    }
}
