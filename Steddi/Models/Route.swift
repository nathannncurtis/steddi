import Foundation
import SwiftData

@Model
final class Route {
    var id: UUID
    var rank: Int                    // 0 = preferred, 1 = fallback 1, etc.
    var name: String?                // Optional user label, e.g. "The 60", "I-10 FasTrak"
    var encodedPolyline: String      // Encoded polyline geometry from Map Matching
    var encodedSteps: String?        // JSON-encoded turn-by-turn steps (saved at planning time)
    var distanceMeters: Double?
    var typicalDurationSeconds: Double?
    var createdAt: Date
    var source: RouteSource          // How this route was created
    var direction: CommuteDirection   // Which way this route goes

    var commute: Commute?

    @Relationship(deleteRule: .cascade)
    var noGoZones: [NoGoZone]?

    /// Whether this route overrides global no-go zones
    var overridesGlobalNoGoZones: Bool

    init(
        rank: Int,
        encodedPolyline: String,
        name: String? = nil,
        distanceMeters: Double? = nil,
        typicalDurationSeconds: Double? = nil,
        source: RouteSource = .recorded,
        direction: CommuteDirection = .originToDestination
    ) {
        self.id = UUID()
        self.rank = rank
        self.name = name
        self.encodedPolyline = encodedPolyline
        self.distanceMeters = distanceMeters
        self.typicalDurationSeconds = typicalDurationSeconds
        self.createdAt = Date()
        self.source = source
        self.direction = direction
        self.overridesGlobalNoGoZones = false
    }
}

/// A turn-by-turn step saved with the route. JSON-encodable for storage.
struct SavedStep: Codable {
    let instruction: String
    let distance: Double
    let latitude: Double
    let longitude: Double
    let maneuverSymbol: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var toNavStep: NavStep {
        NavStep(instruction: instruction, distance: distance, coordinate: coordinate, maneuverSymbol: maneuverSymbol)
    }

    init(from directionsStep: DirectionsStep) {
        self.instruction = directionsStep.instructions
        self.distance = directionsStep.distance
        self.latitude = directionsStep.coordinate.latitude
        self.longitude = directionsStep.coordinate.longitude
        self.maneuverSymbol = directionsStep.maneuverType
    }

    init(instruction: String, distance: Double, coordinate: CLLocationCoordinate2D, maneuverSymbol: String) {
        self.instruction = instruction
        self.distance = distance
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.maneuverSymbol = maneuverSymbol
    }
}

import CoreLocation

extension Route {
    /// Decode the saved steps from JSON.
    /// Legacy blobs from the chained-leg planner embed an arrival step at
    /// every plot point — only the final arrival is real, so mid-route
    /// arrival-pattern steps are dropped.
    var savedNavSteps: [NavStep]? {
        guard let json = encodedSteps, let data = json.data(using: .utf8) else { return nil }
        guard let savedSteps = try? JSONDecoder().decode([SavedStep].self, from: data) else { return nil }
        let nonEmpty = savedSteps.filter { !$0.instruction.isEmpty }
        let navSteps = nonEmpty.enumerated()
            .filter { index, step in index == nonEmpty.count - 1 || !Self.isArrivalPattern(step) }
            .map { $0.element.toNavStep }
        return navSteps.isEmpty ? nil : navSteps
    }

    /// Whether a saved step reads as an arrival, by symbol or instruction.
    private static func isArrivalPattern(_ step: SavedStep) -> Bool {
        step.maneuverSymbol == "flag.fill"
            || NavigationEngine.sfSymbolFromInstruction(step.instruction) == "flag.fill"
    }

    /// Encode steps as JSON for storage.
    static func encodeSteps(_ directionsSteps: [DirectionsStep]) -> String? {
        let saved = directionsSteps.map { SavedStep(from: $0) }
        guard let data = try? JSONEncoder().encode(saved) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum RouteSource: String, Codable {
    case recorded   // "Drive it" — GPS trace snapped via Map Matching
    case planned    // "Draw/plan it" — manually created on map
    case suggested  // System-suggested from repeated pattern (future)
}

enum CommuteDirection: String, Codable {
    case originToDestination
    case destinationToOrigin
}
