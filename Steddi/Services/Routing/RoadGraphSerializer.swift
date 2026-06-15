import Foundation
import CoreLocation

/// Versioned binary (de)serializer for `RoadGraph`. JSON-encoding the graph at
/// corridor scale is slow and huge (§3.8); instead we write the flat arrays
/// (`nodes`, `edges`, packed attrs/class, the geometry coord pool) with a
/// versioned header. Coordinates are stored as precision-6 `Int32` deltas
/// (PolylineEncoder proves precision-6 is enough), which both shrinks the blob
/// and keeps it endian-defined. Pure and fully unit-testable (round-trip).
enum RoadGraphSerializer {

    /// Bump when the on-disk layout changes; an older/newer byte makes
    /// `deserialize` return nil so the loader re-fetches rather than misreads.
    /// v3: `lengthMeters` widened from `Float` (4 bytes) to `Double` (8 bytes).
    static let formatVersion: UInt8 = 3

    /// 4-byte magic ("SRG1") so a truncated/foreign file is rejected fast.
    private static let magic: [UInt8] = [0x53, 0x52, 0x47, 0x31]

    /// Fixed-point factor for precision-6 coordinates.
    private static let coordFactor = 1_000_000.0

    /// Valid WGS-84 coordinate ranges.
    private static let latRange = -90.0...90.0
    private static let lonRange = -180.0...180.0

    /// Encode a latitude/longitude to a precision-6 fixed-point `Int32`.
    /// Out-of-range or non-finite inputs are clamped to the valid WGS-84 bounds
    /// before scaling so the multiply can never exceed `Int32` and silently wrap
    /// (the unchecked `Int32(_:)` cast would trap or wrap on overflow). The
    /// clamped magnitudes (±180e6) sit comfortably inside `Int32`.
    private static func encodeLat(_ lat: Double) -> Int32 {
        let clamped = min(max(lat.isFinite ? lat : 0, latRange.lowerBound), latRange.upperBound)
        return Int32((clamped * coordFactor).rounded())
    }

    private static func encodeLon(_ lon: Double) -> Int32 {
        let clamped = min(max(lon.isFinite ? lon : 0, lonRange.lowerBound), lonRange.upperBound)
        return Int32((clamped * coordFactor).rounded())
    }

    // MARK: - Serialize

    static func serialize(_ graph: RoadGraph) -> Data {
        var writer = ByteWriter()
        writer.writeBytes(magic)
        writer.writeU8(formatVersion)

        // --- Geometry pool (delta-encoded precision-6 ints) ---
        writer.writeU32(UInt32(graph.geometry.count))
        var prevLat: Int32 = 0
        var prevLon: Int32 = 0
        for coord in graph.geometry {
            let lat = encodeLat(coord.latitude)
            let lon = encodeLon(coord.longitude)
            writer.writeVarintSigned(Int64(lat) - Int64(prevLat))
            writer.writeVarintSigned(Int64(lon) - Int64(prevLon))
            prevLat = lat
            prevLon = lon
        }

        // --- Nodes ---
        writer.writeU32(UInt32(graph.nodes.count))
        for node in graph.nodes {
            writer.writeI64(node.osmID)
            writer.writeI32(encodeLat(node.coordinate.latitude))
            writer.writeI32(encodeLon(node.coordinate.longitude))
            writer.writeI32(node.firstEdge)
            writer.writeI32(node.edgeCount)
            var flags: UInt8 = 0
            if node.isIntersection { flags |= 1 << 0 }
            if node.hasTrafficSignal { flags |= 1 << 1 }
            if node.hasStopSign { flags |= 1 << 2 }
            writer.writeU8(flags)
        }

        // --- Edges ---
        writer.writeU32(UInt32(graph.edges.count))
        for edge in graph.edges {
            writer.writeI32(edge.from)
            writer.writeI32(edge.to)
            writer.writeI32(edge.geometryRange.lowerBound)
            writer.writeI32(edge.geometryRange.upperBound)
            writer.writeF64(edge.lengthMeters)
            writer.writeF32(edge.freeFlowSpeedMPS)
            writer.writeI64(edge.osmWayID)
            writer.writeU8(edge.roadClass.rawValue)
            writer.writeU16(edge.attrs.rawValue)
            writer.writeU8(edge.oncomingLanes)
        }

        // --- graphMaxSpeedMPS ---
        writer.writeF32(graph.graphMaxSpeedMPS)

        // `osmToIndex` and `snapIndex` are derived; rebuilt on deserialize.
        return writer.data
    }

    // MARK: - Deserialize

    static func deserialize(_ data: Data) -> RoadGraph? {
        var reader = ByteReader(data)
        guard let head = reader.readBytes(4), head == magic else { return nil }
        guard let version = reader.readU8(), version == formatVersion else { return nil }

        guard let geomCount = reader.readU32() else { return nil }
        // The count comes from an untrusted/possibly-corrupt blob; a wild value
        // (e.g. 0xFFFFFFFF) would make reserveCapacity request tens of GB and
        // abort the process BEFORE the per-element bounds-checked reads or the
        // structural validation could fail it cleanly into a MapKit re-fetch.
        // Bound each count against the bytes that remain, using each record's
        // MINIMUM encoded size, so the reservation can never exceed the file.
        // Geometry: 2 signed varints/coord, each >= 1 byte -> >= 2 bytes each.
        guard reader.canHold(count: geomCount, minBytesEach: 2) else { return nil }
        var geometry: [CLLocationCoordinate2D] = []
        geometry.reserveCapacity(Int(geomCount))
        var prevLat: Int32 = 0
        var prevLon: Int32 = 0
        for _ in 0..<geomCount {
            guard let dLat = reader.readVarintSigned(), let dLon = reader.readVarintSigned() else { return nil }
            prevLat = Int32(truncatingIfNeeded: Int64(prevLat) + dLat)
            prevLon = Int32(truncatingIfNeeded: Int64(prevLon) + dLon)
            let lat = Double(prevLat) / coordFactor
            let lon = Double(prevLon) / coordFactor
            // A corrupt/foreign blob can decode into out-of-range coordinates
            // (deltas wrap via truncatingIfNeeded); reject so the loader falls
            // back to MapKit rather than feeding bad geometry into snapping.
            guard latRange.contains(lat), lonRange.contains(lon) else { return nil }
            geometry.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }

        guard let nodeCount = reader.readU32() else { return nil }
        // Each node record is a fixed 25 bytes (osmID 8 + lat 4 + lon 4 +
        // firstEdge 4 + edgeCount 4 + flags 1).
        guard reader.canHold(count: nodeCount, minBytesEach: 25) else { return nil }
        var nodes: [GraphNode] = []
        nodes.reserveCapacity(Int(nodeCount))
        var osmToIndex: [OSMNodeID: NodeIndex] = [:]
        osmToIndex.reserveCapacity(Int(nodeCount))
        for index in 0..<nodeCount {
            guard let osmID = reader.readI64(),
                  let lat = reader.readI32(),
                  let lon = reader.readI32(),
                  let firstEdge = reader.readI32(),
                  let edgeCount = reader.readI32(),
                  let flags = reader.readU8() else { return nil }
            let nodeLat = Double(lat) / coordFactor
            let nodeLon = Double(lon) / coordFactor
            guard latRange.contains(nodeLat), lonRange.contains(nodeLon) else { return nil }
            osmToIndex[osmID] = NodeIndex(index)
            nodes.append(GraphNode(
                osmID: osmID,
                coordinate: CLLocationCoordinate2D(
                    latitude: nodeLat,
                    longitude: nodeLon
                ),
                firstEdge: firstEdge,
                edgeCount: edgeCount,
                isIntersection: flags & (1 << 0) != 0,
                hasTrafficSignal: flags & (1 << 1) != 0,
                hasStopSign: flags & (1 << 2) != 0
            ))
        }

        guard let edgeCount = reader.readU32() else { return nil }
        // Each edge record is a fixed 40 bytes (from 4 + to 4 + lower 4 +
        // upper 4 + length 8 + speed 4 + wayID 8 + class 1 + attrs 2 + oncoming 1).
        guard reader.canHold(count: edgeCount, minBytesEach: 40) else { return nil }
        var edges: [GraphEdge] = []
        edges.reserveCapacity(Int(edgeCount))
        for _ in 0..<edgeCount {
            guard let from = reader.readI32(),
                  let to = reader.readI32(),
                  let lower = reader.readI32(),
                  let upper = reader.readI32(),
                  let length = reader.readF64(),
                  let speed = reader.readF32(),
                  let wayID = reader.readI64(),
                  let classRaw = reader.readU8(),
                  let attrsRaw = reader.readU16(),
                  let oncoming = reader.readU8() else { return nil }
            edges.append(GraphEdge(
                from: from,
                to: to,
                geometryRange: lower..<upper,
                lengthMeters: length,
                freeFlowSpeedMPS: speed,
                osmWayID: wayID,
                roadClass: RoadClass(rawValue: classRaw) ?? .unknown,
                attrs: EdgeAttributes(rawValue: attrsRaw),
                oncomingLanes: oncoming
            ))
        }

        guard let maxSpeed = reader.readF32() else { return nil }

        // Structural validation: a corrupt or foreign blob can decode into a
        // well-formed `RoadGraph` value whose indices point out of bounds, which
        // would crash the search at the point of use. Reject such graphs here so
        // the loader falls back to MapKit rather than trusting bad data. Every
        // edge endpoint must index a node; every node's CSR window and every
        // edge's geometry slice must stay within their backing arrays.
        let totalNodes = nodes.count
        let totalEdges = edges.count
        let totalGeometry = geometry.count
        for node in nodes {
            let first = Int(node.firstEdge)
            let count = Int(node.edgeCount)
            guard count >= 0, first >= 0, first <= totalEdges, first + count <= totalEdges else { return nil }
        }
        for edge in edges {
            guard Int(edge.from) >= 0, Int(edge.from) < totalNodes,
                  Int(edge.to) >= 0, Int(edge.to) < totalNodes else { return nil }
            let lower = Int(edge.geometryRange.lowerBound)
            let upper = Int(edge.geometryRange.upperBound)
            guard lower >= 0, upper >= lower, upper <= totalGeometry else { return nil }
        }

        let snapIndex = RoadGraphBuilder.buildSnapIndex(edges: edges, geometry: geometry)
        return RoadGraph(
            nodes: nodes,
            edges: edges,
            geometry: geometry,
            osmToIndex: osmToIndex,
            snapIndex: snapIndex,
            graphMaxSpeedMPS: maxSpeed
        )
    }
}

// MARK: - Byte primitives (little-endian, varint zig-zag for deltas)

/// Minimal little-endian byte writer. Fixed-width ints for record fields;
/// zig-zag varints for geometry deltas (most deltas are tiny → 1-2 bytes).
private struct ByteWriter {
    private(set) var data = Data()

    mutating func writeBytes(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
    mutating func writeU8(_ v: UInt8) { data.append(v) }

    mutating func writeU16(_ v: UInt16) {
        data.append(UInt8(v & 0xff))
        data.append(UInt8((v >> 8) & 0xff))
    }

    mutating func writeU32(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((v >> shift) & 0xff)) }
    }

    mutating func writeI32(_ v: Int32) { writeU32(UInt32(bitPattern: v)) }

    mutating func writeI64(_ v: Int64) {
        let u = UInt64(bitPattern: v)
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8((u >> shift) & 0xff)) }
    }

    mutating func writeF32(_ v: Float) { writeU32(v.bitPattern) }

    mutating func writeF64(_ v: Double) {
        let u = v.bitPattern
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8((u >> shift) & 0xff)) }
    }

    /// Zig-zag + LEB128 varint for a signed delta.
    mutating func writeVarintSigned(_ v: Int64) {
        var zig = UInt64(bitPattern: (v << 1) ^ (v >> 63))
        while zig >= 0x80 {
            data.append(UInt8((zig & 0x7f) | 0x80))
            zig >>= 7
        }
        data.append(UInt8(zig))
    }
}

/// Companion reader. Every read is bounds-checked and returns nil on underrun
/// so a truncated/corrupt blob fails cleanly into a re-fetch.
private struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    private mutating func next() -> UInt8? {
        guard offset < data.endIndex else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    /// Bytes not yet consumed.
    private var remaining: Int { data.endIndex - offset }

    /// Whether `count` records of at least `minBytesEach` bytes could possibly
    /// fit in the bytes that remain. Guards `reserveCapacity` so a corrupt count
    /// can't trigger a multi-GB allocation; the per-element reads still enforce
    /// the exact layout afterward. `minBytesEach` is assumed >= 1.
    func canHold(count: UInt32, minBytesEach: Int) -> Bool {
        // UInt64 math so count * minBytesEach can never overflow Int.
        UInt64(count) * UInt64(minBytesEach) <= UInt64(remaining)
    }

    mutating func readBytes(_ count: Int) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let b = next() else { return nil }
            out.append(b)
        }
        return out
    }

    mutating func readU8() -> UInt8? { next() }

    mutating func readU16() -> UInt16? {
        guard let b0 = next(), let b1 = next() else { return nil }
        return UInt16(b0) | (UInt16(b1) << 8)
    }

    mutating func readU32() -> UInt32? {
        var v: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            guard let b = next() else { return nil }
            v |= UInt32(b) << shift
        }
        return v
    }

    mutating func readI32() -> Int32? { readU32().map { Int32(bitPattern: $0) } }

    mutating func readI64() -> Int64? {
        var v: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 8) {
            guard let b = next() else { return nil }
            v |= UInt64(b) << shift
        }
        return Int64(bitPattern: v)
    }

    mutating func readF32() -> Float? { readU32().map { Float(bitPattern: $0) } }

    mutating func readF64() -> Double? {
        var u: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 8) {
            guard let b = next() else { return nil }
            u |= UInt64(b) << shift
        }
        return Double(bitPattern: u)
    }

    mutating func readVarintSigned() -> Int64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard let b = next() else { return nil }
            result |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { break }
            shift += 7
            if shift >= 64 { return nil }
        }
        // un-zig-zag
        return Int64(bitPattern: (result >> 1) ^ (~(result & 1) &+ 1))
    }
}
