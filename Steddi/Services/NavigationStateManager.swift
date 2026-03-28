import Foundation
import CoreLocation
import MapKit

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
    var headingDegrees: Double = 0
    var currentCoordinate: CLLocationCoordinate2D? = nil
    var distanceRemainingMeters: Double = 0
    var etaSeconds: TimeInterval = 0

    var hasArrived: Bool = false

    var activeCommute: Commute? = nil
    var activeDirection: CommuteDirection? = nil

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

    // MARK: - Observation

    func startObserving(
        engine: NavigationEngine,
        commute: Commute? = nil,
        direction: CommuteDirection? = nil
    ) {
        stopObserving()

        isNavigating = true
        activeEngine = engine
        activeCommute = commute
        activeDirection = direction

        // Store route coords for CarPlay map rendering
        activeRouteCoords = engine.routePolylineCoordinates

        // Polling task — copies engine state to manager properties (for CarPlay to read)
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let engine = self.activeEngine else { break }
                guard engine.isNavigating else { break }

                self.instruction = engine.instruction
                self.stepDistance = engine.stepDistance
                self.stepDistanceRaw = engine.stepDistanceRaw
                self.etaMinutes = engine.etaMinutes
                self.distanceRemaining = engine.distanceRemaining
                self.arrivalTime = engine.arrivalTime
                self.roadName = engine.roadName
                self.maneuverType = engine.maneuverType
                self.followOnInstruction = engine.followOnInstruction
                self.followOnManeuverSymbol = engine.followOnManeuverSymbol
                self.currentSpeedMph = engine.currentSpeedMph
                self.speedLimitMph = engine.speedLimitMph
                self.headingDegrees = engine.headingDegrees
                self.currentCoordinate = engine.currentCoordinate
                self.distanceRemainingMeters = engine.distanceRemainingMeters
                self.etaSeconds = engine.etaSeconds

                // Build upcoming steps from engine
                self.upcomingSteps = Self.buildUpcomingSteps(from: engine)

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
                                    savingsPercentage: decision.savingsSeconds / remainingETA
                                )
                            }
                        } catch {
                            continue
                        }
                    }

                    if let suggestion = bestSuggestion {
                        self.rerouteSuggestion = suggestion
                    }
                }
            }
        }
    }

    func stopObserving() {
        pollingTask?.cancel()
        rerouteTask?.cancel()

        pollingTask = nil
        rerouteTask = nil

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
        headingDegrees = 0
        currentCoordinate = nil
        distanceRemainingMeters = 0
        etaSeconds = 0
        hasArrived = false
        activeCommute = nil
        activeDirection = nil
        activeEngine = nil
        activeRouteCoords = []
        rerouteSuggestion = nil
        currentRemainingETA = 0
        upcomingSteps = []
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
