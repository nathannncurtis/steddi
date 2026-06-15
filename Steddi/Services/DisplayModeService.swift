import Foundation
import UIKit

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

    /// Whether to show extra contrast — the app's own Accessibility mode OR the
    /// system "Increase Contrast" (Darker Colors) setting. Drives both the glass
    /// solid-fallback (`SteddiGlass.isAvailable`) and the high-contrast color
    /// promotion, so an Increase-Contrast user gets opaque, legible chrome.
    var useHighContrast: Bool {
        isAccessibilityMode || UIAccessibility.isDarkerSystemColorsEnabled
    }

    // MARK: - Instruction Simplifier

    /// Connectors that always introduce road-name detail ("Merge onto I-215 S").
    private static let alwaysCutConnectors = [" onto ", " towards ", " toward "]
    /// Connectors that introduce road names unless followed by "the …" —
    /// "on the right" / "at the fork" is maneuver detail, not a road name.
    private static let guardedConnectors = [" to ", " on ", " at "]

    /// Strip road-name detail from a maneuver instruction, leaving the bare
    /// maneuver: "Turn left onto N Orange St" -> "Turn left".
    /// Display-time transform only — voice guidance keeps the full instruction.
    static func simplifiedInstruction(_ instruction: String) -> String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let lower = trimmed.lowercased()

        // Arrival phrasing is already bare — the destination is not road noise
        if lower.contains("destination") || lower.hasPrefix("arrive") {
            return trimmed
        }

        var cut: String.Index?

        for connector in Self.alwaysCutConnectors {
            if let range = trimmed.range(of: connector, options: .caseInsensitive),
               range.lowerBound < (cut ?? trimmed.endIndex) {
                cut = range.lowerBound
            }
        }

        for connector in Self.guardedConnectors {
            var searchStart = trimmed.startIndex
            while let range = trimmed.range(of: connector, options: .caseInsensitive, range: searchStart..<trimmed.endIndex) {
                if !trimmed[range.upperBound...].lowercased().hasPrefix("the ") {
                    if range.lowerBound < (cut ?? trimmed.endIndex) {
                        cut = range.lowerBound
                    }
                    break
                }
                searchStart = range.upperBound
            }
        }

        guard let cut else { return trimmed }
        let bareManeuver = trimmed[..<cut].trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        return bareManeuver.isEmpty ? trimmed : bareManeuver
    }
}
