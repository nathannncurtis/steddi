import Testing
import CoreLocation
@testable import Steddi

@Suite("PolylineEncoder")
struct PolylineEncoderTests {

    @Test("Encode then decode round-trips")
    func roundTrip() {
        let coords = [
            CLLocationCoordinate2D(latitude: 38.5, longitude: -120.2),
            CLLocationCoordinate2D(latitude: 40.7, longitude: -120.95),
            CLLocationCoordinate2D(latitude: 43.252, longitude: -126.453),
        ]

        let encoded = PolylineEncoder.encode(coords)
        let decoded = PolylineEncoder.decode(encoded)

        #expect(decoded.count == coords.count)
        for (original, result) in zip(coords, decoded) {
            #expect(abs(original.latitude - result.latitude) < 0.000001)
            #expect(abs(original.longitude - result.longitude) < 0.000001)
        }
    }

    @Test("Empty input returns empty output")
    func emptyInput() {
        let encoded = PolylineEncoder.encode([])
        #expect(encoded.isEmpty)

        let decoded = PolylineEncoder.decode("")
        #expect(decoded.isEmpty)
    }

    @Test("Single coordinate round-trips")
    func singleCoordinate() {
        let coords = [CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)]
        let encoded = PolylineEncoder.encode(coords)
        let decoded = PolylineEncoder.decode(encoded)

        #expect(decoded.count == 1)
        #expect(abs(decoded[0].latitude - 37.7749) < 0.000001)
        #expect(abs(decoded[0].longitude - (-122.4194)) < 0.000001)
    }

    @Test("Negative coordinates round-trip")
    func negativeCoordinates() {
        let coords = [
            CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093),
            CLLocationCoordinate2D(latitude: -37.8136, longitude: 144.9631),
        ]
        let encoded = PolylineEncoder.encode(coords)
        let decoded = PolylineEncoder.decode(encoded)

        #expect(decoded.count == 2)
        for (original, result) in zip(coords, decoded) {
            #expect(abs(original.latitude - result.latitude) < 0.000001)
            #expect(abs(original.longitude - result.longitude) < 0.000001)
        }
    }

    @Test("Encoded string is non-trivial")
    func encodedIsNontrivial() {
        let coords = [
            CLLocationCoordinate2D(latitude: 38.5, longitude: -120.2),
            CLLocationCoordinate2D(latitude: 40.7, longitude: -120.95),
        ]
        let encoded = PolylineEncoder.encode(coords)
        #expect(!encoded.isEmpty)
        #expect(encoded.count < 100)
    }

    @Test("Non-ASCII byte fails safely instead of hanging", .timeLimit(.minutes(1)))
    func nonASCIIByteDoesNotHang() {
        // Encode a valid prefix, then append multibyte / out-of-charset content
        // that a corrupted or garbled routing response could carry. The decoder
        // must terminate promptly, never spin the CPU or allocate without bound.
        let valid = PolylineEncoder.encode([
            CLLocationCoordinate2D(latitude: 38.5, longitude: -120.2),
        ])

        for garbage in ["🚗", "é", "\u{80}", "\u{FFFD}"] {
            let decoded = PolylineEncoder.decode(valid + garbage)
            // Returns what decoded cleanly so far; never an unbounded array.
            #expect(decoded.count <= 1)
        }
    }

    @Test("Truncated continuation fails safely", .timeLimit(.minutes(1)))
    func truncatedContinuationDoesNotHang() {
        // A lone continuation byte (high bit set, no terminating byte) is a
        // truncated varint — must not loop or emit a phantom coordinate.
        let decoded = PolylineEncoder.decode("\u{7e}\u{7e}\u{7e}")
        #expect(decoded.isEmpty)
    }

    @Test("decodeValidated rejects malformed input without hanging", .timeLimit(.minutes(1)))
    func validatedHandlesMalformed() {
        // Pure garbage decodes to nothing, which is trivially in-bounds, so it
        // returns []; the key assertion is that it returns at all (no spin).
        let decoded = PolylineEncoder.decodeValidated("🚗garbage💥")
        #expect(decoded == nil || decoded?.isEmpty == true)
    }

    @Test("Many coordinates round-trip")
    func manyCoordinates() {
        var coords: [CLLocationCoordinate2D] = []
        for i in 0..<200 {
            coords.append(CLLocationCoordinate2D(
                latitude: 37.0 + Double(i) * 0.01,
                longitude: -122.0 + Double(i) * 0.005
            ))
        }

        let encoded = PolylineEncoder.encode(coords)
        let decoded = PolylineEncoder.decode(encoded)

        #expect(decoded.count == 200)
        for (original, result) in zip(coords, decoded) {
            #expect(abs(original.latitude - result.latitude) < 0.000001)
            #expect(abs(original.longitude - result.longitude) < 0.000001)
        }
    }
}
