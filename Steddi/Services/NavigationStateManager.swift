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

    @ObservationIgnored
    private let widgetDefaults = UserDefaults(suiteName: NavigationStateManager.widgetSuiteName)

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

                    // Use the engine's ETA (in seconds) — etaMinutes * 60 as approximation
                    let remainingETA = Double(engine.etaMinutes) * 60.0
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

        // Write to shared App Group for widget
        widgetDefaults?.set(engine.etaMinutes, forKey: "widget.etaMinutes")
        widgetDefaults?.set(engine.isNavigating, forKey: "widget.isNavigating")
    }

    /// Tear down an in-progress trip session cleanly — used when the active
    /// trip is deleted out from under navigation. Stops the engine first so no
    /// further ticks fire, then clears all observation state (including
    /// `activeTrip`) so nothing is left pointing at a deleted model.
    func endActiveTripSession() {
        activeEngine?.stopNavigation()
        stopObserving()
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
    }

    // MARK: - Widget Session

    /// Write the session identity (commute + destination names) the widget
    /// renders alongside the per-tick ETA, then refresh its timeline.
    private func writeWidgetSession(commute: Commute?, direction: CommuteDirection?, destinationName: String?) {
        let resolvedDestination = destinationName ?? Self.commuteEndpointName(commute: commute, direction: direction)

        if let commuteName = commute?.name {
            widgetDefaults?.set(commuteName, forKey: "widget.commuteName")
        } else {
            // No commute (search nav) — fall back to the widget's default label
            widgetDefaults?.removeObject(forKey: "widget.commuteName")
        }

        if let resolvedDestination {
            widgetDefaults?.set(resolvedDestination, forKey: "widget.destinationName")
        } else {
            widgetDefaults?.removeObject(forKey: "widget.destinationName")
        }

        widgetDefaults?.set(true, forKey: "widget.isNavigating")
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }

    /// Navigation ended — the live ETA is meaningless now, but the names stay
    /// so the widget keeps its commute context until the next session.
    private func clearWidgetSession() {
        widgetDefaults?.set(false, forKey: "widget.isNavigating")
        widgetDefaults?.set(0, forKey: "widget.etaMinutes")
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
