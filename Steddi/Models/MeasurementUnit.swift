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
        let value: Double
        switch self {
        case .miles: value = meters / 1609.34
        case .kilometers: value = meters / 1000
        }
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
}
