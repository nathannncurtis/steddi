import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - Serializer fixture helpers

private func nodeJSON(_ id: Int64, _ lat: Double, _ lon: Double, tags: [String: String] = [:]) -> String {
    let tagJSON = tags.map { #""\#($0.key)":"\#($0.value)""# }.joined(separator: ",")
    let tagPart = tags.isEmpty ? "" : #","tags":{\#(tagJSON)}"#
    return #"{"type":"node","id":\#(id),"lat":\#(lat),"lon":\#(lon)\#(tagPart)}"#
}

private func wayElementJSON(_ id: Int64, nodes: [Int64], tags: [String: String]) -> String {
    let nodeList = nodes.map(String.init).joined(separator: ",")
    let tagJSON = tags.map { #""\#($0.key)":"\#($0.value)""# }.joined(separator: ",")
    return #"{"type":"way","id":\#(id),"nodes":[\#(nodeList)],"tags":{\#(tagJSON)}}"#
}

private func buildSampleGraph() -> RoadGraph {
    let elements = [
        nodeJSON(1, 33.123456, -117.111111, tags: ["highway": "traffic_signals"]),
        nodeJSON(2, 33.124000, -117.110000),
        nodeJSON(3, 33.125000, -117.109000, tags: ["highway": "stop"]),
        nodeJSON(4, 33.126000, -117.108000),
        nodeJSON(5, 33.124500, -117.108500),
        wayElementJSON(100, nodes: [1, 2, 3], tags: ["highway": "primary", "maxspeed": "45 mph"]),
        wayElementJSON(101, nodes: [3, 4], tags: ["highway": "secondary", "oneway": "yes", "tunnel": "yes"]),
        wayElementJSON(102, nodes: [3, 5], tags: ["highway": "residential", "junction": "roundabout", "toll": "yes"])
    ]
    let json = #"{"version":0.6,"elements":[\#(elements.joined(separator: ","))]}"#
    let response = try! JSONDecoder().decode(OverpassGraphResponse.self, from: Data(json.utf8))
    return RoadGraphBuilder.buildGraph(from: response)
}

private func coordsEqual(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, tolerance: Double = 1e-6) -> Bool {
    abs(a.latitude - b.latitude) < tolerance && abs(a.longitude - b.longitude) < tolerance
}

// MARK: - Round-trip

@Suite("RoadGraphSerializer")
struct RoadGraphSerializerTests {

    @Test("Round-trip preserves node count, edge count, and geometry count")
    func roundTripCounts() {
        let graph = buildSampleGraph()
        let data = RoadGraphSerializer.serialize(graph)
        let restored = RoadGraphSerializer.deserialize(data)
        #expect(restored != nil)
        #expect(restored!.nodes.count == graph.nodes.count)
        #expect(restored!.edges.count == graph.edges.count)
        #expect(restored!.geometry.count == graph.geometry.count)
    }

    @Test("Round-trip preserves node fields")
    func roundTripNodes() throws {
        let graph = buildSampleGraph()
        let restored = try #require(RoadGraphSerializer.deserialize(RoadGraphSerializer.serialize(graph)))
        for (original, copy) in zip(graph.nodes, restored.nodes) {
            #expect(original.osmID == copy.osmID)
            #expect(coordsEqual(original.coordinate, copy.coordinate))
            #expect(original.firstEdge == copy.firstEdge)
            #expect(original.edgeCount == copy.edgeCount)
            #expect(original.isIntersection == copy.isIntersection)
            #expect(original.hasTrafficSignal == copy.hasTrafficSignal)
            #expect(original.hasStopSign == copy.hasStopSign)
        }
    }

    @Test("Round-trip preserves edge fields")
    func roundTripEdges() throws {
        let graph = buildSampleGraph()
        let restored = try #require(RoadGraphSerializer.deserialize(RoadGraphSerializer.serialize(graph)))
        for (original, copy) in zip(graph.edges, restored.edges) {
            #expect(original.from == copy.from)
            #expect(original.to == copy.to)
            #expect(original.geometryRange == copy.geometryRange)
            #expect(abs(original.lengthMeters - copy.lengthMeters) < 0.001)
            #expect(abs(original.freeFlowSpeedMPS - copy.freeFlowSpeedMPS) < 0.001)
            #expect(original.osmWayID == copy.osmWayID)
            #expect(original.roadClass == copy.roadClass)
            #expect(original.attrs == copy.attrs)
        }
    }

    @Test("Round-trip preserves geometry coordinates within precision-6")
    func roundTripGeometry() throws {
        let graph = buildSampleGraph()
        let restored = try #require(RoadGraphSerializer.deserialize(RoadGraphSerializer.serialize(graph)))
        for (original, copy) in zip(graph.geometry, restored.geometry) {
            // precision-6 → ~1e-6 degree rounding.
            #expect(coordsEqual(original, copy, tolerance: 1e-6))
        }
    }

    @Test("Round-trip preserves graphMaxSpeedMPS and rebuilds osmToIndex / snap")
    func roundTripDerived() throws {
        let graph = buildSampleGraph()
        let restored = try #require(RoadGraphSerializer.deserialize(RoadGraphSerializer.serialize(graph)))
        #expect(abs(restored.graphMaxSpeedMPS - graph.graphMaxSpeedMPS) < 0.001)
        // osmToIndex rebuilt to the same mapping.
        #expect(restored.osmToIndex == graph.osmToIndex)
        // Snap index works after restore: snapping near a known node returns a hit.
        let snap = restored.snap(graph.nodes[0].coordinate, maxDistanceMeters: 30)
        #expect(snap != nil)
    }

    @Test("Round-trip survives an attribute-heavy edge (oneway+tunnel+toll+roundabout)")
    func roundTripAttributes() throws {
        let graph = buildSampleGraph()
        let restored = try #require(RoadGraphSerializer.deserialize(RoadGraphSerializer.serialize(graph)))
        // The roundabout edge (way 102) must keep its packed flags exactly.
        let originalRoundabout = graph.edges.first { $0.attrs.contains(.roundabout) }
        let copyRoundabout = restored.edges.first { $0.attrs.contains(.roundabout) }
        #expect(originalRoundabout != nil)
        #expect(copyRoundabout != nil)
        #expect(originalRoundabout!.attrs == copyRoundabout!.attrs)
        #expect(copyRoundabout!.attrs.contains(.oneway))
        #expect(copyRoundabout!.attrs.contains(.toll))
    }

    // MARK: - Header / corruption guards

    @Test("Wrong magic is rejected")
    func wrongMagic() {
        let bad = Data([0x00, 0x01, 0x02, 0x03, 0x99])
        #expect(RoadGraphSerializer.deserialize(bad) == nil)
    }

    @Test("Wrong version is rejected")
    func wrongVersion() {
        var data = RoadGraphSerializer.serialize(buildSampleGraph())
        // Byte 4 is the version field (after the 4 magic bytes).
        data[data.startIndex + 4] = 0xFE
        #expect(RoadGraphSerializer.deserialize(data) == nil)
    }

    @Test("Truncated blob returns nil rather than crashing")
    func truncated() {
        let data = RoadGraphSerializer.serialize(buildSampleGraph())
        let half = data.prefix(data.count / 2)
        #expect(RoadGraphSerializer.deserialize(Data(half)) == nil)
    }

    @Test("Empty graph round-trips")
    func emptyGraph() throws {
        let empty = RoadGraph(
            nodes: [], edges: [], geometry: [],
            osmToIndex: [:],
            snapIndex: GraphSpatialIndex(grid: [:]),
            graphMaxSpeedMPS: 0
        )
        let restored = try #require(RoadGraphSerializer.deserialize(RoadGraphSerializer.serialize(empty)))
        #expect(restored.nodes.isEmpty)
        #expect(restored.edges.isEmpty)
        #expect(restored.geometry.isEmpty)
    }

    @Test("Binary blob is materially smaller than JSON would be")
    func compact() {
        let graph = buildSampleGraph()
        let binary = RoadGraphSerializer.serialize(graph)
        // Sanity: the blob is non-trivial but compact for a few-edge graph.
        #expect(binary.count > 0)
        #expect(binary.count < 2000)
    }
}
