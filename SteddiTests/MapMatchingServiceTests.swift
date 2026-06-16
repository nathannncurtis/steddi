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

    /// Build a tail region of `count` coords ending at `tail`, spaced `meters`
    /// apart heading north — mirrors the stitched tail span the dedupe sees.
    private func tailRegion(endingAt tail: CLLocationCoordinate2D, count: Int, meters: Double) -> [CLLocationCoordinate2D] {
        let degPerMeter = 1.0 / 111_320.0
        return (0..<count).reversed().map {
            CLLocationCoordinate2D(
                latitude: tail.latitude - Double($0) * meters * degPerMeter,
                longitude: tail.longitude
            )
        }
    }

    @Test("empty tail region returns the chunk unchanged")
    func emptyTailRegionReturnsChunk() {
        let chunk = line(from: .init(latitude: 33.0, longitude: -117.0), count: 3, meters: 30)
        let stitched = MapMatchingService.stitchSeam(tailRegion: [], chunk: chunk)
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

        let stitched = MapMatchingService.stitchSeam(tailRegion: [tail], chunk: chunk)

        // The three near-tail points are dropped; the two clear ones remain.
        #expect(stitched.count == 2)
        #expect(NavigationEngine.haversineDistance(from: tail, to: stitched[0]) > MapMatchingService.seamEpsilon)
    }

    @Test("Stops dropping at the first point clear of the whole tail region (no seam gap)")
    func stopsAtFirstClearPoint() {
        let tail = CLLocationCoordinate2D(latitude: 33.001, longitude: -117.0)
        let degPerMeter = 1.0 / 111_320.0

        // First point already clear of the tail region (~15m ahead, and the
        // region only extends behind the tail); a later point happens to pass
        // back near the tail's latitude. Only the leading run is considered, so
        // nothing is dropped and the later near point is preserved.
        let region = tailRegion(endingAt: tail, count: 5, meters: 10)
        let chunk: [CLLocationCoordinate2D] = [
            .init(latitude: tail.latitude + 15 * degPerMeter, longitude: -117.0),
            .init(latitude: tail.latitude + 40 * degPerMeter, longitude: -117.0),
            .init(latitude: tail.latitude + 2 * degPerMeter, longitude: -117.0),
        ]

        let stitched = MapMatchingService.stitchSeam(tailRegion: region, chunk: chunk)
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
        let stitched = MapMatchingService.stitchSeam(tailRegion: [tail], chunk: chunk)
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

        let stitched = MapMatchingService.stitchSeam(tailRegion: [tail], chunk: chunk)
        #expect(stitched.count == 3)
        // A raw drop-5 would have produced 0 points here, losing real geometry.
    }

    @Test("Coarse OSRM resample: overlap re-traced as widely-spaced vertices is fully dropped")
    func coarseResampleOverlapDroppedViaTailRegion() {
        // The real failure mode: chunk N's overlap geometry begins ~100m BEHIND
        // the stitched tail (it re-feeds ~5 input points ending one fix before
        // the tail). On a straight freeway OSRM resamples that overlap coarsely —
        // here as vertices ~25m apart — so NOT ONE of them lands within the 10m
        // seamEpsilon of the SINGLE tail vertex. The previous single-vertex
        // dedupe therefore dropped 0 points and re-appended the entire overlap,
        // backtracking the polyline and inflating distance. Comparing against the
        // tail REGION (the last several stitched coords spanning the overlap)
        // catches each overlap vertex near its matching region vertex.
        let degPerMeter = 1.0 / 111_320.0
        let base = 33.0

        // Stitched tail region: vertices every 25m up to the tail at +200m.
        let tailRegion: [CLLocationCoordinate2D] = stride(from: 100.0, through: 200.0, by: 25.0).map {
            .init(latitude: base + $0 * degPerMeter, longitude: -117.0)
        }
        let tail = tailRegion.last!

        // New chunk: re-traces the overlap (125m..200m, every 25m — coarse, and
        // none within 10m of the lone +200m tail) then continues forward.
        let overlapCoords: [CLLocationCoordinate2D] = stride(from: 125.0, through: 200.0, by: 25.0).map {
            .init(latitude: base + $0 * degPerMeter, longitude: -117.0)
        }
        let forwardCoords: [CLLocationCoordinate2D] = stride(from: 225.0, through: 300.0, by: 25.0).map {
            .init(latitude: base + $0 * degPerMeter, longitude: -117.0)
        }
        let chunk = overlapCoords + forwardCoords

        // Single-vertex baseline (old behavior): nothing is within 10m of the
        // lone tail, so the whole overlap survives — the defect.
        let singleVertex = MapMatchingService.stitchSeam(tailRegion: [tail], chunk: chunk)
        #expect(singleVertex.count == chunk.count) // overlap re-appended (bad)

        // Tail-region dedupe: every overlap vertex sits within 10m of a region
        // vertex, so all four overlap points drop and only the forward points
        // remain — no backtrack, no inflated distance.
        let stitched = MapMatchingService.stitchSeam(tailRegion: tailRegion, chunk: chunk)
        #expect(stitched.count == forwardCoords.count)
        #expect(NavigationEngine.haversineDistance(from: tail, to: stitched[0]) > MapMatchingService.seamEpsilon)

        // The kept geometry strictly advances past the tail — no backward jump.
        let firstKeptAlong = (stitched.first!.latitude - base) / degPerMeter
        #expect(firstKeptAlong > 200.0)
    }

    @Test("Overlap mapping to >8 matched vertices: adaptive tail window drops the WHOLE seam")
    func adaptiveTailWindowSpansLongOverlap() {
        // The input overlap (~120m here) re-traces onto MANY matched vertices when
        // OSRM resamples finely — 12 vertices at 10m spacing. A fixed 8-vertex tail
        // window reaches back only ~70m, so the 4 deepest overlap points (the start
        // of the re-trace) sit BEYOND the window, match nothing, and survive — a
        // seam that is under-dropped, backtracking the polyline. An adaptive window
        // sized to the overlap LENGTH reaches all 12 and drops the entire seam.
        let degPerMeter = 1.0 / 111_320.0
        let base = 33.0

        // Stitched tail: vertices every 10m from +0m to +200m (21 vertices). The
        // overlap re-traces the last ~120m of this (+80m .. +200m).
        let stitchedTail: [CLLocationCoordinate2D] = stride(from: 0.0, through: 200.0, by: 10.0).map {
            .init(latitude: base + $0 * degPerMeter, longitude: -117.0)
        }
        let tail = stitchedTail.last!

        // New chunk: re-traces +90m .. +200m at 10m spacing (12 overlap vertices,
        // each ~within seamEpsilon of a tail vertex), then continues +210m .. +300m.
        let overlapCoords: [CLLocationCoordinate2D] = stride(from: 90.0, through: 200.0, by: 10.0).map {
            .init(latitude: base + $0 * degPerMeter, longitude: -117.0)
        }
        // Forward geometry starts ~25m past the tail — comfortably clear of the 10m
        // seamEpsilon so the first kept point is unambiguous.
        let forwardCoords: [CLLocationCoordinate2D] = stride(from: 225.0, through: 300.0, by: 25.0).map {
            .init(latitude: base + $0 * degPerMeter, longitude: -117.0)
        }
        let chunk = overlapCoords + forwardCoords
        #expect(overlapCoords.count > MapMatchingService.seamTailWindow)   // the trigger: >8 overlap vertices

        // The measured overlap span (~120m of input geometry at the seam).
        let overlapMeters = 120.0

        // Fixed 8-vertex window (the old behavior): it reaches only the last ~70m of
        // the tail, so the deepest overlap points (~+90m..+120m) match nothing and
        // survive — the seam is under-dropped.
        let fixedRegion = Array(stitchedTail.suffix(MapMatchingService.seamTailWindow))
        let fixedStitched = MapMatchingService.stitchSeam(tailRegion: fixedRegion, chunk: chunk)
        #expect(fixedStitched.count > forwardCoords.count)   // leftover overlap geometry (bad)

        // Adaptive window: sized by the overlap length, it spans the whole overlap,
        // so every overlap vertex is dropped and only the forward geometry remains.
        let adaptiveRegion = MapMatchingService.adaptiveTailRegion(stitchedTail, overlapMeters: overlapMeters)
        #expect(adaptiveRegion.count > MapMatchingService.seamTailWindow)   // window grew past the fixed floor
        let stitched = MapMatchingService.stitchSeam(tailRegion: adaptiveRegion, chunk: chunk)
        #expect(stitched.count == forwardCoords.count)
        #expect(NavigationEngine.haversineDistance(from: tail, to: stitched[0]) > MapMatchingService.seamEpsilon)
        // The kept geometry strictly advances past the tail — no backtrack.
        let firstKeptAlong = (stitched.first!.latitude - base) / degPerMeter
        #expect(firstKeptAlong > 200.0)
    }
}
