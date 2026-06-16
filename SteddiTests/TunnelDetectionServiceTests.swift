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

@Suite("TunnelDetectionService blind-latch decay")
@MainActor
struct TunnelDetectionBlindLatchTests {

    /// A degraded fix far from any tunnel: negative accuracy (or > weakAccuracy)
    /// marks it weak; speed is irrelevant once weak (not recorded as good).
    private func weakFix(at t: TimeInterval, base: Date) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0),
            altitude: 0,
            horizontalAccuracy: 200,   // > weakAccuracyMeters (80) → degraded
            verticalAccuracy: 10,
            course: 0,
            speed: -1,                 // unknown while degraded
            timestamp: base.addingTimeInterval(t)
        )
    }

    /// A trustworthy fix at road speed, so the blind heuristic's "was moving"
    /// gate arms (lastGoodSpeedMPS ≥ blindMinSpeedMPS).
    private func goodFastFix(at t: TimeInterval, base: Date) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0),
            altitude: 0,
            horizontalAccuracy: 5,     // < weakAccuracyMeters → trustworthy
            verticalAccuracy: 5,
            course: 0,
            speed: 25,                 // ~56 mph, well above blindMinSpeedMPS (8)
            timestamp: base.addingTimeInterval(t)
        )
    }

    @Test("Sustained degraded GPS (no OSM data) releases the blind latch after the timeout")
    func sustainedDegradationReleasesLatch() {
        // No tunnel ways loaded → segments stays empty → the BLIND arm is the
        // only path to `detected`. Drive a clock the fade math reads off `now`.
        let base = Date(timeIntervalSince1970: 1_000_000)
        var clock = base
        var lastDetected: Bool?
        let service = TunnelDetectionService(
            now: { clock },
            apply: { _, detected in lastDetected = detected }
        )

        // 1) One good fast fix arms the "was moving at road speed" gate.
        clock = base
        service.updateLocation(goodFastFix(at: 0, base: base))

        // 2) Enough consecutive weak fixes to cross weakStreakBlind (6) → the
        //    blind latch fires and pins the in-tunnel (dark) theme.
        for i in 1...7 {
            clock = base.addingTimeInterval(Double(i))
            service.updateLocation(weakFix(at: Double(i), base: base))
        }
        #expect(service.status == .inTunnel, "blind latch should fire on a sustained streak after road-speed motion")
        #expect(lastDetected == true)

        // 3) Keep the dropout going past the decay window (180s) WITHOUT a good
        //    fix — exactly the underground-garage / urban-canyon case. The latch
        //    must release: detected flips false and the theme reverts.
        var t = 8.0
        while t <= TunnelDetectionService.blindLatchMaxSecondsForTesting + 5 {
            clock = base.addingTimeInterval(t)
            service.updateLocation(weakFix(at: t, base: base))
            t += 1
        }
        #expect(service.status == .outdoor, "a sustained dropout that isn't a tunnel must not pin dark forever")
        #expect(lastDetected == false, "blind latch should have decayed and released")
    }

    @Test("A good fix during the dropout resets the decay clock (genuine short-tunnel exit preserved)")
    func goodFixResetsDecayClock() {
        let base = Date(timeIntervalSince1970: 2_000_000)
        var clock = base
        var lastDetected: Bool?
        let service = TunnelDetectionService(
            now: { clock },
            apply: { _, detected in lastDetected = detected }
        )

        clock = base
        service.updateLocation(goodFastFix(at: 0, base: base))
        for i in 1...7 {
            clock = base.addingTimeInterval(Double(i))
            service.updateLocation(weakFix(at: Double(i), base: base))
        }
        #expect(service.status == .inTunnel)

        // A good fix arrives well before the decay window — the streak (and its
        // clock) reset, so detection ends via the normal quality escape, not the
        // timeout. This is the genuine short-tunnel path: signal returns, fade out.
        clock = base.addingTimeInterval(20)
        service.updateLocation(goodFastFix(at: 20, base: base))
        #expect(service.status == .outdoor)
        #expect(lastDetected == false)

        // Re-arming starts a fresh streak whose clock begins now — so a brand-new
        // short dropout is NOT immediately decayed by the earlier elapsed time.
        for i in 1...7 {
            let t = 21.0 + Double(i)
            clock = base.addingTimeInterval(t)
            service.updateLocation(weakFix(at: t, base: base))
        }
        #expect(service.status == .inTunnel, "a fresh blind streak after a good fix re-arms and is not pre-decayed")
    }
}
