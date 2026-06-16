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
        if value < 10 {
            return String(format: "%.1f %@", value, abbreviation)
        }
        return "\(Int(value)) \(abbreviation)"
    }
}
