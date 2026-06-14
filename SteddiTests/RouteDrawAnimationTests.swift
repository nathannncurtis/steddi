import Testing
import Foundation
import CoreLocation
@testable import Steddi

// MARK: - RouteDrawGeometry (draw-on partial-path math)

@Suite("RouteDrawGeometry")
struct RouteDrawGeometryTests {

    /// A straight 3-vertex line: (0,0) -> (0,1) -> (0,2). Each leg ~111km,
    /// total ~222km. Distances are along longitude at the equator.
    private var straightLine: [CLLocationCoordinate2D] {
        [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 1),
            CLLocationCoordinate2D(latitude: 0, longitude: 2),
        ]
    }

    @Test("Progress 0 draws nothing")
    func progressZeroEmpty() {
        let coords = straightLine
        let cumulative = RouteGeometry.cumulativeDistances(coords)
        let path = RouteDrawGeometry.partialPath(coords: coords, cumulative: cumulative, progress: 0)
        #expect(path.isEmpty)
    }

    @Test("Negative progress draws nothing")
    func progressNegativeEmpty() {
        let coords = straightLine
        let cumulative = RouteGeometry.cumulativeDistances(coords)
        let path = RouteDrawGeometry.partialPath(coords: coords, cumulative: cumulative, progress: -0.5)
        #expect(path.isEmpty)
    }

    @Test("Progress 1 draws the whole polyline")
    func progressOneFull() {
        let coords = straightLine
        let cumulative = RouteGeometry.cumulativeDistances(coords)
        let path = RouteDrawGeometry.partialPath(coords: coords, cumulative: cumulative, progress: 1)
        #expect(path.count == coords.count)
        #expect(path.last?.longitude == 2)
    }

    @Test("Progress over 1 clamps to the whole polyline")
    func progressOverOneFull() {
        let coords = straightLine
        let cumulative = RouteGeometry.cumulativeDistances(coords)
        let path = RouteDrawGeometry.partialPath(coords: coords, cumulative: cumulative, progress: 1.7)
        #expect(path.count == coords.count)
    }

    @Test("Progress 0.5 ends at the midpoint of the line")
    func progressHalfMidpoint() {
        let coords = straightLine
        let cumulative = RouteGeometry.cumulativeDistances(coords)
        let path = RouteDrawGeometry.partialPath(coords: coords, cumulative: cumulative, progress: 0.5)
        // 0.5 of total (~222km) lands exactly on the middle vertex (0,1).
        #expect(path.count >= 2)
        let tip = path.last!
        #expect(abs(tip.longitude - 1.0) < 0.001)
        #expect(abs(tip.latitude) < 0.001)
    }

    @Test("Progress 0.25 interpolates a tip on the first segment")
    func progressQuarterInterpolatesTip() {
        let coords = straightLine
        let cumulative = RouteGeometry.cumulativeDistances(coords)
        let path = RouteDrawGeometry.partialPath(coords: coords, cumulative: cumulative, progress: 0.25)
        // 0.25 of total is halfway through the first segment -> tip near (0, 0.5).
        let tip = path.last!
        #expect(abs(tip.longitude - 0.5) < 0.01)
        // First vertex is included, then the interpolated tip.
        #expect(path.count == 2)
        #expect(path.first!.longitude == 0)
    }

    @Test("Tip advances monotonically with progress")
    func tipMonotonic() {
        let coords = straightLine
        let cumulative = RouteGeometry.cumulativeDistances(coords)
        var lastLon = -1.0
        for p in stride(from: 0.1, through: 1.0, by: 0.1) {
            let tip = RouteDrawGeometry.partialPath(coords: coords, cumulative: cumulative, progress: p).last!
            #expect(tip.longitude >= lastLon)
            lastLon = tip.longitude
        }
    }

    @Test("Degenerate polyline (< 2 coords) returns input unchanged")
    func degenerateReturnsInput() {
        let single = [CLLocationCoordinate2D(latitude: 1, longitude: 1)]
        let cumulative = RouteGeometry.cumulativeDistances(single)
        let path = RouteDrawGeometry.partialPath(coords: single, cumulative: cumulative, progress: 0.5)
        #expect(path.count == single.count)
    }

    @Test("Mismatched cumulative count returns input unchanged")
    func mismatchedCumulativeReturnsInput() {
        let coords = straightLine
        let path = RouteDrawGeometry.partialPath(coords: coords, cumulative: [0, 1], progress: 0.5)
        #expect(path.count == coords.count)
    }

    // MARK: - easeOut curve

    @Test("easeOut maps endpoints to 0 and 1")
    func easeOutEndpoints() {
        #expect(RouteDrawGeometry.easeOut(0) == 0)
        #expect(RouteDrawGeometry.easeOut(1) == 1)
    }

    @Test("easeOut clamps out-of-range input")
    func easeOutClamps() {
        #expect(RouteDrawGeometry.easeOut(-1) == 0)
        #expect(RouteDrawGeometry.easeOut(2) == 1)
    }

    @Test("easeOut is ahead of linear in the first half (fast start)")
    func easeOutFastStart() {
        // Cubic ease-out: value at t is always >= t for t in (0,1).
        for t in stride(from: 0.1, through: 0.9, by: 0.1) {
            #expect(RouteDrawGeometry.easeOut(t) >= t - 1e-9)
        }
    }

    @Test("easeOut is monotonically increasing")
    func easeOutMonotonic() {
        var last = -1.0
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            let v = RouteDrawGeometry.easeOut(t)
            #expect(v >= last)
            last = v
        }
    }
}

// MARK: - RouteDrawGeometry adversarial edge cases

@Suite("RouteDrawGeometry edge cases")
struct RouteDrawGeometryEdgeTests {

    private var straightLine: [CLLocationCoordinate2D] {
        [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 1),
            CLLocationCoordinate2D(latitude: 0, longitude: 2),
        ]
    }

    @Test("Tiny positive progress yields origin + interpolated tip on first segment")
    func tinyProgress() {
        let coords = straightLine
        let cumulative = RouteGeometry.cumulativeDistances(coords)
        let path = RouteDrawGeometry.partialPath(coords: coords, cumulative: cumulative, progress: 0.0001)
        // First vertex retained, plus a tip barely past it — never empty for p > 0.
        #expect(path.count == 2)
        #expect(path.first!.longitude == 0)
        #expect(path.last!.longitude > 0)
        #expect(path.last!.longitude < 0.01)
    }

    @Test("Progress just below 1 retains all vertices and a near-end tip")
    func progressJustBelowOne() {
        let coords = straightLine
        let cumulative = RouteGeometry.cumulativeDistances(coords)
        let path = RouteDrawGeometry.partialPath(coords: coords, cumulative: cumulative, progress: 0.999999)
        // Every real vertex plus the interpolated tip on the last segment.
        #expect(path.count == coords.count)
        #expect(path.last!.longitude > 1.99)
        #expect(path.last!.longitude < 2.0)
    }

    @Test("Zero-length leading segment (duplicate coords) does not divide by zero")
    func zeroLengthSegment() {
        // Vertices 0 and 1 are identical -> first segment length 0.
        let coords = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 2),
        ]
        let cumulative = [0.0, 0.0, 222_000.0]
        let path = RouteDrawGeometry.partialPath(coords: coords, cumulative: cumulative, progress: 0.5)
        // Half the (only real) length lands at longitude 1; no NaN/crash.
        #expect(path.last!.longitude.isFinite)
        #expect(abs(path.last!.longitude - 1.0) < 0.01)
    }

    @Test("Target landing exactly on a middle vertex keeps that vertex as the tip")
    func exactVertexBoundary() {
        let coords = straightLine
        let cumulative = RouteGeometry.cumulativeDistances(coords)
        // progress chosen so target == cumulative[1] exactly.
        let progress = cumulative[1] / cumulative[2]
        let path = RouteDrawGeometry.partialPath(coords: coords, cumulative: cumulative, progress: progress)
        #expect(abs(path.last!.longitude - 1.0) < 1e-6)
        #expect(path.last!.latitude == 0)
    }

    @Test("Empty coords returns empty (degenerate, no crash)")
    func emptyCoords() {
        let path = RouteDrawGeometry.partialPath(coords: [], cumulative: [], progress: 0.5)
        #expect(path.isEmpty)
    }

    @Test("Two-coord polyline interpolates a single tip at progress < 1")
    func twoCoordTip() {
        let coords = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 10),
        ]
        let cumulative = RouteGeometry.cumulativeDistances(coords)
        let path = RouteDrawGeometry.partialPath(coords: coords, cumulative: cumulative, progress: 0.3)
        #expect(path.count == 2)
        #expect(path.first!.longitude == 0)
        #expect(abs(path.last!.longitude - 3.0) < 0.1)
    }

    @Test("Zero total distance (all coincident) returns input unchanged")
    func zeroTotalDistance() {
        let coords = [
            CLLocationCoordinate2D(latitude: 1, longitude: 1),
            CLLocationCoordinate2D(latitude: 1, longitude: 1),
        ]
        let cumulative = [0.0, 0.0]
        let path = RouteDrawGeometry.partialPath(coords: coords, cumulative: cumulative, progress: 0.5)
        // total == 0 -> guard returns the input untouched (no draw-on possible).
        #expect(path.count == coords.count)
    }

    @Test("easeOut is strictly increasing on the open interval")
    func easeOutStrictlyIncreasing() {
        var last = RouteDrawGeometry.easeOut(0)
        for t in stride(from: 0.05, through: 1.0, by: 0.05) {
            let v = RouteDrawGeometry.easeOut(t)
            #expect(v > last)
            last = v
        }
    }

    @Test("easeOut midpoint sits above linear (ease-out shape)")
    func easeOutMidpointAboveLinear() {
        // 1 - 0.5^3 = 0.875, comfortably ahead of linear 0.5.
        #expect(abs(RouteDrawGeometry.easeOut(0.5) - 0.875) < 1e-9)
    }
}

// MARK: - TransitionKit timing params

@Suite("TransitionKit")
struct TransitionKitTests {

    @Test("Durations are ordered quick < standard < slow")
    func durationsOrdered() {
        #expect(TransitionKit.durationQuick < TransitionKit.durationStandard)
        #expect(TransitionKit.durationStandard < TransitionKit.durationSlow)
    }

    @Test("Durations match the spec values")
    func durationValues() {
        #expect(TransitionKit.durationQuick == 0.2)
        #expect(TransitionKit.durationStandard == 0.35)
        #expect(TransitionKit.durationSlow == 0.6)
    }

    @Test("Route draw duration is 1.2s per spec")
    func routeDrawDuration() {
        #expect(TransitionKit.routeDrawDuration == 1.2)
    }

    @Test("Spring damping fractions stay in the 0.6...0.8 comfort band")
    func springDampingInBand() {
        for params in [
            TransitionKit.springButton,
            TransitionKit.springFloatingButton,
            TransitionKit.springArrival,
            TransitionKit.springReroute,
        ] {
            #expect(params.damping >= 0.6)
            #expect(params.damping <= 0.8)
        }
    }

    @Test("Spring responses are positive and snappy (<= 0.6s)")
    func springResponsesPositive() {
        for params in [
            TransitionKit.springButton,
            TransitionKit.springFloatingButton,
            TransitionKit.springArrival,
            TransitionKit.springReroute,
        ] {
            #expect(params.response > 0)
            #expect(params.response <= 0.6)
        }
    }

    @Test("Arrival spring is the loosest (lowest damping) for a visible bounce")
    func arrivalSpringLoosest() {
        #expect(TransitionKit.springArrival.damping <= TransitionKit.springButton.damping)
        #expect(TransitionKit.springArrival.damping <= TransitionKit.springFloatingButton.damping)
    }

    @Test("Press scale dips below 1 for tactile feedback")
    func pressScale() {
        #expect(TransitionKit.pressScale < 1.0)
        #expect(TransitionKit.pressScale > 0.8)
    }

    @Test("Card stagger delay grows with index")
    func staggerStepPositive() {
        #expect(TransitionKit.staggerStep > 0)
    }

    @Test("Floating button entrance trails the banner")
    func floatingButtonTrailsBanner() {
        #expect(TransitionKit.floatingButtonDelay > TransitionKit.bannerDelay)
    }
}
