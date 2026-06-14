import AVFoundation

/// The two independent classes of Steddi sound that can duck media.
/// Voice = turn-by-turn guidance; Alert = speed traps, hazards, reroute chimes.
enum DuckingSoundClass: String, CaseIterable, Sendable {
    case voice
    case alert
}

/// Pure, side-effect-free ducking policy. Decides the AVAudioSession category
/// options and deactivation behaviour for a given set of toggles and live
/// session state. Kept separate from `AudioDuckingService` so the decision
/// matrix is unit-testable without touching the shared `AVAudioSession`.
enum DuckingPolicy {

    /// Whether a given sound class should duck media when it plays, given the
    /// user's toggle for that class. Ducking is opt-out: when the toggle is on,
    /// media ducks; when off, Steddi's sound plays over media at full volume and
    /// media is left untouched.
    static func shouldDuck(for soundClass: DuckingSoundClass, voiceEnabled: Bool, alertEnabled: Bool) -> Bool {
        switch soundClass {
        case .voice: return voiceEnabled
        case .alert: return alertEnabled
        }
    }

    /// Session category options for an active Steddi sound.
    ///
    /// Steddi NEVER pauses media — it mixes with and ducks it. When the relevant
    /// toggle is on we add `.duckOthers` so the OS lowers media volume for the
    /// duration; when off we still `.mixWithOthers` so our sound is audible but
    /// media stays at full volume. `.interruptSpokenAudioAndMixWithOthers` lets
    /// voice guidance pause-and-resume *spoken* media (podcasts/audiobooks)
    /// rather than just ducking it, which is the iOS-native behaviour for
    /// navigation prompts.
    static func sessionOptions(for soundClass: DuckingSoundClass, shouldDuck: Bool) -> AVAudioSession.CategoryOptions {
        guard shouldDuck else {
            // Not ducking: just mix in over media without lowering its volume.
            return [.mixWithOthers]
        }
        switch soundClass {
        case .voice:
            return [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        case .alert:
            return [.duckOthers]
        }
    }

    /// Whether the shared session can be deactivated once `ending` finishes,
    /// given whether the *other* sound class is still active. We only tear the
    /// session down (and thus restore media volume) when nothing else Steddi is
    /// playing — otherwise the surviving sound keeps the duck in place.
    static func canDeactivate(ending: DuckingSoundClass, otherClassActive: Bool) -> Bool {
        !otherClassActive
    }
}

/// Manages the shared `AVAudioSession` so every Steddi sound (voice guidance,
/// alerts, future trap tones) DUCKS media instead of pausing it, and restores
/// media volume cleanly when our sounds end.
///
/// Two independent sound classes (voice, alert) each have their own toggle.
/// The service tracks which classes are currently active so it can hold the
/// duck while any are playing and only deactivate — with
/// `notifyOthersOnDeactivation` so the OS bumps media volume back up — once the
/// last one stops.
@MainActor
final class AudioDuckingService {
    static let shared = AudioDuckingService()

    /// User toggles. Defaults match the spec (both on). Read lazily from
    /// UserDefaults so Settings changes take effect on the next sound event.
    private var voiceEnabled: Bool {
        UserDefaults.standard.object(forKey: "steddi.voiceNavDuckingEnabled") as? Bool ?? true
    }
    private var alertEnabled: Bool {
        UserDefaults.standard.object(forKey: "steddi.alertDuckingEnabled") as? Bool ?? true
    }

    /// Sound classes with a live session activation. A class stays in here from
    /// `activate` until its matching `deactivate`.
    private(set) var activeClasses: Set<DuckingSoundClass> = []

    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    // MARK: - Voice guidance

    /// Configure + activate the session for voice guidance. Safe to call on
    /// every utterance — re-setting the category mid-speech is cheap and keeps
    /// the options correct if the toggle flipped since the last prompt.
    func activateForVoiceGuidance() {
        activate(.voice)
    }

    /// Voice guidance finished. Deactivates (restoring media volume) only if no
    /// alert is still ducking.
    func deactivateVoiceGuidance() {
        deactivate(.voice)
    }

    // MARK: - Alerts

    /// Configure + activate the session for an alert sound.
    func activateForAlert() {
        activate(.alert)
    }

    /// Alert finished. Deactivates only if voice guidance isn't still ducking.
    func deactivateAlert() {
        deactivate(.alert)
    }

    // MARK: - Core

    private func activate(_ soundClass: DuckingSoundClass) {
        let duck = DuckingPolicy.shouldDuck(for: soundClass, voiceEnabled: voiceEnabled, alertEnabled: alertEnabled)
        let options = DuckingPolicy.sessionOptions(for: soundClass, shouldDuck: duck)

        // playback + voicePrompt keeps us audible over the ringer switch and
        // routes prompts the way iOS expects for navigation.
        try? session.setCategory(.playback, mode: .voicePrompt, options: options)
        try? session.setActive(true)
        activeClasses.insert(soundClass)
    }

    private func deactivate(_ soundClass: DuckingSoundClass) {
        activeClasses.remove(soundClass)
        let otherActive = !activeClasses.isEmpty
        guard DuckingPolicy.canDeactivate(ending: soundClass, otherClassActive: otherActive) else { return }

        // notifyOthersOnDeactivation: tells the OS our sound is done so it can
        // restore the ducked media to full volume cleanly.
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
