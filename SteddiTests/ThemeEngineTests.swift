import Testing
import Foundation
import CoreLocation
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

// MARK: - Location-driven solar theming (vs the no-location 7am–7pm fallback)

/// `ThemeEngine.shared` previously got no working location provider, so dynamic
/// solar theming silently degraded to a fixed 7am–7pm clock and golden-hour
/// warmth never fired. These verify that WHEN a real coordinate is provided the
/// solar pipeline engages: the day-progress is the accurate solar value (not the
/// crude hour ramp) and golden-hour warmth is produced — neither of which the
/// location-less fallback path can do.
@Suite("ThemeEngine solar theming with a provided location")
struct ThemeEngineSolarTests {

    /// Equator / prime-meridian on the June solstice at 06:00 UTC: the sun sits
    /// exactly on the horizon (local solar hour 12 ± ... actually 06:00 → sunrise),
    /// elevation ≈ 0°, which is the peak of the golden-hour band.
    private static let equator = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    private static func solsticeSunrise() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 6))!
    }

    @Test("Provided location yields solar elevation ≈ horizon, far from the fallback hours")
    func solarElevationFromLocation() {
        let elevation = ThemeEngine.computeSolarElevation(at: Self.equator, timestamp: Self.solsticeSunrise())
        // Sun on the horizon at this instant — solar, not the 7am/7pm clock.
        #expect(abs(elevation) < 1.0, "expected near-horizon elevation, got \(elevation)")
    }

    @Test("Solar day-progress differs from the fixed 7am–7pm fallback at the same instant")
    func solarDayProgressDiffersFromFallback() {
        let elevation = ThemeEngine.computeSolarElevation(at: Self.equator, timestamp: Self.solsticeSunrise())
        let solarProgress = ThemeEngine.dayProgress(forSolarElevation: elevation)

        // The fallback maps 06:00 (just before the 7am ramp) to ~full night (≈0),
        // while the real sun is on the horizon mid-twilight (≈0.65). They must
        // genuinely diverge — proving the engine uses the solar value, not the clock.
        let fallbackProgress = ThemeEngine.fallbackDayProgress(forHour: 6.0)
        #expect(abs(solarProgress - fallbackProgress) > 0.2,
                "solar \(solarProgress) should differ from 7-7 fallback \(fallbackProgress)")
    }

    @Test("Golden-hour warmth fires from a provided solar elevation but never from the fallback")
    func goldenHourWarmthGatedOnSolar() {
        let elevation = ThemeEngine.computeSolarElevation(at: Self.equator, timestamp: Self.solsticeSunrise())
        var components = DynamicThemeComponents()
        components.solarCycle = true

        // With a real solar elevation, golden-hour warmth engages.
        let withSolar = ThemeEngine.composeState(
            mode: .dynamic, components: components,
            solarElevation: elevation, fallbackHour: 6.0
        )
        #expect(withSolar.warmthVector != .zero, "golden-hour warmth should fire at the horizon")

        // The location-less fallback path (nil solar elevation) can NEVER produce
        // golden-hour warmth — the exact degradation the missing provider caused.
        let withoutSolar = ThemeEngine.composeState(
            mode: .dynamic, components: components,
            solarElevation: nil, fallbackHour: 6.0
        )
        #expect(withoutSolar.warmthVector == .zero, "fallback must not produce golden-hour warmth")
    }

    @Test("Engine built with a location provider feeds the solar value into its published state")
    @MainActor
    func engineWiresProvidedLocation() {
        // An engine GIVEN a location provider must compute solar-derived state and
        // golden-hour warmth — the regression was the shared singleton getting no
        // working provider at all.
        let engine = ThemeEngine(
            locationProvider: { Self.equator },
            now: { Self.solsticeSunrise() }
        )
        engine.baseMode = .dynamic
        var components = DynamicThemeComponents()
        components.solarCycle = true
        engine.dynamicComponents = components

        // Solar pipeline engaged: horizon sun => active solar transition + warmth.
        #expect(engine.currentState.warmthVector != .zero,
                "wired location should drive golden-hour warmth")
        #expect(engine.currentState.solarElevationNorm > 0.0 && engine.currentState.solarElevationNorm < 1.0,
                "twilight day-progress should be mid-range, got \(engine.currentState.solarElevationNorm)")
    }

    @Test("Engine with no location available still falls back to the clock (no warmth)")
    @MainActor
    func engineFallsBackWhenNoLocation() {
        // Genuinely no location: provider returns nil. The clock fallback must
        // still work — we keep it ONLY for the no-location case.
        let engine = ThemeEngine(
            locationProvider: { nil },
            now: { Self.solsticeSunrise() }
        )
        engine.baseMode = .dynamic
        var components = DynamicThemeComponents()
        components.solarCycle = true
        engine.dynamicComponents = components

        #expect(engine.currentState.warmthVector == .zero,
                "no location => no solar elevation => no golden-hour warmth")
    }
}
