import Foundation
import CoreLocation

/// Encodes and decodes Google-style encoded polylines.
/// Used for storing route geometry compactly in SwiftData.
enum PolylineEncoder {

    /// Encode coordinates to a polyline string.
    ///
    /// A non-finite coordinate (NaN/±Inf, e.g. from a degenerate map-match
    /// projection, a divide-by-zero while stitching legs, or a corrupt persisted
    /// leg) would otherwise trap the `Int(round(...))` conversion below — `Int(_:)`
    /// of a NaN/infinite `Double` is a hard runtime trap in Swift, crashing the
    /// whole app at encode time. Such a point is silently skipped so the rest of
    /// the polyline still encodes (a recoverable, slightly-shortened line) rather
    /// than crashing — mirroring the defensive posture already taken on `decode`
    /// and in `RoadGraphSerializer`. The delta is taken against the previous
    /// *encoded* point, so dropping one coordinate keeps every surviving point
    /// correct.
    static func encode(_ coordinates: [CLLocationCoordinate2D], precision: Int = 6) -> String {
        let factor = pow(10.0, Double(precision))
        var output = ""
        var prevLat = 0
        var prevLng = 0

        for coord in coordinates {
            guard coord.latitude.isFinite, coord.longitude.isFinite else { continue }
            let lat = Int(round(coord.latitude * factor))
            let lng = Int(round(coord.longitude * factor))

            output += encodeValue(lat - prevLat)
            output += encodeValue(lng - prevLng)

            prevLat = lat
            prevLng = lng
        }

        return output
    }

    /// Decode a polyline string, returning nil if any decoded coordinate falls
    /// outside valid lat/lon bounds. The whole app encodes at precision 6; a
    /// string encoded at a different precision (e.g. 5) decoded here produces
    /// coordinates scaled ~10x off. A precision-6 line decoded at 5 lands well
    /// outside ±90/±180, so this catches that class of mismatch instead of
    /// silently mis-aligning corridor buffers / polygon tests. (A precision-5
    /// line decoded at 6 collapses toward 0 and can't be distinguished by bounds
    /// alone — but the app never emits precision-5 lines, so the asymmetric guard
    /// covers the realistic failure mode.)
    static func decodeValidated(_ encoded: String, precision: Int = 6) -> [CLLocationCoordinate2D]? {
        let coords = decode(encoded, precision: precision)
        guard coords.allSatisfy({ CLLocationCoordinate2DIsValid($0) }) else { return nil }
        return coords
    }

    /// Decode a polyline string to coordinates.
    ///
    /// Input can be network-sourced (OSRM/Overpass) or persisted geometry, so it
    /// may be malformed: a non-charset byte (>= 0x80 or otherwise outside the
    /// polyline alphabet) or a truncated continuation that never terminates.
    /// Such input is treated as a hard decode failure — the decode aborts and
    /// returns the coordinates accumulated so far rather than spinning the CPU
    /// or allocating without bound.
    static func decode(_ encoded: String, precision: Int = 6) -> [CLLocationCoordinate2D] {
        let factor = pow(10.0, Double(precision))
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var lat = 0
        var lng = 0

        while index < encoded.endIndex {
            let startOfPair = index
            guard let dLat = decodeValue(encoded, index: &index) else { break }
            lat += dLat
            guard index < encoded.endIndex else { break }
            guard let dLng = decodeValue(encoded, index: &index) else { break }
            lng += dLng
            // Any pair that consumed no input would loop forever — bail out.
            guard index > startOfPair else { break }

            coordinates.append(CLLocationCoordinate2D(
                latitude: Double(lat) / factor,
                longitude: Double(lng) / factor
            ))
        }

        return coordinates
    }

    // MARK: - Private

    private static func encodeValue(_ value: Int) -> String {
        var v = value < 0 ? ~(value << 1) : (value << 1)
        var encoded = ""

        while v >= 0x20 {
            encoded += String(UnicodeScalar((0x20 | (v & 0x1F)) + 63)!)
            v >>= 5
        }
        encoded += String(UnicodeScalar(v + 63)!)

        return encoded
    }

    /// Decode one zig-zag varint. Returns nil on malformed input — a non-ASCII /
    /// non-charset byte, or a continuation longer than a 32-bit value can hold
    /// (a truncated/garbled stream that never sets the terminating low bit).
    /// Always advances `index` past the offending byte so callers can never spin.
    private static func decodeValue(_ encoded: String, index: inout String.Index) -> Int? {
        var result = 0
        var shift = 0

        while index < encoded.endIndex {
            guard let ascii = encoded[index].asciiValue, ascii >= 63 else {
                // Non-charset byte: consume it so the caller makes progress, then fail.
                index = encoded.index(after: index)
                return nil
            }
            let byte = Int(ascii) - 63
            index = encoded.index(after: index)
            result |= (byte & 0x1F) << shift
            shift += 5
            if byte < 0x20 {
                return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
            }
            // No terminating byte within 32 bits — over-long continuation, bail.
            if shift >= 32 { return nil }
        }

        // Ran off the end without a terminating byte: truncated continuation.
        return nil
    }
}
