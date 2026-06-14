import Testing
import Foundation
@testable import Steddi

@Suite("goldenHourFactor")
struct GoldenHourFactorTests {

    @Test("Peaks at the horizon")
    func peaksAtHorizon() {
        #expect(ThemeEngine.goldenHourFactor(forSolarElevation: 0) == 1)
    }

    @Test("Reaches zero exactly at the −8° lower edge")
    func zeroAtLowerEdge() {
        #expect(ThemeEngine.goldenHourFactor(forSolarElevation: -8) == 0)
    }

    @Test("Reaches zero exactly at the +10° upper edge")
    func zeroAtUpperEdge() {
        #expect(ThemeEngine.goldenHourFactor(forSolarElevation: 10) == 0)
    }

    @Test("Stays clamped to zero below the lower edge (regression: was 2.25 at −10°)")
    func clampedBelowLowerEdge() {
        for elevation in stride(from: -8.0, through: -90.0, by: -2.0) {
            let factor = ThemeEngine.goldenHourFactor(forSolarElevation: elevation)
            #expect(factor == 0, "expected 0 at \(elevation)°, got \(factor)")
        }
        // The specific value called out in review.
        #expect(ThemeEngine.goldenHourFactor(forSolarElevation: -10) == 0)
    }

    @Test("Stays clamped to zero above the upper edge")
    func clampedAboveUpperEdge() {
        for elevation in stride(from: 10.0, through: 90.0, by: 5.0) {
            #expect(ThemeEngine.goldenHourFactor(forSolarElevation: elevation) == 0)
        }
    }

    @Test("Never leaves [0, 1] across the full elevation range")
    func boundedEverywhere() {
        for elevation in stride(from: -90.0, through: 90.0, by: 0.5) {
            let factor = ThemeEngine.goldenHourFactor(forSolarElevation: elevation)
            #expect(factor >= 0 && factor <= 1, "out of range at \(elevation)°: \(factor)")
        }
    }

    @Test("Rises monotonically from the lower edge up to the horizon")
    func monotonicBelowHorizon() {
        var previous = -Double.infinity
        for elevation in stride(from: -8.0, through: 0.0, by: 0.25) {
            let factor = ThemeEngine.goldenHourFactor(forSolarElevation: elevation)
            #expect(factor >= previous, "not monotonic at \(elevation)°")
            previous = factor
        }
    }

    @Test("Falls monotonically from the horizon up to the upper edge")
    func monotonicAboveHorizon() {
        var previous = Double.infinity
        for elevation in stride(from: 0.0, through: 10.0, by: 0.25) {
            let factor = ThemeEngine.goldenHourFactor(forSolarElevation: elevation)
            #expect(factor <= previous, "not monotonic at \(elevation)°")
            previous = factor
        }
    }
}
