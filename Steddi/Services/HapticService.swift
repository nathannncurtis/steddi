import UIKit

/// Haptic feedback events that can occur during navigation.
enum HapticEvent: String, CaseIterable, Identifiable {
    case turnApproaching
    case rerouteSuggestion
    case arrival
    case uiToggle
    case alert

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .turnApproaching: return "Turn Approaching"
        case .rerouteSuggestion: return "Reroute Suggestion"
        case .arrival: return "Arrival"
        case .uiToggle: return "UI Interactions"
        case .alert: return "Alerts"
        }
    }

    /// Default intensity for Dynamic mode (0.0 to 1.0).
    var dynamicDefault: Double {
        switch self {
        case .turnApproaching: return 0.4
        case .rerouteSuggestion: return 0.6
        case .arrival: return 1.0
        case .uiToggle: return 0.2
        case .alert: return 0.7
        }
    }
}

/// Haptic intensity levels.
enum HapticLevel: String, CaseIterable, Identifiable {
    case off
    case subtle
    case standard
    case dynamic
    case advanced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .subtle: return "Subtle"
        case .standard: return "Standard"
        case .dynamic: return "Dynamic"
        case .advanced: return "Advanced"
        }
    }
}

/// Centralized haptic feedback service.
final class HapticService {
    static let shared = HapticService()

    private let defaults: UserDefaults
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notification = UINotificationFeedbackGenerator()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        impactLight.prepare()
        impactMedium.prepare()
        impactHeavy.prepare()
        notification.prepare()
    }

    private var level: HapticLevel {
        let raw = defaults.string(forKey: "steddi.hapticLevel") ?? HapticLevel.dynamic.rawValue
        return HapticLevel(rawValue: raw) ?? .dynamic
    }

    // MARK: - Per-Event Intensity (Advanced mode)

    /// Stored intensity for an event, clamped to 0...1. Falls back to the Dynamic default.
    func intensity(for event: HapticEvent) -> Double {
        guard let stored = defaults.object(forKey: intensityKey(for: event)) as? Double else {
            return event.dynamicDefault
        }
        return min(max(stored, 0), 1)
    }

    /// Persist a custom intensity for an event, clamped to 0...1.
    func setIntensity(_ intensity: Double, for event: HapticEvent) {
        defaults.set(min(max(intensity, 0), 1), forKey: intensityKey(for: event))
    }

    /// Clear all custom intensities so events fall back to their Dynamic defaults.
    func resetIntensitiesToDynamicDefaults() {
        for event in HapticEvent.allCases {
            defaults.removeObject(forKey: intensityKey(for: event))
        }
    }

    private func intensityKey(for event: HapticEvent) -> String {
        "steddi.haptic.\(event.rawValue)"
    }

    /// Fire a haptic for the given event.
    func fire(_ event: HapticEvent) {
        switch level {
        case .off:
            return
        case .subtle:
            impactLight.impactOccurred(intensity: 0.3)
        case .standard:
            impactMedium.impactOccurred(intensity: 0.6)
        case .dynamic:
            fireAtIntensity(event.dynamicDefault)
        case .advanced:
            fireAtIntensity(intensity(for: event))
        }
    }

    /// Fire an event at its stored intensity, for auditioning in settings.
    /// Bypasses the level-based intensity mapping (the fine-tune UI is only
    /// reachable in Advanced) but still respects Off so a future caller can
    /// never buzz a user who disabled haptics.
    func preview(_ event: HapticEvent) {
        guard level != .off else { return }
        fireAtIntensity(intensity(for: event))
    }

    private func fireAtIntensity(_ intensity: Double) {
        guard intensity > 0 else { return }
        if intensity <= 0.3 {
            impactLight.impactOccurred(intensity: intensity)
        } else if intensity <= 0.6 {
            impactMedium.impactOccurred(intensity: intensity)
        } else {
            impactHeavy.impactOccurred(intensity: intensity)
        }
    }

    /// Convenience for notification-style haptics.
    func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard level != .off else { return }
        notification.notificationOccurred(type)
    }
}
