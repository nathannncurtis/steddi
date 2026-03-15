import Foundation
import SwiftData
import CoreLocation
import Observation

/// Lightweight wrapper around UserDefaults for simple app preferences.
struct AppSettings {
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let defaultThresholdPercentage = "steddi.defaultThresholdPercentage"
        static let defaultHardMinuteFloor = "steddi.defaultHardMinuteFloor"
        static let voiceGuidanceEnabled = "steddi.voiceGuidanceEnabled"
        static let units = "steddi.units"
    }

    var defaultThresholdPercentage: Double {
        get { defaults.object(forKey: Keys.defaultThresholdPercentage) as? Double ?? 0.20 }
        set { defaults.set(newValue, forKey: Keys.defaultThresholdPercentage) }
    }

    var defaultHardMinuteFloor: Int {
        get { defaults.object(forKey: Keys.defaultHardMinuteFloor) as? Int ?? 10 }
        set { defaults.set(newValue, forKey: Keys.defaultHardMinuteFloor) }
    }

    var voiceGuidanceEnabled: Bool {
        get { defaults.object(forKey: Keys.voiceGuidanceEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.voiceGuidanceEnabled) }
    }

    var units: MeasurementUnit {
        get {
            guard let raw = defaults.string(forKey: Keys.units) else { return .miles }
            return MeasurementUnit(rawValue: raw) ?? .miles
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.units) }
    }
}

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
}

/// View model for global app settings and no-go zone management.
@Observable
@MainActor
final class SettingsViewModel {

    // MARK: - Published State

    var globalNoGoZones: [NoGoZone] = []
    var defaultThresholdPercentage: Double
    var defaultHardMinuteFloor: Int
    var voiceGuidanceEnabled: Bool
    var units: MeasurementUnit

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private var settings = AppSettings()

    // MARK: - Init

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.defaultThresholdPercentage = settings.defaultThresholdPercentage
        self.defaultHardMinuteFloor = settings.defaultHardMinuteFloor
        self.voiceGuidanceEnabled = settings.voiceGuidanceEnabled
        self.units = settings.units
    }

    // MARK: - Data Loading

    func loadGlobalNoGoZones() {
        let descriptor = FetchDescriptor<NoGoZone>(
            predicate: #Predicate { $0.isGlobal },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        globalNoGoZones = (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - No-Go Zone Management

    func addGlobalNoGoZone(name: String?, coordinate: CLLocationCoordinate2D, radius: Double) {
        let zone = NoGoZone(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusMeters: radius,
            name: name,
            isGlobal: true
        )
        modelContext.insert(zone)
        try? modelContext.save()
        loadGlobalNoGoZones()
    }

    func deleteGlobalNoGoZone(_ zone: NoGoZone) {
        modelContext.delete(zone)
        try? modelContext.save()
        loadGlobalNoGoZones()
    }

    // MARK: - Defaults

    func updateDefaults(percentage: Double, minuteFloor: Int) {
        defaultThresholdPercentage = percentage
        defaultHardMinuteFloor = minuteFloor
        settings.defaultThresholdPercentage = percentage
        settings.defaultHardMinuteFloor = minuteFloor
    }

    /// Persists the current in-memory values back to UserDefaults.
    /// Called when the settings view disappears.
    func save() {
        settings.defaultThresholdPercentage = defaultThresholdPercentage
        settings.defaultHardMinuteFloor = defaultHardMinuteFloor
        settings.voiceGuidanceEnabled = voiceGuidanceEnabled
        settings.units = units
    }
}
