import Foundation
import CoreLocation
import MapKit
import WidgetKit
import SwiftData

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

    /// Reroute candidate inputs captured as a `Sendable` value snapshot at
    /// `startObserving` time, while the @Model graph is guaranteed valid. The
    /// reroute loop iterates THIS — never the live `commute.routes` relationship —
    /// so a mid-drive deletion of the commute/route (on a session that never tore
    /// down, e.g. CarPlay-only) can't trap the loop on an invalidated model after
    /// a suspension. Cleared at session end.
    @ObservationIgnored
    private var rerouteInputs: RerouteSnapshot?

    /// The SwiftData context the active commute lives in, captured at session
    /// start. Used to re-fetch the winning route by id (via a predicate fetch that
    /// safely returns nil if deleted) when surfacing a suggestion, instead of
    /// dereferencing a possibly-stale `@Model` handle. Cleared at session end.
    @ObservationIgnored
    private var rerouteModelContext: ModelContext?

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

    /// Reroute-loop cadence. The FIRST evaluation runs after only the short
    /// settle delay (let GPS/EWMA warm up) so a faster alternate that exists
    /// from departure surfaces promptly instead of being silenced for the whole
    /// first leg; subsequent evaluations use the full steady interval to avoid
    /// spamming the network/UI. `var` (not `let`) so tests can shrink the delays
    /// and assert an evaluation lands well before 5 minutes.
    static var rerouteInitialDelay: Duration = .seconds(30)
    static var rerouteSteadyInterval: Duration = .seconds(300)

    /// Test-only instrumentation: counts how many times the reroute loop has
    /// woken from its sleep and reached the candidate-evaluation phase. Lets a
    /// test confirm the FIRST evaluation happens promptly after nav starts
    /// (well before the 5-minute steady interval) rather than being gated behind
    /// the first sleep. Not used by production logic.
    @ObservationIgnored
    private(set) var rerouteEvaluationCount: Int = 0

    var upcomingSteps: [UpcomingStep] = []

    /// The active navigation engine — shared so CarPlay can read the same state
    var activeEngine: NavigationEngine? = nil
    /// Route coordinates for map rendering
    var activeRouteCoords: [CLLocationCoordinate2D] = []

    /// Durable home for the off-route recovery budget so it survives a SwiftUI
    /// view rebuild mid-trip. The cap (RouteRecoveryEngine abandons to
    /// destination once `recoveriesThisTrip >= 3`) is meant to hold across a
    /// WHOLE trip; HomeView used to keep this only in its own @State, which a
    /// forced subtree re-identity (scene reconnect, etc.) resets to 0 — re-arming
    /// the cap mid-trip. HomeView mirrors its working copy here on every change
    /// and restores from here in reAdoptActiveSessionIfNeeded, the same way it
    /// restores activeCommute/activeTrip/activeRouteCoords. `lastRecoveryAt` is
    /// kept alongside so the 30s request cooldown survives the rebuild too.
    /// These live OUTSIDE startObserving/stopObserving's reset because the budget
    /// must persist across the begin*/startObserving boundary that runs on every
    /// trip leg; HomeView owns when to reset it (RecoveryBudget.shouldReset).
    @ObservationIgnored
    var recoveriesThisTrip: Int = 0
    @ObservationIgnored
    var lastRecoveryAt: Date?

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

    /// Wall-clock time of the last `reloadTimelines` forced during an active
    /// drive's per-minute sync. WidgetKit budgets app-initiated timeline reloads
    /// (only a few dozen/day); a 40-60 min commute that reloaded on every
    /// whole-minute ETA tick could alone consume the whole day's budget, after
    /// which even the idle "next commute" widget stops refreshing. So during
    /// active nav we coarsen the forced reload to at most one per
    /// `liveReloadMinInterval` — the App Group defaults are still rewritten every
    /// minute (so the widget shows fresh data whenever iOS refreshes it on its
    /// own ~15-min timeline cadence), we just stop *forcing* a reload each minute.
    /// The live ETA is already surfaced minute-by-minute by the phone UI / Live
    /// Activity / CarPlay, so the home-screen widget doesn't need it. Session
    /// start, arrival, and end still force an immediate reload (those go through
    /// writeWidgetSession / the arrival branch / clearWidgetSession). Reset at
    /// session start/end.
    @ObservationIgnored
    private var lastWidgetReloadAt: Date?

    /// Minimum spacing between drive-time forced widget reloads. Coarse enough
    /// that a long commute spends a handful of reloads, not one per minute.
    static let liveReloadMinInterval: TimeInterval = 180 // 3 min

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
        // Fresh session starts a fresh reroute-cadence count.
        rerouteEvaluationCount = 0
        activeEngine = engine
        activeCommute = commute
        activeDirection = direction
        activeTrip = trip
        // Identity of the route actually being driven, so the reroute loop can
        // exclude it (and only it) from candidates regardless of its rank.
        activeRouteID = routeID

        // Capture the reroute inputs NOW, while the @Model graph is valid, into a
        // Sendable value snapshot the loop iterates instead of the live
        // relationship — so a mid-drive deletion can never trap the loop. Also
        // capture the context to re-fetch the winning route by id later.
        if let commute, let direction {
            rerouteInputs = Self.rerouteSnapshot(
                commute: commute,
                direction: direction,
                excludingRouteID: routeID
            )
            rerouteModelContext = commute.modelContext
        } else {
            rerouteInputs = nil
            rerouteModelContext = nil
        }

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

        // Reroute engine - periodic fallback check.
        //
        // Cadence: evaluate PROMPTLY after nav starts, then settle into the
        // steady 5-minute interval. The loop sleeps at the END of each cycle —
        // never before the first evaluation — so a faster alternate that exists
        // from departure (the moment it's most valuable, and the only moment a
        // short commute may have) can surface without being silenced for the
        // whole first leg. The first sleep is shortened to let GPS/EWMA settle
        // and a valid currentCoordinate appear; subsequent sleeps use the full
        // interval to avoid spamming the network/UI.
        if let commute, let direction {
            rerouteTask = Task { @MainActor [weak self] in
                let directionsService = DirectionsService()
                let initialDelay = Self.rerouteInitialDelay
                let steadyInterval = Self.rerouteSteadyInterval
                var isFirstCycle = true

                while !Task.isCancelled {
                    guard let self else { break }
                    guard !self.hasArrived else { break }

                    // Short settle delay before the FIRST evaluation (let GPS /
                    // EWMA warm up), full interval between subsequent cycles.
                    let delay = isFirstCycle ? initialDelay : steadyInterval
                    isFirstCycle = false
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { break }
                    guard !self.hasArrived else { break }

                    // Reached the evaluation phase for this cycle. Record it
                    // (test instrumentation) BEFORE the suppression/engine
                    // guards so the count reflects loop cadence, not whether a
                    // suggestion is currently pending.
                    self.rerouteEvaluationCount += 1

                    guard self.rerouteSuggestion == nil else { continue }

                    guard let engine = self.activeEngine,
                          engine.isNavigating,
                          let currentCoord = engine.currentCoordinate else { continue }

                    // Use the Sendable snapshot captured at session start — NEVER
                    // the live `commute.routes` relationship. The commute/route
                    // @Models can be deleted mid-drive (CommuteListView/DetailView
                    // delete, Settings "delete all data") on a session that never
                    // tore down (e.g. a CarPlay-only drive with no HomeView
                    // observer). Even reading a cascade-deleted route's `isDeleted`
                    // off the cached relationship traps once its backing data is
                    // gone, so the loop must not touch the graph at all here.
                    guard let snapshot = self.rerouteInputs,
                          !snapshot.candidates.isEmpty else { continue }

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
                    let baseline: RouteETA
                    do {
                        baseline = try await directionsService.fetchPathAwareETA(
                            from: currentCoord,
                            along: PolylineEncoder.encode(remainingPolyline, precision: 6)
                        )
                    } catch {
                        // Couldn't get a comparable baseline this cycle — skip
                        // rather than fall back to a non-path-aware estimate and
                        // compare incomparable numbers.
                        continue
                    }
                    let remainingETA = baseline.duration

                    // The fetch awaited; bail if the session changed underneath.
                    guard !Task.isCancelled,
                          let liveEngine = self.activeEngine,
                          liveEngine === engine,
                          liveEngine.isNavigating,
                          !self.hasArrived else { break }

                    self.currentRemainingETA = remainingETA

                    // Snapshot the "Stay" suppression state HERE, on the main
                    // actor, into a Sendable value — BEFORE bestReroute's awaits.
                    // bestReroute then evaluates the cooldown purely from this
                    // snapshot. Reading the @MainActor suppression fields from
                    // inside the nonisolated post-await continuation (as the old
                    // closure did) raced a concurrent decline writing them.
                    let suppression = self.rerouteSuppressionSnapshot()

                    // Evaluate candidates over the Sendable snapshot — never the
                    // @Models — so the network awaits inside `bestReroute` can't
                    // touch a model invalidated by a concurrent delete. The result
                    // is the WINNING candidate's id, mapped back to a live Route
                    // below under a fresh liveness gate.
                    let bestRerouteResult = await Self.bestReroute(
                        candidates: snapshot.candidates,
                        currentCoord: currentCoord,
                        baseline: baseline,
                        basePercentage: snapshot.thresholdPercentage,
                        hardMinuteFloor: snapshot.hardMinuteFloor,
                        suppression: suppression,
                        fetchETA: { coord, polyline in
                            try await directionsService.fetchPathAwareETA(from: coord, along: polyline)
                        }
                    )

                    // Final guard: only surface the suggestion if the same session
                    // is still live after all the awaits above, AND the winning
                    // route still exists. The commute/route may have been deleted
                    // during the candidate fetches, so re-resolve the winner by id
                    // with a fresh predicate fetch (which safely returns nil if the
                    // route was deleted) instead of dereferencing a stale @Model —
                    // the suggestion's `route` is handed to switchToRoute, which
                    // needs a valid @Model, so a stale handle would crash on switch.
                    if let result = bestRerouteResult,
                       !Task.isCancelled,
                       let liveEngine = self.activeEngine,
                       liveEngine === engine,
                       liveEngine.isNavigating,
                       !self.hasArrived,
                       let liveRoute = Self.fetchLiveRoute(id: result.routeID, in: self.rerouteModelContext) {
                        self.rerouteSuggestion = (
                            route: liveRoute,
                            savingsMinutes: result.savingsMinutes,
                            savingsPercentage: result.savingsPercentage
                        )
                    }
                }
            }
        }
    }

    // MARK: - Reroute Snapshot (cross-await safety)

    /// A plain, `Sendable` snapshot of one candidate route the reroute decision
    /// needs — its identity and the geometry to fetch a path-aware ETA along.
    /// Decoupled from the `@Model Route` so the async ETA fetches never re-touch a
    /// model that a concurrent mid-drive delete may have invalidated.
    struct RerouteCandidate: Sendable {
        let id: UUID
        let encodedPolyline: String
    }

    /// Everything the reroute decision reads off the `@Model Commute`/`Route`
    /// graph, captured as `Sendable` value types so it can cross the loop's
    /// `await` points safely. Built on the main actor while the models are valid.
    struct RerouteSnapshot: Sendable {
        let thresholdPercentage: Double
        let hardMinuteFloor: Int?
        let candidates: [RerouteCandidate]
    }

    /// A plain, `Sendable` value snapshot of the reroute-suppression state
    /// (the "Stay" cooldown): which route was just declined, when, and the
    /// savings that were rejected. Captured on the main actor immediately before
    /// `bestReroute`'s candidate loop, so the post-`await` suppression decision
    /// reads from THIS immutable value instead of touching the `@MainActor`
    /// fields `dismissedRouteID`/`dismissedAt`/`dismissedSavingsSeconds` from a
    /// background continuation — those fields are written on the main actor
    /// (`dismissRerouteSuggestion`/`clearDismissedReroute`), so reading them off
    /// the actor after the ETA fetch raced a concurrent decline. The cooldown
    /// policy lives here as a pure function so the loop never re-enters the
    /// actor to ask "is this suppressed?". Mirrors how `RerouteSnapshot`
    /// detaches the `@Model` graph for the same cross-await safety reason.
    struct RerouteSuppression: Sendable {
        let dismissedRouteID: UUID?
        let dismissedAt: Date?
        let dismissedSavingsSeconds: TimeInterval

        /// Nothing declined — suppresses nothing. The state at session start and
        /// after `clearDismissedReroute`; also the obvious test default.
        static let none = RerouteSuppression(dismissedRouteID: nil, dismissedAt: nil, dismissedSavingsSeconds: 0)

        /// Whether a candidate is suppressed by a prior "Stay" at evaluation time
        /// `now`. Suppressed only while the same route is still inside the cooldown
        /// window, unless the new savings beats the rejected savings by a material
        /// margin. Pure (no actor access) — safe to call from the nonisolated loop.
        func isSuppressed(routeID: UUID, savingsSeconds: TimeInterval, now: Date) -> Bool {
            guard routeID == dismissedRouteID, let dismissedAt else { return false }
            guard now.timeIntervalSince(dismissedAt) < NavigationStateManager.rerouteDismissCooldown else { return false }
            return savingsSeconds < dismissedSavingsSeconds + NavigationStateManager.rerouteResuggestMargin
        }
    }

    /// Whether a SwiftData `@Model` is still valid to read. A deleted model has a
    /// nil `modelContext` (and/or `isDeleted == true`); reading its persisted
    /// properties after deletion traps. Mirrors the `condition.modelContext`
    /// liveness checks in RoadConditionService / SpeedCameraService.
    private static func isLive(_ commute: Commute) -> Bool {
        !commute.isDeleted && commute.modelContext != nil
    }

    /// Build a `Sendable` snapshot of the reroute inputs from the live commute,
    /// excluding the route currently being driven (by identity, not rank — see the
    /// `activeRouteID` doc). Captured once at session start (`startObserving`),
    /// while the @Model graph is valid, so the long-lived reroute loop iterates the
    /// value snapshot and never re-touches the relationship. Returns nil if the
    /// commute is already gone.
    static func rerouteSnapshot(
        commute: Commute,
        direction: CommuteDirection,
        excludingRouteID activeRouteID: UUID?
    ) -> RerouteSnapshot? {
        guard isLive(commute) else { return nil }
        let candidates = commute.orderedRoutes(for: direction)
            .filter { !$0.isDeleted && $0.modelContext != nil && $0.id != activeRouteID }
            .map { RerouteCandidate(id: $0.id, encodedPolyline: $0.encodedPolyline) }
        return RerouteSnapshot(
            thresholdPercentage: commute.thresholdPercentage,
            hardMinuteFloor: commute.hardMinuteFloor,
            candidates: candidates
        )
    }

    /// Re-resolve a candidate route by id with a fresh predicate fetch, after the
    /// candidate-fetch awaits. A predicate fetch on the context safely returns an
    /// empty result if the route was deleted mid-drive — unlike dereferencing a
    /// cached @Model handle, which traps once its backing data is gone. Returns
    /// nil if the context is unavailable or the route no longer exists, so the
    /// loop never surfaces a suggestion pointing at an invalidated @Model
    /// (switchToRoute would otherwise crash on it). MainActor-isolated: the fetch
    /// runs on the context's main-actor executor.
    static func fetchLiveRoute(id: UUID, in context: ModelContext?) -> Route? {
        guard let context else { return nil }
        var descriptor = FetchDescriptor<Route>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
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
    /// The active route's baseline carries its measurement basis (`isPathAware`),
    /// and each candidate's fetched ETA carries its own. A candidate is only
    /// compared when its basis MATCHES the baseline's: if either side fell back
    /// to a direct (open-road) estimate while the other stayed path-aware, the
    /// two numbers are incomparable (the direct estimate is generally shorter
    /// than the committed path), so comparing them would manufacture phantom
    /// "faster route" savings. Mismatched candidates are skipped this cycle
    /// rather than compared across bases — exactly the symmetry guarantee the
    /// main via-route path already upholds, now extended to the fallback.
    ///
    /// Pure and dependency-injected (`fetchETA`, plus a value `suppression`
    /// snapshot) so the symmetric-comparison contract is unit-testable without a
    /// live engine or network. Candidate exclusion (the active route) is the
    /// caller's job.
    ///
    /// Operates on `Sendable` `RerouteCandidate` value snapshots (id + encoded
    /// polyline), never the `@Model Route`, so the network `fetchETA` awaits
    /// inside this loop can't re-touch a model invalidated by a concurrent
    /// mid-drive delete. Returns the WINNING candidate's id; the caller maps it
    /// back to a still-live `Route` under a fresh liveness gate.
    ///
    /// Suppression ("Stay" cooldown) is evaluated against the `Sendable`
    /// `suppression` value snapshot captured on the main actor before this loop
    /// runs — NEVER by reaching back into the `@MainActor` suppression fields
    /// from this nonisolated continuation, which would race a concurrent decline
    /// after the ETA `await`. `now` is injectable for tests; the cooldown is
    /// measured from `now` against the snapshot's `dismissedAt`.
    nonisolated static func bestReroute(
        candidates: [RerouteCandidate],
        currentCoord: CLLocationCoordinate2D,
        baseline: RouteETA,
        basePercentage: Double,
        hardMinuteFloor: Int?,
        suppression: RerouteSuppression,
        now: Date = Date(),
        fetchETA: (CLLocationCoordinate2D, String) async throws -> RouteETA
    ) async -> (routeID: UUID, savingsMinutes: Double, savingsPercentage: Double)? {
        let remainingETASeconds = baseline.duration
        var bestSuggestion: (routeID: UUID, savingsMinutes: Double, savingsPercentage: Double)?
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

            let candidateETA: RouteETA
            do {
                candidateETA = try await fetchETA(
                    currentCoord,
                    PolylineEncoder.encode(candidateRemaining, precision: 6)
                )
            } catch {
                continue
            }

            // Comparability gate: only compare ETAs measured on the SAME basis.
            // A path-aware baseline vs. a direct-fallback candidate (or vice
            // versa) would yield phantom savings, so skip the candidate rather
            // than compare incomparable numbers.
            guard candidateETA.isPathAware == baseline.isPathAware else { continue }

            let decision = RerouteEngine.evaluate(
                remainingETASeconds: remainingETASeconds,
                fallbackETASeconds: candidateETA.duration,
                basePercentage: basePercentage,
                hardMinuteFloor: hardMinuteFloor
            )

            // Don't re-surface a route the driver just declined ("Stay") until
            // the cooldown lapses or it becomes materially faster than rejected.
            // Evaluated against the main-actor-captured snapshot, not the live
            // @MainActor fields — so this off-actor read can't race a decline.
            if suppression.isSuppressed(routeID: candidate.id, savingsSeconds: decision.savingsSeconds, now: now) {
                continue
            }

            if decision.shouldReroute, decision.savingsSeconds > bestSavings {
                bestSavings = decision.savingsSeconds
                bestSuggestion = (
                    routeID: candidate.id,
                    savingsMinutes: decision.savingsMinutes,
                    savingsPercentage: remainingETASeconds > 0 ? decision.savingsSeconds / remainingETASeconds : 0
                )
            }
        }

        return bestSuggestion
    }

    /// Copy one tick of engine state into the manager's published properties.
    /// CarPlay reads these instead of touching the engine directly.
    ///
    /// `now` and `reload` are injectable for tests (the production polling task
    /// calls `syncFromEngine(engine)` with the live clock and `WidgetCenter`).
    /// The `reload` sink lets a test count how often the timeline is actually
    /// reloaded across a simulated multi-minute drive.
    func syncFromEngine(
        _ engine: NavigationEngine,
        now: Date = Date(),
        reload: (String) -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: $0) }
    ) {
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
        // Only write the ETA + restamp when the minute actually changes.
        //
        // We ALWAYS rewrite the App Group defaults on a minute change, so the
        // widget shows fresh data whenever iOS refreshes it on its own ~15-min
        // timeline cadence. But we do NOT force a `reloadTimelines` every minute:
        // a long commute would fire ~40-60 app-initiated reloads and can blow
        // through WidgetKit's daily reload budget, after which even the idle
        // widget stops updating. The live minute-by-minute ETA is already
        // surfaced by the phone UI / Live Activity / CarPlay, so the home-screen
        // widget doesn't need a per-minute push. Instead, during active nav we
        // force a reload at most once per `liveReloadMinInterval` (session start,
        // arrival, and end still force immediate reloads via their own paths).
        widgetDefaults?.set(engine.isNavigating, forKey: Self.kIsNavigating)
        if engine.etaMinutes != lastWidgetETAMinutes {
            lastWidgetETAMinutes = engine.etaMinutes
            widgetDefaults?.set(engine.etaMinutes, forKey: Self.kETAMinutes)
            widgetDefaults?.set(now.timeIntervalSince1970, forKey: Self.kETAUpdatedAt)

            // Throttle drive-time forced reloads to a coarse cadence. First
            // minute-change of a session (lastWidgetReloadAt nil) reloads
            // immediately so the widget reflects the live drive promptly; after
            // that, only once per interval.
            let dueForReload = lastWidgetReloadAt.map {
                now.timeIntervalSince($0) >= Self.liveReloadMinInterval
            } ?? true
            if dueForReload {
                lastWidgetReloadAt = now
                reload(Self.widgetKind)
            }
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

    /// Capture the current "Stay" suppression state as a `Sendable` value so the
    /// nonisolated reroute loop can evaluate the cooldown across its `await`
    /// boundary WITHOUT reading the `@MainActor` suppression fields off-actor.
    /// Built on the main actor (these fields are main-actor-isolated), then
    /// handed to `bestReroute`. The race the snapshot closes: a driver tapping
    /// "Stay" (`dismissRerouteSuggestion`) writes these fields on the main actor
    /// at the same instant the post-ETA-fetch continuation reads them on a
    /// cooperative-pool thread.
    func rerouteSuppressionSnapshot() -> RerouteSuppression {
        RerouteSuppression(
            dismissedRouteID: dismissedRouteID,
            dismissedAt: dismissedAt,
            dismissedSavingsSeconds: dismissedSavingsSeconds
        )
    }

    /// Whether a candidate route is currently suppressed because the driver just
    /// declined it. Suppressed while inside the cooldown window, unless the new
    /// savings beats the rejected savings by a material margin.
    /// `internal` (not `private`) so the cooldown policy is unit-testable.
    /// Delegates to the same pure logic the reroute loop uses via its snapshot,
    /// so the live-state and snapshot paths can never drift.
    func isRerouteSuppressed(routeID: UUID, savingsSeconds: TimeInterval, now: Date = Date()) -> Bool {
        rerouteSuppressionSnapshot().isSuppressed(routeID: routeID, savingsSeconds: savingsSeconds, now: now)
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
        rerouteInputs = nil
        rerouteModelContext = nil
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
        // New session — clear the drive-time reload throttle so the first
        // minute-change of the new drive forces an immediate reload (and this
        // session-start reload below seeds the cadence implicitly).
        lastWidgetReloadAt = nil
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
        lastWidgetReloadAt = nil
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
        // Round, don't truncate: 10.95 mi -> "11 mi", not "10 mi" (an up-to-1-mi
        // understatement of the distance remaining).
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
        // Mirror NavigationEngine.formatArrivalTime: "jmm" is the locale-aware
        // hour:minute template — it resolves to a 12h clock (with AM/PM) or a 24h
        // clock per the locale's own preference, instead of forcing "h:mm a"
        // which renders garbage like "16:00 PM"-equivalents in 24h locales.
        formatter.setLocalizedDateFormatFromTemplate("jmm")
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
