import ActivityKit
import Foundation

/// Defines the data model for the Steddi navigation Live Activity.
struct NavigationAttributes: ActivityAttributes {
    /// Static data set when the activity starts
    public struct ContentState: Codable, Hashable {
        var instruction: String
        var stepDistance: String
        var etaMinutes: Int
        var distanceRemaining: String
        var arrivalTime: String
        var maneuverSymbol: String
        var speedMph: Int
        var roadName: String

        // Trip context (nil for commute/place navigation) — the Live
        // Activity shows "Leg 2 of 5" with the trip name when these are set
        var tripName: String? = nil
        var legIndex: Int? = nil
        var totalLegs: Int? = nil
    }

    /// Fixed data for this navigation session
    var destinationName: String
}
