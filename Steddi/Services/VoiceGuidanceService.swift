import AVFoundation

/// Speaks turn-by-turn navigation instructions using AVSpeechSynthesizer.
final class VoiceGuidanceService {
    static let shared = VoiceGuidanceService()

    private let synthesizer = AVSpeechSynthesizer()
    private var isEnabled = true

    private init() {
        // Ensure audio session is set up for speech over other audio
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
    }

    var enabled: Bool {
        get { isEnabled }
        set { isEnabled = newValue; if !newValue { stop() } }
    }

    /// Speak a navigation instruction (e.g. "Turn left onto Main Street")
    func speak(_ text: String) {
        guard isEnabled, !text.isEmpty else { return }

        // Stop any current speech before starting new
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        // Small delay so it doesn't fire instantly on step change
        utterance.preUtteranceDelay = 0.2

        try? AVAudioSession.sharedInstance().setActive(true)
        synthesizer.speak(utterance)
    }

    /// Speak with distance prefix (e.g. "In 500 feet, turn left onto Main Street")
    func speakWithDistance(_ instruction: String, distance: Double) {
        guard isEnabled else { return }

        let distText: String
        if distance < 160 {
            distText = "In \(Int(distance * 3.281)) feet"
        } else {
            let miles = distance / 1609.34
            if miles < 0.15 {
                distText = "In \(Int(distance * 3.281)) feet"
            } else if miles < 1 {
                distText = String(format: "In %.1f miles", miles)
            } else {
                distText = "In \(Int(miles)) miles"
            }
        }

        speak("\(distText), \(instruction)")
    }

    /// Announce arrival
    func speakArrival() {
        speak("You have arrived at your destination")
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}
