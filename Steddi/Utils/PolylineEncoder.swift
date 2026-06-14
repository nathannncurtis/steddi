import Foundation
import CoreLocation

/// Encodes and decodes Google-style encoded polylines.
/// Used for storing route geometry compactly in SwiftData.
enum PolylineEncoder {

    /// Encode coordinates to a polyline string.
    static func encode(_ coordinates: [CLLocationCoordinate2D], precision: Int = 6) -> String {
        let factor = pow(10.0, Double(precision))
        var output = ""
        var prevLat = 0
        var prevLng = 0

        for coord in coordinates {
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
    static func decode(_ encoded: String, precision: Int = 6) -> [CLLocationCoordinate2D] {
        let factor = pow(10.0, Double(precision))
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var lat = 0
        var lng = 0

        while index < encoded.endIndex {
            lat += decodeValue(encoded, index: &index)
            guard index < encoded.endIndex else { break }
            lng += decodeValue(encoded, index: &index)

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

    private static func decodeValue(_ encoded: String, index: inout String.Index) -> Int {
        var result = 0
        var shift = 0

        while index < encoded.endIndex {
            guard let ascii = encoded[index].asciiValue else {
                break
            }
            let byte = Int(ascii) - 63
            index = encoded.index(after: index)
            result |= (byte & 0x1F) << shift
            shift += 5
            if byte < 0x20 { break }
        }

        return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
    }
}
