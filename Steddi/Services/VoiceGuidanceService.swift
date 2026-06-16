import AVFoundation

/// Available voice options for navigation guidance.
enum VoiceOption: String, CaseIterable, Identifiable {
    case samantha = "com.apple.voice.compact.en-US.Samantha"
    case ava = "com.apple.voice.premium.en-US.Ava"
    case zoe = "com.apple.voice.premium.en-US.Zoe"
    case tom = "com.apple.voice.premium.en-US.Tom"
    case evan = "com.apple.voice.premium.en-US.Evan"
    case aaron = "com.apple.voice.enhanced.en-US.Aaron"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .samantha: return "Samantha"
        case .ava: return "Ava"
        case .zoe: return "Zoe"
        case .tom: return "Tom"
        case .evan: return "Evan"
        case .aaron: return "Aaron"
        }
    }

    var previewText: String { "In 500 feet, turn right onto Main Street" }

    /// Resolve the best available voice for this option.
    /// Falls back to enhanced → compact → default language voice.
    /// Returns nil when the OS voice catalog is unavailable; a nil utterance
    /// voice makes AVSpeechSynthesizer use the system default.
    func resolve() -> AVSpeechSynthesisVoice? {
        if let voice = AVSpeechSynthesisVoice(identifier: rawValue) { return voice }

        // Try enhanced variant
        let enhanced = rawValue.replacingOccurrences(of: ".premium.", with: ".enhanced.")
        if let voice = AVSpeechSynthesisVoice(identifier: enhanced) { return voice }

        // Try compact variant
        let compact = rawValue.replacingOccurrences(of: ".premium.", with: ".compact.")
            .replacingOccurrences(of: ".enhanced.", with: ".compact.")
        if let voice = AVSpeechSynthesisVoice(identifier: compact) { return voice }

        if let voice = AVSpeechSynthesisVoice(language: "en-US") { return voice }
        if let voice = AVSpeechSynthesisVoice(language: "en") { return voice }
        // speechVoices() can be empty when the OS voice db fails to load —
        // simulators often log "[VoiceDBClient] Error fetching voices:
        // DecodingError ... Using fallback voices". That noise is Apple's
        // private AVSpeechSynthesis machinery, not app code; don't chase it.
        return AVSpeechSynthesisVoice.speechVoices().first
    }
}

/// Speaks turn-by-turn navigation instructions using AVSpeechSynthesizer.
///
/// Owns the audio lifecycle for voice guidance: it delegates AVAudioSession
/// category/duck management to `AudioDuckingService` so media DUCKS (never
/// pauses) while speaking and restores cleanly when the prompt ends. NSObject
/// so it can be the synthesizer delegate and learn when an utterance finishes.
///
/// `@MainActor`-isolated: every entry point (NavigationEngine, the SwiftUI
/// settings/overlay views) already runs on the main actor, and the duck service
/// it drives (`AudioDuckingService`) is `@MainActor` too. Isolating the class
/// lets the compiler GUARANTEE main-actor delivery instead of relying on a
/// `MainActor.assumeIsolated` precondition that would FATAL-TRAP a future
/// off-main caller mid-drive. The synthesizer delegate callbacks stay
/// `nonisolated` (they can arrive off-main) and hop back via `Task { @MainActor }`.
@MainActor
final class VoiceGuidanceService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceGuidanceService()

    private let synthesizer = AVSpeechSynthesizer()
    private var isEnabled = true
    private var currentVoice: AVSpeechSynthesisVoice?

    /// Monotonic utterance generation. Bumped in `speak()` BEFORE we cancel the
    /// in-flight utterance and start the new one, and stamped onto the new
    /// utterance (`utteranceGeneration[id]`). When an utterance finishes/cancels
    /// the delegate compares its stamp against `currentGeneration`: an older stamp
    /// means a newer `speak()` has already superseded it (e.g. the `didCancel`
    /// fired for the utterance we just interrupted), so its un-duck MUST be
    /// suppressed — the newer utterance has re-activated the duck and the stale
    /// deactivate would race that activate, un-ducking media mid-prompt. Only the
    /// LATEST generation's natural finish (or an explicit `stop()`) releases the
    /// duck. See `shouldReleaseDuck(finishedGeneration:current:isSpeaking:)`.
    private var currentGeneration: UInt64 = 0

    /// Maps each live `AVSpeechUtterance` to the generation it was issued under.
    /// Identity-keyed (utterances are reference types) so the delegate can recover
    /// the stamp without subclassing AVSpeechUtterance. Entries are pruned the
    /// moment their utterance finishes/cancels, so this holds at most the handful
    /// of utterances briefly in flight across a back-to-back interrupt.
    private var utteranceGeneration: [ObjectIdentifier: UInt64] = [:]

    private override init() {
        let savedId = UserDefaults.standard.string(forKey: "steddi.voiceIdentifier") ?? VoiceOption.ava.rawValue
        let option = VoiceOption(rawValue: savedId) ?? .ava
        currentVoice = option.resolve()
        super.init()
        synthesizer.delegate = self
        // AVAudioSession category is now configured per-utterance by
        // AudioDuckingService so the duck reflects the current toggle and is
        // torn down (restoring media volume) when speech ends.
    }

    var enabled: Bool {
        get { isEnabled }
        set { isEnabled = newValue; if !newValue { stop() } }
    }

    var voiceOption: VoiceOption {
        get {
            let savedId = UserDefaults.standard.string(forKey: "steddi.voiceIdentifier") ?? VoiceOption.ava.rawValue
            return VoiceOption(rawValue: savedId) ?? .ava
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "steddi.voiceIdentifier")
            currentVoice = newValue.resolve()
        }
    }

    /// Speak a navigation instruction (e.g. "Turn left onto Main Street")
    func speak(_ text: String) {
        guard isEnabled, !text.isEmpty else { return }

        // Bump the generation BEFORE cancelling: the `didCancel` that
        // `stopSpeaking` triggers for the old utterance will now see its stamp is
        // stale (< currentGeneration) and skip its un-duck, so the duck stays held
        // continuously across the interrupt instead of being torn down under the
        // new utterance we're about to start.
        currentGeneration &+= 1
        let generation = currentGeneration

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = currentVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.2
        utteranceGeneration[ObjectIdentifier(utterance)] = generation

        // Duck media (respecting the voice-nav-ducking toggle) and activate the
        // session before speaking. Both this method and AudioDuckingService are
        // @MainActor, so this is a direct, compiler-checked main-actor call.
        AudioDuckingService.shared.activateForVoiceGuidance()
        synthesizer.speak(utterance)
    }

    /// Whether a finished/cancelled utterance should release the voice duck.
    ///
    /// Pure decision (so it's unit-testable without driving the synthesizer): an
    /// utterance only releases the duck when it is the LATEST generation issued
    /// (`finishedGeneration == current`) AND the synthesizer is not still
    /// speaking. An older generation means a newer `speak()` already superseded
    /// this utterance and re-activated the duck — releasing here would race that
    /// activate and un-duck media mid-prompt, the bug this guards.
    nonisolated static func shouldReleaseDuck(
        finishedGeneration: UInt64?,
        current: UInt64,
        isSpeaking: Bool
    ) -> Bool {
        guard !isSpeaking else { return false }
        guard let finishedGeneration else { return false }
        return finishedGeneration == current
    }

    #if DEBUG
    /// Test seam: the generation an utterance would be stamped with right now.
    /// Lets duck-race tests register a synthetic utterance under the current
    /// generation (mirroring what `speak()` does) and then drive
    /// `handleUtteranceEnd` deterministically — without depending on the real
    /// synthesizer actually speaking (the simulator's voice DB is often broken).
    var currentGenerationForTesting: UInt64 { currentGeneration }

    /// Test seam: bump the generation and stamp `utterance` under it, exactly as
    /// `speak()` does for the utterance it issues. Returns the stamped generation.
    @discardableResult
    func registerUtteranceForTesting(_ utterance: AVSpeechUtterance) -> UInt64 {
        currentGeneration &+= 1
        utteranceGeneration[ObjectIdentifier(utterance)] = currentGeneration
        return currentGeneration
    }
    #endif

    /// MainActor handler shared by `didFinish`/`didCancel`: prune the utterance's
    /// stamp, then release the duck only if this was the final, un-superseded
    /// utterance. Returns whether it released (for tests).
    @MainActor
    @discardableResult
    func handleUtteranceEnd(_ utterance: AVSpeechUtterance) -> Bool {
        let stamp = utteranceGeneration.removeValue(forKey: ObjectIdentifier(utterance))
        guard Self.shouldReleaseDuck(
            finishedGeneration: stamp,
            current: currentGeneration,
            isSpeaking: synthesizer.isSpeaking
        ) else { return false }
        AudioDuckingService.shared.deactivateVoiceGuidance()
        return true
    }

    /// Speak with distance prefix (e.g. "In 500 feet, turn left onto Main Street").
    /// Spoken units follow the user's persisted preference (miles+feet or
    /// kilometers+meters).
    func speakWithDistance(_ instruction: String, distance: Double) {
        guard isEnabled else { return }
        speak("\(Self.distancePhrase(meters: distance)), \(instruction)")
    }

    /// The spoken distance prefix for a maneuver at `meters` away, in the user's
    /// unit ("In 500 feet" / "In 0.3 miles" / "In 11 miles", or "In 150 meters" /
    /// "In 0.3 kilometers" / "In 11 kilometers"). Pure and `nonisolated` so the
    /// rounding contract is unit-testable without driving the synthesizer.
    /// `unit` defaults to the persisted preference so the live call site is
    /// preference-driven; tests pin it explicitly.
    nonisolated static func distancePhrase(
        meters distance: Double,
        unit: MeasurementUnit = .current
    ) -> String {
        switch unit {
        case .miles:
            if distance < 160 {
                return "In \(Int(distance * 3.281)) feet"
            }
            let miles = distance / unit.metersPerUnit
            if miles < 0.15 {
                return "In \(Int(distance * 3.281)) feet"
            } else if miles < 1 {
                return String(format: "In %.1f miles", miles)
            } else {
                // Round, don't truncate: 10.95 mi announces "In 11 miles", not 10.
                return "In \(Int(miles.rounded())) miles"
            }
        case .kilometers:
            // Metric mirror: speak whole meters in the short range, then
            // one-decimal kilometers under 1 km, then whole kilometers — the same
            // sub-unit / decimal / whole-number band structure as imperial.
            let km = distance / unit.metersPerUnit
            if km < 0.25 {
                return "In \(Int(distance.rounded())) meters"
            } else if km < 1 {
                return String(format: "In %.1f kilometers", km)
            } else {
                // Round, don't truncate: 10.95 km announces "In 11 kilometers".
                return "In \(Int(km.rounded())) kilometers"
            }
        }
    }

    /// Announce arrival
    func speakArrival() {
        speak("You have arrived at your destination")
    }

    func stop() {
        // Bump the generation so the `didCancel` that `stopSpeaking` fires for the
        // in-flight utterance sees a stale stamp and does NOT release the duck —
        // this method releases it explicitly below. Without the bump, both the
        // stale cancel and this call would deactivate (harmless today, but it keeps
        // the single-owner release invariant), and any utterance still queued is
        // abandoned: clear the stamp map so it can't later release.
        currentGeneration &+= 1
        utteranceGeneration.removeAll()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        AudioDuckingService.shared.deactivateVoiceGuidance()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    /// Speech finished naturally — un-duck media (unless this utterance was
    /// superseded by a newer prompt, or an alert still holds the duck; see
    /// `handleUtteranceEnd`). AVSpeechSynthesizer USUALLY fires delegate callbacks
    /// on the main queue, but that is not contractually guaranteed
    /// (interruption/route-change paths can deliver off-main), so hop explicitly —
    /// `assumeIsolated` would FATAL-TRAP an off-main delivery mid-drive.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.handleUtteranceEnd(utterance) }
    }

    /// Speech was cancelled (e.g. a newer prompt interrupted it). The interrupt
    /// path bumps the generation in `speak()` BEFORE cancelling, so this cancelled
    /// utterance's stamp is now stale and `handleUtteranceEnd` suppresses its
    /// un-duck — the new utterance keeps the duck held. Only a cancel of the
    /// genuinely-last utterance with nothing speaking releases media.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.handleUtteranceEnd(utterance) }
    }
}
