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

    @Test("Encoding a non-finite coordinate does not trap")
    func nonFiniteCoordinateDoesNotTrap() {
        // A NaN/±Inf lat or lon (e.g. a degenerate map-match projection or a
        // divide-by-zero while stitching legs) would otherwise trap the
        // Int(round(...)) conversion and crash the app. The bad point is skipped
        // so the surviving coordinates still encode and round-trip cleanly.
        let good1 = CLLocationCoordinate2D(latitude: 38.5, longitude: -120.2)
        let good2 = CLLocationCoordinate2D(latitude: 40.7, longitude: -120.95)
        let bad: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: .nan, longitude: -120.2),
            CLLocationCoordinate2D(latitude: 38.5, longitude: .nan),
            CLLocationCoordinate2D(latitude: .infinity, longitude: -120.2),
            CLLocationCoordinate2D(latitude: 38.5, longitude: -.infinity),
        ]

        for badPoint in bad {
            // The key assertion is simply that this returns at all (no trap).
            let encoded = PolylineEncoder.encode([good1, badPoint, good2])
            let decoded = PolylineEncoder.decode(encoded)
            // Bad point dropped; the two finite points survive and round-trip.
            #expect(decoded.count == 2)
            #expect(abs(decoded[0].latitude - good1.latitude) < 0.000001)
            #expect(abs(decoded[0].longitude - good1.longitude) < 0.000001)
            #expect(abs(decoded[1].latitude - good2.latitude) < 0.000001)
            #expect(abs(decoded[1].longitude - good2.longitude) < 0.000001)
        }

        // An all-non-finite sequence encodes to empty rather than trapping.
        #expect(PolylineEncoder.encode([bad[0]]).isEmpty)
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
