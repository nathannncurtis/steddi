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

/// Minimal little-endian cursor for locating a field's byte offset in a
/// serialized blob from the test (the serializer's own reader is private). Only
/// the few operations the CSR-tamper test needs: skip fixed bytes, read a U32,
/// and skip a LEB128 varint (one continuation-bit walk).
private struct ByteReaderProbe {
    private let data: Data
    private(set) var offset: Int
    init(_ data: Data) { self.data = data; self.offset = 0 }
    mutating func skip(_ n: Int) { offset += n }
    mutating func readU32LE() -> Int {
        var v = 0
        for i in 0..<4 { v |= Int(data[data.startIndex + offset + i]) << (8 * i) }
        offset += 4
        return v
    }
    mutating func skipVarint() {
        while data[data.startIndex + offset] & 0x80 != 0 { offset += 1 }
        offset += 1   // the terminating byte (high bit clear)
    }
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

    @Test("Round-trip preserves lengthMeters at full Double precision")
    func roundTripLengthMetersDoublePrecision() throws {
        let graph = buildSampleGraph()
        let restored = try #require(RoadGraphSerializer.deserialize(RoadGraphSerializer.serialize(graph)))
        // lengthMeters is serialized as F64 now; the value survives bit-exact,
        // including the sub-meter precision a Float field/serialization would have
        // truncated (the truncation is what let snap fractions overflow past 1.0).
        for (original, copy) in zip(graph.edges, restored.edges) {
            #expect(original.lengthMeters == copy.lengthMeters)
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

    /// Coordinates that produce large negative→positive delta swings (e.g. an
    /// antimeridian-adjacent corridor and southern hemisphere) must survive the
    /// zig-zag varint delta round-trip without sign or truncation error.
    @Test("Large-magnitude and sign-flipping coordinates round-trip exactly")
    func roundTripExtremeCoords() throws {
        let elements = [
            nodeJSON(1, -41.288889, 174.777222),    // Wellington, near +180
            nodeJSON(2, -41.290000, 179.999000),     // just shy of the antimeridian
            nodeJSON(3, -41.291000, -179.999000),    // just past it (sign flip)
            wayElementJSON(100, nodes: [1, 2, 3], tags: ["highway": "primary", "maxspeed": "50"])
        ]
        let json = #"{"version":0.6,"elements":[\#(elements.joined(separator: ","))]}"#
        let response = try JSONDecoder().decode(OverpassGraphResponse.self, from: Data(json.utf8))
        let graph = RoadGraphBuilder.buildGraph(from: response)
        let restored = try #require(RoadGraphSerializer.deserialize(RoadGraphSerializer.serialize(graph)))
        #expect(restored.geometry.count == graph.geometry.count)
        for (original, copy) in zip(graph.geometry, restored.geometry) {
            #expect(coordsEqual(original, copy, tolerance: 1e-6))
        }
        for (original, copy) in zip(graph.nodes, restored.nodes) {
            #expect(coordsEqual(original.coordinate, copy.coordinate, tolerance: 1e-6))
        }
    }

    /// A blob that is byte-for-byte valid header + truncated mid-geometry-varint
    /// must fail cleanly to nil rather than crash on the varint reader's shift
    /// overrun guard.
    @Test("Truncation mid-geometry returns nil, never crashes")
    func truncatedMidGeometry() {
        let data = RoadGraphSerializer.serialize(buildSampleGraph())
        // Keep magic+version+geomCount (4+1+4=9 bytes) but cut the geometry stream.
        let chopped = data.prefix(11)
        #expect(RoadGraphSerializer.deserialize(Data(chopped)) == nil)
    }

    /// A blob with a valid magic+version header but a wildly oversized geometry
    /// count (the partial-write / bit-rot corruption mode) must fail cleanly to
    /// nil rather than try to reserveCapacity tens of GB and abort the process.
    @Test("Corrupt oversized geometry count returns nil, never OOM-crashes")
    func corruptOversizedGeomCount() {
        // magic "SRG1" + version 3 + geomCount = 0xFFFFFFFF (≈4.29e9), then
        // nothing — far more than the remaining 0 bytes could ever hold.
        var bytes: [UInt8] = [0x53, 0x52, 0x47, 0x31]      // magic
        bytes.append(RoadGraphSerializer.formatVersion)     // version
        bytes.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // geomCount (little-endian)
        #expect(RoadGraphSerializer.deserialize(Data(bytes)) == nil)
    }

    /// A corrupt oversized node count (header + valid empty geometry, then a
    /// huge nodeCount) must likewise fail cleanly rather than over-reserve.
    @Test("Corrupt oversized node count returns nil, never OOM-crashes")
    func corruptOversizedNodeCount() {
        var bytes: [UInt8] = [0x53, 0x52, 0x47, 0x31]      // magic
        bytes.append(RoadGraphSerializer.formatVersion)     // version
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // geomCount = 0 (none to read)
        bytes.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // nodeCount = 0xFFFFFFFF
        #expect(RoadGraphSerializer.deserialize(Data(bytes)) == nil)
    }

    /// A corrupt oversized edge count (header + empty geometry + empty nodes,
    /// then a huge edgeCount) must fail cleanly rather than over-reserve.
    @Test("Corrupt oversized edge count returns nil, never OOM-crashes")
    func corruptOversizedEdgeCount() {
        var bytes: [UInt8] = [0x53, 0x52, 0x47, 0x31]      // magic
        bytes.append(RoadGraphSerializer.formatVersion)     // version
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // geomCount = 0
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // nodeCount = 0
        bytes.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // edgeCount = 0xFFFFFFFF
        #expect(RoadGraphSerializer.deserialize(Data(bytes)) == nil)
    }

    /// The guard must not over-reject: a count that fits the remaining bytes
    /// still deserializes. The round-trip suite already proves the happy path,
    /// but assert the boundary explicitly so a too-tight bound is caught.
    @Test("A legitimate full-size blob still deserializes after the count guard")
    func legitimateBlobStillDeserializes() {
        let graph = buildSampleGraph()
        let data = RoadGraphSerializer.serialize(graph)
        #expect(RoadGraphSerializer.deserialize(data) != nil)
    }

    // MARK: - CSR adjacency-consistency revalidation

    /// Byte offset of node `index`'s `firstEdge` field within the serialized blob.
    /// Layout: 4 magic + 1 version, then geomCount(4) + geometry varints, then
    /// nodeCount(4) + nodes. Each node record is a fixed 25 bytes; within it the
    /// fields are osmID(8) + lat(4) + lon(4) + firstEdge(4) + edgeCount(4) +
    /// flags(1), so `firstEdge` sits 16 bytes into the record.
    private func firstEdgeFieldOffset(in data: Data, nodeIndex: Int) -> Int {
        var reader = ByteReaderProbe(data)
        reader.skip(5)                          // magic + version
        let geomCount = reader.readU32LE()
        for _ in 0..<geomCount {                // two signed varints per coord
            reader.skipVarint()
            reader.skipVarint()
        }
        reader.skip(4)                          // nodeCount
        let nodesStart = reader.offset
        return nodesStart + nodeIndex * 25 + 16 // firstEdge field within the record
    }

    private func writeI32LE(_ data: inout Data, at offset: Int, _ value: Int32) {
        let bits = UInt32(bitPattern: value)
        for i in 0..<4 {
            data[data.startIndex + offset + i] = UInt8((bits >> (8 * UInt32(i))) & 0xff)
        }
    }

    /// Byte offset of edge `index`'s geometry-range fields within the serialized
    /// blob. Layout after the node section: edgeCount(4) + edges. Each edge record
    /// is a fixed 40 bytes: from(4) + to(4) + lower(4) + upper(4) + length(8) +
    /// speed(4) + wayID(8) + class(1) + attrs(2) + oncoming(1). So `lower` sits 8
    /// bytes into the record and `upper` 12 bytes in.
    private func edgeGeometryRangeOffsets(in data: Data, nodeCount: Int, edgeIndex: Int) -> (lower: Int, upper: Int) {
        var reader = ByteReaderProbe(data)
        reader.skip(5)                          // magic + version
        let geomCount = reader.readU32LE()
        for _ in 0..<geomCount {                // two signed varints per coord
            reader.skipVarint()
            reader.skipVarint()
        }
        reader.skip(4)                          // nodeCount
        reader.skip(nodeCount * 25)             // node records (fixed 25 bytes each)
        reader.skip(4)                          // edgeCount
        let edgesStart = reader.offset
        let recordStart = edgesStart + edgeIndex * 40
        return (lower: recordStart + 8, upper: recordStart + 12)
    }

    /// A blob whose edge geometry range is IN BOUNDS but DEGENERATE
    /// (`upper == lower`, i.e. zero coords — or a single coord) must be rejected.
    /// The builder always emits a slice with both endpoints (`geometryRange.count
    /// >= 2`, RoadGraph.swift:83); a corrupt/bit-rotted blob that collapses one
    /// edge's range slips a <2-coord slice into `graph.geometry(of:)`, which
    /// `StepSynthesizer.stitchedPolyline` would silently drop — teleporting the
    /// drawn route across the missing step while A* already charged its cost. The
    /// loader must reject it so the corrupt blob never enters the search.
    @Test("Degenerate (zero-coord) edge geometry range is rejected on load")
    func degenerateEdgeGeometryRejected() throws {
        let graph = buildSampleGraph()
        #expect(graph.edges.count > 0)
        let nodeCount = graph.nodes.count

        var data = RoadGraphSerializer.serialize(graph)
        // Sanity: the untampered blob deserializes (valid round-trip).
        #expect(RoadGraphSerializer.deserialize(data) != nil)

        // Collapse edge 0's range to empty by writing `upper = lower`. This stays
        // in-bounds (lower is a valid geometry index) so only the new geometry-
        // length check — not the existing bounds check — can reject it.
        let offsets = edgeGeometryRangeOffsets(in: data, nodeCount: nodeCount, edgeIndex: 0)
        var probe = ByteReaderProbe(data)
        probe.skip(offsets.lower)
        let lower = Int32(probe.readU32LE())
        writeI32LE(&data, at: offsets.upper, lower)   // upper := lower -> empty range

        #expect(RoadGraphSerializer.deserialize(data) == nil)
    }

    /// A blob whose CSR offsets stay IN BOUNDS but no longer describe a real CSR
    /// layout (a node's `firstEdge` shifted off the running offset) must be
    /// rejected — otherwise the forward expansion in A* would trust the window
    /// blindly and stitch a disconnected/teleporting route presented as valid
    /// instead of falling back to MapKit. The valid blob round-trips (proven by
    /// the round-trip suite); this asserts the inconsistent twin returns nil.
    @Test("Inconsistent (but in-bounds) CSR node offset is rejected")
    func inconsistentCSROffsetRejected() throws {
        let graph = buildSampleGraph()
        let totalEdges = Int32(graph.edges.count)
        #expect(totalEdges > 1)

        // Find a node with a non-empty out-edge window — its `firstEdge` carries a
        // real CSR offset we can shift to break tiling while staying in bounds.
        guard let nodeIndex = graph.nodes.firstIndex(where: { $0.edgeCount > 0 }) else {
            Issue.record("sample graph has no node with out-edges")
            return
        }
        let node = graph.nodes[nodeIndex]
        // Pick an in-bounds target offset that differs from the true one and keeps
        // `firstEdge + edgeCount <= totalEdges` (so the EXISTING per-node bounds
        // check still passes and only the new consistency check can reject it).
        let trueFirst = node.firstEdge
        let maxStart = totalEdges - node.edgeCount        // largest in-bounds start
        let tamperedFirst: Int32 = trueFirst == maxStart ? max(0, maxStart - 1) : trueFirst + 1
        #expect(tamperedFirst != trueFirst)
        #expect(tamperedFirst >= 0 && tamperedFirst + node.edgeCount <= totalEdges)

        var data = RoadGraphSerializer.serialize(graph)
        // Sanity: the untampered blob deserializes (valid round-trip).
        #expect(RoadGraphSerializer.deserialize(data) != nil)

        let offset = firstEdgeFieldOffset(in: data, nodeIndex: nodeIndex)
        writeI32LE(&data, at: offset, tamperedFirst)

        // In-bounds but CSR-inconsistent → rejected so the loader falls back.
        #expect(RoadGraphSerializer.deserialize(data) == nil)
    }

    @Test("Binary blob is materially smaller than JSON would be")
    func compact() {
        let graph = buildSampleGraph()
        let binary = RoadGraphSerializer.serialize(graph)
        // Sanity: the blob is non-trivial but compact for a few-edge graph.
        #expect(binary.count > 0)
        #expect(binary.count < 2000)
    }

    // MARK: - Heuristic-admissibility (graphMaxSpeedMPS) revalidation

    /// Little-endian F32 bit pattern for the trailing `graphMaxSpeedMPS` field,
    /// which `serialize` writes as the very last 4 bytes of the blob.
    private func overwriteTrailingMaxSpeed(_ data: Data, with value: Float) -> Data {
        var out = data
        let bits = value.bitPattern
        let end = out.endIndex
        for i in 0..<4 {
            out[end - 4 + i] = UInt8((bits >> (8 * UInt32(i))) & 0xff)
        }
        return out
    }

    /// The A* heuristic is `h = haversine / graphMaxSpeedMPS`; it stays admissible
    /// (a true lower bound) only while `graphMaxSpeedMPS` >= every edge's
    /// `freeFlowSpeedMPS`. A corrupt/stale blob whose stored maxSpeed is BELOW
    /// some edge's speed would make `h` overestimate and break A* optimality. The
    /// loader must re-derive the floor from the edges and clamp the stored value
    /// up to it, so the heuristic can never become inadmissible regardless of
    /// what the blob claims.
    @Test("A stored maxSpeed below an edge's speed is corrected on load (heuristic stays admissible)")
    func belowFloorMaxSpeedIsClampedUp() throws {
        let graph = buildSampleGraph()
        let trueMax = graph.edges.reduce(Float(0)) { max($0, $1.freeFlowSpeedMPS) }
        #expect(trueMax > 0)

        // Tamper the trailing maxSpeed to a positive-but-too-LOW value (half the
        // slowest plausible edge speed) — the inadmissible direction.
        let tampered = overwriteTrailingMaxSpeed(
            RoadGraphSerializer.serialize(graph),
            with: trueMax / 2
        )
        let restored = try #require(RoadGraphSerializer.deserialize(tampered))

        // Corrected up to (at least) the true max edge speed, so for EVERY edge
        // `graphMaxSpeedMPS >= freeFlowSpeedMPS` and `h` is a true lower bound.
        #expect(restored.graphMaxSpeedMPS >= trueMax)
        for edge in restored.edges {
            #expect(restored.graphMaxSpeedMPS >= edge.freeFlowSpeedMPS)
        }
    }

    /// A non-finite (NaN/∞) stored maxSpeed — another corruption mode — must not
    /// propagate into the heuristic denominator; it is replaced by the derived
    /// finite floor so `h` stays a finite, admissible lower bound.
    @Test("A non-finite stored maxSpeed is replaced by the derived edge max")
    func nonFiniteMaxSpeedIsReplaced() throws {
        let graph = buildSampleGraph()
        let trueMax = graph.edges.reduce(Float(0)) { max($0, $1.freeFlowSpeedMPS) }

        let tampered = overwriteTrailingMaxSpeed(
            RoadGraphSerializer.serialize(graph),
            with: .nan
        )
        let restored = try #require(RoadGraphSerializer.deserialize(tampered))
        #expect(restored.graphMaxSpeedMPS.isFinite)
        #expect(restored.graphMaxSpeedMPS >= trueMax)
    }

    /// A stored maxSpeed already ABOVE every edge speed is admissible (only weak),
    /// so the loader must keep it untouched rather than needlessly lowering it.
    @Test("A stored maxSpeed at or above the edge max is preserved unchanged")
    func aboveFloorMaxSpeedIsPreserved() throws {
        let graph = buildSampleGraph()
        let trueMax = graph.edges.reduce(Float(0)) { max($0, $1.freeFlowSpeedMPS) }
        let inflated = trueMax + 100

        let tampered = overwriteTrailingMaxSpeed(
            RoadGraphSerializer.serialize(graph),
            with: inflated
        )
        let restored = try #require(RoadGraphSerializer.deserialize(tampered))
        #expect(abs(restored.graphMaxSpeedMPS - inflated) < 0.001)
    }
}
