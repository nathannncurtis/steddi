import Foundation
import CoreLocation

/// The decoded Overpass payload the graph builder consumes. Kept distinct from
/// `OSMSpeedLimitService`'s private response type because routing needs node
/// IDs (topology), which the speed service deliberately omits.
///
/// Built from `out body; >; out skel qt;` — ways carry their node-id sequence
/// and tags; nodes carry id + lat/lon (+ any node tags like traffic_signals).
struct OverpassGraphResponse: Decodable, Sendable {
    let elements: [Element]

    struct Element: Decodable, Sendable {
        let type: String                  // "way" | "node" | "relation"
        let id: Int64
        let tags: [String: String]?
        // Way fields:
        let nodes: [Int64]?               // ordered node-id sequence
        // Node fields:
        let lat: Double?
        let lon: Double?
    }
}

/// Builds a `RoadGraph` from an Overpass response. Pure, off-main-safe, fully
/// unit-testable: feed it canned JSON and assert the topology.
///
/// The one subtle algorithm here is split-at-intersections (§3.5): one OSM way
/// becomes one-or-more directed edges, split at every node shared by ≥2 ways
/// (and at the way's own endpoints). Interior degree-2 nodes become edge
/// geometry, not graph nodes. Two ways that visually cross but share no node are
/// NOT connected — that is how OSM models grade separation.
enum RoadGraphBuilder {

    /// Mutable accumulator for a node while ingesting ways. `wayRefCount` counts
    /// how many distinct ways reference the node; ≥2 ⇒ it is an intersection.
    private struct NodeAccumulator {
        let coordinate: CLLocationCoordinate2D
        var wayRefCount: Int = 0
        var hasTrafficSignal: Bool = false
        var hasStopSign: Bool = false
        /// Set once the node is promoted to a graph node, holding its dense index.
        var nodeIndex: NodeIndex?
    }

    static func buildGraph(from response: OverpassGraphResponse) -> RoadGraph {
        // 1. Index nodes by id, capturing signal/stop tags (they live on nodes).
        var nodeAcc: [OSMNodeID: NodeAccumulator] = [:]
        var ways: [(id: OSMNodeID, nodeIDs: [OSMNodeID], tags: [String: String])] = []

        for element in response.elements {
            switch element.type {
            case "node":
                guard let lat = element.lat, let lon = element.lon else { continue }
                let tags = element.tags ?? [:]
                let highway = tags["highway"]?.lowercased()
                nodeAcc[element.id] = NodeAccumulator(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    hasTrafficSignal: highway == "traffic_signals" || tags["traffic_signals"] != nil,
                    hasStopSign: highway == "stop" || highway == "give_way"
                )
            case "way":
                guard let nodeIDs = element.nodes, nodeIDs.count >= 2 else { continue }
                let tags = element.tags ?? [:]
                guard OSMTagParsing.parseRoadClass(tags["highway"]) != .unknown else { continue }
                // Access restrictions (private/no/destination) are carried as edge
                // flags so the Phase-4 cost model decides (§5.2), not dropped here.
                ways.append((id: element.id, nodeIDs: nodeIDs, tags: tags))
            default:
                continue
            }
        }

        // 2. Count node references across ALL kept ways. A node referenced by ≥2
        //    ways is an intersection. Endpoints are always graph nodes too.
        //    Drop way nodes that have no coordinate (response missing the node).
        var validWays: [(id: OSMNodeID, nodeIDs: [OSMNodeID], tags: [String: String])] = []
        validWays.reserveCapacity(ways.count)
        for way in ways {
            let present = way.nodeIDs.filter { nodeAcc[$0] != nil }
            guard present.count >= 2 else { continue }
            validWays.append((id: way.id, nodeIDs: present, tags: way.tags))
            for nodeID in present {
                nodeAcc[nodeID]?.wayRefCount += 1
            }
        }

        // 3. Promote graph nodes: intersections (refCount ≥ 2) plus every way's
        //    first & last node. Assign dense NodeIndex in a stable order.
        var nodes: [GraphNode] = []
        var osmToIndex: [OSMNodeID: NodeIndex] = [:]

        func graphNodeID(_ osmID: OSMNodeID, isEndpoint: Bool) -> Bool {
            guard let acc = nodeAcc[osmID] else { return false }
            return isEndpoint || acc.wayRefCount >= 2
        }

        // Determine the set of promoted ids first (endpoints + intersections),
        // then materialize in encounter order for deterministic indices.
        var promoted = Set<OSMNodeID>()
        for way in validWays {
            promoted.insert(way.nodeIDs.first!)
            promoted.insert(way.nodeIDs.last!)
            for nodeID in way.nodeIDs where (nodeAcc[nodeID]?.wayRefCount ?? 0) >= 2 {
                promoted.insert(nodeID)
            }
        }

        for way in validWays {
            for nodeID in way.nodeIDs where promoted.contains(nodeID) {
                guard nodeAcc[nodeID]?.nodeIndex == nil else { continue }
                let index = NodeIndex(nodes.count)
                nodeAcc[nodeID]?.nodeIndex = index
                osmToIndex[nodeID] = index
                let acc = nodeAcc[nodeID]!
                nodes.append(GraphNode(
                    osmID: nodeID,
                    coordinate: acc.coordinate,
                    firstEdge: 0,        // filled after CSR sort
                    edgeCount: 0,
                    isIntersection: acc.wayRefCount >= 2,
                    hasTrafficSignal: acc.hasTrafficSignal,
                    hasStopSign: acc.hasStopSign
                ))
            }
        }

        // 4-7. Walk each way, emitting an edge between consecutive graph nodes.
        //      Interior (non-promoted) nodes contribute geometry only.
        struct PendingEdge {
            let from: NodeIndex
            let to: NodeIndex
            let coords: [CLLocationCoordinate2D]
            let lengthMeters: Float
            let freeFlowSpeedMPS: Float
            let osmWayID: OSMNodeID
            let roadClass: RoadClass
            let attrs: EdgeAttributes
            let oncomingLanes: UInt8
        }
        var pending: [PendingEdge] = []

        for way in validWays {
            let tags = way.tags
            let roadClass = OSMTagParsing.parseRoadClass(tags["highway"])
            let direction = OSMTagParsing.parseOneway(
                oneway: tags["oneway"],
                junction: tags["junction"],
                highway: tags["highway"]
            )
            let speedMPS = Float(OSMTagParsing.freeFlowSpeedMPS(
                maxspeed: tags["maxspeed"],
                highway: (tags["highway"] ?? "").lowercased()
            ) ?? 0)
            let attrs = edgeAttributes(tags: tags, direction: direction, roadClass: roadClass)
            // Oncoming-lane count a driver crossing this way faces on an
            // unprotected left, precomputed once per way (§5.1). Capped to a byte.
            let oncoming = UInt8(min(255, OSMTagParsing.oncomingLaneCount(
                lanes: tags["lanes"],
                lanesForward: tags["lanes:forward"],
                oneway: direction
            )))

            // Walk the node list, accumulating geometry between graph nodes.
            var segmentCoords: [CLLocationCoordinate2D] = []
            var startNodeID: OSMNodeID?

            for nodeID in way.nodeIDs {
                guard let acc = nodeAcc[nodeID] else { continue }
                segmentCoords.append(acc.coordinate)
                if startNodeID == nil {
                    startNodeID = nodeID
                    continue
                }
                if promoted.contains(nodeID) {
                    // Close out an edge from startNodeID to this graph node.
                    if let start = startNodeID,
                       let fromIdx = nodeAcc[start]?.nodeIndex,
                       let toIdx = acc.nodeIndex,
                       segmentCoords.count >= 2,
                       fromIdx != toIdx {
                        let length = Float(polylineLength(segmentCoords))
                        if direction.allowsForward {
                            pending.append(PendingEdge(
                                from: fromIdx, to: toIdx, coords: segmentCoords,
                                lengthMeters: length, freeFlowSpeedMPS: speedMPS,
                                osmWayID: way.id, roadClass: roadClass, attrs: attrs,
                                oncomingLanes: oncoming
                            ))
                        }
                        if direction.allowsReverse {
                            pending.append(PendingEdge(
                                from: toIdx, to: fromIdx, coords: Array(segmentCoords.reversed()),
                                lengthMeters: length, freeFlowSpeedMPS: speedMPS,
                                osmWayID: way.id, roadClass: roadClass, attrs: attrs,
                                oncomingLanes: oncoming
                            ))
                        }
                    }
                    // Next edge starts at this node; keep its coord as the seed.
                    startNodeID = nodeID
                    segmentCoords = [acc.coordinate]
                }
            }
        }

        // 8a. CSR: sort edges by `from` so each node's out-edges are contiguous.
        pending.sort { $0.from < $1.from }

        var geometryPool: [CLLocationCoordinate2D] = []
        var edges: [GraphEdge] = []
        edges.reserveCapacity(pending.count)
        var firstEdge = [EdgeIndex](repeating: 0, count: nodes.count)
        var edgeCount = [Int32](repeating: 0, count: nodes.count)
        var maxSpeed: Float = 0

        var i = 0
        while i < pending.count {
            let from = pending[i].from
            firstEdge[Int(from)] = EdgeIndex(edges.count)
            var count: Int32 = 0
            while i < pending.count, pending[i].from == from {
                let p = pending[i]
                let lower = Int32(geometryPool.count)
                geometryPool.append(contentsOf: p.coords)
                let upper = Int32(geometryPool.count)
                edges.append(GraphEdge(
                    from: p.from,
                    to: p.to,
                    geometryRange: lower..<upper,
                    lengthMeters: p.lengthMeters,
                    freeFlowSpeedMPS: p.freeFlowSpeedMPS,
                    osmWayID: p.osmWayID,
                    roadClass: p.roadClass,
                    attrs: p.attrs,
                    oncomingLanes: p.oncomingLanes
                ))
                maxSpeed = max(maxSpeed, p.freeFlowSpeedMPS)
                count += 1
                i += 1
            }
            edgeCount[Int(from)] = count
        }

        // 8b. Rewrite node CSR offsets.
        for index in nodes.indices {
            nodes[index] = GraphNode(
                osmID: nodes[index].osmID,
                coordinate: nodes[index].coordinate,
                firstEdge: firstEdge[index],
                edgeCount: edgeCount[index],
                isIntersection: nodes[index].isIntersection,
                hasTrafficSignal: nodes[index].hasTrafficSignal,
                hasStopSign: nodes[index].hasStopSign
            )
        }

        // 8c. Build the snap spatial index over edge geometry.
        let snapIndex = buildSnapIndex(edges: edges, geometry: geometryPool)

        return RoadGraph(
            nodes: nodes,
            edges: edges,
            geometry: geometryPool,
            osmToIndex: osmToIndex,
            snapIndex: snapIndex,
            graphMaxSpeedMPS: maxSpeed
        )
    }

    // MARK: - Helpers

    /// Resolve `EdgeAttributes` from a way's tags.
    static func edgeAttributes(
        tags: [String: String],
        direction: OSMTagParsing.OnewayDirection,
        roadClass: RoadClass
    ) -> EdgeAttributes {
        var attrs: EdgeAttributes = []
        if direction != .both { attrs.insert(.oneway) }
        if OSMTagParsing.parseBoolTag(tags["tunnel"], presentIfNonNo: true) { attrs.insert(.tunnel) }
        if OSMTagParsing.parseBoolTag(tags["bridge"], presentIfNonNo: true) { attrs.insert(.bridge) }
        if OSMTagParsing.parseBoolTag(tags["toll"]) { attrs.insert(.toll) }
        let junction = tags["junction"]?.lowercased()
        if junction == "roundabout" || junction == "circular" { attrs.insert(.roundabout) }
        if roadClass == .link { attrs.insert(.link) }
        if roadClass == .motorway { attrs.insert(.isMotorway) }
        if roadClass == .residential { attrs.insert(.isResidential) }
        if roadClass == .service { attrs.insert(.isService) }

        switch OSMTagParsing.parseAccess(
            access: tags["access"],
            motorVehicle: tags["motor_vehicle"],
            vehicle: tags["vehicle"]
        ) {
        case .restricted: attrs.insert(.privateAccess)
        case .destinationOnly: attrs.insert(.destinationOnly)
        case .allowed: break
        }

        // A dedicated left-turn pocket (a left-only `turn:lanes` cell) implies a
        // protected left phase in most US signals (§5.1). `turn:lanes:forward`
        // takes precedence for two-way ways where the bare tag is ambiguous.
        let turnLanes = OSMTagParsing.parseTurnLanes(tags["turn:lanes:forward"] ?? tags["turn:lanes"])
        if turnLanes.contains(where: { $0.isDedicatedLeft }) {
            attrs.insert(.dedicatedLeftLane)
        }
        return attrs
    }

    /// Geodesic polyline length in meters via `RouteGeometry`.
    static func polylineLength(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count >= 2 else { return 0 }
        return RouteGeometry.cumulativeDistances(coords).last ?? 0
    }

    /// Build the snap grid: register each edge in every cell its geometry's
    /// segment bounding boxes cover. Mirrors `OSMSpeedLimitService.buildIndex`.
    static func buildSnapIndex(
        edges: [GraphEdge],
        geometry: [CLLocationCoordinate2D]
    ) -> GraphSpatialIndex {
        var grid: [GraphSpatialIndex.Cell: [EdgeIndex]] = [:]
        for (edgeIndex, edge) in edges.enumerated() {
            let lower = Int(edge.geometryRange.lowerBound)
            let upper = Int(edge.geometryRange.upperBound)
            guard upper - lower >= 2 else { continue }
            var seen = Set<GraphSpatialIndex.Cell>()
            for i in lower..<(upper - 1) {
                let a = geometry[i]
                let b = geometry[i + 1]
                let latRange = GraphSpatialIndex.cellRange(a.latitude, b.latitude)
                let lonRange = GraphSpatialIndex.cellRange(a.longitude, b.longitude)
                guard latRange.count <= GraphSpatialIndex.maxCellSpanPerSegment,
                      lonRange.count <= GraphSpatialIndex.maxCellSpanPerSegment else { continue }
                for latCell in latRange {
                    for lonCell in lonRange {
                        let cell = GraphSpatialIndex.Cell(lat: latCell, lon: lonCell)
                        if seen.insert(cell).inserted == false { continue }
                        grid[cell, default: []].append(EdgeIndex(edgeIndex))
                    }
                }
            }
        }
        return GraphSpatialIndex(grid: grid)
    }
}
