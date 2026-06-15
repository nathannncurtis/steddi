import SwiftUI
import CoreLocation
import Observation

// MARK: - Theme Domain Types

/// Weather reduced to exactly what theming needs. Produced by
/// WeatherKitService (or its heuristics fallback) — never WeatherKit types,
/// so the engine compiles and tests without the entitlement.
struct WeatherConditionSnapshot: Equatable {
    enum Kind: String, CaseIterable {
        case clear, partlyCloudy, overcast, fog, rain, snow, storm, unknown
    }

    var kind: Kind = .unknown
    var temperatureF: Double?
    var fetchedAt: Date?

    static let unknown = WeatherConditionSnapshot()
}

/// How a weather condition bends the theme.
struct WeatherThemeCoefficients: Equatable {
    /// 0 = no pull, 1 = fully grey. Overcast and fog pull toward the grey palette.
    var greyPull: Double = 0
    /// Shifts the dark↔light progress: negative darkens (storms), positive brightens (snow glare).
    var brightnessShift: Double = 0

    static let neutral = WeatherThemeCoefficients()
}

/// Local climate context for temperature tinting: 65°F reads warm in Anchorage
/// and cool in San Diego.
struct TemperatureNorm: Equatable {
    var typicalHighF: Double
    var typicalLowF: Double

    /// Continental-US average — last-resort fallback when no table row matches.
    static let nationalAverage = TemperatureNorm(typicalHighF: 65, typicalLowF: 45)
}

enum ThemeTransitionType: String, Equatable {
    case solar, weather, temperature, tunnel
}

/// Per-layer easing description. Solar drifts over the golden window; tunnel
/// entry is sharp (signal-loss feedback) while exit fades late.
struct ThemeTransitionCurve: Equatable {
    enum Easing { case linear, easeInOut, sharpIn, delayedOut }

    var duration: TimeInterval
    var easing: Easing
}

/// Immutable snapshot of the complete visual state at one moment.
/// ~200 bytes of value-type data; recomputed at most 1x/second.
struct ThemeState: Equatable {
    var surfacePrimary: RGBColor
    var surfaceSecondary: RGBColor
    var surfaceElevated: RGBColor
    var textPrimary: RGBColor
    var textSecondary: RGBColor
    var textMuted: RGBColor

    /// Temperature/golden-hour RGB offset already applied to the surfaces above.
    var warmthVector: SIMD3<Float> = .zero
    /// Normalized day progress: 0 = full night, 1 = full day. (Spec sketched a
    /// 0…0.5 noon scale; a plain 0…1 day fraction is the clearer contract.)
    var solarElevationNorm: Double = 0
    var weatherCondition: WeatherConditionSnapshot = .unknown
    var isTunnelDetected: Bool = false
    var tunnelTransitionProgress: Double = 0
    var interpolationProgress: Double = 0
    var activeTransition: ThemeTransitionType?
    /// True when the resolved surfaces are dark enough to want dark chrome.
    var prefersDarkChrome: Bool = true

    init(palette: ThemePalette) {
        surfacePrimary = palette.surfacePrimary
        surfaceSecondary = palette.surfaceSecondary
        surfaceElevated = palette.surfaceElevated
        textPrimary = palette.textPrimary
        textSecondary = palette.textSecondary
        textMuted = palette.textMuted
        prefersDarkChrome = palette.surfacePrimary.luminance < 0.5
    }
}

// MARK: - ThemeEngine

/// Central computation engine producing a continuous ThemeState from solar
/// elevation, weather, temperature, and tunnel signals. Singleton, same
/// pattern as the other global services. Environmental services push their
/// inputs in; the engine owns composition, cadence, and notification fan-out.
@Observable
@MainActor
final class ThemeEngine {
    static let shared = ThemeEngine()

    /// Nonisolated mirror of `currentState` for the SteddiTheme static facade,
    /// which is called from nonisolated contexts. Written only on the main
    /// actor; a torn read can at worst mix two adjacent 1Hz frames of color.
    nonisolated(unsafe) private(set) static var snapshot: ThemeState = ThemeEngine.bootstrapState()

    /// Monotonic counter bumped on every published state change. The app root
    /// mirrors this into the window's `ThemeRevisionTrait`, which forces every
    /// `Color(UIColor { ... })`-backed facade color in the hosted tree to
    /// re-resolve against the latest `snapshot` — the mechanism that carries a
    /// dynamic theme step into HomeView / the nav overlay without editing them.
    nonisolated(unsafe) private(set) static var revision: Int = 0

    private(set) var currentState: ThemeState

    var baseMode: ThemeModeEx {
        didSet {
            guard baseMode != oldValue else { return }
            UserDefaults.standard.set(baseMode.rawValue, forKey: ThemeModeEx.defaultsKey)
            ThemeModeEx.syncLegacyShadow(baseMode)
            updateThemeState()
            NotificationCenter.default.post(name: .steddiThemeModeChanged, object: nil)
        }
    }

    var dynamicComponents: DynamicThemeComponents {
        didSet {
            guard dynamicComponents != oldValue else { return }
            dynamicComponents.save()
            updateThemeState()
        }
    }

    var isGreyModeEnabled: Bool {
        get { dynamicComponents.greyMode }
        set { dynamicComponents.greyMode = newValue }
    }

    var isDynamicTheming: Bool { baseMode.isDynamic }

    // MARK: External inputs (pushed by environmental services)

    private(set) var weatherCondition: WeatherConditionSnapshot = .unknown
    private(set) var weatherCoefficients: WeatherThemeCoefficients = .neutral
    private(set) var currentTemperatureF: Double?
    private(set) var localNorm: TemperatureNorm?
    private(set) var tunnelTransitionProgress: Double = 0
    private(set) var isTunnelDetected = false

    private var updateTimer: Timer?
    /// Cadence the live `updateTimer` was scheduled at. Lets `scheduleNextUpdate`
    /// coalesce rapid successive calls: if the required interval is unchanged and
    /// a timer is already pending, we leave it running instead of thrashing
    /// invalidate/recreate on every input update.
    private var scheduledInterval: TimeInterval?
    private let locationProvider: () -> CLLocationCoordinate2D?
    private let now: () -> Date
    private let normsProvider = LocalNormsProvider()

    init(
        locationProvider: (() -> CLLocationCoordinate2D?)? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        if let locationProvider {
            self.locationProvider = locationProvider
        } else {
            let manager = CLLocationManager()
            self.locationProvider = { manager.location?.coordinate }
        }
        self.now = now
        baseMode = ThemeModeEx.current()
        dynamicComponents = DynamicThemeComponents.load()
        currentState = ThemeState(palette: .dark)
        updateThemeState()
    }

    // MARK: - Input setters

    func setWeather(condition: WeatherConditionSnapshot, coefficients: WeatherThemeCoefficients) {
        guard condition != weatherCondition || coefficients != weatherCoefficients else { return }
        weatherCondition = condition
        weatherCoefficients = coefficients
        if let temp = condition.temperatureF { currentTemperatureF = temp }
        updateThemeState()
    }

    func setTemperature(currentF: Double?, norm: TemperatureNorm?) {
        guard currentF != currentTemperatureF || norm != localNorm else { return }
        currentTemperatureF = currentF
        localNorm = norm
        updateThemeState()
    }

    func setTunnel(progress: Double, isDetected: Bool) {
        let clamped = min(1, max(0, progress))
        guard clamped != tunnelTransitionProgress || isDetected != isTunnelDetected else { return }
        tunnelTransitionProgress = clamped
        isTunnelDetected = isDetected
        updateThemeState()
    }

    // MARK: - State computation

    /// Recompute the current state from all sources, publish it, and schedule
    /// the next periodic update at the appropriate cadence.
    func updateThemeState() {
        let coordinate = locationProvider()
        let timestamp = now()
        let elevation = coordinate.map { Self.computeSolarElevation(at: $0, timestamp: timestamp) }

        let newState = Self.composeState(
            mode: baseMode,
            components: dynamicComponents,
            solarElevation: elevation,
            fallbackHour: Self.fractionalHour(of: timestamp),
            weatherCondition: weatherCondition,
            weatherCoefficients: weatherCoefficients,
            temperatureF: currentTemperatureF,
            localNorm: localNorm ?? coordinate.map { normsProvider.getNormForToday(at: $0) },
            tunnelProgress: tunnelTransitionProgress,
            isTunnelDetected: isTunnelDetected
        )

        if newState != currentState {
            let chromeFlipped = newState.prefersDarkChrome != currentState.prefersDarkChrome
            currentState = newState
            Self.snapshot = newState
            Self.revision &+= 1
            NotificationCenter.default.post(name: .steddiDynamicThemeUpdated, object: nil)
            if chromeFlipped {
                // Map surfaces re-resolve SteddiTheme.currentThemeMode on this
                // existing notification — repost so dynamic day/night flips
                // reach them without any map-file changes.
                NotificationCenter.default.post(name: .steddiThemeModeChanged, object: nil)
            }
        }

        scheduleNextUpdate(solarElevation: elevation)
    }

    /// Pure composition of a ThemeState from explicit inputs. Nonisolated and
    /// side-effect free so blending behavior is directly unit-testable.
    nonisolated static func composeState(
        mode: ThemeModeEx,
        components: DynamicThemeComponents,
        solarElevation: Double?,
        fallbackHour: Double,
        weatherCondition: WeatherConditionSnapshot = .unknown,
        weatherCoefficients: WeatherThemeCoefficients = .neutral,
        temperatureF: Double? = nil,
        localNorm: TemperatureNorm? = nil,
        tunnelProgress: Double = 0,
        isTunnelDetected: Bool = false
    ) -> ThemeState {
        let dayProgress: Double
        if let solarElevation {
            dayProgress = Self.dayProgress(forSolarElevation: solarElevation)
        } else {
            dayProgress = Self.fallbackDayProgress(forHour: fallbackHour)
        }

        // 1. Base dark↔light progress per mode.
        var progress: Double
        var throughGrey = false
        switch mode {
        case .dark:
            progress = 0
        case .light:
            progress = 1
        case .grey:
            progress = 0.5
            throughGrey = true
        case .dynamic:
            progress = components.solarCycle ? dayProgress : (dayProgress >= 0.5 ? 1 : 0)
            throughGrey = components.greyMode
        }

        // 2. Weather layer (dynamic mode only): brightness shift plus grey pull.
        var greyPull: Double = 0
        if mode == .dynamic && components.weatherResponse {
            progress = min(1, max(0, progress + weatherCoefficients.brightnessShift))
            greyPull = min(1, max(0, weatherCoefficients.greyPull))
        }

        var palette = ThemePalette.blend(progress: progress, throughGrey: throughGrey)
        if greyPull > 0 {
            palette = ThemePalette.lerp(palette, .grey, greyPull)
        }

        // 3. Tunnel layer: highest priority — pull hard toward dark on entry.
        let effectiveTunnel = (mode == .dynamic && components.tunnelDetection) ? min(1, max(0, tunnelProgress)) : 0
        if effectiveTunnel > 0 {
            palette = ThemePalette.lerp(palette, .dark, effectiveTunnel)
        }

        // 4. Warmth: golden-hour glow (solar layer) + deviation vs local norms
        //    (temperature layer). Surfaces only — text keeps full contrast.
        var warmth: Double = 0
        if mode == .dynamic && components.solarCycle, let solarElevation {
            warmth += Tuning.goldenHourWarmth * goldenHourFactor(forSolarElevation: solarElevation)
        }
        if mode == .dynamic && components.temperatureTinting,
           let temperatureF, let localNorm {
            warmth += Tuning.temperatureWarmth * temperatureWarmth(temperatureF: temperatureF, norm: localNorm)
        }
        // Tunnels mute warmth along with everything else.
        warmth *= (1 - effectiveTunnel)
        let warmthVector = Self.warmthVector(for: warmth)
        if warmthVector != .zero {
            palette.surfacePrimary = palette.surfacePrimary.offset(by: warmthVector)
            palette.surfaceSecondary = palette.surfaceSecondary.offset(by: warmthVector)
            palette.surfaceElevated = palette.surfaceElevated.offset(by: warmthVector)
        }

        var state = ThemeState(palette: palette)
        state.warmthVector = warmthVector
        state.solarElevationNorm = dayProgress
        state.weatherCondition = weatherCondition
        state.isTunnelDetected = isTunnelDetected
        state.tunnelTransitionProgress = effectiveTunnel

        // Active transition, by priority: tunnel > solar.
        if effectiveTunnel > 0 && effectiveTunnel < 1 {
            state.activeTransition = .tunnel
            state.interpolationProgress = effectiveTunnel
        } else if mode == .dynamic && components.solarCycle && dayProgress > 0 && dayProgress < 1 {
            state.activeTransition = .solar
            state.interpolationProgress = dayProgress
        }
        return state
    }

    // MARK: - Solar math

    /// Continuous solar elevation in degrees (-90…+90). Same declination and
    /// solar-time model as `ThemeMode.sunIsUp` — `elevation > 0` agrees with
    /// the legacy binary answer — extended through the full elevation formula:
    /// sin(el) = sin(lat)·sin(dec) + cos(lat)·cos(dec)·cos(hourAngle).
    nonisolated static func computeSolarElevation(
        at coordinate: CLLocationCoordinate2D,
        timestamp: Date
    ) -> Double {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .gmt

        let dayOfYear = Double(utcCal.ordinality(of: .day, in: .year, for: timestamp) ?? 1)
        let declination = -23.44 * cos(2.0 * .pi / 365.0 * (dayOfYear + 10))

        let latRad = coordinate.latitude * .pi / 180
        let decRad = declination * .pi / 180

        let utcHour = Double(utcCal.component(.hour, from: timestamp))
            + Double(utcCal.component(.minute, from: timestamp)) / 60.0
            + Double(utcCal.component(.second, from: timestamp)) / 3600.0
        var localSolarHour = (utcHour + coordinate.longitude / 15.0).truncatingRemainder(dividingBy: 24.0)
        if localSolarHour < 0 { localSolarHour += 24.0 }

        let hourAngleRad = (localSolarHour - 12.0) * 15.0 * .pi / 180.0
        let sinElevation = sin(latRad) * sin(decRad) + cos(latRad) * cos(decRad) * cos(hourAngleRad)
        return asin(min(1, max(-1, sinElevation))) * 180.0 / .pi
    }

    /// Map solar elevation onto 0…1 day progress with a smooth twilight band.
    /// The band (civil twilight −6° up to +4°) spans roughly 45 minutes of sun
    /// travel at mid latitudes — the spec's sunrise/sunset transition window.
    nonisolated static func dayProgress(forSolarElevation elevation: Double) -> Double {
        smoothstep(elevation, from: Tuning.nightElevation, to: Tuning.dayElevation)
    }

    /// Golden-hour warmth factor in [0, 1]: peaks (1) at the horizon, fades to
    /// zero by +10° (sun well clear) and at/below −8° (dusk has settled),
    /// monotonic and continuous in between.
    ///
    /// The negative branch was both unbounded *and* inverted: the old
    /// `1 + elevation / -goldenLowerElevation` divides by −8, so it rose with
    /// depth instead of falling (2.0 at −8°, 2.25 at −10° — backwards and out of
    /// range). Dividing by +goldenLowerElevation gives the intended ramp —
    /// 1 at the horizon down to 0 at −8° — and clamping pins everything to [0, 1]
    /// so deeper twilight stays at 0.
    nonisolated static func goldenHourFactor(forSolarElevation elevation: Double) -> Double {
        let factor: Double
        if elevation >= 0 {
            factor = 1 - elevation / Tuning.goldenUpperElevation
        } else {
            factor = 1 + elevation / Tuning.goldenLowerElevation
        }
        return min(1, max(0, factor))
    }

    /// No-location fallback: 7am–7pm daytime with 45-minute ramps at each edge.
    nonisolated static func fallbackDayProgress(forHour hour: Double) -> Double {
        let ramp = 0.75 // 45 minutes
        let rise = smoothstep(hour, from: 7.0 - ramp / 2, to: 7.0 + ramp / 2)
        let set = smoothstep(hour, from: 19.0 - ramp / 2, to: 19.0 + ramp / 2)
        return rise * (1 - set)
    }

    nonisolated static func smoothstep(_ x: Double, from edge0: Double, to edge1: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    nonisolated static func fractionalHour(of date: Date) -> Double {
        let cal = Calendar.current
        return Double(cal.component(.hour, from: date))
            + Double(cal.component(.minute, from: date)) / 60.0
    }

    // MARK: - Warmth math

    /// Signed warmth (−1 cool … +1 warm) of a temperature relative to the
    /// local norm band: 0 at the high/low midpoint, ±1 one full band out.
    nonisolated static func temperatureWarmth(temperatureF: Double, norm: TemperatureNorm) -> Double {
        let mid = (norm.typicalHighF + norm.typicalLowF) / 2
        let halfBand = max(5, (norm.typicalHighF - norm.typicalLowF) / 2)
        return min(1, max(-1, (temperatureF - mid) / (halfBand * 2)))
    }

    /// RGB offset for a signed warmth value. Warm pushes red up / blue down;
    /// cool does the inverse. Magnitudes stay subtle by construction.
    nonisolated static func warmthVector(for warmth: Double) -> SIMD3<Float> {
        let w = Float(min(1, max(-1, warmth)))
        guard w != 0 else { return .zero }
        return SIMD3<Float>(0.040 * w, 0.008 * w, -0.035 * w)
    }

    /// Spec-shaped convenience over the warmth pipeline.
    nonisolated static func applyWarmthTint(
        baseColor: RGBColor,
        temperatureF: Double,
        localNorm: TemperatureNorm
    ) -> RGBColor {
        let warmth = Tuning.temperatureWarmth * temperatureWarmth(temperatureF: temperatureF, norm: localNorm)
        return baseColor.offset(by: warmthVector(for: warmth))
    }

    // MARK: - Transition curves

    nonisolated static func resolveTransitionCurve(for type: ThemeTransitionType) -> ThemeTransitionCurve {
        switch type {
        case .solar:
            return ThemeTransitionCurve(duration: 45 * 60, easing: .easeInOut)
        case .weather:
            return ThemeTransitionCurve(duration: 8, easing: .easeInOut)
        case .temperature:
            return ThemeTransitionCurve(duration: 12, easing: .linear)
        case .tunnel:
            // Entry ramp; exit timing (delayed fade) lives in TunnelDetectionService.
            return ThemeTransitionCurve(duration: 1, easing: .sharpIn)
        }
    }

    // MARK: - Cadence

    /// Adaptive cadence: 1s while a transition animates, 10s inside the solar
    /// twilight band, 5min otherwise. Nothing here allocates per frame.
    private func scheduleNextUpdate(solarElevation: Double?) {
        let interval: TimeInterval
        if currentState.activeTransition == .tunnel {
            interval = 1
        } else if isDynamicTheming, dynamicComponents.solarCycle,
                  let solarElevation,
                  solarElevation > Tuning.nightElevation - 2,
                  solarElevation < Tuning.dayElevation + 2 {
            interval = 10
        } else {
            interval = 300
        }

        // Coalesce: when the cadence is unchanged and a timer is already pending,
        // let the in-flight timer keep running rather than invalidating and
        // recreating it on every rapid input update. Only reschedule when the
        // required interval actually changes (e.g. entering/leaving the tunnel
        // or twilight band) or no timer is live.
        if let existing = updateTimer, existing.isValid, scheduledInterval == interval {
            return
        }

        updateTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            Task { @MainActor in
                ThemeEngine.shared.updateThemeState()
            }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
        scheduledInterval = interval
    }

    // MARK: - Bootstrap

    /// Initial facade snapshot before the engine spins up: resolve the stored
    /// mode against the time-of-day fallback so first paint is already right.
    nonisolated private static func bootstrapState() -> ThemeState {
        composeState(
            mode: ThemeModeEx.current(),
            components: DynamicThemeComponents.load(),
            solarElevation: nil,
            fallbackHour: fractionalHour(of: Date())
        )
    }

    private enum Tuning {
        /// Twilight band: full night at −6° (end of civil twilight), full day at +4°.
        static let nightElevation: Double = -6
        static let dayElevation: Double = 4
        static let goldenUpperElevation: Double = 10
        static let goldenLowerElevation: Double = 8
        /// Peak surface warmth contributed by golden hour / temperature deviation.
        static let goldenHourWarmth: Double = 0.8
        static let temperatureWarmth: Double = 0.6
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Fires whenever the dynamic ThemeState changes (at most ~1Hz).
    static let steddiDynamicThemeUpdated = Notification.Name("steddiDynamicThemeUpdated")
}
