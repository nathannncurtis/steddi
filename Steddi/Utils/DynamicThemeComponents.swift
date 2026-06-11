import Foundation

/// Per-layer enable/disable toggles for the dynamic theming pipeline.
/// Persisted as JSON under one defaults key so the shape can grow without a
/// migration: decoding is tolerant — missing fields take their defaults.
struct DynamicThemeComponents: Codable, Equatable {
    /// Bumped if the payload shape ever changes incompatibly.
    var version: Int = 1
    var solarCycle: Bool = true
    var weatherResponse: Bool = true
    var temperatureTinting: Bool = true
    var tunnelDetection: Bool = true
    /// Grey is a distinctive perceptual shift — ships opt-in.
    var greyMode: Bool = false

    static let defaultsKey = "steddi.dynamicComponents"

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        solarCycle = try container.decodeIfPresent(Bool.self, forKey: .solarCycle) ?? true
        weatherResponse = try container.decodeIfPresent(Bool.self, forKey: .weatherResponse) ?? true
        temperatureTinting = try container.decodeIfPresent(Bool.self, forKey: .temperatureTinting) ?? true
        tunnelDetection = try container.decodeIfPresent(Bool.self, forKey: .tunnelDetection) ?? true
        greyMode = try container.decodeIfPresent(Bool.self, forKey: .greyMode) ?? false
    }

    // MARK: - JSON (for @AppStorage string round-trips)

    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// Decode from a JSON string; any malformed payload falls back to defaults
    /// so a bad write can never wedge the settings screen.
    static func fromJSON(_ string: String) -> DynamicThemeComponents {
        guard let data = string.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(DynamicThemeComponents.self, from: data) else {
            return DynamicThemeComponents()
        }
        return decoded
    }

    // MARK: - Defaults round-trip

    static func load(from defaults: UserDefaults = .standard) -> DynamicThemeComponents {
        guard let json = defaults.string(forKey: defaultsKey) else {
            return DynamicThemeComponents()
        }
        return fromJSON(json)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(jsonString, forKey: Self.defaultsKey)
    }
}
