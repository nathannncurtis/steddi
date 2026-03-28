import AppIntents
import MapKit
import CoreLocation

/// "Hey Siri, how's my drive to work?" — returns current ETA without opening the app.
struct CheckCommuteETAIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Commute ETA"
    static var description: IntentDescription = "Check how long your commute will take right now."

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // Try to get current location
        let locationManager = CLLocationManager()
        guard let location = locationManager.location else {
            return .result(value: "I couldn't determine your location. Open Steddi and try again.")
        }

        // Look up the first active commute from SwiftData
        // For now, return a generic message — full SwiftData integration requires model container access
        let etaMinutes = try await fetchQuickETA(from: location.coordinate)
        if let eta = etaMinutes {
            return .result(value: "Your commute looks like about \(eta) minutes right now.")
        }
        return .result(value: "I couldn't calculate your commute ETA. Open Steddi for details.")
    }

    private func fetchQuickETA(from origin: CLLocationCoordinate2D) async throws -> Int? {
        // This is a simplified version — will be enhanced when we have shared data via App Group
        return nil
    }
}
