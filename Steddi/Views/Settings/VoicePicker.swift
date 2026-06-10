import SwiftUI
import AVFoundation

struct VoicePicker: View {
    @AppStorage("steddi.voiceIdentifier") private var selectedVoiceId: String = VoiceOption.ava.rawValue
    @State private var catalogIsEmpty = false

    var body: some View {
        Group {
            if catalogIsEmpty {
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
        .onAppear {
            catalogIsEmpty = AVSpeechSynthesisVoice.speechVoices().isEmpty
        }
    }
}
