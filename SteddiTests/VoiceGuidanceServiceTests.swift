import Testing
import AVFoundation
@testable import Steddi

@Suite("VoiceOption")
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
