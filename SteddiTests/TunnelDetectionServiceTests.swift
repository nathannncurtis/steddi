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

    @Test("High-latitude tunnel: a point within radius but east of the segment is NOT skipped by the longitude pre-filter")
    func highLatitudeLongitudePreFilterCosineScaled() {
        // At latitude 70° one degree of longitude is only 111km·cos(70°) ≈ 38km, so
        // an UN-scaled longitude pad (a raw degree delta applied identically to both
        // axes) covers far fewer meters than intended. For the 150m portal radius the
        // un-scaled pad spans only ~140m of longitude here — narrower than the radius
        // itself — so a driver within 150m of, but just east of, a tunnel's longitude
        // band falls outside the box pre-filter and the precise distance check is
        // wrongly skipped. Scaling the longitude pad by 1/cos(latitude) restores it.
        let lat = 70.0
        let radius = 150.0
        // A roughly north-south tunnel at longitude 20.0, spanning ~1.1km in latitude
        // so the probe's latitude sits comfortably inside the latitude band.
        let segment = TunnelSegment(
            start: CLLocationCoordinate2D(latitude: lat - 0.005, longitude: 20.0),
            end: CLLocationCoordinate2D(latitude: lat + 0.005, longitude: 20.0)
        )
        // Probe at the segment's mid-latitude, offset EAST by ~145m — inside the 150m
        // radius, but ~145m > the un-scaled pad's ~140m longitude reach at this
        // latitude. metersPerLonDegree = 111_000·cos(lat).
        let metersPerLonDegree = 111_000.0 * cos(lat * .pi / 180)
        let lonOffset = 145.0 / metersPerLonDegree
        let probe = CLLocationCoordinate2D(latitude: lat, longitude: 20.0 + lonOffset)

        // The precise perpendicular distance really is within the radius (~145m).
        let precise = OSMSpeedLimitService.distanceToSegment(probe, segment.start, segment.end)
        #expect(precise <= radius, "probe is genuinely \(precise) m from the segment, within \(radius) m")

        // So isNear must report it — the cosine-scaled longitude pad keeps it in the box.
        #expect(TunnelDetectionService.isNear(probe, segments: [segment], radius: radius))

        // Guard: a point genuinely well beyond the radius (~400m east) is still
        // rejected — the scaled pad widens the cheap pass, not the precise decision.
        let farOffset = 400.0 / metersPerLonDegree
        let far = CLLocationCoordinate2D(latitude: lat, longitude: 20.0 + farOffset)
        #expect(!TunnelDetectionService.isNear(far, segments: [segment], radius: radius))
    }
}
