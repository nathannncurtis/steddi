import Foundation

/// Display mode settings — Passenger and Accessibility are independent toggles.
final class DisplayModeService {
    static let shared = DisplayModeService()

    private init() {}

    /// Passenger mode: bigger text, simplified UI, passenger handles reroute/reports
    var isPassengerMode: Bool {
        get { UserDefaults.standard.bool(forKey: "steddi.passengerMode") }
        set { UserDefaults.standard.set(newValue, forKey: "steddi.passengerMode") }
    }

    /// Accessibility mode: larger icons, higher contrast, simplified instructions
    var isAccessibilityMode: Bool {
        get { UserDefaults.standard.bool(forKey: "steddi.accessibilityMode") }
        set { UserDefaults.standard.set(newValue, forKey: "steddi.accessibilityMode") }
    }

    /// Text scale factor based on active modes
    var textScale: Double {
        if isAccessibilityMode { return 1.4 }
        if isPassengerMode { return 1.2 }
        return 1.0
    }

    /// Icon scale factor
    var iconScale: Double {
        if isAccessibilityMode { return 1.5 }
        if isPassengerMode { return 1.2 }
        return 1.0
    }

    /// Whether to show simplified instructions
    var useSimplifiedInstructions: Bool {
        isAccessibilityMode
    }

    /// Whether to show extra contrast
    var useHighContrast: Bool {
        isAccessibilityMode
    }
}
