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
