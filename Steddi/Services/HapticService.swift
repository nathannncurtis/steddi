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

    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notification = UINotificationFeedbackGenerator()

    private init() {
        impactLight.prepare()
        impactMedium.prepare()
        impactHeavy.prepare()
        notification.prepare()
    }

    private var level: HapticLevel {
        let raw = UserDefaults.standard.string(forKey: "steddi.hapticLevel") ?? HapticLevel.dynamic.rawValue
        return HapticLevel(rawValue: raw) ?? .dynamic
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
            let key = "steddi.haptic.\(event.rawValue)"
            let custom = UserDefaults.standard.double(forKey: key)
            let intensity = custom > 0 ? custom : event.dynamicDefault
            fireAtIntensity(intensity)
        }
    }

    private func fireAtIntensity(_ intensity: Double) {
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
