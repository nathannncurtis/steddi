import Foundation
import CoreLocation
import Observation

/// Coordinates the full navigation session lifecycle.
/// Manages active route tracking, ETA polling, and reroute suggestions.
@MainActor
@Observable
final class NavigationCoordinator {
    var isNavigating: Bool = false
    var currentCommute: Commute?
    var activeRoute: Route?
    var currentETA: TimeInterval?
    var isRecordingTrace: Bool = false
    var rerouteSuggestion: RerouteSuggestion?

    private let directionsService: DirectionsService
    private let locationService: LocationService
    private let offlineCacheService: OfflineCacheService

    private var lazyPollTask: Task<Void, Never>?
    private let pollIntervalSeconds: TimeInterval = 420 // 7 minutes

    init(
        directionsService: DirectionsService,
        locationService: LocationService,
        offlineCacheService: OfflineCacheService
    ) {
        self.directionsService = directionsService
        self.locationService = locationService
        self.offlineCacheService = offlineCacheService
    }

    /// Start a navigation session to a pinned location, optionally tied to a commute.
    func startNavigation(to destination: PinnedLocation, commute: Commute? = nil) async {
        guard let currentLocation = locationService.currentLocation else { return }

        currentCommute = commute
        isNavigating = true
        rerouteSuggestion = nil

        // Fetch initial route if no commute preferred route
        if let preferred = commute?.preferredRoute {
            activeRoute = preferred
        } else {
            do {
                let origin = currentLocation.coordinate
                let dest = destination.coordinate
                let directions = try await directionsService.fetchRoute(from: origin, to: dest)
                // Create a transient route for non-commute navigation
                activeRoute = Route(
                    rank: 0,
                    encodedPolyline: directions.encodedPolyline,
                    distanceMeters: directions.distanceMeters,
                    typicalDurationSeconds: directions.durationSeconds,
                    source: .planned
                )
                currentETA = directions.durationSeconds
            } catch {
                isNavigating = false
                return
            }
        }

        // Cache the active route for offline fallback
        if let route = activeRoute {
            try? offlineCacheService.cacheActiveRoute(route)
            offlineCacheService.cancelScheduledCleanup()
        }

        // Begin GPS recording
        locationService.startRecording()
        isRecordingTrace = true

        // Fetch initial ETA for commute routes
        if let route = activeRoute, currentCommute != nil {
            await refreshETA(for: route)
        }

        // Start lazy polling for fallback evaluation
        startLazyPolling()
    }

    /// Stop the current navigation session.
    func stopNavigation() -> [GPSPoint] {
        isNavigating = false
        currentCommute = nil
        activeRoute = nil
        currentETA = nil
        rerouteSuggestion = nil

        stopLazyPolling()

        // Stop GPS recording and return the trace
        isRecordingTrace = false
        let trace = locationService.stopRecording()

        // Schedule cache cleanup
        offlineCacheService.scheduleCleanup()

        return trace
    }

    /// Switch to a fallback route mid-navigation.
    func switchToFallback(_ route: Route) {
        activeRoute = route
        rerouteSuggestion = nil

        // Cache the new active route
        try? offlineCacheService.cacheActiveRoute(route)
    }

    // MARK: - ETA & Reroute Polling

    private func startLazyPolling() {
        stopLazyPolling()
        lazyPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pollIntervalSeconds))
                guard !Task.isCancelled, isNavigating else { break }
                await evaluateFallbacks()
            }
        }
    }

    private func stopLazyPolling() {
        lazyPollTask?.cancel()
        lazyPollTask = nil
    }

    private func refreshETA(for route: Route) async {
        guard let location = locationService.currentLocation else { return }
        do {
            let eta = try await directionsService.fetchETA(
                from: location.coordinate,
                along: route.encodedPolyline
            )
            currentETA = eta
        } catch {
            // Keep the previous ETA on failure
        }
    }

    /// Evaluate all fallback routes against the active route.
    /// Uses RerouteEngine to decide if a switch should be suggested.
    private func evaluateFallbacks() async {
        guard let commute = currentCommute,
              let active = activeRoute,
              let location = locationService.currentLocation else { return }

        // Refresh current route ETA
        await refreshETA(for: active)
        guard let remainingETA = currentETA else { return }

        let fallbacks = commute.orderedRoutes.filter { $0.id != active.id }
        guard !fallbacks.isEmpty else { return }

        var bestSuggestion: RerouteSuggestion?
        var bestSavings: TimeInterval = 0

        for fallback in fallbacks {
            do {
                let fallbackETA = try await directionsService.fetchETA(
                    from: location.coordinate,
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
                    bestSuggestion = RerouteSuggestion(
                        fallbackRoute: fallback,
                        savingsMinutes: decision.savingsMinutes,
                        savingsPercentage: decision.savingsSeconds / remainingETA
                    )
                }
            } catch {
                continue
            }
        }

        rerouteSuggestion = bestSuggestion
    }
}

/// A suggested reroute with the fallback route and estimated savings.
struct RerouteSuggestion {
    let fallbackRoute: Route
    let savingsMinutes: Double
    let savingsPercentage: Double
}
