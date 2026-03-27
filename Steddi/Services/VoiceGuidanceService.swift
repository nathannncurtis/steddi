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
    func resolve() -> AVSpeechSynthesisVoice {
        if let voice = AVSpeechSynthesisVoice(identifier: rawValue) { return voice }

        // Try enhanced variant
        let enhanced = rawValue.replacingOccurrences(of: ".premium.", with: ".enhanced.")
        if let voice = AVSpeechSynthesisVoice(identifier: enhanced) { return voice }

        // Try compact variant
        let compact = rawValue.replacingOccurrences(of: ".premium.", with: ".compact.")
            .replacingOccurrences(of: ".enhanced.", with: ".compact.")
        if let voice = AVSpeechSynthesisVoice(identifier: compact) { return voice }

        return AVSpeechSynthesisVoice(language: "en-US")!
    }
}

/// Speaks turn-by-turn navigation instructions using AVSpeechSynthesizer.
final class VoiceGuidanceService {
    static let shared = VoiceGuidanceService()

    private let synthesizer = AVSpeechSynthesizer()
    private var isEnabled = true
    private var currentVoice: AVSpeechSynthesisVoice

    private init() {
        let savedId = UserDefaults.standard.string(forKey: "steddi.voiceIdentifier") ?? VoiceOption.ava.rawValue
        let option = VoiceOption(rawValue: savedId) ?? .ava
        currentVoice = option.resolve()

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
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

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = currentVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
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
