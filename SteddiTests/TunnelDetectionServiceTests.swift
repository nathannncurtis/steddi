import Testing
import CoreLocation
@testable import Steddi

@Suite("TunnelDetectionService geometry")
struct TunnelDetectionServiceTests {

    @Test("North-south tunnel: mid-segment point is detected as inside")
    func northSouthMidSegmentInside() {
        // ~1.1km roughly north-south segment, the kind Overpass `out geom` yields
        // for a straight tunnel mapped with sparse nodes. The driver sits exactly
        // on the centerline at the midpoint — far in latitude from BOTH endpoints,
        // which the old latitude-only pre-filter wrongly skipped.
        let segment = TunnelSegment(
            start: CLLocationCoordinate2D(latitude: 40.0000, longitude: -74.0000),
            end: CLLocationCoordinate2D(latitude: 40.0100, longitude: -74.0000)
        )
        let midpoint = CLLocationCoordinate2D(latitude: 40.0050, longitude: -74.0000)

        #expect(TunnelDetectionService.isInside(midpoint, segments: [segment]))
    }

    @Test("North-south tunnel: point well off the line is not inside")
    func northSouthOffLineOutside() {
        // Same N-S segment; a point ~200m east (well beyond the 30m radius) must
        // still be rejected — the bounding box widens the cheap pass but the
        // precise distance check is what decides.
        let segment = TunnelSegment(
            start: CLLocationCoordinate2D(latitude: 40.0000, longitude: -74.0000),
            end: CLLocationCoordinate2D(latitude: 40.0100, longitude: -74.0000)
        )
        let offLine = CLLocationCoordinate2D(latitude: 40.0050, longitude: -73.9976)

        #expect(!TunnelDetectionService.isInside(offLine, segments: [segment]))
    }

    @Test("East-west tunnel: mid-segment point still detected")
    func eastWestMidSegmentInside() {
        // The complementary axis — guards against a regression that fixes N-S by
        // breaking E-W. Mid-segment point far in longitude from both endpoints.
        let segment = TunnelSegment(
            start: CLLocationCoordinate2D(latitude: 40.0000, longitude: -74.0100),
            end: CLLocationCoordinate2D(latitude: 40.0000, longitude: -74.0000)
        )
        let midpoint = CLLocationCoordinate2D(latitude: 40.0000, longitude: -74.0050)

        #expect(TunnelDetectionService.isInside(midpoint, segments: [segment]))
    }
}
