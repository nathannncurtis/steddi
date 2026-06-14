import SwiftUI
import Observation

/// Drives Steddi's first-run flow: a small, ordered set of "beats" the user
/// steps through, plus the selections they make along the way.
///
/// The coordinator owns *flow* state only — beat advancement and the
/// in-progress accent/theme/emergency picks. Persistence
/// lives in `@AppStorage`/the theme engine; the coordinator never writes those
/// directly so a mid-flow `steddi://reset-onboarding` can rebuild a fresh
/// coordinator without leaving partial writes behind. `OnboardingView` reads
/// `currentBeat` to decide which subview to show and calls `advance()` /
/// `skipToCompletion()` from the footer.
///
/// Named `Onboarding…` (not a bare `Coordinator`/`Beat`) on purpose — generic
/// top-level names have collided across pillars before.
@Observable
@MainActor
final class OnboardingCoordinator {

    /// The ordered first-run beats. `CaseIterable` order *is* the flow order.
    enum OnboardingBeat: String, CaseIterable {
        case hero        // animated route draw across a dark map
        case permissions // location, framed in-context
        case theme       // accent + theme pick — the delight moment
        case emergency   // optional emergency contact

        /// Permissions is the one beat without a top-level Skip: the user makes
        /// an explicit allow/defer choice there rather than skipping past it.
        var allowsSkip: Bool { self != .permissions }

        /// The footer's primary label. The last beat completes onboarding, so it
        /// reads "Get Started" rather than "Next".
        var primaryLabel: String {
            self == OnboardingBeat.allCases.last ? "Get Started" : "Next"
        }
    }

    /// The beat currently on screen.
    private(set) var currentBeat: OnboardingBeat = .hero

    /// Set when the hero's draw-on finishes (or immediately under Reduce Motion),
    /// so the footer's primary button can pop in on cue.
    var heroAnimationComplete: Bool = false

    /// In-progress accent pick. Persisted to `@AppStorage("accentColor")` by the
    /// theme beat; mirrored here so the live flow can tint itself.
    var selectedAccent: SteddiTheme.AccentOption = SteddiTheme.currentAccentOption

    /// In-progress theme-mode pick. Applied through the engine on completion.
    var selectedTheme: ThemeModeEx = ThemeModeEx.current()

    /// Phone number of a chosen emergency contact, if any. Mirrors the value
    /// `EmergencyView` reads from `@AppStorage("steddi.emergencyContact")`.
    var emergencyContact: String?

    /// True while a beat transition is in flight, so the footer can disable its
    /// buttons and avoid double-advances during the animation window.
    var isTransitioning: Bool = false

    // MARK: - Beat navigation

    /// True when there is a beat after the current one.
    var hasNextBeat: Bool {
        guard let idx = OnboardingBeat.allCases.firstIndex(of: currentBeat) else { return false }
        return idx < OnboardingBeat.allCases.count - 1
    }

    /// Move to the next beat, or signal completion when there isn't one.
    /// Returns `true` if the flow advanced, `false` if it's finished (the caller
    /// then flips `hasCompletedOnboarding`).
    @discardableResult
    func advance() -> Bool {
        guard let idx = OnboardingBeat.allCases.firstIndex(of: currentBeat),
              idx < OnboardingBeat.allCases.count - 1 else {
            return false
        }
        currentBeat = OnboardingBeat.allCases[idx + 1]
        return true
    }

    /// Jump straight to the final beat's *next* step — i.e. end the flow. The
    /// caller completes onboarding; this just records intent for any observers.
    func skipToCompletion() {
        currentBeat = OnboardingBeat.allCases.last ?? .emergency
    }

    /// Record the contact choice from the picker. `nil` clears it (user backed
    /// out of the picker without choosing).
    func setEmergencyContact(_ phone: String?) {
        let trimmed = phone?.trimmingCharacters(in: .whitespacesAndNewlines)
        emergencyContact = (trimmed?.isEmpty == false) ? trimmed : nil
    }
}
