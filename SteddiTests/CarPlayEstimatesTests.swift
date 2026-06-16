import Testing
import Foundation
@testable import Steddi

// Covers the maneuver-vs-trip estimate split and unit-aware distance formatting
// used by the CarPlay route/maneuver banners.

@Suite("CarPlay maneuver-vs-trip estimate split")
struct CarPlayManeuverEstimateTests {

    // MARK: - timeToNextManeuver (per-maneuver time derivation)

    @Test("Time to next maneuver = step distance / speed, not whole-trip ETA")
    func derivesPerStepTime() {
        // 300 m to the next turn at 60 mph (~26.82 m/s) -> ~11.2 s.
        let seconds = CarPlaySceneDelegate.timeToNextManeuver(distanceMeters: 300, speedMph: 60)
        #expect(seconds > 10 && seconds < 13)
    }

    @Test("Per-maneuver time scales with the per-step distance, not the trip")
    func tracksStepDistance() {
        // The whole point of the fix: a short step distance yields a short time
        // regardless of how far the destination is. A 200 ft (~61 m) turn at
        // 30 mph (~13.4 m/s) should be only a handful of seconds.
        let nearTurn = CarPlaySceneDelegate.timeToNextManeuver(distanceMeters: 61, speedMph: 30)
        #expect(nearTurn > 3 && nearTurn < 6)

        // A far-off turn at the same speed must take proportionally longer.
        let farTurn = CarPlaySceneDelegate.timeToNextManeuver(distanceMeters: 6100, speedMph: 30)
        #expect(farTurn > nearTurn * 90) // ~100x the distance -> ~100x the time
    }

    @Test("Zero distance to maneuver yields zero time")
    func zeroDistance() {
        #expect(CarPlaySceneDelegate.timeToNextManeuver(distanceMeters: 0, speedMph: 60) == 0)
    }

    @Test("Negative distance is treated as zero")
    func negativeDistance() {
        #expect(CarPlaySceneDelegate.timeToNextManeuver(distanceMeters: -50, speedMph: 60) == 0)
    }

    @Test("Stopped/near-zero speed returns 0 rather than exploding")
    func stoppedSpeed() {
        #expect(CarPlaySceneDelegate.timeToNextManeuver(distanceMeters: 300, speedMph: 0) == 0)
        #expect(CarPlaySceneDelegate.timeToNextManeuver(distanceMeters: 300, speedMph: 0.5) == 0)
    }
}

@Suite("MeasurementUnit.formatDistance")
struct MeasurementUnitFormatTests {

    @Test("Miles: short distance gets one decimal")
    func milesShort() {
        // 1609.34 m == 1.0 mi
        #expect(MeasurementUnit.miles.formatDistance(meters: 1609.34) == "1.0 mi")
    }

    @Test("Miles: long distance is a whole number")
    func milesLong() {
        // 32186.8 m == 20 mi
        #expect(MeasurementUnit.miles.formatDistance(meters: 32186.8) == "20 mi")
    }

    @Test("Kilometers: short distance gets one decimal in km")
    func kmShort() {
        // 1500 m == 1.5 km (must NOT render as miles)
        #expect(MeasurementUnit.kilometers.formatDistance(meters: 1500) == "1.5 km")
    }

    @Test("Kilometers: long distance is a whole number in km")
    func kmLong() {
        // 20000 m == 20 km
        #expect(MeasurementUnit.kilometers.formatDistance(meters: 20000) == "20 km")
    }

    @Test("Same input differs by unit preference")
    func differsByUnit() {
        let meters = 5000.0
        #expect(MeasurementUnit.miles.formatDistance(meters: meters) != MeasurementUnit.kilometers.formatDistance(meters: meters))
        #expect(MeasurementUnit.kilometers.formatDistance(meters: meters) == "5.0 km")
    }

    // Rounding (not truncation) above 10 units: Int(10.95) truncated to "10",
    // understating the distance by nearly a unit. .rounded() fixes it.
    @Test("Miles: 10.95 mi rounds up to 11 mi (not truncated to 10)")
    func milesRoundsUp() {
        #expect(MeasurementUnit.miles.formatDistance(meters: 10.95 * 1609.34) == "11 mi")
    }

    @Test("Miles: 10.4 mi rounds down to 10 mi")
    func milesRoundsDown() {
        #expect(MeasurementUnit.miles.formatDistance(meters: 10.4 * 1609.34) == "10 mi")
    }

    @Test("Kilometers: 10.95 km rounds up to 11 km")
    func kmRoundsUp() {
        #expect(MeasurementUnit.kilometers.formatDistance(meters: 10_950) == "11 km")
    }

    @Test("Kilometers: 10.4 km rounds down to 10 km")
    func kmRoundsDown() {
        #expect(MeasurementUnit.kilometers.formatDistance(meters: 10_400) == "10 km")
    }

    // Band-boundary edge: distances that round to 10 must use the whole-number
    // style ("10 km"), not the "%.1f" path that rendered a stray-decimal
    // "10.0 km". The whole/decimal decision is made off the rounded value.
    @Test("Kilometers: 9.95 km rounds to whole 10 km (no stray decimal)")
    func kmBoundary995() {
        #expect(MeasurementUnit.kilometers.formatDistance(meters: 9_950) == "10 km")
    }

    @Test("Kilometers: 9.99 km rounds to whole 10 km (no stray decimal)")
    func kmBoundary999() {
        #expect(MeasurementUnit.kilometers.formatDistance(meters: 9_990) == "10 km")
    }

    @Test("Kilometers: exactly 10.0 km is whole 10 km")
    func kmBoundary10() {
        #expect(MeasurementUnit.kilometers.formatDistance(meters: 10_000) == "10 km")
    }

    @Test("Miles: 9.95 mi rounds to whole 10 mi (no stray decimal)")
    func milesBoundary995() {
        #expect(MeasurementUnit.miles.formatDistance(meters: 9.95 * 1609.34) == "10 mi")
    }

    @Test("Miles: 9.99 mi rounds to whole 10 mi (no stray decimal)")
    func milesBoundary999() {
        #expect(MeasurementUnit.miles.formatDistance(meters: 9.99 * 1609.34) == "10 mi")
    }

    @Test("Miles: exactly 10.0 mi is whole 10 mi")
    func milesBoundary10() {
        #expect(MeasurementUnit.miles.formatDistance(meters: 10.0 * 1609.34) == "10 mi")
    }

    @Test("Just below the band: 9.4 km keeps one decimal")
    func kmBelowBand() {
        #expect(MeasurementUnit.kilometers.formatDistance(meters: 9_400) == "9.4 km")
    }
}
