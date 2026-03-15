import Foundation
import SwiftData
import CoreLocation
import Observation

/// View model that wraps NavigationCoordinator for the navigation UI.
/// Manages active navigation state, reroute suggestions, and post-arrival recording.
@Observable
@MainActor
final class NavigationViewModel {

    // MARK: - Navigation State

    var isNavigating: Bool = false
    var currentETA: TimeInterval?
    var currentRoute: Route?
    var rerouteSuggestion: RerouteSuggestion?
    var isRecording: Bool = false
    var navigationProgress: NavigationProgress = .idle

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let navigationCoordinator: NavigationCoordinator
    private let locationService: LocationService
    private let mapMatchingService: MapMatchingService
    private var navigationTask: Task<Void, Never>?

    // MARK: - Init

    init(
        modelContext: ModelContext,
        navigationCoordinator: NavigationCoordinator,
        locationService: LocationService,
        mapMatchingService: MapMatchingService
    ) {
        self.modelContext = modelContext
        self.navigationCoordinator = navigationCoordinator
        self.locationService = locationService
        self.mapMatchingService = mapMatchingService
    }

    deinit {
        navigationTask?.cancel()
    }

    // MARK: - Navigation Lifecycle

    func startNavigation(to destination: PinnedLocation, commute: Commute?) {
        guard let route = commute?.preferredRoute else { return }

        currentRoute = route
        isNavigating = true
        navigationProgress = .navigating
        isRecording = true
        locationService.startRecording()

        navigationTask = Task { [weak self] in
            await self?.navigationCoordinator.startSession(
                route: route,
                commute: commute,
                destination: destination
            )
            await self?.observeNavigationUpdates()
        }
    }

    func stopNavigation() {
        navigationTask?.cancel()
        navigationTask = nil
        navigationCoordinator.stopSession()

        if isRecording {
            _ = locationService.stopRecording()
            isRecording = false
        }

        isNavigating = false
        currentETA = nil
        currentRoute = nil
        rerouteSuggestion = nil
        navigationProgress = .idle
    }

    // MARK: - Reroute Handling

    func acceptReroute() {
        guard let suggestion = rerouteSuggestion else { return }
        currentRoute = suggestion.fallbackRoute
        currentETA = suggestion.fallbackETA
        rerouteSuggestion = nil
        navigationCoordinator.switchToRoute(suggestion.fallbackRoute)
    }

    func dismissReroute() {
        rerouteSuggestion = nil
        navigationCoordinator.dismissCurrentSuggestion()
    }

    // MARK: - Post-Arrival Recording

    /// After arriving, save the recorded GPS trace as a new route for the commute.
    func saveRecordedRoute(name: String?, asPreferredFor commute: Commute) async throws {
        let points = locationService.stopRecording()
        isRecording = false
        navigationProgress = .processing

        let matched = try await mapMatchingService.matchTrace(points)

        let nextRank = (commute.routes?.count ?? 0)
        let route = Route(
            rank: nextRank,
            encodedPolyline: matched.encodedPolyline,
            name: name,
            distanceMeters: matched.distanceMeters,
            source: .recorded
        )
        route.commute = commute
        if commute.routes == nil {
            commute.routes = []
        }
        commute.routes?.append(route)
        modelContext.insert(route)

        // Also persist the raw drive record
        let record = DriveRecord(startedAt: Date())
        record.rawGPSPoints = points
        record.matchedPolyline = matched.encodedPolyline
        record.associatedCommute = commute
        record.wasConverted = true
        modelContext.insert(record)

        try? modelContext.save()
        navigationProgress = .arrived
    }

    // MARK: - Internal

    private func observeNavigationUpdates() async {
        // Poll the coordinator for state changes while navigating.
        // In production this would use AsyncStream from the coordinator.
        while !Task.isCancelled && isNavigating {
            currentETA = navigationCoordinator.currentETASeconds
            if let suggestion = navigationCoordinator.pendingSuggestion {
                rerouteSuggestion = suggestion
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

// MARK: - Supporting Types

enum NavigationProgress {
    case idle
    case navigating
    case processing  // map matching the recorded trace
    case arrived
}

struct RerouteSuggestion {
    let fallbackRoute: Route
    let fallbackETA: TimeInterval
    let savingsSeconds: TimeInterval
    let decision: RerouteDecision
}
