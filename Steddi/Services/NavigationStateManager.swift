import Foundation
import CoreLocation
import MapboxNavigationCore
import MapboxDirections

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

    var hasArrived: Bool = false

    var activeCommute: Commute? = nil
    var activeDirection: CommuteDirection? = nil

    var rerouteSuggestion: (route: Route, savingsMinutes: Double, savingsPercentage: Double)? = nil
    var currentRemainingETA: TimeInterval = 0

    var upcomingSteps: [UpcomingStep] = []

    // MARK: - Task Storage

    private nonisolated(unsafe) var routeProgressTask: Task<Void, Never>?
    private nonisolated(unsafe) var locationMatchingTask: Task<Void, Never>?
    private nonisolated(unsafe) var arrivalTask: Task<Void, Never>?
    private nonisolated(unsafe) var rerouteTask: Task<Void, Never>?

    // MARK: - Observation

    func startObserving(
        provider: MapboxNavigationProvider,
        commute: Commute? = nil,
        direction: CommuteDirection? = nil
    ) {
        stopObserving()

        isNavigating = true
        activeCommute = commute
        activeDirection = direction

        let nav = provider.navigation()

        // Route progress
        routeProgressTask = Task { @MainActor [weak self] in
            for await state in nav.routeProgress.values {
                guard let self, let state else { continue }
                let progress = state.routeProgress

                self.etaMinutes = max(1, Int(ceil(progress.durationRemaining / 60)))
                self.distanceRemaining = Self.formatDistance(progress.distanceRemaining)
                self.arrivalTime = Self.formatArrivalTime(progress.durationRemaining)

                // Current step
                let step = progress.currentLegProgress.currentStep
                self.instruction = step.instructions
                self.stepDistanceRaw = progress.currentLegProgress.currentStepProgress.distanceRemaining
                self.stepDistance = Self.formatDistance(self.stepDistanceRaw)
                self.maneuverType = Self.sfSymbol(for: step.maneuverType, direction: step.maneuverDirection)

                // Follow-on step
                if let followOn = progress.currentLegProgress.followOnStep {
                    self.followOnInstruction = followOn.instructions
                    self.followOnManeuverSymbol = Self.sfSymbol(for: followOn.maneuverType, direction: followOn.maneuverDirection)
                } else {
                    self.followOnInstruction = ""
                    self.followOnManeuverSymbol = ""
                }

                // Build upcoming steps from remaining steps in the current leg
                self.upcomingSteps = Self.buildUpcomingSteps(from: progress)
            }
        }

        // Location matching - road name, speed, heading
        locationMatchingTask = Task { @MainActor [weak self] in
            for await state in nav.locationMatching.values {
                guard let self else { return }

                self.roadName = state.roadName?.text ?? ""

                let speedMS = state.currentSpeed.converted(to: .metersPerSecond).value
                self.currentSpeedMph = max(0, speedMS * 2.23694)

                if let limitValue = state.speedLimit.value {
                    self.speedLimitMph = limitValue.converted(to: .milesPerHour).value
                } else {
                    self.speedLimitMph = nil
                }

                self.headingDegrees = state.location.course
                self.currentCoordinate = state.location.coordinate
            }
        }

        // Arrival
        arrivalTask = Task { @MainActor [weak self] in
            for await arrival in nav.waypointsArrival.values {
                guard let self else { return }
                if arrival.event != nil {
                    self.hasArrived = true
                }
            }
        }

        // Reroute engine - periodic fallback check (every 5 minutes)
        if let commute, let direction {
            rerouteTask = Task { @MainActor [weak self] in
                let directionsService = DirectionsService(accessToken: MapboxTokenProvider.accessToken)

                while !Task.isCancelled {
                    guard let self else { break }
                    guard !self.hasArrived else { break }

                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled else { break }
                    guard !self.hasArrived else { break }
                    guard self.rerouteSuggestion == nil else { continue }

                    guard let currentLocation = nav.currentLocationMatching?.enhancedLocation,
                          let currentProgress = nav.currentRouteProgress else { continue }

                    let remainingETA = currentProgress.routeProgress.durationRemaining
                    self.currentRemainingETA = remainingETA

                    let fallbacks = commute.orderedRoutes(for: direction).filter { $0.rank > 0 }
                    guard !fallbacks.isEmpty else { continue }

                    var bestSuggestion: (route: Route, savingsMinutes: Double, savingsPercentage: Double)?
                    var bestSavings: TimeInterval = 0

                    for fallback in fallbacks {
                        do {
                            let fallbackETA = try await directionsService.fetchETA(
                                from: currentLocation.coordinate,
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
        routeProgressTask?.cancel()
        locationMatchingTask?.cancel()
        arrivalTask?.cancel()
        rerouteTask?.cancel()

        routeProgressTask = nil
        locationMatchingTask = nil
        arrivalTask = nil
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
        hasArrived = false
        activeCommute = nil
        activeDirection = nil
        rerouteSuggestion = nil
        currentRemainingETA = 0
        upcomingSteps = []
    }

    // MARK: - Upcoming Steps Builder

    private static func buildUpcomingSteps(from progress: RouteProgress) -> [UpcomingStep] {
        let legProgress = progress.currentLegProgress
        let steps = legProgress.leg.steps
        let currentIndex = legProgress.stepIndex

        // Gather remaining steps after the current one
        guard currentIndex + 1 < steps.count else { return [] }

        return steps[(currentIndex + 1)...].compactMap { step in
            // Skip arrive steps with no real instruction
            guard step.maneuverType != .arrive || step.instructions.isEmpty == false else {
                return UpcomingStep(
                    instruction: step.instructions,
                    distance: formatDistance(step.distance),
                    maneuverSymbol: sfSymbol(for: step.maneuverType, direction: step.maneuverDirection),
                    roadName: step.names?.first
                )
            }
            return UpcomingStep(
                instruction: step.instructions,
                distance: formatDistance(step.distance),
                maneuverSymbol: sfSymbol(for: step.maneuverType, direction: step.maneuverDirection),
                roadName: step.names?.first
            )
        }
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

    nonisolated static func sfSymbol(for maneuverType: ManeuverType, direction: ManeuverDirection?) -> String {
        switch maneuverType {
        case .turn:
            switch direction {
            case .left, .sharpLeft, .slightLeft: return "arrow.turn.up.left"
            case .right, .sharpRight, .slightRight: return "arrow.turn.up.right"
            case .uTurn: return "arrow.uturn.down"
            default: return "arrow.up"
            }
        case .merge: return "arrow.merge"
        case .takeOnRamp, .takeOffRamp:
            switch direction {
            case .left, .sharpLeft, .slightLeft: return "arrow.up.left"
            case .right, .sharpRight, .slightRight: return "arrow.up.right"
            default: return "arrow.up.right"
            }
        case .reachFork:
            switch direction {
            case .left, .slightLeft: return "arrow.up.left"
            default: return "arrow.up.right"
            }
        case .reachEnd: return "arrow.turn.up.right"
        case .useLane: return "arrow.up"
        case .takeRotary, .takeRoundabout: return "arrow.triangle.2.circlepath"
        case .arrive: return "flag.fill"
        case .depart: return "location.fill"
        default: return "arrow.up"
        }
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
