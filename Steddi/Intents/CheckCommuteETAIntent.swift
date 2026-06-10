import AppIntents
import CoreLocation
import SwiftData

/// "Hey Siri, how's my drive to work?" — returns the current ETA without opening the app.
struct CheckCommuteETAIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Commute ETA"
    static var description: IntentDescription = "Check how long your commute will take right now."

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        // Read commutes from the shared App Group store (read-only).
        let container: ModelContainer
        do {
            container = try ModelStoreLocator.makeReadOnlyGroupContainer()
        } catch {
            return respond("You haven't set up any commutes yet.")
        }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Commute>(
            predicate: #Predicate { $0.isActive },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let commutes = (try? context.fetch(descriptor)) ?? []

        guard let commute = commutes.first else {
            return respond("You haven't set up any commutes yet.")
        }
        guard let origin = commute.origin, let destination = commute.destination else {
            return respond("Your commute isn't fully set up yet. Open Steddi to add its locations.")
        }

        // Resolve direction: proximity when we have a location fix, then the
        // active schedule window, then the next scheduled window, defaulting
        // to heading out (origin → destination).
        let currentLocation = CLLocationManager().location
        let direction = resolveDirection(commute: commute, currentLocation: currentLocation)

        let destinationPin = direction == .originToDestination ? destination : origin
        let startCoordinate = currentLocation?.coordinate
            ?? (direction == .originToDestination ? origin.coordinate : destination.coordinate)
        let destinationName = destinationPin.name

        do {
            let eta = try await DirectionsService().fetchETA(
                from: startCoordinate,
                to: destinationPin.coordinate
            )
            let minutes = max(1, Int((eta / 60).rounded()))
            return respond("Your drive to \(destinationName) is about \(minutes) minutes right now.")
        } catch {
            // Live traffic unavailable — fall back to the route's typical time.
            if let typical = commute.preferredRoute(for: direction)?.typicalDurationSeconds,
               typical > 0 {
                let minutes = max(1, Int((typical / 60).rounded()))
                return respond("I couldn't get live traffic, but your drive to \(destinationName) is typically about \(minutes) minutes.")
            }
            return respond("I couldn't calculate your commute ETA right now. Open Steddi for details.")
        }
    }

    // MARK: - Private

    private func respond(_ message: String) -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        .result(value: message, dialog: IntentDialog("\(message)"))
    }

    private func resolveDirection(
        commute: Commute,
        currentLocation: CLLocation?
    ) -> CommuteDirection {
        if let currentLocation,
           case .confident(let direction, _) = CommuteDirectionResolver.resolve(
               commute: commute,
               currentLocation: currentLocation
           ) {
            return direction
        }
        if let scheduled = CommuteDirectionResolver.scheduledDirection(commute: commute) {
            return scheduled
        }
        if let next = CommuteDirectionResolver.nextScheduledDirection(commute: commute) {
            return next
        }
        return .originToDestination
    }
}
