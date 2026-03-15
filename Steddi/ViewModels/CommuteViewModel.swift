import Foundation
import SwiftData
import Observation

/// View model for creating, editing, and managing commutes and their routes.
@Observable
@MainActor
final class CommuteViewModel {

    // MARK: - Published State

    var commutes: [Commute] = []
    var selectedCommute: Commute?

    // MARK: - Dependencies

    private let modelContext: ModelContext

    // MARK: - Init

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Data Loading

    func loadCommutes() {
        let descriptor = FetchDescriptor<Commute>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        commutes = (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Commute CRUD

    @discardableResult
    func createCommute(name: String, origin: PinnedLocation?, destination: PinnedLocation?) -> Commute {
        let commute = Commute(name: name, origin: origin, destination: destination)
        modelContext.insert(commute)
        try? modelContext.save()
        loadCommutes()
        return commute
    }

    func updateThreshold(commute: Commute, percentage: Double, minuteFloor: Int?) {
        commute.thresholdPercentage = percentage
        commute.hardMinuteFloor = minuteFloor
        try? modelContext.save()
    }

    func deleteCommute(_ commute: Commute) {
        modelContext.delete(commute)
        try? modelContext.save()
        if selectedCommute?.id == commute.id {
            selectedCommute = nil
        }
        loadCommutes()
    }

    // MARK: - Route Management

    func addRouteToCommute(_ commute: Commute, route: Route) {
        route.commute = commute
        if commute.routes == nil {
            commute.routes = []
        }
        commute.routes?.append(route)
        modelContext.insert(route)
        try? modelContext.save()
    }

    func reorderRoutes(commute: Commute, fromIndex: Int, toIndex: Int) {
        var ordered = commute.orderedRoutes
        guard fromIndex >= 0, fromIndex < ordered.count,
              toIndex >= 0, toIndex < ordered.count else { return }

        let moving = ordered.remove(at: fromIndex)
        ordered.insert(moving, at: toIndex)

        // Reassign ranks to match new order
        for (index, route) in ordered.enumerated() {
            route.rank = index
        }
        try? modelContext.save()
    }

    func deleteRoute(from commute: Commute, route: Route) {
        commute.routes?.removeAll { $0.id == route.id }
        modelContext.delete(route)

        // Re-rank remaining routes
        for (index, remaining) in commute.orderedRoutes.enumerated() {
            remaining.rank = index
        }
        try? modelContext.save()
    }
}
