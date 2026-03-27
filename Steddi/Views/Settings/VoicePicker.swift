import SwiftUI
import AVFoundation

struct VoicePicker: View {
    @AppStorage("steddi.voiceIdentifier") private var selectedVoiceId: String = VoiceOption.ava.rawValue

    private var selectedOption: VoiceOption {
        VoiceOption(rawValue: selectedVoiceId) ?? .ava
    }

    var body: some View {
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
