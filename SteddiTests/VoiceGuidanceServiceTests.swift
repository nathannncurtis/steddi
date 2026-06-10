import Testing
import AVFoundation
@testable import Steddi

// .serialized: concurrent AVSpeechSynthesisVoice(identifier:) calls can segfault
// inside Apple's TextToSpeech framework when the simulator's voice db is broken
// (the "[VoiceDBClient] Error fetching voices" condition). Running the
// parameterized cases one at a time avoids the framework race; see crash
// reports Steddi-2026-06-09-233750.ips / -234145.ips (EXC_BAD_ACCESS in
// TextToSpeech on Concurrent Executor threads).
@Suite("VoiceOption", .serialized)
struct VoiceOptionTests {

    @Test("resolve never traps, even with an empty voice catalog", arguments: VoiceOption.allCases)
    func resolveNeverTraps(option: VoiceOption) {
        if let voice = option.resolve() {
            #expect(!voice.identifier.isEmpty)
        }
    }

    @Test("display names are unique and non-empty")
    func displayNames() {
        let names = VoiceOption.allCases.map(\.displayName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == names.count)
    }

    @Test("identifiers round-trip through rawValue")
    func rawValueRoundTrip() {
        for option in VoiceOption.allCases {
            #expect(VoiceOption(rawValue: option.rawValue) == option)
        }
    }
}
