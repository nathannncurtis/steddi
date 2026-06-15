import Foundation
import SwiftData
import CoreLocation
import SwiftUI

/// A road surface or construction condition the user discovered on a commute —
/// a pothole, a construction zone, rough pavement, debris, etc. Stored
/// locally-only (no crowdsourcing in v1) and scoped to a specific `Route` so
/// the user only sees conditions on *their* commute, not arbitrary geography.
///
/// Mirrors the persistence shape of `Report` and `NoGoZone`: a point location
/// kept in scalar lat/lon columns (so SwiftData predicates can read them and
/// migrations stay lightweight), metadata, and an optional route relationship.
///
/// Two timestamps drive the decay state machine (see `RoadConditionService`):
/// - `createdAt` — original report time, never changes.
/// - `lastConfirmedAt` — last time the user confirmed "still there?". Resets to
///   now on confirmation, which restarts both the 14-day reconfirm window and
///   the 90-day silent-expiry window.
@Model
final class RoadCondition {
    var id: UUID
    /// Persisted as the enum's raw value so SwiftData stores a plain string and
    /// unknown future kinds degrade to `.other` instead of failing to decode.
    var kindRaw: String
    var latitude: Double
    var longitude: Double
    /// Optional free-text context ("large pothole on the west side",
    /// "construction ends Fri").
    var note: String?
    var createdAt: Date
    /// Last "still there?" confirmation. Seeded to `createdAt` on creation.
    var lastConfirmedAt: Date
    /// Persisted lifecycle status, raw-valued for the same forward-compat reason
    /// as `kindRaw`.
    var statusRaw: String

    /// Owning route. Conditions cascade-delete with their route (set on the
    /// `Route` side via `@Relationship(deleteRule: .cascade)`), so forgetting a
    /// route also forgets its remembered conditions.
    var route: Route?

    var coordinate: CLLocationCoordinate2D {
        get { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
        set {
            latitude = newValue.latitude
            longitude = newValue.longitude
        }
    }

    /// Typed accessor over `kindRaw`. Unknown raw values resolve to `.other`.
    var kind: RoadConditionKind {
        get { RoadConditionKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    /// Typed accessor over `statusRaw`. Unknown raw values resolve to `.active`
    /// so a corrupt row stays visible rather than silently vanishing.
    var status: RoadConditionStatus {
        get { RoadConditionStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    init(
        kind: RoadConditionKind,
        coordinate: CLLocationCoordinate2D,
        note: String? = nil,
        route: Route? = nil,
        status: RoadConditionStatus = .active,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.note = note
        self.createdAt = createdAt
        self.lastConfirmedAt = createdAt
        self.statusRaw = status.rawValue
        self.route = route
    }

    // MARK: - Derived state

    /// Whole days since the user last confirmed (or created) this condition.
    func daysSinceConfirmed(now: Date = Date()) -> Int {
        Int(now.timeIntervalSince(lastConfirmedAt) / 86_400)
    }

    /// True when an active condition is past the reconfirm window and should be
    /// offered for "still there?" on the next post-arrival. Expired/archived
    /// conditions never prompt.
    func needsReconfirmation(now: Date = Date(), windowDays: Double = RoadConditionDecay.reconfirmWindowDays) -> Bool {
        status == .active && now.timeIntervalSince(lastConfirmedAt) > windowDays * 86_400
    }
}

// MARK: - Kind

/// The five condition types the user can report. Each carries a display name,
/// an SF Symbol for map badges and chips, and a theme color. A `priority`
/// orders simultaneous alerts (pothole beats debris beats construction).
enum RoadConditionKind: String, CaseIterable, Identifiable, Codable {
    case pothole
    case construction
    case roughSurface
    case debris
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pothole:      return "Pothole"
        case .construction: return "Construction"
        case .roughSurface: return "Rough Surface"
        case .debris:       return "Debris"
        case .other:        return "Other"
        }
    }

    var icon: String {
        switch self {
        case .pothole:      return "circle.bottomhalf.filled"
        case .construction: return "cone.fill"
        case .roughSurface: return "road.lanes"
        case .debris:       return "trash.fill"
        case .other:        return "exclamationmark.triangle.fill"
        }
    }

    /// Theme color for the map badge / chip. Pulls from the dynamic SteddiTheme
    /// facade so badges track the user's accent and light/dark mode.
    var color: Color {
        switch self {
        case .pothole:      return SteddiTheme.warmRed
        case .construction: return SteddiTheme.warningAmber
        case .roughSurface: return SteddiTheme.accent
        case .debris:       return SteddiTheme.warningAmber
        case .other:        return SteddiTheme.accent
        }
    }

    /// Fill to use for a SELECTED chip whose label/glyph sits ON the fill. Mirrors
    /// `color` except the accent kinds use the raw brand hue (`accentBrand`) so the
    /// paired on-fill foreground (`selectedChipForeground`) clears AA — the text-
    /// safe `accent` fill + onAccent collapses to ~3:1 in light.
    var selectedChipFill: Color {
        switch self {
        case .pothole:      return SteddiTheme.warmRed
        case .construction: return SteddiTheme.warningAmber
        case .roughSurface: return SteddiTheme.accentBrand
        case .debris:       return SteddiTheme.warningAmber
        case .other:        return SteddiTheme.accentBrand
        }
    }

    /// AA-correct foreground for a label/glyph drawn ON `selectedChipFill`. Never
    /// hardcoded white — white-on-amber is 2.05:1 and white-on-warmRed 3.78:1, both
    /// failing WCAG AA in every theme. Picks the legible near-black/white per fill.
    var selectedChipForeground: Color {
        switch self {
        case .pothole:      return SteddiTheme.contrastingForeground(on: SteddiTheme.warmRedRGB)
        case .construction: return SteddiTheme.contrastingForeground(on: SteddiTheme.warningAmberRGB)
        case .debris:       return SteddiTheme.contrastingForeground(on: SteddiTheme.warningAmberRGB)
        case .roughSurface: return SteddiTheme.onAccent
        case .other:        return SteddiTheme.onAccent
        }
    }

    /// Voice phrasing for the proximity heads-up, e.g. "Pothole ahead".
    var spokenName: String {
        switch self {
        case .pothole:      return "Pothole"
        case .construction: return "Construction"
        case .roughSurface: return "Rough road"
        case .debris:       return "Debris"
        case .other:        return "Road condition"
        }
    }

    /// Higher fires first when multiple conditions are in range at once.
    var priority: Int {
        switch self {
        case .pothole:      return 4
        case .debris:       return 3
        case .construction: return 2
        case .roughSurface: return 1
        case .other:        return 0
        }
    }
}

// MARK: - Status

/// Lifecycle of a remembered condition. Soft-delete (`.expired`) precedes the
/// 90-day hard-delete sweep so the reconfirmation workflow can restore a
/// condition via "Yes" and a future undo/history feature has an audit trail.
enum RoadConditionStatus: String, CaseIterable, Codable {
    /// Live: shown on the map, fires proximity alerts, eligible for reconfirm.
    case active
    /// User said "Gone" or it aged out — hidden from map and alerts, retained
    /// until the launch sweep hard-deletes it.
    case expired
    /// Reserved for future manual archival; treated like expired for display.
    case archived
}

// MARK: - Decay tuning

/// Centralized decay-window constants so the model, service, and tests share one
/// source of truth for the 14-day reconfirm and 90-day expiry boundaries.
enum RoadConditionDecay {
    /// Conditions older than this since last confirmation are offered for
    /// reconfirmation at post-arrival.
    static let reconfirmWindowDays: Double = 14
    /// Conditions older than this since last confirmation are hard-deleted at
    /// app launch, regardless of status.
    static let expiryWindowDays: Double = 90
}
