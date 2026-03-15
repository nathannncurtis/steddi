import Foundation
import SwiftData
import CoreLocation
import Observation

/// View model for the home screen.
/// Surfaces pinned locations, active commutes, and per-commute traffic badges.
@Observable
@MainActor
final class HomeViewModel {

    // MARK: - Published State

    var pinnedLocations: [PinnedLocation] = []
    var commutes: [Commute] = []
    var selectedLocation: PinnedLocation?

    /// Maps commute IDs to their current preferred-route ETA in seconds.
    /// A nil value means the ETA has not been fetched yet.
    var commuteETAs: [UUID: TimeInterval] = [:]

    /// Maps commute IDs to whether the preferred route is experiencing delays.
    var commuteHasTrafficIssue: [UUID: Bool] = [:]

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let directionsService: DirectionsService
    private var etaRefreshTask: Task<Void, Never>?

    // MARK: - Init

    init(modelContext: ModelContext, directionsService: DirectionsService) {
        self.modelContext = modelContext
        self.directionsService = directionsService
    }

    deinit {
        etaRefreshTask?.cancel()
    }

    // MARK: - Data Loading

    func loadData() {
        fetchPinnedLocations()
        fetchCommutes()
        startPeriodicETARefresh()
    }

    private func fetchPinnedLocations() {
        let descriptor = FetchDescriptor<PinnedLocation>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        pinnedLocations = (try? modelContext.fetch(descriptor)) ?? []
    }

    private func fetchCommutes() {
        let descriptor = FetchDescriptor<Commute>(
            predicate: #Predicate { $0.isActive },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        commutes = (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - ETA Polling

    /// Periodically refreshes ETAs for active commutes to power home screen badges.
    private func startPeriodicETARefresh() {
        etaRefreshTask?.cancel()
        etaRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAllETAs()
                try? await Task.sleep(for: .seconds(300)) // every 5 minutes
            }
        }
    }

    private func refreshAllETAs() async {
        for commute in commutes {
            guard let route = commute.preferredRoute,
                  let origin = commute.origin,
                  let destination = commute.destination else { continue }

            do {
                let eta = try await directionsService.fetchETA(
                    from: origin.coordinate,
                    to: destination.coordinate,
                    encodedPolyline: route.encodedPolyline
                )
                commuteETAs[commute.id] = eta

                // Flag traffic issue if live ETA exceeds typical by the commute threshold
                if let typical = route.typicalDurationSeconds, typical > 0 {
                    let ratio = (eta - typical) / typical
                    commuteHasTrafficIssue[commute.id] = ratio >= commute.thresholdPercentage
                }
            } catch {
                // Silently skip — badge just won't update this cycle
            }
        }
    }

    // MARK: - Pinned Location Management

    func addPinnedLocation(name: String, coordinate: CLLocationCoordinate2D, address: String?) {
        let nextOrder = (pinnedLocations.map(\.sortOrder).max() ?? -1) + 1
        let location = PinnedLocation(
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            address: address,
            sortOrder: nextOrder
        )
        modelContext.insert(location)
        try? modelContext.save()
        fetchPinnedLocations()
    }

    func deletePinnedLocation(_ location: PinnedLocation) {
        modelContext.delete(location)
        try? modelContext.save()
        fetchPinnedLocations()
        fetchCommutes() // commutes referencing this location may have changed
    }

    // MARK: - Navigation

    func navigateToLocation(_ location: PinnedLocation) {
        selectedLocation = location
    }
}
