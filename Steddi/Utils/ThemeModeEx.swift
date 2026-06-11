import SwiftUI
import UIKit

/// Successor to `ThemeMode`: adds grey as a first-class theme.
///
/// `ThemeMode` stays untouched for source compatibility — map surfaces resolve
/// their interface style through `SteddiTheme.currentThemeMode`, which reads
/// the legacy `"themeMode"` defaults key. That key lives on as a derived
/// shadow of this mode (see `syncLegacyShadow`) so those surfaces keep working
/// without edits: they re-resolve on `.steddiThemeModeChanged` as before.
enum ThemeModeEx: String, CaseIterable, Codable {
    case dark, light, grey, dynamic

    var displayName: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .grey: return "Grey"
        case .dynamic: return "Dynamic"
        }
    }

    var isDynamic: Bool { self == .dynamic }

    /// UIKit style for map surfaces. Grey maps render light — MapKit has no
    /// grey style, and muted light cartography reads closest to the grey
    /// palette without washing out road labels.
    var mapInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .grey: return .light
        case .dynamic: return ThemeMode.isDaytime ? .light : .dark
        }
    }

    /// SwiftUI color scheme. Grey surfaces are mid-graphite with light text,
    /// so system chrome (sheets, pickers, keyboards) matches best in dark.
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .grey: return .dark
        case .dynamic: return ThemeMode.isDaytime ? .light : .dark
        }
    }
}

// MARK: - Persistence & Migration

extension ThemeModeEx {
    static let defaultsKey = "steddi.themeModeEx"
    static let legacyDefaultsKey = "themeMode"

    /// Current user-selected mode. Falls back to the legacy key for users who
    /// have not launched since the migration, then to dynamic.
    static func current(in defaults: UserDefaults = .standard) -> ThemeModeEx {
        if let raw = defaults.string(forKey: defaultsKey), let mode = ThemeModeEx(rawValue: raw) {
            return mode
        }
        if let raw = defaults.string(forKey: legacyDefaultsKey), let mode = ThemeModeEx(rawValue: raw) {
            return mode
        }
        return .dynamic
    }

    /// One-time startup migration from the legacy `"themeMode"` key.
    /// Legacy values map 1:1 (dark/light/dynamic); the legacy key is NOT
    /// deleted — it is demoted to a shadow that map surfaces keep reading.
    @discardableResult
    static func migrateLegacyIfNeeded(in defaults: UserDefaults = .standard) -> ThemeModeEx {
        if let raw = defaults.string(forKey: defaultsKey), let mode = ThemeModeEx(rawValue: raw) {
            syncLegacyShadow(mode, in: defaults)
            return mode
        }
        let migrated = defaults.string(forKey: legacyDefaultsKey)
            .flatMap(ThemeModeEx.init(rawValue:)) ?? .dynamic
        defaults.set(migrated.rawValue, forKey: defaultsKey)
        syncLegacyShadow(migrated, in: defaults)
        return migrated
    }

    /// Legacy `"themeMode"` value this mode projects onto for surfaces that
    /// still read it (maps, CarPlay). Grey projects to light per spec.
    var legacyShadowValue: String {
        switch self {
        case .dark: return ThemeMode.dark.rawValue
        case .light: return ThemeMode.light.rawValue
        case .grey: return ThemeMode.light.rawValue
        case .dynamic: return ThemeMode.dynamic.rawValue
        }
    }

    /// Keep the legacy key in lockstep so `SteddiTheme.currentThemeMode`
    /// (and every view observing `.steddiThemeModeChanged`) stays correct.
    static func syncLegacyShadow(_ mode: ThemeModeEx, in defaults: UserDefaults = .standard) {
        defaults.set(mode.legacyShadowValue, forKey: legacyDefaultsKey)
    }
}
