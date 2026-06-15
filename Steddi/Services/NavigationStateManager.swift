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
        destinationName: String? = nil
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

                    let fallbacks = commute.orderedRoutes(for: direction).filter { $0.rank > 0 }
                    guard !fallbacks.isEmpty else { continue }

                    var bestSuggestion: (route: Route, savingsMinutes: Double, savingsPercentage: Double)?
                    var bestSavings: TimeInterval = 0

                    for fallback in fallbacks {
                        do {
                            let fallbackETA = try await directionsService.fetchETA(
                                from: currentCoord,
                                along: fallback.encodedPolyline
                            )

                            // The fetch awaited; the session may have ended (or a
                            // different engine taken over) while it was in flight.
                            // Bail before applying a stale reroute result so it
                            // can't land after navigation was torn down.
                            guard !Task.isCancelled,
                                  let liveEngine = self.activeEngine,
                                  liveEngine === engine,
                                  liveEngine.isNavigating,
                                  !self.hasArrived else { break }

                            let decision = RerouteEngine.evaluate(
                                remainingETASeconds: remainingETA,
                                fallbackETASeconds: fallbackETA,
                                basePercentage: commute.thresholdPercentage,
                                hardMinuteFloor: commute.hardMinuteFloor
                            )

                            // Don't re-surface a route the driver just declined
                            // (tapped "Stay") until the cooldown lapses or it
                            // becomes materially faster than what was rejected.
                            if self.isRerouteSuppressed(
                                routeID: fallback.id,
                                savingsSeconds: decision.savingsSeconds
                            ) {
                                continue
                            }

                            if decision.shouldReroute, decision.savingsSeconds > bestSavings {
                                bestSavings = decision.savingsSeconds
                                bestSuggestion = (
                                    route: fallback,
                                    savingsMinutes: decision.savingsMinutes,
                                    savingsPercentage: remainingETA > 0 ? decision.savingsSeconds / remainingETA : 0
                                )
                            }
                        } catch {
                            continue
                        }
                    }

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
        widgetDefaults?.set(engine.etaMinutes, forKey: Self.kETAMinutes)
        widgetDefaults?.set(Date().timeIntervalSince1970, forKey: Self.kETAUpdatedAt)
        widgetDefaults?.set(engine.isNavigating, forKey: Self.kIsNavigating)
        if engine.etaMinutes != lastWidgetETAMinutes {
            lastWidgetETAMinutes = engine.etaMinutes
            WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        }
    }

    /// Tear down an in-progress trip session cleanly — used when the active
    /// trip is deleted out from under navigation. Stops the engine first so no
    /// further ticks fire, then clears all observation state (including
    /// `activeTrip`) so nothing is left pointing at a deleted model.
    func endActiveTripSession() {
        activeEngine?.stopNavigation()
        stopObserving()
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

    /// Navigation ended. Keep the last live ETA + its timestamp so the widget
    /// shows the most recent known commute ETA when idle (the whole point of a
    /// commute-ETA widget) — flagged as not-live and with a freshness stamp so
    /// the widget can present it as "last known" rather than a live number.
    private func clearWidgetSession() {
        lastWidgetETAMinutes = nil
        widgetDefaults?.set(false, forKey: Self.kIsNavigating)
        // Intentionally NOT clearing kETAMinutes/kDestinationName/kCommuteName:
        // the last-known commute ETA is exactly what the idle widget should show.
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
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
