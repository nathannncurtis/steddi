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
    }

    /// Fixed data for this navigation session
    var destinationName: String
}
