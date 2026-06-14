import SwiftUI

/// Predefined categories for a `PinnedLocation`. The model stores a raw String
/// key (see `PinnedLocation.category`) so the set can grow without a SwiftData
/// migration; this enum is the lookup/rendering layer over those keys.
///
/// Each case carries an SF Symbol, a display name, and a theme color used for
/// the category chip on place cards and grouping headers on the Places tab.
enum PlaceCategory: String, CaseIterable, Identifiable {
    case home
    case work
    case gym
    case grocery
    case cafe
    case restaurant
    case hospital
    case school
    case airport
    case gasStation = "gas_station"
    case parking
    case other

    var id: String { rawValue }

    /// The raw key persisted on `PinnedLocation.category`.
    var key: String { rawValue }

    /// SF Symbol shown as the category's default icon.
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .work: return "building.2.fill"
        case .gym: return "figure.run"
        case .grocery: return "cart.fill"
        case .cafe: return "cup.and.saucer.fill"
        case .restaurant: return "fork.knife"
        case .hospital: return "cross.fill"
        case .school: return "book.fill"
        case .airport: return "airplane"
        case .gasStation: return "fuelpump.fill"
        case .parking: return "parkingsign"
        case .other: return "mappin.circle.fill"
        }
    }

    var displayName: String {
        switch self {
        case .home: return "Home"
        case .work: return "Work"
        case .gym: return "Gym"
        case .grocery: return "Grocery"
        case .cafe: return "Cafe"
        case .restaurant: return "Restaurant"
        case .hospital: return "Hospital"
        case .school: return "School"
        case .airport: return "Airport"
        case .gasStation: return "Gas Station"
        case .parking: return "Parking"
        case .other: return "Other"
        }
    }

    /// Color hint for the category chip. Computed (not stored) so theme updates
    /// apply without a data migration. Falls back to the live accent for cases
    /// without a strong real-world color association.
    var themeColor: Color {
        switch self {
        case .home: return SteddiTheme.sage
        case .work: return SteddiTheme.accent
        case .gym: return Color(red: 0.95, green: 0.45, blue: 0.30)   // coral
        case .grocery: return Color(red: 0.30, green: 0.70, blue: 0.40) // green
        case .cafe: return Color(red: 0.62, green: 0.45, blue: 0.32)  // mocha
        case .restaurant: return Color(red: 0.90, green: 0.55, blue: 0.20) // amber
        case .hospital: return SteddiTheme.warmRed
        case .school: return Color(red: 0.35, green: 0.55, blue: 0.90) // blue
        case .airport: return Color(red: 0.40, green: 0.70, blue: 0.85) // sky
        case .gasStation: return Color(red: 0.85, green: 0.40, blue: 0.50) // rose
        case .parking: return Color(red: 0.45, green: 0.55, blue: 0.75) // slate blue
        case .other: return SteddiTheme.accent
        }
    }

    // MARK: - Lookup

    /// Every category in display order.
    static var allCategories: [PlaceCategory] { allCases }

    /// Resolve a stored key to a category. Unknown / empty keys map to `.other`,
    /// matching the model's fallback contract.
    static func category(for key: String) -> PlaceCategory {
        PlaceCategory(rawValue: key) ?? .other
    }

    /// Best-guess category for an existing pin's SF Symbol. Used by the
    /// one-time migration to backfill `category` on pins created before the
    /// field existed. Returns nil when no confident mapping exists; the caller
    /// falls back to `.other`.
    static func inferred(fromIcon icon: String) -> PlaceCategory? {
        switch icon {
        case "house.fill", "house": return .home
        case "building.2.fill", "building.2", "briefcase.fill": return .work
        case "figure.run", "dumbbell.fill", "figure.strengthtraining.traditional": return .gym
        case "cart.fill", "cart": return .grocery
        case "cup.and.saucer.fill", "cup.and.saucer": return .cafe
        case "fork.knife": return .restaurant
        case "cross.fill", "cross.case.fill": return .hospital
        case "book.fill", "graduationcap.fill": return .school
        case "airplane": return .airport
        case "fuelpump.fill", "fuelpump": return .gasStation
        case "parkingsign", "parkingsign.circle.fill": return .parking
        case "mappin.circle.fill", "mappin": return .other
        default: return nil
        }
    }

    /// Icon choices surfaced in the picker for a given category. The category's
    /// own symbol leads, followed by the full predefined set so the user can
    /// override (category is a grouping hint, not a constraint). Returns
    /// (symbol, label) pairs.
    static func iconOptions(for category: PlaceCategory?) -> [(symbol: String, label: String)] {
        let base: [(symbol: String, label: String)] = allCases.map { (symbol: $0.symbol, label: $0.displayName) }
        guard let category else { return base }
        // Promote the selected category's symbol to the front, de-duplicated.
        let lead: (symbol: String, label: String) = (symbol: category.symbol, label: category.displayName)
        let rest = base.filter { $0.symbol != lead.symbol }
        return [lead] + rest
    }
}
