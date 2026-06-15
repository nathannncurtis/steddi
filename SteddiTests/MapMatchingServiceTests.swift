import Testing
import CoreLocation
@testable import Steddi

@Suite("MapMatchingService seam stitching")
struct MapMatchingServiceTests {

    /// Walk north from a base coordinate, one point every `meters`.
    private func line(from base: CLLocationCoordinate2D, count: Int, meters: Double) -> [CLLocationCoordinate2D] {
        // ~111_320 m per degree of latitude.
        let degPerMeter = 1.0 / 111_320.0
        return (0..<count).map {
            CLLocationCoordinate2D(
                latitude: base.latitude + Double($0) * meters * degPerMeter,
                longitude: base.longitude
            )
        }
    }

    @Test("nil tail returns the chunk unchanged")
    func nilTailReturnsChunk() {
        let chunk = line(from: .init(latitude: 33.0, longitude: -117.0), count: 3, meters: 30)
        let stitched = MapMatchingService.stitchSeam(tail: nil, chunk: chunk)
        #expect(stitched.count == 3)
    }

    @Test("Leading matched points within epsilon of the tail are dropped")
    func dropsOverlapWithinEpsilon() {
        // Previous chunk's tail.
        let tail = CLLocationCoordinate2D(latitude: 33.001, longitude: -117.0)

        // The matched second chunk re-traces the seam: its first three points
        // are all within ~10m of the tail (re-snapped overlap), then it moves on.
        let degPerMeter = 1.0 / 111_320.0
        let chunk: [CLLocationCoordinate2D] = [
            // ~2m, ~5m, ~8m from the tail — all inside the 10m epsilon.
            .init(latitude: tail.latitude + 2 * degPerMeter, longitude: -117.0),
            .init(latitude: tail.latitude + 5 * degPerMeter, longitude: -117.0),
            .init(latitude: tail.latitude + 8 * degPerMeter, longitude: -117.0),
            // ~30m, ~60m — clear of the seam, must be kept.
            .init(latitude: tail.latitude + 30 * degPerMeter, longitude: -117.0),
            .init(latitude: tail.latitude + 60 * degPerMeter, longitude: -117.0),
        ]

        let stitched = MapMatchingService.stitchSeam(tail: tail, chunk: chunk)

        // The three near-tail points are dropped; the two clear ones remain.
        #expect(stitched.count == 2)
        #expect(NavigationEngine.haversineDistance(from: tail, to: stitched[0]) > MapMatchingService.seamEpsilon)
    }

    @Test("Stops dropping at the first point beyond epsilon (no seam gap)")
    func stopsAtFirstClearPoint() {
        let tail = CLLocationCoordinate2D(latitude: 33.001, longitude: -117.0)
        let degPerMeter = 1.0 / 111_320.0

        // First point already clear of the tail (~15m); a later point happens to
        // pass back near the tail's latitude. Only the leading run is considered,
        // so nothing is dropped and the later near point is preserved.
        let chunk: [CLLocationCoordinate2D] = [
            .init(latitude: tail.latitude + 15 * degPerMeter, longitude: -117.0),
            .init(latitude: tail.latitude + 40 * degPerMeter, longitude: -117.0),
            .init(latitude: tail.latitude + 2 * degPerMeter, longitude: -117.0),
        ]

        let stitched = MapMatchingService.stitchSeam(tail: tail, chunk: chunk)
        #expect(stitched.count == 3)
    }

    @Test("All points within epsilon yields an empty remainder")
    func allWithinEpsilonDropsAll() {
        let tail = CLLocationCoordinate2D(latitude: 33.001, longitude: -117.0)
        let degPerMeter = 1.0 / 111_320.0
        let chunk: [CLLocationCoordinate2D] = [
            .init(latitude: tail.latitude + 1 * degPerMeter, longitude: -117.0),
            .init(latitude: tail.latitude + 3 * degPerMeter, longitude: -117.0),
        ]
        let stitched = MapMatchingService.stitchSeam(tail: tail, chunk: chunk)
        #expect(stitched.isEmpty)
    }

    @Test("Dedupe by geometry beats a raw input-overlap count at the seam")
    func geometryDedupeBeatsInputCount() {
        // Regression intent: the old code dropped `overlap` (=5) leading MATCHED
        // points. Here only 2 matched points actually re-trace the seam, so a
        // fixed drop of 5 would eat 3 real forward points (a gap). Geometry
        // dedupe drops exactly the 2 overlapping points.
        let tail = CLLocationCoordinate2D(latitude: 33.001, longitude: -117.0)
        let degPerMeter = 1.0 / 111_320.0
        let chunk: [CLLocationCoordinate2D] = [
            .init(latitude: tail.latitude + 3 * degPerMeter, longitude: -117.0),   // within epsilon
            .init(latitude: tail.latitude + 7 * degPerMeter, longitude: -117.0),   // within epsilon
            .init(latitude: tail.latitude + 25 * degPerMeter, longitude: -117.0),  // keep
            .init(latitude: tail.latitude + 50 * degPerMeter, longitude: -117.0),  // keep
            .init(latitude: tail.latitude + 75 * degPerMeter, longitude: -117.0),  // keep
        ]

        let stitched = MapMatchingService.stitchSeam(tail: tail, chunk: chunk)
        #expect(stitched.count == 3)
        // A raw drop-5 would have produced 0 points here, losing real geometry.
    }
}
