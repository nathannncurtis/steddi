import Foundation

enum MeasurementUnit: String, CaseIterable, Identifiable {
    case miles
    case kilometers

    var id: String { rawValue }

    var abbreviation: String {
        switch self {
        case .miles: return "mi"
        case .kilometers: return "km"
        }
    }

    /// Speed-unit abbreviation for this distance unit (mph / km/h), used by the
    /// speedometer + speed-limit readout so the velocity label tracks the same
    /// preference as distance.
    var speedAbbreviation: String {
        switch self {
        case .miles: return "mph"
        case .kilometers: return "km/h"
        }
    }

    /// Spoken word for this distance unit, singular and plural, for voice
    /// guidance ("In 0.3 miles" / "In 2 kilometers"). Pluralized by the caller.
    var spokenName: (singular: String, plural: String) {
        switch self {
        case .miles: return ("mile", "miles")
        case .kilometers: return ("kilometer", "kilometers")
        }
    }

    /// Meters in one of this unit (mile or kilometer). The single conversion
    /// constant the distance formatters share.
    var metersPerUnit: Double {
        switch self {
        case .miles: return 1609.34
        case .kilometers: return 1000
        }
    }

    /// km/h per mph, the factor that turns the mph-internal speed pipeline
    /// (OSM `maxspeed`, GPS speed) into the user's velocity unit. Inverse of
    /// `OSMTagParsing.mphPerKmh`.
    static let kmhPerMph = 1 / OSMTagParsing.mphPerKmh

    /// Convert a speed given in mph into this unit's velocity value, rounded to a
    /// whole number — the speedometer/limit readout has no decimals. Speeds stay
    /// internally in mph (OSM `maxspeed` and GPS both flow through mph); this is
    /// the single place that converts for display.
    func speedValue(mph: Double) -> Int {
        switch self {
        case .miles: return Int(mph.rounded())
        case .kilometers: return Int((mph * Self.kmhPerMph).rounded())
        }
    }

    /// The numeric speed (in this unit) plus its abbreviation, e.g. "65 mph" /
    /// "105 km/h". Used where a speed/limit is shown as a single string.
    func formatSpeed(mph: Double) -> String {
        "\(speedValue(mph: mph)) \(speedAbbreviation)"
    }

    /// The user's persisted unit preference (AppStorage key "steddi.units"),
    /// defaulting to miles. Usable from non-SwiftUI contexts like CarPlay.
    static var current: MeasurementUnit {
        let raw = UserDefaults.standard.string(forKey: "steddi.units") ?? MeasurementUnit.miles.rawValue
        return MeasurementUnit(rawValue: raw) ?? .miles
    }

    /// Format a distance given in meters per this unit. Uses one decimal place
    /// for short distances (under 10 units) and a whole number above that,
    /// matching the rest of the app's distance presentation.
    func formatDistance(meters: Double) -> String {
        let value = meters / metersPerUnit
        // Decide whole-vs-decimal off the ROUNDED value, not the raw one, so the
        // band boundary is consistent. Branching on the raw value let a distance
        // in [9.95, 10.0) take the "%.1f" path and round up to a stray-decimal
        // "10.0 mi", contradicting the whole-number "10 mi"/"11 mi" just above the
        // threshold. A value that rounds to >= 10 takes the whole-number path.
        let whole = value.rounded()
        if whole < 10 {
            return String(format: "%.1f %@", value, abbreviation)
        }
        // Round, don't truncate: 10.95 -> "11 mi", not "10 mi" (an up-to-1-unit
        // understatement of the distance).
        return "\(Int(whole)) \(abbreviation)"
    }

    /// Turn-by-turn distance string with a short-range sub-unit (feet for miles,
    /// meters for kilometers): "350 ft" / "0.3 mi" / "11 mi" — or "150 m" /
    /// "0.3 km" / "11 km". The single source for the nav HUD / Live Activity /
    /// route-preview distance readouts, which previously hardcoded imperial.
    /// Rounding bands match the prior imperial behavior exactly.
    func formatNavDistance(meters: Double) -> String {
        // Short range: feet (miles) or whole meters (km). 160 m is the imperial
        // ~500 ft hand-off the readout has always used; keep it for both so the
        // band boundary doesn't shift for existing (mile) users.
        if meters < 160 {
            switch self {
            case .miles: return "\(Int(meters * 3.281)) ft"
            case .kilometers: return "\(Int(meters.rounded())) m"
            }
        }
        let value = meters / metersPerUnit
        if value < 10 {
            return String(format: "%.1f %@", value, abbreviation)
        }
        // Round, don't truncate: 10.95 mi -> "11 mi" (an up-to-1-unit
        // understatement of the distance remaining otherwise).
        return "\(Int(value.rounded())) \(abbreviation)"
    }
}
