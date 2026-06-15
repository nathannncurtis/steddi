import ActivityKit
import Foundation

// Single source of truth for the navigation Live Activity's ActivityAttributes.
// This one file is compiled into BOTH the Steddi app target and the
// SteddiLiveActivity widget extension (see project.yml: both targets list
// `Shared/NavigationAttributes.swift` in their sources). ActivityKit matches the
// app's Activity<NavigationAttributes>.request against the extension's
// ActivityConfiguration(for: NavigationAttributes.self) by the type's name and
// its Codable ContentState shape, so the two MUST stay identical. Keeping a
// single physical file removes the dual-edit footgun where one copy could drift.

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
