import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - Fixture helpers

/// Build an Overpass node element JSON (id + lat/lon + optional tags).
private func nodeJSON(_ id: Int64, _ lat: Double, _ lon: Double, tags: [String: String] = [:]) -> String {
    let tagJSON = tags.map { #""\#($0.key)":"\#($0.value)""# }.joined(separator: ",")
    let tagPart = tags.isEmpty ? "" : #","tags":{\#(tagJSON)}"#
    return #"{"type":"node","id":\#(id),"lat":\#(lat),"lon":\#(lon)\#(tagPart)}"#
}

/// Build an Overpass way element JSON (id + ordered node ids + tags).
private func wayElementJSON(_ id: Int64, nodes: [Int64], tags: [String: String]) -> String {
    let nodeList = nodes.map(String.init).joined(separator: ",")
    let tagJSON = tags.map { #""\#($0.key)":"\#($0.value)""# }.joined(separator: ",")
    return #"{"type":"way","id":\#(id),"nodes":[\#(nodeList)],"tags":{\#(tagJSON)}}"#
}

private func decodeResponse(_ elements: String...) -> OverpassGraphResponse {
    let json = #"{"version":0.6,"elements":[\#(elements.joined(separator: ","))]}"#
    return try! JSONDecoder().decode(OverpassGraphResponse.self, from: Data(json.utf8))
}

private func buildGraph(_ elements: String...) -> RoadGraph {
    let json = #"{"version":0.6,"elements":[\#(elements.joined(separator: ","))]}"#
    let response = try! JSONDecoder().decode(OverpassGraphResponse.self, from: Data(json.utf8))
    return RoadGraphBuilder.buildGraph(from: response)
}

// MARK: - Split-at-intersections

@Suite("RoadGraphBuilder.split")
struct RoadGraphBuilderSplitTests {

    /// A single two-node way → exactly one bidirectional pair (no oneway).
    @Test("Simple two-node way yields two graph nodes and a both-direction edge pair")
    func simpleWay() {
        let graph = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            nodeJSON(2, 0.0, 0.001),
            wayElementJSON(100, nodes: [1, 2], tags: ["highway": "residential"])
        )
        #expect(graph.nodes.count == 2)
        #expect(graph.edges.count == 2) // forward + reverse
        // Both nodes are endpoints; neither is an intersection (refCount 1).
        #expect(graph.nodes.allSatisfy { !$0.isIntersection })
    }

    /// A degree-2 interior node (only in one way) is NOT a graph node — it
    /// becomes edge geometry. Two ways sharing node 3 → 3 IS a graph node.
    @Test("Interior degree-2 node is geometry; shared node is a graph node")
    func interiorVsShared() {
        // Way A: 1-2-3 (node 2 interior to A only). Way B: 3-4 (shares node 3).
        let graph = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            nodeJSON(2, 0.0, 0.001),
            nodeJSON(3, 0.0, 0.002),
            nodeJSON(4, 0.001, 0.002),
            wayElementJSON(100, nodes: [1, 2, 3], tags: ["highway": "residential"]),
            wayElementJSON(101, nodes: [3, 4], tags: ["highway": "residential"])
        )
        // Graph nodes: 1, 3, 4 (node 2 is interior → geometry only).
        #expect(graph.osmToIndex[2] == nil)
        #expect(graph.osmToIndex[1] != nil)
        #expect(graph.osmToIndex[3] != nil)
        #expect(graph.osmToIndex[4] != nil)
        #expect(graph.nodes.count == 3)
        // Node 3 is shared by 2 ways → intersection.
        let idx3 = Int(graph.osmToIndex[3]!)
        #expect(graph.nodes[idx3].isIntersection)
        // The 1→3 edge geometry must include the interior node 2 (3 coords).
        guard let edge13 = graph.edges.first(where: {
            $0.from == graph.osmToIndex[1] && $0.to == graph.osmToIndex[3]
        }) else { Issue.record("missing 1->3 edge"); return }
        #expect(edge13.geometryRange.count == 3)
    }

    /// CRITICAL: two ways crossing geographically but sharing NO node are not
    /// connected (grade separation — bridge over road).
    @Test("Crossing ways with no shared node are not connected")
    func gradeSeparation() {
        // Way A runs west-east through (0,0)-(0,0.002). Way B runs south-north
        // through (-0.001,0.001)-(0.001,0.001), crossing A's midpoint visually
        // but using its OWN nodes (5,6) — no shared node id.
        let graph = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            nodeJSON(2, 0.0, 0.002),
            nodeJSON(5, -0.001, 0.001),
            nodeJSON(6, 0.001, 0.001),
            wayElementJSON(100, nodes: [1, 2], tags: ["highway": "primary"]),
            wayElementJSON(101, nodes: [5, 6], tags: ["highway": "primary"])
        )
        // 4 distinct graph nodes, none an intersection (no shared node).
        #expect(graph.nodes.count == 4)
        #expect(graph.nodes.allSatisfy { !$0.isIntersection })
        // No edge bridges way A's nodes to way B's nodes.
        let aNodes: Set<NodeIndex> = [graph.osmToIndex[1]!, graph.osmToIndex[2]!]
        let bNodes: Set<NodeIndex> = [graph.osmToIndex[5]!, graph.osmToIndex[6]!]
        for edge in graph.edges {
            let crossesPlanes = (aNodes.contains(edge.from) && bNodes.contains(edge.to))
                || (bNodes.contains(edge.from) && aNodes.contains(edge.to))
            #expect(!crossesPlanes)
        }
    }

    /// A four-way intersection: a node shared by two crossing ways splits both.
    @Test("Shared center node splits both ways into four edges each direction")
    func fourWayIntersection() {
        // Way A: 1-3-2 (west-center-east). Way B: 4-3-5 (south-center-north).
        // Node 3 is the shared center.
        let graph = buildGraph(
            nodeJSON(1, 0.0, -0.001),
            nodeJSON(2, 0.0, 0.001),
            nodeJSON(3, 0.0, 0.0),
            nodeJSON(4, -0.001, 0.0),
            nodeJSON(5, 0.001, 0.0),
            wayElementJSON(100, nodes: [1, 3, 2], tags: ["highway": "primary"]),
            wayElementJSON(101, nodes: [4, 3, 5], tags: ["highway": "primary"])
        )
        // 5 graph nodes. Center node 3 has 4 outgoing edges (to 1,2,4,5).
        #expect(graph.nodes.count == 5)
        let center = Int(graph.osmToIndex[3]!)
        #expect(graph.nodes[center].isIntersection)
        #expect(graph.nodes[center].edgeCount == 4)
        // Each of the 4 spokes is bidirectional → 8 edges total.
        #expect(graph.edges.count == 8)
    }
}

// MARK: - Direction

@Suite("RoadGraphBuilder.direction")
struct RoadGraphBuilderDirectionTests {

    @Test("oneway=yes yields a single forward edge")
    func onewayYes() {
        let graph = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            nodeJSON(2, 0.0, 0.001),
            wayElementJSON(100, nodes: [1, 2], tags: ["highway": "primary", "oneway": "yes"])
        )
        #expect(graph.edges.count == 1)
        #expect(graph.edges[0].from == graph.osmToIndex[1])
        #expect(graph.edges[0].to == graph.osmToIndex[2])
        #expect(graph.edges[0].attrs.contains(.oneway))
    }

    @Test("oneway=-1 yields a single reverse edge")
    func onewayReverse() {
        let graph = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            nodeJSON(2, 0.0, 0.001),
            wayElementJSON(100, nodes: [1, 2], tags: ["highway": "primary", "oneway": "-1"])
        )
        #expect(graph.edges.count == 1)
        #expect(graph.edges[0].from == graph.osmToIndex[2])
        #expect(graph.edges[0].to == graph.osmToIndex[1])
    }

    @Test("junction=roundabout implies oneway even without oneway tag")
    func roundaboutImpliesOneway() {
        // A 3-node roundabout segment 1-2-3 (2 interior). Without explicit
        // oneway, the roundabout tag forces forward-only.
        let graph = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            nodeJSON(2, 0.0005, 0.0005),
            nodeJSON(3, 0.0, 0.001),
            wayElementJSON(100, nodes: [1, 2, 3], tags: ["highway": "primary", "junction": "roundabout"])
        )
        #expect(graph.edges.count == 1) // forward only
        #expect(graph.edges[0].attrs.contains(.roundabout))
        #expect(graph.edges[0].attrs.contains(.oneway))
    }

    @Test("highway=motorway implies oneway by OSM default")
    func motorwayImpliesOneway() {
        let graph = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            nodeJSON(2, 0.0, 0.001),
            wayElementJSON(100, nodes: [1, 2], tags: ["highway": "motorway"])
        )
        #expect(graph.edges.count == 1)
        #expect(graph.edges[0].attrs.contains(.isMotorway))
        #expect(graph.edges[0].attrs.contains(.oneway))
    }

    @Test("Reverse edge geometry is the forward geometry reversed")
    func reverseGeometryMirrored() {
        let graph = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            nodeJSON(2, 0.0, 0.001),
            nodeJSON(3, 0.0, 0.002),
            wayElementJSON(100, nodes: [1, 2, 3], tags: ["highway": "residential"])
        )
        // Both endpoints 1 and 3 are graph nodes; 2 is geometry.
        let fwd = graph.edges.first { $0.from == graph.osmToIndex[1] }!
        let rev = graph.edges.first { $0.from == graph.osmToIndex[3] }!
        let fwdCoords = Array(graph.geometry(of: EdgeIndex(graph.edges.firstIndex { $0.from == fwd.from && $0.to == fwd.to }!)))
        let revCoords = Array(graph.geometry(of: EdgeIndex(graph.edges.firstIndex { $0.from == rev.from && $0.to == rev.to }!)))
        #expect(fwdCoords.count == revCoords.count)
        #expect(fwdCoords.first!.longitude == revCoords.last!.longitude)
        #expect(fwdCoords.last!.longitude == revCoords.first!.longitude)
    }
}

// MARK: - Attributes, speed, length

@Suite("RoadGraphBuilder.attributes")
struct RoadGraphBuilderAttributeTests {

    @Test("Edge length matches RouteGeometry.cumulativeDistances")
    func edgeLength() {
        let graph = buildGraph(
            nodeJSON(1, 33.0, -117.0),
            nodeJSON(2, 33.001, -117.0),
            wayElementJSON(100, nodes: [1, 2], tags: ["highway": "residential"])
        )
        let coords = [
            CLLocationCoordinate2D(latitude: 33.0, longitude: -117.0),
            CLLocationCoordinate2D(latitude: 33.001, longitude: -117.0)
        ]
        let expected = RouteGeometry.cumulativeDistances(coords).last!
        #expect(abs(Double(graph.edges[0].lengthMeters) - expected) < 0.5)
    }

    @Test("Free-flow speed uses parsed maxspeed in m/s")
    func freeFlowSpeed() {
        let graph = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            nodeJSON(2, 0.0, 0.001),
            wayElementJSON(100, nodes: [1, 2], tags: ["highway": "residential", "maxspeed": "30 mph"])
        )
        // 30 mph * 0.44704 = 13.41 m/s
        #expect(abs(Double(graph.edges[0].freeFlowSpeedMPS) - 13.4112) < 0.01)
    }

    @Test("Free-flow speed falls back to class default when maxspeed missing")
    func freeFlowDefault() {
        let graph = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            nodeJSON(2, 0.0, 0.001),
            wayElementJSON(100, nodes: [1, 2], tags: ["highway": "motorway"])
        )
        // motorway default 65 mph * 0.44704 = 29.06 m/s
        #expect(abs(Double(graph.edges[0].freeFlowSpeedMPS) - 29.0576) < 0.05)
    }

    @Test("tunnel/bridge/toll flags set from way tags")
    func physicalFlags() {
        let graph = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            nodeJSON(2, 0.0, 0.001),
            wayElementJSON(100, nodes: [1, 2], tags: ["highway": "primary", "tunnel": "yes", "bridge": "yes", "toll": "yes"])
        )
        let attrs = graph.edges[0].attrs
        #expect(attrs.contains(.tunnel))
        #expect(attrs.contains(.bridge))
        #expect(attrs.contains(.toll))
    }

    @Test("access=private sets privateAccess flag, destination sets destinationOnly")
    func accessFlags() {
        let priv = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            nodeJSON(2, 0.0, 0.001),
            wayElementJSON(100, nodes: [1, 2], tags: ["highway": "service", "access": "private"])
        )
        #expect(priv.edges[0].attrs.contains(.privateAccess))
        #expect(priv.edges[0].attrs.contains(.isService))

        let dest = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            nodeJSON(2, 0.0, 0.001),
            wayElementJSON(100, nodes: [1, 2], tags: ["highway": "service", "access": "destination"])
        )
        #expect(dest.edges[0].attrs.contains(.destinationOnly))
    }

    @Test("Non-drivable highway classes are dropped")
    func nonDrivableDropped() {
        let graph = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            nodeJSON(2, 0.0, 0.001),
            wayElementJSON(100, nodes: [1, 2], tags: ["highway": "footway"]),
            wayElementJSON(101, nodes: [1, 2], tags: ["highway": "cycleway"])
        )
        #expect(graph.nodes.isEmpty)
        #expect(graph.edges.isEmpty)
    }

    @Test("traffic_signals and stop tagged on node are captured")
    func nodeSignalTags() {
        let graph = buildGraph(
            nodeJSON(1, 0.0, 0.0, tags: ["highway": "traffic_signals"]),
            nodeJSON(2, 0.0, 0.001, tags: ["highway": "stop"]),
            nodeJSON(3, 0.0, 0.002),
            wayElementJSON(100, nodes: [1, 3], tags: ["highway": "primary"]),
            wayElementJSON(101, nodes: [2, 3], tags: ["highway": "primary"])
        )
        #expect(graph.nodes[Int(graph.osmToIndex[1]!)].hasTrafficSignal)
        #expect(graph.nodes[Int(graph.osmToIndex[2]!)].hasStopSign)
    }

    @Test("graphMaxSpeedMPS is the max free-flow speed across edges")
    func maxSpeed() {
        let graph = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            nodeJSON(2, 0.0, 0.001),
            nodeJSON(3, 0.0, 0.002),
            wayElementJSON(100, nodes: [1, 2], tags: ["highway": "residential", "maxspeed": "25 mph"]),
            wayElementJSON(101, nodes: [2, 3], tags: ["highway": "motorway", "maxspeed": "65 mph"])
        )
        #expect(abs(Double(graph.graphMaxSpeedMPS) - 29.0576) < 0.05)
    }
}

// MARK: - CSR adjacency

@Suite("RoadGraphBuilder.CSR")
struct RoadGraphBuilderCSRTests {

    @Test("CSR out-edge ranges are contiguous and correctly sized")
    func csrAdjacency() {
        // Star: center node 1 connected to 2, 3, 4 via three two-node ways.
        let graph = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            nodeJSON(2, 0.0, 0.001),
            nodeJSON(3, 0.001, 0.0),
            nodeJSON(4, -0.001, 0.0),
            wayElementJSON(100, nodes: [1, 2], tags: ["highway": "residential"]),
            wayElementJSON(101, nodes: [1, 3], tags: ["highway": "residential"]),
            wayElementJSON(102, nodes: [1, 4], tags: ["highway": "residential"])
        )
        let center = graph.osmToIndex[1]!
        let range = graph.outEdgeRange(of: center)
        #expect(range.count == 3)
        // Every edge in the range originates at the center node.
        for e in range {
            #expect(graph.edges[Int(e)].from == center)
        }
        // Total edges = 3 ways * 2 directions = 6.
        #expect(graph.edges.count == 6)
        // Sum of edgeCount across nodes equals total edges (CSR invariant).
        let totalDegree = graph.nodes.reduce(0) { $0 + Int($1.edgeCount) }
        #expect(totalDegree == graph.edges.count)
    }

    @Test("Every node's out-edges all share that node as `from`")
    func csrFromConsistency() {
        let graph = buildGraph(
            nodeJSON(1, 0.0, -0.001),
            nodeJSON(2, 0.0, 0.001),
            nodeJSON(3, 0.0, 0.0),
            nodeJSON(4, -0.001, 0.0),
            nodeJSON(5, 0.001, 0.0),
            wayElementJSON(100, nodes: [1, 3, 2], tags: ["highway": "primary"]),
            wayElementJSON(101, nodes: [4, 3, 5], tags: ["highway": "primary"])
        )
        for index in graph.nodes.indices {
            for e in graph.outEdgeRange(of: NodeIndex(index)) {
                #expect(graph.edges[Int(e)].from == NodeIndex(index))
            }
        }
    }
}

// MARK: - Lookup

@Suite("RoadGraph.snap")
struct RoadGraphSnapTests {

    @Test("Snap finds the nearest edge and a fractional position")
    func snapNearest() {
        let graph = buildGraph(
            nodeJSON(1, 33.0, -117.0),
            nodeJSON(2, 33.0, -116.999),
            wayElementJSON(100, nodes: [1, 2], tags: ["highway": "residential"])
        )
        // A point ~10m north of the midpoint of the edge.
        let mid = CLLocationCoordinate2D(latitude: 33.00009, longitude: -116.9995)
        let snap = graph.snap(mid)
        #expect(snap != nil)
        #expect(snap!.distanceMeters < 20)
        #expect(snap!.fraction > 0.3 && snap!.fraction < 0.7)
    }

    @Test("Snap returns nil when nothing is within range")
    func snapMiss() {
        let graph = buildGraph(
            nodeJSON(1, 33.0, -117.0),
            nodeJSON(2, 33.0, -116.999),
            wayElementJSON(100, nodes: [1, 2], tags: ["highway": "residential"])
        )
        let faraway = CLLocationCoordinate2D(latitude: 40.0, longitude: -100.0)
        #expect(graph.snap(faraway, maxDistanceMeters: 50) == nil)
    }
}

// MARK: - Empty / degenerate

@Suite("RoadGraphBuilder.degenerate")
struct RoadGraphBuilderDegenerateTests {

    @Test("Empty response yields an empty graph")
    func empty() {
        let graph = RoadGraphBuilder.buildGraph(from: decodeResponse())
        #expect(graph.nodes.isEmpty)
        #expect(graph.edges.isEmpty)
        #expect(graph.geometry.isEmpty)
        #expect(graph.graphMaxSpeedMPS == 0)
    }

    @Test("Way referencing a missing node is dropped if fewer than 2 nodes remain")
    func missingNode() {
        // Way references node 99 which has no coordinate element.
        let graph = buildGraph(
            nodeJSON(1, 0.0, 0.0),
            wayElementJSON(100, nodes: [1, 99], tags: ["highway": "residential"])
        )
        #expect(graph.edges.isEmpty)
    }
}
