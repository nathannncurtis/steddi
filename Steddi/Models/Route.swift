import Foundation
import SwiftData

@Model
final class Route {
    var id: UUID
    var rank: Int                    // 0 = preferred, 1 = fallback 1, etc.
    var name: String?                // Optional user label, e.g. "The 60", "I-10 FasTrak"
    var encodedPolyline: String      // Encoded polyline geometry from Map Matching
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

enum RouteSource: String, Codable {
    case recorded   // "Drive it" — GPS trace snapped via Map Matching
    case planned    // "Draw/plan it" — manually created on map
    case suggested  // System-suggested from repeated pattern (future)
}

enum CommuteDirection: String, Codable {
    case originToDestination
    case destinationToOrigin
}
