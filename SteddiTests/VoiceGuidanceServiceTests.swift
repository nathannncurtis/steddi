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

    // Guards against a regression that makes resolve() always return nil:
    // the fallback chain ends in speechVoices().first, so on any non-empty
    // catalog every option must resolve to something. Only vacuous in the
    // broken-voice-db state where the catalog itself is empty.
    @Test("every option resolves when the voice catalog is non-empty")
    func resolveFindsVoiceOnHealthyCatalog() {
        guard !AVSpeechSynthesisVoice.speechVoices().isEmpty else { return }
        for option in VoiceOption.allCases {
            #expect(option.resolve() != nil, "\(option) should resolve on a non-empty catalog")
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

// MARK: - Spoken distance phrase

@Suite("VoiceGuidanceService.distancePhrase")
struct VoiceGuidanceDistancePhraseTests {

    @Test("Short distance is spoken in feet")
    func feet() {
        // 100 m ≈ 328 ft
        #expect(VoiceGuidanceService.distancePhrase(meters: 100) == "In 328 feet")
    }

    @Test("Sub-mile distance gets one decimal mile")
    func decimalMile() {
        // 0.5 mi
        #expect(VoiceGuidanceService.distancePhrase(meters: 0.5 * 1609.34) == "In 0.5 miles")
    }

    // Rounding (not truncation) for whole-mile announcements.
    @Test("10.95 mi announces 11 miles (not truncated to 10)")
    func roundsUpNotTruncated() {
        #expect(VoiceGuidanceService.distancePhrase(meters: 10.95 * 1609.34) == "In 11 miles")
    }

    @Test("10.4 mi announces 10 miles")
    func roundsDown() {
        #expect(VoiceGuidanceService.distancePhrase(meters: 10.4 * 1609.34) == "In 10 miles")
    }
}

// MARK: - Main-actor isolation

// VoiceGuidanceService is @MainActor: speak()/stop() drive the @MainActor
// AudioDuckingService directly (no more MainActor.assumeIsolated precondition
// that would FATAL-TRAP an off-main caller). This @MainActor suite proves the
// main-actor call path compiles and runs without trapping; an off-actor caller
// is now a compile-time error.
@Suite("VoiceGuidanceService main-actor isolation", .serialized)
@MainActor
struct VoiceGuidanceIsolationTests {

    @Test("speak then stop on the main actor does not trap")
    func speakStopOnMainActorIsSafe() {
        let service = VoiceGuidanceService.shared
        let wasEnabled = service.enabled
        service.enabled = true
        // Drives AudioDuckingService.activate/deactivateForVoiceGuidance under
        // the hood — reaching the end without a fatal trap is the assertion.
        service.speak("Turn left onto Main Street")
        service.stop()
        service.enabled = wasEnabled
        #expect(Bool(true))
    }
}
