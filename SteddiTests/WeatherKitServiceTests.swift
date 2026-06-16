import Testing
import Foundation
import CoreLocation
#if canImport(WeatherKit)
import WeatherKit
#endif
@testable import Steddi

// MARK: - Helpers

private let testLocation = CLLocation(latitude: 33.0, longitude: -117.0)

/// A non-entitlement transient error, the kind a momentary network blip or a
/// WeatherKit backend hiccup surfaces.
private func transientError() -> Error {
    URLError(.timedOut)
}

/// A WeatherKit auth/entitlement URLError (auth required), which IS permanent.
private func authURLError() -> Error {
    NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired)
}

/// The WeatherDaemon JWT authenticator domain error — a genuine entitlement
/// failure surfaced by the WeatherKit auth pipeline.
private func jwtAuthError() -> Error {
    NSError(domain: "WeatherDaemon.WDSJWTAuthenticatorServiceListener.Errors", code: 1)
}

// MARK: - isEntitlementFailure classification

@Suite("WeatherKitService.isEntitlementFailure")
struct WeatherKitEntitlementClassificationTests {

    @Test("Transient URLError is NOT an entitlement failure")
    func transientURLErrorIsTransient() {
        #expect(WeatherKitService.isEntitlementFailure(transientError()) == false)
    }

    #if canImport(WeatherKit)
    @Test("WeatherError.unknown is NOT an entitlement failure (transient catch-all)")
    func weatherErrorUnknownIsTransient() {
        #expect(WeatherKitService.isEntitlementFailure(WeatherError.unknown) == false)
    }

    @Test("WeatherError.permissionDenied IS an entitlement failure")
    func weatherErrorPermissionDeniedIsEntitlement() {
        #expect(WeatherKitService.isEntitlementFailure(WeatherError.permissionDenied) == true)
    }
    #endif

    @Test("Auth-required URLError IS an entitlement failure")
    func authURLErrorIsEntitlement() {
        #expect(WeatherKitService.isEntitlementFailure(authURLError()) == true)
    }

    @Test("JWT authenticator domain error IS an entitlement failure")
    func jwtErrorIsEntitlement() {
        #expect(WeatherKitService.isEntitlementFailure(jwtAuthError()) == true)
    }
}

// MARK: - refresh() availability behavior

@Suite("WeatherKitService refresh availability")
@MainActor
struct WeatherKitRefreshAvailabilityTests {

    /// Build a service whose provider always throws `error`, with theming
    /// applications routed to a no-op so we observe only availability state.
    private func makeService(throwing error: Error, now: @escaping () -> Date) -> WeatherKitService {
        WeatherKitService(
            provider: { _ in throw error },
            now: now,
            apply: { _, _ in }
        )
    }

    @Test("A transient error does NOT arm the 6-hour disable")
    func transientErrorKeepsServiceAvailable() async {
        let service = makeService(throwing: transientError(), now: { Date() })
        #expect(service.isAvailable)

        await service.refresh(at: testLocation)

        // The blip degraded this one cycle to heuristics but must leave the
        // service available so the very next refresh tries WeatherKit again.
        #expect(service.isAvailable)
    }

    #if canImport(WeatherKit)
    @Test("WeatherError.unknown does NOT arm the 6-hour disable")
    func weatherErrorUnknownKeepsServiceAvailable() async {
        let service = makeService(throwing: WeatherError.unknown, now: { Date() })
        await service.refresh(at: testLocation)
        #expect(service.isAvailable)
    }

    @Test("An entitlement failure arms the disable")
    func entitlementFailureDisablesService() async {
        let service = makeService(throwing: WeatherError.permissionDenied, now: { Date() })
        #expect(service.isAvailable)

        await service.refresh(at: testLocation)

        // A genuine entitlement failure is the only thing that should disable
        // WeatherKit and arm the long backoff.
        #expect(service.isAvailable == false)
    }
    #endif

    @Test("An auth-required failure arms the disable")
    func authFailureDisablesService() async {
        let service = makeService(throwing: authURLError(), now: { Date() })
        await service.refresh(at: testLocation)
        #expect(service.isAvailable == false)
    }
}

// MARK: - refresh() drives the ThemeEngine weather + temperature layers

/// The weather and temperature theme layers were inert: nothing fed
/// `WeatherKitService.refresh()` output into `ThemeEngine`, so the weather grey
/// pull / brightness shift and the temperature warmth never moved. These verify
/// the wired path — a fresh observation drives BOTH layers through the same
/// setters production uses (`setWeather` + `setTemperature`) — and that a fixed
/// (non-dynamic) theme suppresses the effect even when the inputs land.
@Suite("WeatherKitService refresh drives ThemeEngine")
@MainActor
struct WeatherKitDrivesThemeTests {

    /// San Diego in summer — a hot 95°F reading sits well above the local norm,
    /// so temperature tinting must push the surfaces warm.
    private static let location = CLLocation(latitude: 32.7, longitude: -117.2)
    private static func summerNoon() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 20))!
    }

    /// Build a dynamic-theming engine with the weather + temperature layers on,
    /// and a WeatherKitService whose apply closure routes into it exactly as the
    /// production default closure routes into `ThemeEngine.shared`.
    private func makeEngine(mode: ThemeModeEx) -> ThemeEngine {
        let engine = ThemeEngine(
            locationProvider: { Self.location.coordinate },
            now: { Self.summerNoon() }
        )
        engine.baseMode = mode
        var components = DynamicThemeComponents()
        components.weatherResponse = true
        components.temperatureTinting = true
        // Isolate the weather/temperature layers from solar golden-hour warmth so
        // a changed warmth vector is unambiguously the temperature layer's doing.
        components.solarCycle = false
        engine.dynamicComponents = components
        return engine
    }

    /// The VISIBLE look of a state: surfaces, warmth, and chrome — everything
    /// the user actually sees. Deliberately excludes the informational
    /// `weatherCondition`/`fetchedAt` tags, which `composeState` records on the
    /// state regardless of mode (so a fixed theme can stamp the latest reading
    /// without it ever touching the rendered palette). Comparing this proves the
    /// LOOK is unchanged even when the condition tag advances.
    private func visibleLook(_ state: ThemeState) -> [RGBColor] {
        [state.surfacePrimary, state.surfaceSecondary, state.surfaceElevated,
         state.textPrimary, state.textSecondary, state.textMuted]
    }

    private func makeService(
        condition: WeatherConditionSnapshot,
        into engine: ThemeEngine
    ) -> WeatherKitService {
        WeatherKitService(
            provider: { _ in condition },
            now: { Self.summerNoon() },
            apply: { snapshot, coefficients in
                engine.setWeather(condition: snapshot, coefficients: coefficients)
                engine.setTemperature(currentF: snapshot.temperatureF, norm: nil)
            }
        )
    }

    @Test("A rain + hot observation moves the dynamic theme's weather and temperature state")
    func refreshDrivesDynamicTheme() async {
        let engine = makeEngine(mode: .dynamic)
        let baselineWarmth = engine.currentState.warmthVector
        let baselineCondition = engine.weatherCondition

        let observation = WeatherConditionSnapshot(
            kind: .rain, temperatureF: 95, fetchedAt: Self.summerNoon()
        )
        let service = makeService(condition: observation, into: engine)
        await service.refresh(at: Self.location)

        // Weather layer engaged: the engine now holds the rain condition and its
        // grey-pull / brightness-shift coefficients (rain pulls grey + darkens).
        #expect(engine.weatherCondition.kind == .rain)
        #expect(engine.weatherCondition != baselineCondition)
        #expect(engine.weatherCoefficients.greyPull > 0)
        #expect(engine.weatherCoefficients.brightnessShift < 0)

        // Temperature layer engaged: 95°F drove a temperature into the engine and
        // the warm reading shifted the surfaces (warmth vector changed).
        #expect(engine.currentTemperatureF == 95)
        #expect(engine.currentState.warmthVector != baselineWarmth,
                "a hot reading should warm the surfaces vs the no-weather baseline")
    }

    @Test("Clear vs rain produce different theme states through the refresh path")
    func differentConditionsMoveDifferently() async {
        let clearEngine = makeEngine(mode: .dynamic)
        await makeService(
            condition: WeatherConditionSnapshot(kind: .clear, temperatureF: 70, fetchedAt: Self.summerNoon()),
            into: clearEngine
        ).refresh(at: Self.location)

        let rainEngine = makeEngine(mode: .dynamic)
        await makeService(
            condition: WeatherConditionSnapshot(kind: .rain, temperatureF: 70, fetchedAt: Self.summerNoon()),
            into: rainEngine
        ).refresh(at: Self.location)

        // Rain pulls grey + darkens; clear is neutral. The published surfaces
        // must differ — proof the weather layer actually reaches the look.
        #expect(clearEngine.currentState != rainEngine.currentState)
        #expect(clearEngine.weatherCoefficients.greyPull == 0)
        #expect(rainEngine.weatherCoefficients.greyPull > 0)
    }

    @Test("A fixed (non-dynamic) theme ignores the weather + temperature inputs")
    func fixedThemeSuppressesWeatherAndTemperature() async {
        // Same hot-rain observation, but the user chose a FIXED Dark theme — the
        // weather/temperature layers must NOT alter the look, even though the
        // inputs still land in the engine. This is the user's explicit choice;
        // dynamic-only layers must respect it.
        let fixedEngine = makeEngine(mode: .dark)
        let fixedBaseline = fixedEngine.currentState

        let observation = WeatherConditionSnapshot(
            kind: .rain, temperatureF: 95, fetchedAt: Self.summerNoon()
        )
        await makeService(condition: observation, into: fixedEngine).refresh(at: Self.location)

        // Inputs landed (the setters ran)...
        #expect(fixedEngine.weatherCondition.kind == .rain)
        #expect(fixedEngine.currentTemperatureF == 95)
        // ...but the published LOOK is the fixed Dark palette unchanged: no grey
        // pull, no brightness shift, no warmth. The fixed theme is honored. (The
        // state's weatherCondition tag advances regardless — it is informational
        // and never reaches the rendered palette in a fixed mode.)
        #expect(visibleLook(fixedEngine.currentState) == visibleLook(fixedBaseline))
        #expect(fixedEngine.currentState.warmthVector == .zero)
    }

    @Test("Disabling the weatherResponse / temperatureTinting toggles suppresses the layers")
    func disabledTogglesSuppressLayers() async {
        let engine = ThemeEngine(
            locationProvider: { Self.location.coordinate },
            now: { Self.summerNoon() }
        )
        engine.baseMode = .dynamic
        var components = DynamicThemeComponents()
        components.weatherResponse = false
        components.temperatureTinting = false
        components.solarCycle = false // isolate: no solar warmth either
        engine.dynamicComponents = components
        let baseline = engine.currentState

        let observation = WeatherConditionSnapshot(
            kind: .rain, temperatureF: 95, fetchedAt: Self.summerNoon()
        )
        await makeService(condition: observation, into: engine).refresh(at: Self.location)

        // Both per-layer toggles are off, so even in dynamic mode the LOOK must
        // not move — the engine honors the user's component preferences. (The
        // informational weatherCondition tag still advances; the rendered
        // surfaces/warmth do not.)
        #expect(visibleLook(engine.currentState) == visibleLook(baseline))
        #expect(engine.currentState.warmthVector == .zero)
    }
}
