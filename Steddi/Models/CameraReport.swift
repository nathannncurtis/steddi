import Foundation
import SwiftData
import CoreLocation
import SwiftUI

/// A crowdsourced enforcement-camera report submitted by the user — a fixed
/// speed camera, a red-light camera, or a mobile speed trap they spotted.
///
/// Stored locally-only for now (no backend), but shaped for a future sync: a
/// stable `id`, a `source` discriminator separating user reports from
/// OSM-derived seeds, `createdAt`, and a `confirmations` counter so a later
/// server can merge duplicate sightings. Mirrors the persistence shape of
/// `RoadCondition` and `Report`: a point location kept in scalar lat/lon columns
/// so SwiftData predicates can read them and migrations stay lightweight.
///
/// Distinct from the OSM-sourced `SpeedCameraNode` (a value type built from
/// Overpass): `CameraReport` is the persisted, user-owned record. The
/// `SpeedCameraService` unifies both into one spatial index for proximity
/// alerts.
@Model
final class CameraReport {
    var id: UUID
    /// Persisted as the enum's raw value so SwiftData stores a plain string and
    /// unknown future kinds degrade to `.speedCamera` instead of failing to decode.
    var kindRaw: String
    var latitude: Double
    var longitude: Double
    /// How this report originated — user-submitted vs OSM-seeded. Raw-valued for
    /// the same forward-compat reason as `kindRaw`.
    var sourceRaw: String
    /// Optional free-text context ("northbound only", "school-zone hours").
    var note: String?
    var createdAt: Date
    /// Last "still there?" confirmation. Seeded to `createdAt` on creation; a
    /// future sync uses this plus `confirmationCount` to age out stale sightings.
    var lastConfirmedAt: Date
    /// How many times this sighting has been confirmed (by this user for now).
    /// A future server merges duplicate reports by bumping this.
    var confirmationCount: Int
    /// Lifecycle status, raw-valued for forward-compat.
    var statusRaw: String

    var coordinate: CLLocationCoordinate2D {
        get { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
        set {
            latitude = newValue.latitude
            longitude = newValue.longitude
        }
    }

    /// Typed accessor over `kindRaw`. Unknown raw values resolve to `.speedCamera`.
    var kind: CameraReportKind {
        get { CameraReportKind(rawValue: kindRaw) ?? .speedCamera }
        set { kindRaw = newValue.rawValue }
    }

    /// Typed accessor over `sourceRaw`. Unknown raw values resolve to `.userReport`.
    var source: CameraReportSource {
        get { CameraReportSource(rawValue: sourceRaw) ?? .userReport }
        set { sourceRaw = newValue.rawValue }
    }

    /// Typed accessor over `statusRaw`. Unknown raw values resolve to `.active`
    /// so a corrupt row stays alerting rather than silently vanishing.
    var status: CameraReportStatus {
        get { CameraReportStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    init(
        kind: CameraReportKind,
        coordinate: CLLocationCoordinate2D,
        source: CameraReportSource = .userReport,
        note: String? = nil,
        status: CameraReportStatus = .active,
        confirmationCount: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.sourceRaw = source.rawValue
        self.note = note
        self.createdAt = createdAt
        self.lastConfirmedAt = createdAt
        self.confirmationCount = confirmationCount
        self.statusRaw = status.rawValue
    }
}

// MARK: - Kind

/// The enforcement-camera types a user can report. Mobile speed traps are
/// transient (a parked patrol with radar) and decay faster than fixed cameras —
/// see `CameraReportDecay`.
enum CameraReportKind: String, CaseIterable, Identifiable, Codable {
    case speedCamera
    case redLightCamera
    case mobileSpeedTrap

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speedCamera:     return "Speed Camera"
        case .redLightCamera:  return "Red Light Camera"
        case .mobileSpeedTrap: return "Speed Trap"
        }
    }

    var icon: String {
        switch self {
        case .speedCamera:     return "camera.fill"
        case .redLightCamera:  return "light.beacon.max.fill"
        case .mobileSpeedTrap: return "badge.plus.radiowaves.right"
        }
    }

    /// Theme color for map badge / alert chip. Pulls from the dynamic
    /// SteddiTheme facade so badges track the user's accent and light/dark mode.
    var color: Color {
        switch self {
        case .speedCamera:     return SteddiTheme.warningAmber
        case .redLightCamera:  return SteddiTheme.warmRed
        case .mobileSpeedTrap: return SteddiTheme.accent
        }
    }

    /// Voice phrasing for the proximity heads-up, e.g. "Speed camera ahead".
    var spokenName: String {
        switch self {
        case .speedCamera:     return "Speed camera"
        case .redLightCamera:  return "Red light camera"
        case .mobileSpeedTrap: return "Speed trap"
        }
    }

    /// Higher fires first when multiple cameras are in range at once. A red-light
    /// camera (runs both speed + signal in many jurisdictions) outranks a plain
    /// speed camera, which outranks a transient mobile trap.
    var priority: Int {
        switch self {
        case .redLightCamera:  return 2
        case .speedCamera:     return 1
        case .mobileSpeedTrap: return 0
        }
    }
}

// MARK: - Source

/// Where a camera record came from. Kept on the persisted report so a future
/// sync can distinguish authoritative OSM seeds from unverified user sightings.
enum CameraReportSource: String, CaseIterable, Codable {
    /// Submitted by the user via the in-app report flow.
    case userReport
    /// Seeded from an OSM Overpass node (persisted so it survives offline).
    /// Reserved for a future "save OSM cameras locally" path; the live OSM
    /// lookup currently flows through `SpeedCameraNode` value types instead.
    case osmSeed
}

// MARK: - Status

/// Lifecycle of a reported camera. Soft-delete (`.expired`) precedes the hard
/// sweep so a "Yes, still there" can restore it and a future history feature
/// has an audit trail.
enum CameraReportStatus: String, CaseIterable, Codable {
    /// Live: shown on the map and fires proximity alerts.
    case active
    /// User said "Gone" or it aged out — hidden, retained until the sweep.
    case expired
    /// Reserved for future manual archival; treated like expired for display.
    case archived
}

// MARK: - Decay tuning

/// Centralized decay-window constants so the model, service, and tests share one
/// source of truth. Mobile traps are transient and age out fast; fixed cameras
/// are effectively permanent and only need a long safety expiry.
enum CameraReportDecay {
    /// Mobile speed traps older than this since last confirmation are swept —
    /// a parked patrol won't still be there tomorrow.
    static let mobileTrapExpiryHours: Double = 6
    /// Fixed cameras older than this since last confirmation are swept at launch.
    /// Long, because fixed enforcement infrastructure rarely moves.
    static let fixedCameraExpiryDays: Double = 365

    /// Expiry cutoff age in seconds for a given kind.
    static func expirySeconds(for kind: CameraReportKind) -> TimeInterval {
        switch kind {
        case .mobileSpeedTrap: return mobileTrapExpiryHours * 3_600
        case .speedCamera, .redLightCamera: return fixedCameraExpiryDays * 86_400
        }
    }
}
