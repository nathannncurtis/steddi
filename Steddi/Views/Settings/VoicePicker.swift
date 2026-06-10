import SwiftUI
import AVFoundation

struct VoicePicker: View {
    @AppStorage("steddi.voiceIdentifier") private var selectedVoiceId: String = VoiceOption.ava.rawValue
    @State private var catalogUnavailable = false

    var body: some View {
        Group {
            if catalogUnavailable {
                LabeledContent("Voice", value: "System default")
            } else {
                Picker("Voice", selection: $selectedVoiceId) {
                    ForEach(VoiceOption.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .onChange(of: selectedVoiceId) {
                    if let option = VoiceOption(rawValue: selectedVoiceId) {
                        VoiceGuidanceService.shared.voiceOption = option
                        // Preview the voice
                        VoiceGuidanceService.shared.speak(option.previewText)
                    }
                }
            }
        }
        .task {
            // speechVoices() XPCs to the TTS daemon on first use — hundreds of
            // ms normally, and it can hang outright when the OS voice db is
            // broken ("[VoiceDBClient] Error fetching voices"). This view is
            // recreated every time voice guidance is toggled on in Settings,
            // so probe the catalog off the main thread.
            catalogUnavailable = await Task.detached(priority: .userInitiated) {
                let voices = AVSpeechSynthesisVoice.speechVoices()
                if voices.isEmpty { return true }
                // "Using fallback voices" condition: the catalog is non-empty
                // but none of our named options are actually installed, so all
                // six names would resolve to the same fallback voice. Showing
                // the picker would be misleading — fall back to system default.
                let installed = Set(voices.map(\.identifier))
                return VoiceOption.allCases.allSatisfy { !installed.contains($0.rawValue) }
            }.value
        }
    }
}
