import Foundation
import MapKit
import CoreLocation
import Observation

/// A single navigation step — Steddi's own type, independent of MKRoute.Step.
struct NavStep {
    let instruction: String
    let distance: Double // meters
    let coordinate: CLLocationCoordinate2D // where this step begins
    let maneuverSymbol: String
}

/// Snapshot of the moment a deviation is confirmed — everything the recovery
/// pipeline needs to pick a forward rejoin target without re-deriving state.
/// Fired once per deviation episode; cleared when the driver returns within
/// the route corridor.
struct OffRouteEvent {
    /// Raw GPS coordinate of the confirming fix.
    let coordinate: CLLocationCoordinate2D
    /// Raw GPS course of the confirming fix, pre-smoothing — nil when the fix
    /// reports an invalid course. Never the engine's low-passed bearing.
    let courseDegrees: Double?
    /// Ground speed of the confirming fix in meters per second (>= 0).
    let speedMPS: Double
    /// Arc-length position on the active route at the confirming fix.
    let distanceAlongRoute: Double
    /// Engine step index when the deviation was confirmed.
    let currentStepIndex: Int
}

/// Pure decision for when the off-route recovery budget should reset.
///
/// The cap (`RouteRecoveryEngine.choose` abandons to destination once
/// `recoveriesThisTrip >= 3`) is meant to hold across a WHOLE trip, not per
/// leg. A multi-stop trip starts each leg through the same `begin*` navigation
/// machinery, so resetting inside `begin*` unconditionally would re-arm the
/// budget on every leg and defeat the cap. The rule:
///
/// - A standalone drive (no active trip) resets at its start.
/// - A trip resets exactly once, when the trip begins; subsequent legs
///   (which run with the trip already active) keep the running count.
enum RecoveryBudget {
    /// Whether a navigation session that is now starting should zero the
    /// per-trip recovery counter.
    ///
    /// - Parameter isContinuingTripLeg: true when this start is a leg of a
    ///   trip that is already underway (i.e. not the trip's first leg). Single
    ///   drives and the first leg of a trip pass `false`.
    static func shouldReset(isContinuingTripLeg: Bool) -> Bool {
        !isContinuingTripLeg
    }
}

/// Pure custom navigation engine. Works entirely from coordinates and steps.
/// MKRoute is just an input adapter — the engine never touches Apple routing internals.
@Observable
@MainActor
final class NavigationEngine {

    // MARK: - Public State

    var isNavigating: Bool = false
    var currentStepIndex: Int = 0
    var instruction: String = ""
    var stepDistance: String = ""
    var stepDistanceRaw: Double = 0
    var etaMinutes: Int = 0
    var etaSeconds: TimeInterval = 0
    var distanceRemaining: String = ""
    var distanceRemainingMeters: Double = 0
    var arrivalTime: String = ""
    var roadName: String = ""
    var maneuverType: String = "arrow.up"
    var followOnInstruction: String = ""
    var followOnManeuverSymbol: String = ""
    var currentSpeedMph: Double = 0
    var speedLimitMph: Double? = nil
    var speedLimitIsEstimated = false

    /// The enforcement camera currently being approached, for the overlay banner.
    /// Set when `checkSpeedCameraProximity` first detects a camera ahead, cleared
    /// once the driver passes it (no longer in range). Observable so the overlay
    /// re-renders; the one-shot tone/haptic/voice still flows through
    /// `onSpeedCameraApproaching` and is debounced separately.
    var approachingCamera: SpeedCameraAlert? = nil

    /// Injected position-based speed limit lookup (OSM-backed). Closure keeps
    /// the engine free of service dependencies and unit-testable.
    @ObservationIgnored
    var speedLimitProvider: ((CLLocationCoordinate2D, Double?) -> (mph: Double, isEstimated: Bool)?)? = nil

    /// Injected road-condition proximity lookup. Given the current snapped
    /// position it returns the highest-priority active condition within the
    /// alert range, or nil. Kept as a closure so the engine never imports the
    /// RoadConditionService — same decoupling as `speedLimitProvider`.
    ///
    /// Returns a `Sendable` `RoadConditionSnapshot`, NOT a `@Model RoadCondition`:
    /// this closure is retained for the entire drive and invoked every fix, so it
    /// must never dereference a model that a mid-drive delete may have invalidated.
    /// The wiring captures the conditions into snapshots at session start (see
    /// HomeView.wireRoadConditions), mirroring the reroute-loop's RerouteSnapshot.
    @ObservationIgnored
    var roadConditionProvider: ((CLLocationCoordinate2D) -> RoadConditionSnapshot?)? = nil
    /// Fired once when the engine first comes within range of a condition this
    /// session. The wiring side does the haptic + voice; the engine only owns
    /// the detection and debounce. Carries the `Sendable` snapshot so the wiring
    /// never re-touches a possibly-deleted `@Model` for the spoken heads-up.
    @ObservationIgnored
    var onRoadConditionApproaching: ((RoadConditionSnapshot) -> Void)? = nil
    /// Condition ids already announced this session, so passing a single pothole
    /// fires exactly one heads-up instead of one per fix while in range.
    private var alertedConditionIDs: Set<UUID> = []

    /// Injected speed-camera proximity lookup. Given the snapped position and
    /// travel bearing it returns the closest enforcement camera ahead within the
    /// alert range, or nil. A closure so the engine never imports
    /// SpeedCameraService — same decoupling as `speedLimitProvider`.
    @ObservationIgnored
    var speedCameraProvider: ((CLLocationCoordinate2D, Double?) -> SpeedCameraAlert?)? = nil
    /// Fired once per camera when the engine first comes within range this
    /// session. The wiring side does the tone/haptic + voice; the engine owns
    /// only the detection and debounce.
    @ObservationIgnored
    var onSpeedCameraApproaching: ((SpeedCameraAlert) -> Void)? = nil
    /// Camera alert ids already announced this session, so passing one camera
    /// fires exactly one heads-up instead of one per fix while in range.
    private var alertedCameraIDs: Set<String> = []
    /// Smoothed travel bearing. nil until the first valid bearing — never a
    /// due-north sentinel, and held (not reset) when no new bearing is available.
    var headingDegrees: Double? = nil
    var currentCoordinate: CLLocationCoordinate2D?
    var snappedCoordinate: CLLocationCoordinate2D?
    /// Unified projection of the latest GPS fix onto the route — the single
    /// source of truth for the puck, the camera, and the compass.
    var navPose: NavPose?
    var hasArrived: Bool = false

    /// Full route polyline for map rendering and position tracking.
    var routePolylineCoordinates: [CLLocationCoordinate2D] = []

    // MARK: - Private State

    /// Active steps — read-only outside so the recovery pipeline can classify
    /// and splice them; only the engine mutates.
    private(set) var steps: [NavStep] = []
    /// Arc-length position of each step's start along the route polyline,
    /// parallel to `steps`. Lets step advancement compare the projected
    /// distance-along-route against each step boundary in O(1) — so a single
    /// fix can advance past several completed steps (sparse GPS, a tunnel exit,
    /// or clustered recovery-splice steps) instead of being capped at one step
    /// per fix. nil entries mark steps whose start couldn't be projected.
    private var stepAlongDistances: [Double?] = []
    private var projector: RouteProjector?
    private(set) var totalRouteDistance: Double = 0
    private(set) var originalExpectedTravelTime: TimeInterval = 0
    /// Exponentially-weighted moving average of recent moving speed (m/s),
    /// driving the live ETA. An EWMA (vs. a cumulative all-samples mean) lets
    /// recent conditions dominate: after a long fast highway stretch, hitting
    /// stop-and-go pulls the estimate down within a minute or two so the ETA
    /// stops under-estimating time through the jam (and vice-versa). 0 until the
    /// first moving sample seeds it.
    private var averageSpeedMPS: Double = 0
    private var speedSampleCount: Int = 0
    /// EWMA smoothing factor per moving fix (~1Hz feed). ~0.05 gives an
    /// effective window of ~20 fixes (~20s) — responsive to a sustained change
    /// while still ignoring single-fix GPS speed jitter, so the ETA tracks
    /// recent conditions without wild swings.
    private let speedEWMAAlpha: Double = 0.05
    /// Plausible upper bound on a real driving speed (m/s ≈ 134 mph). CoreLocation
    /// BestForNavigation occasionally reports tens of m/s on the very first fixes,
    /// at tunnel exits, or in urban canyons (multipath). Every per-fix speed is
    /// clamped to this ceiling before it touches the EWMA so a wild reading can
    /// neither seed nor yank the live ETA toward an absurd value.
    private let maxPlausibleSpeedMPS: Double = 60
    /// The first few clamped moving fixes are buffered (not used directly) and the
    /// EWMA is seeded from their MEDIAN once `seedFixCount` have arrived — so a
    /// lone GPS spike on the first moving fix can't anchor the average and collapse
    /// the ETA for the ~20s the EWMA needs to decay. A sustained crawl still seeds
    /// low (all buffered samples are low → low median), preserving stop-and-go
    /// behavior. Until seeded, the free-flow fraction (the safer estimate) drives
    /// the ETA.
    private var seedSpeedBuffer: [Double] = []
    private let seedFixCount: Int = 3
    private var locationUpdateCount: Int = 0

    // Thresholds
    private let stepTransitionDistance: CLLocationDistance = 40
    private let arrivalDistance: CLLocationDistance = 50
    private let offRouteDistance: CLLocationDistance = 80
    private var offRouteCount: Int = 0
    private let offRouteThreshold: Int = 5
    private let offRouteGracePeriod: Int = 10
    /// Projected arc-length position at the previous fix — lets off-route
    /// detection recognise a clear forward jump along the corridor (sparse GPS /
    /// tunnel exit covering multiple steps in one fix) and NOT mis-count it as a
    /// deviation just because a single fix's perpendicular distance spiked.
    private var lastOffRouteAlongDistance: Double?
    /// A single-fix forward jump beyond this (meters) is unambiguous on-route
    /// progress, so any transient perpendicular spike on that fix is discounted.
    private let offRouteForwardProgressMeters: Double = 60
    /// Identifies the active navigation session so the async saved-ETA sanity
    /// check can't apply a stale result to a newer route.
    private var navigationToken = UUID()
    /// Saved durations beyond this multiple of a direct estimate are treated
    /// as corrupted (legacy chained-leg planner inflation).
    nonisolated static let savedETAInflationBound: Double = 1.4
    /// In-recovery latch: set when an off-route event fires, cleared when a
    /// fix projects back within the corridor or navigation (re)starts. While
    /// latched, no further events fire and guidance holds instead of churning.
    private var isRecoveringOffRoute = false
    /// Low-pass factor per ~1Hz fix for the published bearing.
    private let headingSmoothingFactor: Double = 0.35
    /// GPS course is only trusted above this ground speed (m/s).
    private let courseMinimumSpeedMPS: Double = 2.5

    /// Fires ONCE per deviation episode when the user goes off-route.
    var onOffRoute: ((OffRouteEvent) -> Void)?

    // MARK: - Start from saved polyline (primary path)

    /// Start navigation from a polyline with custom steps.
    /// This is the core path — everything flows through here.
    ///
    /// - Parameter preservingAlerts: when `true`, the per-session alert debounce
    ///   sets (`alertedCameraIDs` / `alertedConditionIDs`) are CARRIED OVER
    ///   instead of cleared. Use this for an in-place mid-drive restart onto
    ///   continued geometry — a recovery splice or Apple-route reroute — where
    ///   the driver is the same session and has already physically passed (and
    ///   been warned about) cameras/conditions that may still fall inside the
    ///   new combined corridor near the restart origin. Wiping the sets there
    ///   would re-chime an already-passed alert. A brand-new drive passes the
    ///   default `false`, which resets the one-shot-per-session guarantee.
    func startNavigation(
        polyline: [CLLocationCoordinate2D],
        steps: [NavStep],
        expectedTravelTime: TimeInterval? = nil,
        preservingAlerts: Bool = false
    ) {
        self.steps = steps
        currentStepIndex = 0
        isNavigating = true
        hasArrived = false
        averageSpeedMPS = 0
        speedSampleCount = 0
        seedSpeedBuffer.removeAll(keepingCapacity: false)
        offRouteCount = 0
        lastOffRouteAlongDistance = nil
        isRecoveringOffRoute = false
        locationUpdateCount = 0
        navigationToken = UUID()
        // Preserve the alerted sets across an in-place restart so an
        // already-passed camera/condition near the restart origin doesn't
        // re-fire; only a brand-new drive resets the one-shot debounce.
        if !preservingAlerts {
            alertedConditionIDs.removeAll()
            alertedCameraIDs.removeAll()
        }
        approachingCamera = nil
        routePolylineCoordinates = polyline

        projector = polyline.count >= 2
            ? RouteProjector(polyline: polyline, fullRescanThreshold: offRouteDistance)
            : nil
        totalRouteDistance = projector?.totalDistance ?? 0
        originalExpectedTravelTime = expectedTravelTime ?? (totalRouteDistance / 13.4)

        // Precompute each step's arc-length position so a single fix can advance
        // past every step the projection has already cleared (sparse GPS /
        // tunnel exit / clustered recovery steps) instead of one step per fix.
        stepAlongDistances = Self.computeStepAlongDistances(steps: steps, polyline: polyline)

        if let expectedTravelTime, totalRouteDistance > 0 {
            scheduleSavedETASanityCheck(saved: expectedTravelTime)
        }

        // Theming: prefetch tunnel geometry along this route so portal fades
        // are driven by OSM data, not just signal loss. Fire-and-forget —
        // failures degrade to the GPS heuristics.
        if polyline.count >= 2 {
            let routeKey = Self.tunnelRouteKey(for: polyline)
            Task { await TunnelDetectionService.shared.prefetch(for: polyline, routeKey: routeKey) }
        }

        if !steps.isEmpty {
            applyStep(at: 0)
        }
    }

    /// Stable cache key for a route's tunnel geometry: endpoints + point count
    /// identify a polyline without hashing thousands of coordinates.
    nonisolated static func tunnelRouteKey(for polyline: [CLLocationCoordinate2D]) -> String {
        guard let first = polyline.first, let last = polyline.last else { return "empty" }
        return String(
            format: "%.5f,%.5f|%.5f,%.5f|%d",
            first.latitude, first.longitude, last.latitude, last.longitude, polyline.count
        )
    }

    // MARK: - Start from MKRoute (adapter for dumb nav)

    /// Convenience: convert an MKRoute to our format and start navigation.
    /// Apple's data is adapted into NavSteps — the engine doesn't use MKRoute internally.
    ///
    /// - Parameter preservingAlerts: forwarded to the core polyline path; pass
    ///   `true` for an Apple-route reroute mid-drive so already-passed cameras /
    ///   conditions near the reroute origin don't re-chime. See the polyline
    ///   overload. A brand-new drive uses the default `false`.
    func startNavigation(route: MKRoute, preservingAlerts: Bool = false) {
        let polyline = Self.extractCoordinates(from: route.polyline)
        let navSteps = Self.convertMKRouteToSteps(route)

        startNavigation(polyline: polyline, steps: navSteps, preservingAlerts: preservingAlerts)

        // Override with Apple's more accurate values
        totalRouteDistance = route.distance
        originalExpectedTravelTime = route.expectedTravelTime
    }

    /// Snapshot of the per-session alert debounce sets, for carrying the
    /// one-shot-per-session guarantee across an in-place stop()/start() reroute
    /// (which would otherwise wipe them). Paired with `restoreAlertedSets`.
    var alertedSetsSnapshot: (cameraIDs: Set<String>, conditionIDs: Set<UUID>) {
        (alertedCameraIDs, alertedConditionIDs)
    }

    /// Re-seed the per-session alert debounce sets after an in-place reroute
    /// restart so cameras/conditions the driver already passed (and was warned
    /// about) don't re-fire on the new geometry. Unions rather than replaces so
    /// any alert detected on the very first post-restart fix is also retained.
    func restoreAlertedSets(cameraIDs: Set<String>, conditionIDs: Set<UUID>) {
        alertedCameraIDs.formUnion(cameraIDs)
        alertedConditionIDs.formUnion(conditionIDs)
    }

    func stopNavigation() {
        VoiceGuidanceService.shared.stop()
        TunnelDetectionService.shared.clearRoute()
        isNavigating = false
        steps = []
        stepAlongDistances = []
        currentStepIndex = 0
        instruction = ""
        stepDistance = ""
        stepDistanceRaw = 0
        etaMinutes = 0
        etaSeconds = 0
        distanceRemaining = ""
        distanceRemainingMeters = 0
        arrivalTime = ""
        roadName = ""
        maneuverType = "arrow.up"
        followOnInstruction = ""
        followOnManeuverSymbol = ""
        currentSpeedMph = 0
        speedLimitMph = nil
        approachingCamera = nil
        headingDegrees = nil
        currentCoordinate = nil
        snappedCoordinate = nil
        navPose = nil
        hasArrived = false
        routePolylineCoordinates = []
        projector = nil
        totalRouteDistance = 0
        originalExpectedTravelTime = 0
        averageSpeedMPS = 0
        speedSampleCount = 0
        seedSpeedBuffer.removeAll(keepingCapacity: false)
        offRouteCount = 0
        lastOffRouteAlongDistance = nil
        isRecoveringOffRoute = false
        locationUpdateCount = 0
        alertedConditionIDs.removeAll()
        alertedCameraIDs.removeAll()

        // Release the off-route closure. It is set in HomeView and captures a
        // copy of the SwiftUI view, whose `@State` box strongly holds this
        // engine — a retain cycle (engine → closure → view → State box → engine)
        // that would otherwise keep every finished engine and its captured view
        // alive. Clearing it at the authoritative teardown point breaks the
        // cycle; HomeView re-wires it when it starts the next session. The other
        // wired closures (speed-limit/camera/road-condition providers) capture
        // only singletons and value data, form no cycle, and are deliberately
        // left intact so a stop()/start() reroute on the same engine keeps them.
        onOffRoute = nil
    }

    /// Called by the recovery pipeline when a confirmed deviation could NOT be
    /// turned into a reroute (no rejoin candidates, all recovery fetches failed,
    /// or a deliberate abandon-to-destination decision). The in-recovery latch
    /// would otherwise stay set forever: `checkOffRoute` short-circuits every
    /// subsequent fix (freezing step/ETA advancement) and suppresses all further
    /// off-route events, so guidance would be stuck for the rest of the leg even
    /// if the driver never re-enters the corridor. Clearing it here re-arms the
    /// detector — guidance resumes (the engine keeps advancing toward the
    /// destination along the existing geometry) and, if the driver stays off the
    /// corridor, a fresh deviation episode can accrue and fire a new event
    /// (subject to the recovery handler's own cooldown) so recovery can retry.
    func clearOffRouteRecovery() {
        isRecoveringOffRoute = false
        offRouteCount = 0
        // Re-baseline forward-progress tracking so the first post-recovery fix
        // (which may rescan to a new along-route position) isn't read as a jump.
        lastOffRouteAlongDistance = nil
    }

    // MARK: - Location Updates

    func updateLocation(_ location: CLLocation) {
        guard isNavigating, !steps.isEmpty else { return }

        // Theming: the nav loop is the authoritative ~1Hz feed during
        // navigation (deduped against the LocationService forward).
        TunnelDetectionService.shared.updateLocation(location)

        // Publish the fix to the process-wide last-known store so synchronous,
        // nonisolated theming code (SteddiTheme.ThemeMode.isDaytime, read from
        // map surfaces / CarPlay) can run the real solar check instead of a cold
        // CLLocationManager whose `.location` is almost always nil.
        LastKnownLocation.update(location.coordinate)

        currentCoordinate = location.coordinate
        locationUpdateCount += 1

        let speedMPS = max(0, location.speed)
        currentSpeedMph = speedMPS * 2.23694

        // One projection of the raw fix drives snap, bearing, and distance-along
        let projection = projector?.project(location.coordinate)
        if let projection {
            snappedCoordinate = projection.snappedCoordinate
            navPose = NavPose(
                snappedCoordinate: projection.snappedCoordinate,
                segmentIndex: projection.segmentIndex,
                t: projection.t,
                distanceAlongRoute: projection.distanceAlongRoute,
                segmentBearingDegrees: projector?.bearing(atDistance: projection.distanceAlongRoute),
                speedMPS: speedMPS,
                fixTimestamp: location.timestamp
            )
        } else {
            snappedCoordinate = location.coordinate
            navPose = nil
        }

        updateHeading(location: location, projection: projection, speedMPS: speedMPS)
        updateSpeedLimit(location: location)

        // Direction/position-sensitive proximity alerts probe the snapped
        // position. While off-route (deviation latched, or this fix is beyond the
        // off-route corridor) that snapped point is the projection of an
        // off-corridor fix onto a route the driver has left — meaningless for
        // "is this feature ahead of me." Skip the checks and drop the banner so a
        // stale snapped point can't chime for a camera/condition the driver is no
        // longer near. They resume once the driver is back on the corridor.
        let offCorridor = isRecoveringOffRoute
            || (projection.map { $0.perpendicularDistance > offRouteDistance } ?? false)
        if offCorridor {
            approachingCamera = nil
        } else {
            checkRoadConditionProximity()
            checkSpeedCameraProximity()
        }

        // Decaying (EWMA) speed estimate: weight recent moving fixes so the ETA
        // tracks current conditions instead of a frozen whole-drive mean. The
        // >1 m/s gate still drops full stops so a red light doesn't drag the
        // estimate to zero. Each fix is first clamped to a plausible driving
        // ceiling so a GPS glitch can't enter the average at all. The first
        // `seedFixCount` clamped moving fixes are buffered and the EWMA is seeded
        // from their MEDIAN — so a lone first-fix spike can't anchor the average
        // and collapse the ETA, while a sustained crawl still seeds low.
        if speedMPS > 1.0 {
            let clamped = min(speedMPS, maxPlausibleSpeedMPS)
            if speedSampleCount == 0 {
                seedSpeedBuffer.append(clamped)
                if seedSpeedBuffer.count >= seedFixCount {
                    averageSpeedMPS = Self.median(of: seedSpeedBuffer)
                    speedSampleCount = seedSpeedBuffer.count
                    seedSpeedBuffer.removeAll(keepingCapacity: false)
                }
            } else {
                averageSpeedMPS += speedEWMAAlpha * (clamped - averageSpeedMPS)
                speedSampleCount += 1
            }
        }

        if checkArrival(location: location, projection: projection) { return }

        if checkOffRoute(location: location, projection: projection) { return }

        advanceStepIfNeeded(location: location, projection: projection)
        updateDistancesAndETA(location: location, projection: projection)
    }

    /// Published bearing priority:
    /// (a) route segment bearing while on-route (snap within the off-route radius),
    /// (b) valid GPS course while actually moving,
    /// (c) otherwise HOLD the previous bearing — never reset mid-drive.
    /// The chosen target is circular low-pass filtered before publishing.
    private func updateHeading(location: CLLocation, projection: RouteProjection?, speedMPS: Double) {
        let target: Double?
        if let projection, projection.perpendicularDistance < offRouteDistance,
           let routeBearing = navPose?.segmentBearingDegrees {
            target = routeBearing
        } else if location.course >= 0, location.courseAccuracy >= 0, speedMPS > courseMinimumSpeedMPS {
            target = location.course
        } else {
            target = nil
        }

        guard let target else { return }
        if let current = headingDegrees {
            headingDegrees = RouteGeometry.smoothBearing(current: current, target: target, factor: headingSmoothingFactor)
        } else {
            headingDegrees = target
        }
    }

    /// Heads-up when approaching a known road condition. Uses the snapped
    /// position (puck on the polyline) so the lookup tracks the route, not GPS
    /// scatter. Debounced per condition for the session so a single pothole
    /// announces once. The actual haptic/voice is delegated to the wiring via
    /// `onRoadConditionApproaching`.
    private func checkRoadConditionProximity() {
        guard let provider = roadConditionProvider else { return }
        let probe = snappedCoordinate ?? currentCoordinate
        guard let probe, let condition = provider(probe) else { return }
        guard !alertedConditionIDs.contains(condition.id) else { return }
        alertedConditionIDs.insert(condition.id)
        onRoadConditionApproaching?(condition)
    }

    /// Heads-up when approaching a known enforcement camera. Uses the snapped
    /// position (puck on the polyline) and the smoothed travel bearing so the
    /// lookup tracks the route, not GPS scatter, and only warns about cameras
    /// ahead. Debounced per camera for the session so a single camera announces
    /// once. The actual tone/haptic/voice is delegated to the wiring via
    /// `onSpeedCameraApproaching`.
    private func checkSpeedCameraProximity() {
        guard let provider = speedCameraProvider else {
            approachingCamera = nil
            return
        }
        // Until a travel bearing exists, a heading-less lookup degrades to
        // omni-directional and could surface a camera *behind* the driver (e.g.
        // crawling off-corridor out of a parking structure at nav start). The
        // route segment bearing is the safe fallback while on-route; if even
        // that is unavailable, suppress the alert rather than chime on a
        // possibly-behind camera that the one-shot debounce would then lock in.
        guard let bearing = directionalFilterBearing else {
            approachingCamera = nil
            return
        }
        let probe = snappedCoordinate ?? currentCoordinate
        guard let probe, let alert = provider(probe, bearing) else {
            // No camera in range — drop the banner. The debounce set keeps any
            // already-announced camera from re-chiming if it briefly re-enters.
            approachingCamera = nil
            return
        }
        // Banner tracks the live nearest camera every fix (distance updates);
        // the one-shot tone/haptic/voice fires only on the first detection.
        approachingCamera = alert
        guard !alertedCameraIDs.contains(alert.alertID) else { return }
        alertedCameraIDs.insert(alert.alertID)
        onSpeedCameraApproaching?(alert)
    }

    /// Position-based speed limit from the injected provider (OSM data),
    /// refreshed every fix so the limit tracks the actual road, not the step.
    /// Falls back to the instruction heuristic set in applyStep when the
    /// provider has no match for this position.
    private func updateSpeedLimit(location: CLLocation) {
        // Use the same bearing the camera filter does: with no confident bearing
        // the OSM lookup would skip its heading gate and could return the
        // opposite carriageway's limit. Skip the update until a bearing exists so
        // the readout doesn't momentarily flip to the wrong side of the road.
        guard let bearing = directionalFilterBearing else { return }
        guard let provided = speedLimitProvider?(location.coordinate, bearing) else { return }
        speedLimitMph = provided.mph
        speedLimitIsEstimated = provided.isEstimated
    }

    /// Bearing used to gate direction-sensitive lookups (cameras ahead, the
    /// road's speed limit for this carriageway). Prefers the smoothed travel
    /// bearing; before that exists, falls back to the route segment bearing while
    /// on-route so a nav start that hasn't moved yet still filters by the route's
    /// travel direction. nil only when neither is known — callers then suppress
    /// the directional alert rather than answering omni-directionally.
    private var directionalFilterBearing: Double? {
        headingDegrees ?? navPose?.segmentBearingDegrees
    }

    /// Resolve the speed limit for a freshly-advanced step. The instruction
    /// estimate is only a fallback: if the OSM provider has live data for the
    /// new step's road we publish that immediately so a step-advance never
    /// flickers a live limit back to the estimate. When the provider has no
    /// match for the new road, we publish the new step's estimate rather than
    /// letting a stale provider value from the previous road stick.
    ///
    /// Why re-derive here instead of waiting for the next fix: `applyStep` runs
    /// inside `advanceStepIfNeeded`, AFTER `updateSpeedLimit` already ran this
    /// fix. Without this, the readout would show the estimate until the next
    /// fix re-queried the provider — the exact flicker we're fixing.
    private func resolveSpeedLimitForStep(at index: Int, step: NavStep) {
        let estimate = Self.estimateSpeedLimit(from: step.instruction)
        // Probe the provider at the new step's start so the limit matches the
        // road being entered, not the position one fix ago. Pass the route's
        // travel bearing AT THIS STEP so the OSM lookup keeps its carriageway
        // gate: a heading-less probe skips that gate and can publish the
        // opposite carriageway's limit on a divided road (the bug this fixes),
        // and the current pose's bearing (directionalFilterBearing) is the wrong
        // direction for a step that turns. The route bearing at the step's
        // along-distance is GPS-independent and always the correct entry
        // direction. Only when that bearing is unknown (degenerate route / no
        // projector) do we fall back to the instruction estimate rather than
        // querying omni-directionally; the next fix's updateSpeedLimit then
        // upgrades to live data once a travel bearing exists.
        let stepBearing = stepAlongDistanceIfPresent(index).flatMap { projector?.bearing(atDistance: $0) }
            ?? directionalFilterBearing
        if let provider = speedLimitProvider,
           let bearing = stepBearing,
           let provided = provider(step.coordinate, bearing) {
            speedLimitMph = provided.mph
            speedLimitIsEstimated = provided.isEstimated
        } else {
            speedLimitMph = estimate
            speedLimitIsEstimated = true
        }
    }

    // MARK: - Step Logic

    private func applyStep(at index: Int) {
        guard index < steps.count else { return }

        let step = steps[index]
        instruction = step.instruction
        stepDistanceRaw = step.distance
        stepDistance = Self.formatDistance(step.distance)
        maneuverType = step.maneuverSymbol
        roadName = Self.extractRoadName(from: step.instruction)
        resolveSpeedLimitForStep(at: index, step: step)

        if !step.instruction.isEmpty {
            VoiceGuidanceService.shared.speakWithDistance(step.instruction, distance: step.distance)
        }

        let nextIndex = index + 1
        if nextIndex < steps.count {
            followOnInstruction = steps[nextIndex].instruction
            followOnManeuverSymbol = steps[nextIndex].maneuverSymbol
        } else {
            followOnInstruction = ""
            followOnManeuverSymbol = ""
        }
    }

    /// Advance the active step, consuming EVERY step the latest fix has already
    /// cleared — not just one per fix. A step is cleared when the driver is
    /// within `stepTransitionDistance` of its start OR when the projected
    /// distance-along-route has moved past the step's start by that margin
    /// (sparse GPS, a tunnel exit, or short clustered recovery-splice steps can
    /// otherwise leave the displayed maneuver lagging several boundaries behind).
    /// Capping at one step per fix is what made a fast multi-step jump briefly
    /// announce a stale maneuver and confuse off-route detection.
    private func advanceStepIfNeeded(location: CLLocation, projection: RouteProjection?) {
        let along = projection?.distanceAlongRoute
        var advanced = false

        while currentStepIndex + 1 < steps.count {
            let nextIndex = currentStepIndex + 1
            let nextStep = steps[nextIndex]

            // Proximity to the next step's start (raw fix → step coordinate).
            let distToNext = Self.haversineDistance(from: location.coordinate, to: nextStep.coordinate)
            var passed = distToNext < stepTransitionDistance

            // Projection progress: the snapped position has crossed this step's
            // start (with the same transition margin). Lets a single fix consume
            // multiple boundaries the driver clearly already passed, even when
            // none of those starts is within haversine range of THIS fix.
            if !passed, let along, let stepAlong = stepAlongDistanceIfPresent(nextIndex) {
                passed = along >= stepAlong - stepTransitionDistance
            }

            guard passed else { break }
            currentStepIndex = nextIndex
            advanced = true
        }

        if advanced {
            applyStep(at: currentStepIndex)
            HapticService.shared.fire(.turnApproaching)
        }
    }

    /// Safe lookup into the parallel `stepAlongDistances` array.
    private func stepAlongDistanceIfPresent(_ index: Int) -> Double? {
        guard index >= 0, index < stepAlongDistances.count else { return nil }
        return stepAlongDistances[index]
    }

    /// Arc-length position of each step's start along the polyline, parallel to
    /// `steps`. nil for steps whose start can't be projected (degenerate
    /// polyline). Pure + nonisolated so it's directly unit-testable.
    nonisolated static func computeStepAlongDistances(
        steps: [NavStep],
        polyline: [CLLocationCoordinate2D]
    ) -> [Double?] {
        guard polyline.count >= 2 else { return Array(repeating: nil, count: steps.count) }
        let cumulative = RouteGeometry.cumulativeDistances(polyline)
        return steps.map { step in
            RouteGeometry.alongDistance(of: step.coordinate, polyline: polyline, cumulative: cumulative)
        }
    }

    /// Distance (meters) from the route's end, by arc-length, within which the
    /// driver is considered to have consumed enough of the route for the
    /// proximity check to be allowed to latch arrival. Sized to the off-route
    /// corridor so a final-approach fix that snaps a little short still qualifies
    /// while a mid-route brush past the destination vertex (with most of the
    /// route still ahead by arc-length) does not.
    private let arrivalAlongRouteSlack: CLLocationDistance = 80

    /// Arrival requires BOTH:
    /// (a) the driver is physically within `arrivalDistance` of the final
    ///     polyline vertex, AND
    /// (b) the driver has consumed essentially the whole route by arc-length
    ///     (projected distance-along-route is within `arrivalAlongRouteSlack` of
    ///     the route end).
    ///
    /// Proximity alone latched too early on two real geometries: a route whose
    /// final vertex sits within 50m of the start (loops / cul-de-sacs — the very
    /// first fix is "at" the destination), and a self-crossing / out-and-back
    /// route that brushes within 50m of its own endpoint mid-drive. The projector
    /// already gives the along-route position each fix, so gating on progress
    /// distinguishes "near the END of the route" from "near a coordinate that
    /// happens to recur." When the projection is unavailable (degenerate
    /// polyline) we fall back to the proximity-only check — there is no
    /// along-route signal to gate on.
    private func checkArrival(location: CLLocation, projection: RouteProjection?) -> Bool {
        // One-shot latch: arrival side-effects (haptic / voice / instruction set)
        // fire ONLY on the transition into arrived. For commute (non-trip) drives
        // the location feed keeps pumping fixes after arrival (it breaks only when
        // a trip is active), so without this guard a parked car within proximity
        // re-fired the arrival buzz + a stuttering "You have arrived" prompt on
        // every subsequent fix. Returning true preserves the caller's
        // short-circuit so the rest of updateLocation stays skipped while arrived.
        guard !hasArrived else { return true }
        guard let lastCoord = routePolylineCoordinates.last else { return false }
        let destination = CLLocation(latitude: lastCoord.latitude, longitude: lastCoord.longitude)
        let withinProximity = location.distance(from: destination) < arrivalDistance

        // Along-route progress gate: require the driver to be near the route end
        // by arc-length, not merely within 50m of the last vertex. Skipped only
        // when there is no projection to read.
        let nearRouteEndByArcLength: Bool
        if let projection, totalRouteDistance > 0 {
            nearRouteEndByArcLength =
                projection.distanceAlongRoute >= totalRouteDistance - arrivalAlongRouteSlack
        } else {
            nearRouteEndByArcLength = true
        }

        if withinProximity && nearRouteEndByArcLength {
            hasArrived = true
            HapticService.shared.fire(.arrival)
            VoiceGuidanceService.shared.speakArrival()
            instruction = "You have arrived"
            maneuverType = "flag.fill"
            stepDistance = ""
            stepDistanceRaw = 0
            distanceRemaining = ""
            etaMinutes = 0
            arrivalTime = ""
            followOnInstruction = ""
            followOnManeuverSymbol = ""
            // Arrived = nothing remaining. updateDistancesAndETA never runs again
            // after this latch (updateLocation short-circuits on hasArrived), so
            // zero the RAW fields here too — otherwise the last pre-arrival
            // etaSeconds/distanceRemainingMeters leak to downstream surfaces that
            // read the numeric values (CarPlay's trip estimate keeps pushing a
            // stale non-zero distance/ETA next to "You have arrived" for a commute
            // whose session stays live until manual End). The string/int fields
            // above are already cleared; these are their numeric counterparts.
            etaSeconds = 0
            distanceRemainingMeters = 0
            return true
        }
        return false
    }

    /// Off-route detection stays on the RAW GPS fix — the projection passed in
    /// is of the raw coordinate, never the snapped one.
    /// The event fires ONCE per deviation episode: the latch holds until the
    /// driver returns within the corridor (or a recovery restarts navigation),
    /// and guidance freezes instead of being pulled backward while off-route.
    private func checkOffRoute(location: CLLocation, projection: RouteProjection?) -> Bool {
        guard let projection else { return false }

        // Forward-progress discount: if the projection advanced clearly along the
        // corridor since the last fix, the driver is on-route even if THIS fix's
        // perpendicular distance spiked (a multi-step jump from sparse GPS or a
        // tunnel exit can momentarily snap wide). Treat that as on-route and
        // clear any accruing deviation count so the jump can't mis-trigger.
        let previousAlong = lastOffRouteAlongDistance
        lastOffRouteAlongDistance = projection.distanceAlongRoute
        let jumpedForwardOnRoute: Bool
        if let previousAlong {
            jumpedForwardOnRoute =
                projection.distanceAlongRoute - previousAlong >= offRouteForwardProgressMeters
        } else {
            jumpedForwardOnRoute = false
        }

        guard locationUpdateCount > offRouteGracePeriod else { return false }

        if jumpedForwardOnRoute && !isRecoveringOffRoute {
            offRouteCount = 0
            return false
        }

        if projection.perpendicularDistance > offRouteDistance {
            if isRecoveringOffRoute { return true }
            offRouteCount += 1
            if offRouteCount >= offRouteThreshold {
                // The window anchor is stale once the driver leaves the route
                projector?.resetWindow()
                isRecoveringOffRoute = true
                offRouteCount = 0
                let courseIsValid = location.course >= 0 && location.courseAccuracy >= 0
                onOffRoute?(OffRouteEvent(
                    coordinate: location.coordinate,
                    courseDegrees: courseIsValid ? location.course : nil,
                    speedMPS: max(0, location.speed),
                    distanceAlongRoute: projection.distanceAlongRoute,
                    currentStepIndex: currentStepIndex
                ))
                return true
            }
        } else {
            offRouteCount = 0
            isRecoveringOffRoute = false
        }

        return false
    }

    // MARK: - Saved ETA Sanity Floor

    /// Legacy planned routes can carry durations inflated by chained per-leg
    /// routing, and that saved value anchors the live ETA until real speed
    /// samples arrive. Async and non-blocking: navigation starts immediately
    /// on the saved value and is corrected when a quick direct MKDirections
    /// estimate lands and the saved duration blows past the sanity bound.
    private func scheduleSavedETASanityCheck(saved: TimeInterval) {
        guard let origin = routePolylineCoordinates.first,
              let destination = routePolylineCoordinates.last else { return }
        let token = navigationToken
        let distanceDerived = totalRouteDistance / 13.4
        Task { [weak self] in
            guard let direct = try? await DirectionsService().fetchDirectETA(from: origin, to: destination) else { return }
            guard let self, self.isNavigating, self.navigationToken == token else { return }
            self.originalExpectedTravelTime = Self.sanitizedExpectedTravelTime(
                saved: saved,
                directEstimate: direct,
                distanceDerived: distanceDerived
            )
        }
    }

    /// True when a saved duration is implausibly large against a direct
    /// origin-to-destination estimate.
    nonisolated static func exceedsSanityBound(saved: TimeInterval, directEstimate: TimeInterval) -> Bool {
        directEstimate > 0 && saved > directEstimate * savedETAInflationBound
    }

    /// The travel time the live ETA should anchor on. The direct estimate is
    /// only a corruption detector — the replacement is distance-derived so it
    /// still reflects the saved route's actual geometry.
    nonisolated static func sanitizedExpectedTravelTime(
        saved: TimeInterval,
        directEstimate: TimeInterval,
        distanceDerived: TimeInterval
    ) -> TimeInterval {
        exceedsSanityBound(saved: saved, directEstimate: directEstimate) ? distanceDerived : saved
    }

    // MARK: - Distance & ETA

    private func updateDistancesAndETA(location: CLLocation, projection: RouteProjection?) {
        // Distance traveled comes from the shared projection — no rescan
        let distanceTraveled = projection?.distanceAlongRoute ?? 0
        let totalRemaining = max(0, totalRouteDistance - distanceTraveled)

        // Step-level remaining: distance from user to next step's coordinate
        let nextIndex = currentStepIndex + 1
        if nextIndex < steps.count {
            let distToNext = Self.haversineDistance(from: location.coordinate, to: steps[nextIndex].coordinate)
            stepDistanceRaw = distToNext
            stepDistance = Self.formatDistance(distToNext)
        } else {
            // Last step — distance to destination
            if let last = routePolylineCoordinates.last {
                let d = Self.haversineDistance(from: location.coordinate, to: last)
                stepDistanceRaw = d
                stepDistance = Self.formatDistance(d)
            }
        }

        distanceRemainingMeters = totalRemaining
        distanceRemaining = Self.formatDistance(totalRemaining)

        let calculatedETA: TimeInterval
        // Use the observed pace whenever the EWMA holds a real moving estimate.
        // The >1 m/s EWMA gate already excludes genuine stops, so any seeded
        // average reflects fixes the driver actually logged while moving — even a
        // sustained stop-and-go crawl in the ~1-2 m/s band. Gating ETA on a >2 m/s
        // floor here would discard that valid crawl estimate and snap to the
        // optimistic free-flow fraction exactly when traffic is worst. Only fall
        // back to free-flow when no moving sample has ever seeded the EWMA
        // (nav just started, or never moved), where there is no observed pace.
        if speedSampleCount > 0, averageSpeedMPS > 0 {
            calculatedETA = totalRemaining / averageSpeedMPS
        } else if totalRouteDistance > 0 {
            let fraction = totalRemaining / totalRouteDistance
            calculatedETA = originalExpectedTravelTime * fraction
        } else {
            calculatedETA = 0
        }

        etaSeconds = calculatedETA
        etaMinutes = max(1, Int(ceil(calculatedETA / 60)))
        arrivalTime = Self.formatArrivalTime(calculatedETA)
    }

    // MARK: - MKRoute Adapter

    /// Convert MKRoute.Steps into NavSteps. This is the only place Apple types are used.
    /// Internal so the recovery splice can adapt fetched MKRoutes the same way.
    static func convertMKRouteToSteps(_ route: MKRoute) -> [NavStep] {
        route.steps
            .filter { !$0.instructions.isEmpty }
            .map { step in
                let coords = extractCoordinates(from: step.polyline)
                return NavStep(
                    instruction: step.instructions,
                    distance: step.distance,
                    coordinate: coords.first ?? step.polyline.coordinate,
                    maneuverSymbol: sfSymbolFromInstruction(step.instructions)
                )
            }
    }

    // MARK: - Geometry

    nonisolated static func haversineDistance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        RouteGeometry.haversineDistance(from: a, to: b)
    }

    /// Median of a non-empty list. Used to seed the speed EWMA from the first few
    /// moving fixes so a single outlier (a GPS speed spike) can't anchor it. For
    /// an even count returns the lower-middle element (a robust low-side estimate;
    /// the EWMA converges within seconds either way). Returns 0 for an empty list.
    nonisolated static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    nonisolated static func extractCoordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let count = polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }

    nonisolated static func polylineDistance(_ coords: [CLLocationCoordinate2D]) -> Double {
        RouteGeometry.cumulativeDistances(coords).last ?? 0
    }

    // MARK: - Formatting

    nonisolated static func formatDistance(_ meters: Double) -> String {
        if meters < 160 { return "\(Int(meters * 3.281)) ft" }
        let miles = meters / 1609.34
        if miles < 10 { return String(format: "%.1f mi", miles) }
        // Round, don't truncate: 10.95 mi -> "11 mi" (avoid up-to-1-mi understatement).
        return "\(Int(miles.rounded())) mi"
    }

    nonisolated static func formatArrivalTime(
        _ secondsRemaining: TimeInterval,
        now: Date = Date(),
        locale: Locale = .current
    ) -> String {
        let arrival = now.addingTimeInterval(secondsRemaining)
        let formatter = DateFormatter()
        formatter.locale = locale
        // "jmm" is the locale-aware hour:minute template — it resolves to a 12h
        // clock (with AM/PM) or a 24h clock per the locale's own preference,
        // instead of forcing "h:mm a" which breaks 24h locales.
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: arrival)
    }

    // MARK: - Instruction Parsing

    nonisolated static func sfSymbolFromInstruction(_ instruction: String) -> String {
        let lower = instruction.lowercased()
        if lower.contains("arrive") || lower.contains("destination") { return "flag.fill" }
        if lower.contains("depart") || lower.contains("start") || lower.contains("head ") { return "location.fill" }
        if lower.contains("u-turn") || lower.contains("uturn") { return "arrow.uturn.down" }
        if lower.contains("roundabout") || lower.contains("rotary") { return "arrow.triangle.2.circlepath" }
        if lower.contains("merge") { return "arrow.merge" }
        if lower.contains("ramp") && lower.contains("left") { return "arrow.up.left" }
        if lower.contains("ramp") { return "arrow.up.right" }
        if lower.contains("sharp left") { return "arrow.turn.up.left" }
        if lower.contains("sharp right") { return "arrow.turn.up.right" }
        if lower.contains("bear left") || lower.contains("slight left") || lower.contains("keep left") { return "arrow.turn.up.left" }
        if lower.contains("bear right") || lower.contains("slight right") || lower.contains("keep right") { return "arrow.turn.up.right" }
        if lower.contains("turn left") || lower.hasPrefix("left") { return "arrow.turn.up.left" }
        if lower.contains("turn right") || lower.hasPrefix("right") { return "arrow.turn.up.right" }
        return "arrow.up"
    }

    nonisolated static func estimateSpeedLimit(from instruction: String) -> Double {
        let lower = instruction.lowercased()
        // Road-name tiers come before the maneuver tier so "Merge onto I-215"
        // classifies by the road, not the merge.
        if lower.contains("i-") || lower.contains("interstate") || lower.contains("freeway") || lower.contains("motorway") || lower.contains("us-") || lower.contains("ca-") || lower.contains("sr-") || lower.contains("highway") { return 65 }
        if lower.contains("state route") || lower.contains("expressway") || lower.contains("pkwy") || lower.contains("parkway") || lower.contains("blvd") || lower.contains("boulevard") { return 45 }
        // Residential street types — small, low-speed roads (matches OSM's
        // `residential` default of 25). Word-boundary matched so "Way" lands
        // here while "Parkway"/"Broadway" do not (and parkway is caught above).
        if lower.range(of: #"\b(way|pl|place|ter|terrace|cir|circle|cove|loop|trail|ln|lane|ct|court)\b"#, options: .regularExpression) != nil { return 25 }
        if lower.contains("ave") || lower.contains("avenue") || lower.contains("street") || lower.contains("road") || lower.contains("drive") || lower.range(of: #"\b(st|rd|dr)\b"#, options: .regularExpression) != nil { return 35 }
        if lower.contains("ramp") || lower.contains("merge") { return 40 }
        // Unclassifiable instruction (no road type, e.g. "Head west"): a sane
        // urban surface-street default, never above the named-street tiers.
        return 30
    }

    nonisolated static func extractRoadName(from instruction: String) -> String {
        if let ontoRange = instruction.range(of: "onto ", options: .caseInsensitive) {
            let name = String(instruction[ontoRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        if let onRange = instruction.range(of: " on ", options: .caseInsensitive) {
            let name = String(instruction[onRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return ""
    }
}

// MARK: - Last-Known Location (process-wide)

/// Process-wide cache of the most recent location fix, readable synchronously
/// from any (nonisolated) context.
///
/// Some synchronous, non-actor-isolated code needs the user's coordinate without
/// being able to `await` a fix or touch a `@MainActor` location service — most
/// notably `SteddiTheme.ThemeMode.isDaytime`, which decides dynamic light/dark
/// for map surfaces and CarPlay. A freshly-created `CLLocationManager().location`
/// read cold is almost always nil (the property is only populated after updates
/// start), so that path silently fell back to a fixed 7am–7pm clock. The live
/// navigation feed (`NavigationEngine.updateLocation`) publishes every fix here
/// so the real solar check has a coordinate to work with. Thread-safe via an
/// unfair lock; last-writer-wins.
enum LastKnownLocation {
    nonisolated(unsafe) private static var coordinate: CLLocationCoordinate2D?
    private static let lock = NSLock()

    /// Record the latest fix. Called from the live location feed.
    static func update(_ coordinate: CLLocationCoordinate2D) {
        lock.lock()
        defer { lock.unlock() }
        self.coordinate = coordinate
    }

    /// The most recent fix, or nil if none has been recorded this process.
    static var current: CLLocationCoordinate2D? {
        lock.lock()
        defer { lock.unlock() }
        return coordinate
    }
}
