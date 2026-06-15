import Foundation
import CoreLocation
import MapKit
import WidgetKit

/// Shared single source of truth for navigation state.
/// Both the phone UI and CarPlay read from this object.
@Observable
@MainActor
final class NavigationStateManager {

    static let shared = NavigationStateManager()

    // MARK: - Navigation State

    var isNavigating: Bool = false
    var isCarPlayActive: Bool = false

    /// Monotonic counter bumped on every `startObserving` call. CarPlay watches
    /// this to detect a *new* navigation session even when `isNavigating` never
    /// dips to false between sessions — e.g. a continuous-mode trip where one
    /// leg arrives and the next starts in the same main-actor turn, so the
    /// 1 Hz CarPlay sampler can never observe the transient false. Without this,
    /// CarPlay would only re-present nav on a false->true `isNavigating` edge and
    /// would stay on the idle map for every leg after the first.
    private(set) var sessionGeneration: Int = 0

    var instruction: String = ""
    var stepDistance: String = ""
    var stepDistanceRaw: Double = 0
    var etaMinutes: Int = 0
    var distanceRemaining: String = ""
    var arrivalTime: String = ""
    var roadName: String = ""
    var maneuverType: String = "arrow.up"

    var followOnInstruction: String = ""
    var followOnManeuverSymbol: String = ""

    var currentSpeedMph: Double = 0
    var speedLimitMph: Double? = nil
    var headingDegrees: Double? = nil
    var currentCoordinate: CLLocationCoordinate2D? = nil
    /// Engine-snapped navigation pose — CarPlay reads the same projection the
    /// phone renders instead of the raw GPS coordinate.
    var currentPose: NavPose? = nil
    var distanceRemainingMeters: Double = 0
    var etaSeconds: TimeInterval = 0

    var hasArrived: Bool = false

    var activeCommute: Commute? = nil
    var activeDirection: CommuteDirection? = nil

    /// Active multi-stop trip, when the session is a trip leg. CarPlay and
    /// the Live Activity read leg context (leg N of M, next stop) from here
    /// instead of reaching into HomeView state.
    var activeTrip: Trip? = nil

    var rerouteSuggestion: (route: Route, savingsMinutes: Double, savingsPercentage: Double)? = nil
    var currentRemainingETA: TimeInterval = 0

    /// The id of the route the driver is actually navigating, set at session
    /// start. The reroute loop excludes THIS route from candidates by identity
    /// (not by rank), so after `switchToRoute` lands the driver on a fallback
    /// (rank > 0) the loop never re-suggests the route already being driven and
    /// CAN re-offer the preferred (rank 0) route if it becomes faster again.
    /// nil for non-commute sessions (search nav), which run no reroute loop.
    @ObservationIgnored
    private var activeRouteID: UUID?

    /// The route the driver most recently declined (tapped "Stay") plus when,
    /// and the savings they rejected. The reroute loop suppresses re-suggesting
    /// that same route during a cooldown window unless it becomes materially
    /// better, so a dismissed card doesn't immediately nag again on the next
    /// cycle. Cleared at session start/end.
    @ObservationIgnored
    private var dismissedRouteID: UUID?
    @ObservationIgnored
    private var dismissedAt: Date?
    @ObservationIgnored
    private var dismissedSavingsSeconds: TimeInterval = 0

    /// How long a just-declined route stays suppressed after "Stay".
    private static let rerouteDismissCooldown: TimeInterval = 600 // 10 min
    /// A re-suggestion within the cooldown is only allowed if the new savings
    /// beats what was rejected by at least this much — "materially better".
    private static let rerouteResuggestMargin: TimeInterval = 120 // 2 min

    var upcomingSteps: [UpcomingStep] = []

    /// The active navigation engine — shared so CarPlay can read the same state
    var activeEngine: NavigationEngine? = nil
    /// Route coordinates for map rendering
    var activeRouteCoords: [CLLocationCoordinate2D] = []

    // MARK: - Task Storage

    private var pollingTask: Task<Void, Never>?
    private var rerouteTask: Task<Void, Never>?

    // MARK: - Widget Shared Defaults

    private static let widgetSuiteName = "group.to.nathancurtis.steddi"
    private static let widgetKind = "CommuteETAWidget"

    // App Group keys the widget extension reads. Kept in sync with
    // SteddiWidget/CommuteETAWidget.swift (WidgetKeys).
    static let kCommuteName = "widget.commuteName"
    static let kDestinationName = "widget.destinationName"
    static let kIsNavigating = "widget.isNavigating"
    static let kETAMinutes = "widget.etaMinutes"
    /// Epoch seconds when `widget.etaMinutes` was last computed — lets the widget
    /// show how fresh an idle ETA is instead of presenting a stale number as live.
    static let kETAUpdatedAt = "widget.etaUpdatedAt"

    @ObservationIgnored
    private let widgetDefaults = UserDefaults(suiteName: NavigationStateManager.widgetSuiteName)

    /// Last ETA (minutes) pushed to the widget timeline, so per-tick syncs only
    /// reload the widget when the displayed minute actually changes. The polling
    /// task ticks twice a second; the widget shows whole minutes, so reloading
    /// on every tick would be ~120x wasted timeline reloads with no visible
    /// change. Reset to nil at session start/end.
    @ObservationIgnored
    private var lastWidgetETAMinutes: Int?

    // MARK: - Observation

    func startObserving(
        engine: NavigationEngine,
        commute: Commute? = nil,
        direction: CommuteDirection? = nil,
        trip: Trip? = nil,
        destinationName: String? = nil,
        routeID: UUID? = nil
    ) {
        stopObserving()

        isNavigating = true
        // New session — bump the generation so CarPlay re-presents nav even when
        // isNavigating didn't observably dip to false (continuous trip legs).
        sessionGeneration &+= 1
        activeEngine = engine
        activeCommute = commute
        activeDirection = direction
        activeTrip = trip
        // Identity of the route actually being driven, so the reroute loop can
        // exclude it (and only it) from candidates regardless of its rank.
        activeRouteID = routeID

        writeWidgetSession(commute: commute, direction: direction, destinationName: destinationName)

        // Store route coords for CarPlay map rendering
        activeRouteCoords = engine.routePolylineCoordinates

        // Polling task — copies engine state to manager properties (for CarPlay to read)
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let engine = self.activeEngine else { break }
                guard engine.isNavigating else { break }

                self.syncFromEngine(engine)

                if engine.hasArrived {
                    self.hasArrived = true
                    break
                }

                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        // Reroute engine - periodic fallback check (every 5 minutes)
        if let commute, let direction {
            rerouteTask = Task { @MainActor [weak self] in
                let directionsService = DirectionsService()

                while !Task.isCancelled {
                    guard let self else { break }
                    guard !self.hasArrived else { break }

                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled else { break }
                    guard !self.hasArrived else { break }
                    guard self.rerouteSuggestion == nil else { continue }

                    guard let engine = self.activeEngine,
                          engine.isNavigating,
                          let currentCoord = engine.currentCoordinate else { continue }

                    let activePolyline = engine.routePolylineCoordinates
                    guard activePolyline.count >= 2 else { continue }

                    // Comparability — the crux of the reroute decision. Both
                    // numbers below MUST be path-aware ETAs that follow their own
                    // route's geometry. Every route in a commute shares the same
                    // origin/destination, so a plain point-to-point ETA collapses
                    // them all to the SAME value (the open-road shortest path),
                    // making savings ~0 forever and the feature dead. So compute
                    // the active route's REMAINING ETA along the part of its own
                    // polyline still ahead of the driver, and each candidate's
                    // ETA along the candidate's polyline — they share an endpoint
                    // but differ by path, so a genuinely faster route shows real
                    // savings while an equal/slower one shows none.
                    let remainingPolyline = DirectionsService.remainingPolyline(
                        of: activePolyline,
                        from: currentCoord
                    )
                    let remainingETA: TimeInterval
                    do {
                        remainingETA = try await directionsService.fetchETA(
                            from: currentCoord,
                            along: PolylineEncoder.encode(remainingPolyline, precision: 6)
                        )
                    } catch {
                        // Couldn't get a comparable baseline this cycle — skip
                        // rather than fall back to a non-path-aware estimate and
                        // compare incomparable numbers.
                        continue
                    }

                    // The fetch awaited; bail if the session changed underneath.
                    guard !Task.isCancelled,
                          let liveEngine = self.activeEngine,
                          liveEngine === engine,
                          liveEngine.isNavigating,
                          !self.hasArrived else { break }

                    self.currentRemainingETA = remainingETA

                    // Candidates are every OTHER saved route in this direction —
                    // excluded by IDENTITY, not by rank. The driver may already be
                    // on a fallback (rank > 0) after a manual switch, so filtering
                    // on rank-0 would (a) re-suggest the route being driven and
                    // (b) permanently bar the preferred route from being re-offered
                    // when it's faster again. Excluding only `activeRouteID` fixes
                    // both.
                    let candidates = commute.orderedRoutes(for: direction)
                        .filter { $0.id != self.activeRouteID }
                    guard !candidates.isEmpty else { continue }

                    let bestSuggestion = await Self.bestReroute(
                        candidates: candidates,
                        currentCoord: currentCoord,
                        remainingETASeconds: remainingETA,
                        basePercentage: commute.thresholdPercentage,
                        hardMinuteFloor: commute.hardMinuteFloor,
                        isSuppressed: { [weak self] routeID, savingsSeconds in
                            self?.isRerouteSuppressed(routeID: routeID, savingsSeconds: savingsSeconds) ?? false
                        },
                        fetchETA: { coord, polyline in
                            try await directionsService.fetchETA(from: coord, along: polyline)
                        }
                    )

                    // Final guard: only surface the suggestion if the same
                    // session is still live after all the awaits above.
                    if let suggestion = bestSuggestion,
                       !Task.isCancelled,
                       let liveEngine = self.activeEngine,
                       liveEngine === engine,
                       liveEngine.isNavigating,
                       !self.hasArrived {
                        self.rerouteSuggestion = suggestion
                    }
                }
            }
        }
    }

    // MARK: - Reroute Candidate Evaluation

    /// Pick the best reroute suggestion among `candidates`, comparing every ETA
    /// SYMMETRICALLY: each side is "time from where I am NOW to the destination
    /// via route X."
    ///
    /// The crux is that the active route's baseline (`remainingETASeconds`) is
    /// measured along only the geometry still AHEAD of the driver, so each
    /// candidate must be measured the same way — trim the candidate's polyline to
    /// the portion ahead of `currentCoord` (`DirectionsService.remainingPolyline`)
    /// before fetching its path-aware ETA. Passing the candidate's FULL saved
    /// polyline (which begins at the commute origin) would instead measure
    /// "drive BACK to the origin, then the whole candidate," systematically
    /// inflating every candidate's ETA mid-drive and making real savings look
    /// negative — the asymmetry that silently killed the feature after the first
    /// few minutes of any drive. With both sides trimmed-from-current-position,
    /// a genuinely faster alternative shows real savings and an equal route shows
    /// ~0.
    ///
    /// Pure and dependency-injected (`fetchETA`, `isSuppressed`) so the
    /// symmetric-comparison contract is unit-testable without a live engine or
    /// network. Candidate exclusion (the active route) is the caller's job.
    nonisolated static func bestReroute(
        candidates: [Route],
        currentCoord: CLLocationCoordinate2D,
        remainingETASeconds: TimeInterval,
        basePercentage: Double,
        hardMinuteFloor: Int?,
        isSuppressed: (UUID, TimeInterval) -> Bool,
        fetchETA: (CLLocationCoordinate2D, String) async throws -> TimeInterval
    ) async -> (route: Route, savingsMinutes: Double, savingsPercentage: Double)? {
        var bestSuggestion: (route: Route, savingsMinutes: Double, savingsPercentage: Double)?
        var bestSavings: TimeInterval = 0

        for candidate in candidates {
            // Trim the candidate to the part AHEAD of the driver — symmetric with
            // the active route's remaining ETA, so both numbers measure the same
            // origin (current position) to the same destination, differing only
            // by path.
            let candidateCoords = PolylineEncoder.decode(candidate.encodedPolyline, precision: 6)
            guard candidateCoords.count >= 2 else { continue }
            let candidateRemaining = DirectionsService.remainingPolyline(
                of: candidateCoords,
                from: currentCoord
            )

            let candidateETA: TimeInterval
            do {
                candidateETA = try await fetchETA(
                    currentCoord,
                    PolylineEncoder.encode(candidateRemaining, precision: 6)
                )
            } catch {
                continue
            }

            let decision = RerouteEngine.evaluate(
                remainingETASeconds: remainingETASeconds,
                fallbackETASeconds: candidateETA,
                basePercentage: basePercentage,
                hardMinuteFloor: hardMinuteFloor
            )

            // Don't re-surface a route the driver just declined ("Stay") until
            // the cooldown lapses or it becomes materially faster than rejected.
            if isSuppressed(candidate.id, decision.savingsSeconds) {
                continue
            }

            if decision.shouldReroute, decision.savingsSeconds > bestSavings {
                bestSavings = decision.savingsSeconds
                bestSuggestion = (
                    route: candidate,
                    savingsMinutes: decision.savingsMinutes,
                    savingsPercentage: remainingETASeconds > 0 ? decision.savingsSeconds / remainingETASeconds : 0
                )
            }
        }

        return bestSuggestion
    }

    /// Copy one tick of engine state into the manager's published properties.
    /// CarPlay reads these instead of touching the engine directly.
    func syncFromEngine(_ engine: NavigationEngine) {
        instruction = engine.instruction
        stepDistance = engine.stepDistance
        stepDistanceRaw = engine.stepDistanceRaw
        etaMinutes = engine.etaMinutes
        distanceRemaining = engine.distanceRemaining
        arrivalTime = engine.arrivalTime
        roadName = engine.roadName
        maneuverType = engine.maneuverType
        followOnInstruction = engine.followOnInstruction
        followOnManeuverSymbol = engine.followOnManeuverSymbol
        currentSpeedMph = engine.currentSpeedMph
        speedLimitMph = engine.speedLimitMph
        headingDegrees = engine.headingDegrees
        currentCoordinate = engine.currentCoordinate
        currentPose = engine.navPose
        distanceRemainingMeters = engine.distanceRemainingMeters
        etaSeconds = engine.etaSeconds

        // Build upcoming steps from engine
        upcomingSteps = Self.buildUpcomingSteps(from: engine)

        // Write to shared App Group for widget and refresh its timeline when the
        // displayed minute changes. Without the reload the widget keeps showing
        // the ETA captured at session start; writing the defaults alone doesn't
        // re-render the extension. Throttled to minute changes so the 2 Hz sync
        // doesn't spam WidgetKit with no-op reloads.
        //
        // The live ETA is also the freshest real commute ETA the app computes,
        // so persist it (with a timestamp) as the "last known" value the widget
        // shows when idle — that's the whole point of a commute-ETA widget.
        //
        // kIsNavigating is cheap and must stay current every tick. But the
        // displayed ETA only changes on a whole-minute boundary, so writing
        // kETAMinutes + restamping kETAUpdatedAt every 500ms is pure churn the
        // widget can't observe (the freshness stamp would also tick needlessly).
        // Only write the ETA + restamp + reload when the minute actually changes,
        // matching the timeline-reload gate.
        widgetDefaults?.set(engine.isNavigating, forKey: Self.kIsNavigating)
        if engine.etaMinutes != lastWidgetETAMinutes {
            lastWidgetETAMinutes = engine.etaMinutes
            widgetDefaults?.set(engine.etaMinutes, forKey: Self.kETAMinutes)
            widgetDefaults?.set(Date().timeIntervalSince1970, forKey: Self.kETAUpdatedAt)
            WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        }
    }

    /// Tear down an in-progress trip session cleanly — used when the active
    /// trip is deleted out from under navigation. Stops the engine first so no
    /// further ticks fire, then clears all observation state (including
    /// `activeTrip`) so nothing is left pointing at a deleted model.
    ///
    /// `stopObserving()` flips `isNavigating` false; HomeView observes that edge
    /// (`.onChange(of: navStateManager.isNavigating)`) and runs its own local
    /// teardown — dismissing the overlay, leaving GPS navigation mode, and
    /// ending the Live Activity. We also end the Live Activity here so the
    /// teardown is self-sufficient even when HomeView isn't mounted (e.g. a
    /// CarPlay-only session with the phone UI torn down), where no view observer
    /// would otherwise reap the lingering activity.
    func endActiveTripSession() {
        activeEngine?.stopNavigation()
        stopObserving()
        LiveActivityService.shared.endActivity()
    }

    /// The driver tapped "Stay" (or the card auto-dismissed). Clear the visible
    /// suggestion AND remember the declined route + its rejected savings so the
    /// reroute loop won't re-surface the same route on the next cycle within the
    /// cooldown window unless it becomes materially better. UI should call this
    /// instead of setting `rerouteSuggestion = nil` directly, so the decline is
    /// actually recorded.
    func dismissRerouteSuggestion() {
        if let suggestion = rerouteSuggestion {
            dismissedRouteID = suggestion.route.id
            dismissedAt = Date()
            dismissedSavingsSeconds = suggestion.savingsMinutes * 60.0
        }
        rerouteSuggestion = nil
    }

    /// Whether a candidate route is currently suppressed because the driver just
    /// declined it. Suppressed while inside the cooldown window, unless the new
    /// savings beats the rejected savings by a material margin.
    /// `internal` (not `private`) so the cooldown policy is unit-testable.
    func isRerouteSuppressed(routeID: UUID, savingsSeconds: TimeInterval, now: Date = Date()) -> Bool {
        guard routeID == dismissedRouteID, let dismissedAt else { return false }
        guard now.timeIntervalSince(dismissedAt) < Self.rerouteDismissCooldown else { return false }
        return savingsSeconds < dismissedSavingsSeconds + Self.rerouteResuggestMargin
    }

    private func clearDismissedReroute() {
        dismissedRouteID = nil
        dismissedAt = nil
        dismissedSavingsSeconds = 0
    }

    func stopObserving() {
        pollingTask?.cancel()
        rerouteTask?.cancel()

        pollingTask = nil
        rerouteTask = nil

        if isNavigating {
            clearWidgetSession()
        }

        isNavigating = false
        instruction = ""
        stepDistance = ""
        stepDistanceRaw = 0
        etaMinutes = 0
        distanceRemaining = ""
        arrivalTime = ""
        roadName = ""
        maneuverType = "arrow.up"
        followOnInstruction = ""
        followOnManeuverSymbol = ""
        currentSpeedMph = 0
        speedLimitMph = nil
        headingDegrees = nil
        currentCoordinate = nil
        currentPose = nil
        distanceRemainingMeters = 0
        etaSeconds = 0
        hasArrived = false
        activeCommute = nil
        activeDirection = nil
        activeTrip = nil
        activeEngine = nil
        activeRouteCoords = []
        activeRouteID = nil
        rerouteSuggestion = nil
        currentRemainingETA = 0
        upcomingSteps = []
        clearDismissedReroute()
    }

    // MARK: - Widget Session

    /// Write the session identity (commute + destination names) the widget
    /// renders alongside the per-tick ETA, then refresh its timeline.
    private func writeWidgetSession(commute: Commute?, direction: CommuteDirection?, destinationName: String?) {
        // New session — force the next sync to push a fresh ETA to the widget.
        lastWidgetETAMinutes = nil
        let resolvedDestination = destinationName ?? Self.commuteEndpointName(commute: commute, direction: direction)

        if let commuteName = commute?.name {
            widgetDefaults?.set(commuteName, forKey: Self.kCommuteName)
        } else {
            // No commute (search nav) — fall back to the widget's default label
            widgetDefaults?.removeObject(forKey: Self.kCommuteName)
        }

        if let resolvedDestination {
            widgetDefaults?.set(resolvedDestination, forKey: Self.kDestinationName)
        } else {
            widgetDefaults?.removeObject(forKey: Self.kDestinationName)
        }

        widgetDefaults?.set(true, forKey: Self.kIsNavigating)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }

    /// Navigation ended. The last value synced to the widget was the just-ended
    /// drive's REMAINING ETA (near-arrival, ~1-2 min) — that's the time left on
    /// a finished drive, NOT the next commute's duration, so carrying it forward
    /// as the idle "Next Commute" ETA is wrong (and the fresh kETAUpdatedAt
    /// stamp keeps isStale false for 30 min, so it's presented as live). Clear
    /// the live ETA on drive end so the widget shows "No ETA yet" until the idle
    /// path (updateIdleCommuteETA / refreshIdleCommuteETA on next foreground or
    /// the background commute-check) repopulates a real pre-drive ETA for the
    /// NEXT commute. The destination/commute name are left in place as harmless
    /// labels that the next idle update overwrites.
    private func clearWidgetSession() {
        lastWidgetETAMinutes = nil
        widgetDefaults?.set(false, forKey: Self.kIsNavigating)
        // Drop the terminal live ETA + its stamp (widget renders 0 as "No ETA
        // yet"); do NOT leave the finished drive's remaining minutes posing as
        // the upcoming commute's ETA.
        widgetDefaults?.set(0, forKey: Self.kETAMinutes)
        widgetDefaults?.removeObject(forKey: Self.kETAUpdatedAt)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }

    /// Stale-session guard for launch. If the app was killed mid-drive (OOM /
    /// watchdog), the teardown paths that clear `kIsNavigating` never ran, so the
    /// App Group keeps `kIsNavigating == true` plus a near-arrival ETA with a
    /// recent stamp — and the widget then renders a phantom "Navigating" card
    /// with a finished drive's ~1-2 min remaining presented as a live ETA
    /// indefinitely (the idle refresh only runs when a commute departure is
    /// pending). At launch we are by definition not yet in a live session, so if
    /// `isNavigating` is false reconcile the widget to a known-idle baseline.
    /// Mirrors the Live Activity orphan sweep already run at launch. Safe no-op
    /// when actually navigating (a CarPlay-first relaunch into an active drive),
    /// since the next sync immediately repopulates the live values.
    func reconcileWidgetSessionAtLaunch() {
        guard !isNavigating else { return }
        guard widgetDefaults?.bool(forKey: Self.kIsNavigating) == true else { return }
        clearWidgetSession()
    }

    // MARK: - Idle Commute ETA (widget pre-drive)

    /// Push a fresh "next commute" ETA snapshot to the widget while NOT
    /// navigating, so the home-screen widget shows a glanceable ETA before the
    /// drive. Callers compute the ETA with the existing commute-ETA path
    /// (e.g. `DirectionsService.fetchDirectETA` as `CheckCommuteETAIntent` and
    /// the background commute-check already do) and hand the result here; this
    /// type doesn't fetch routes itself. No-op while a live session is active so
    /// it can't clobber the live ETA.
    ///
    /// Intended call sites (in files owned by other areas): app foreground, the
    /// background commute-check pass, and schedule (re)computation.
    func updateIdleCommuteETA(commuteName: String?, destinationName: String?, etaMinutes: Int) {
        guard !isNavigating else { return }
        guard etaMinutes > 0 else { return }

        if let commuteName {
            widgetDefaults?.set(commuteName, forKey: Self.kCommuteName)
        }
        if let destinationName {
            widgetDefaults?.set(destinationName, forKey: Self.kDestinationName)
        }
        widgetDefaults?.set(etaMinutes, forKey: Self.kETAMinutes)
        widgetDefaults?.set(Date().timeIntervalSince1970, forKey: Self.kETAUpdatedAt)
        widgetDefaults?.set(false, forKey: Self.kIsNavigating)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }

    /// Endpoint the driver is heading to for a commute direction.
    private static func commuteEndpointName(commute: Commute?, direction: CommuteDirection?) -> String? {
        guard let commute else { return nil }
        return direction == .destinationToOrigin ? commute.origin?.name : commute.destination?.name
    }

    // MARK: - Upcoming Steps Builder

    private static func buildUpcomingSteps(from engine: NavigationEngine) -> [UpcomingStep] {
        // The NavigationEngine tracks steps internally; build upcoming from its state
        // We read the engine's current step index and expose the remaining steps
        // Since NavigationEngine doesn't expose a steps array directly, we build
        // from the follow-on instruction if available
        var steps: [UpcomingStep] = []

        if !engine.followOnInstruction.isEmpty {
            steps.append(UpcomingStep(
                instruction: engine.followOnInstruction,
                distance: "",
                maneuverSymbol: engine.followOnManeuverSymbol,
                roadName: nil
            ))
        }

        return steps
    }

    // MARK: - Formatting

    nonisolated static func formatDistance(_ meters: Double) -> String {
        if meters < 160 { // ~500 ft
            return "\(Int(meters * 3.281)) ft"
        }
        let miles = meters / 1609.34
        if miles < 10 {
            return String(format: "%.1f mi", miles)
        }
        return "\(Int(miles)) mi"
    }

    nonisolated static func formatArrivalTime(_ secondsRemaining: TimeInterval) -> String {
        let arrival = Date().addingTimeInterval(secondsRemaining)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: arrival)
    }
}

// MARK: - UpcomingStep

struct UpcomingStep: Identifiable {
    let id = UUID()
    let instruction: String
    let distance: String
    let maneuverSymbol: String
    let roadName: String?
}
