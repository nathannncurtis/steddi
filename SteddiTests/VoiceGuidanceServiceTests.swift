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

// MARK: - Duck-release generation gate (interrupt race)

/// The pure release decision that backs the interrupt-race fix: a finished /
/// cancelled utterance only un-ducks media when it is the LATEST generation AND
/// the synthesizer isn't still speaking. An interrupting prompt bumps the
/// generation before cancelling the old one, so the old utterance's `didCancel`
/// sees a stale stamp and must NOT release the duck the new prompt just took.
@Suite("VoiceGuidanceService.shouldReleaseDuck")
struct VoiceGuidanceDuckGateTests {

    @Test("a superseded (older-generation) utterance does NOT release the duck")
    func staleGenerationDoesNotRelease() {
        // speak()=gen 1, then interrupt -> speak()=gen 2. The gen-1 utterance's
        // didCancel arrives with finishedGeneration 1 while current is 2.
        #expect(!VoiceGuidanceService.shouldReleaseDuck(
            finishedGeneration: 1, current: 2, isSpeaking: false))
    }

    @Test("the final, un-superseded utterance releases the duck when speech ends")
    func latestGenerationReleasesWhenIdle() {
        #expect(VoiceGuidanceService.shouldReleaseDuck(
            finishedGeneration: 2, current: 2, isSpeaking: false))
    }

    @Test("the latest generation still does NOT release while speech is in flight")
    func latestGenerationHoldsWhileSpeaking() {
        // Guards the second arm: even the current generation must not tear the
        // session down while the synthesizer is mid-utterance.
        #expect(!VoiceGuidanceService.shouldReleaseDuck(
            finishedGeneration: 2, current: 2, isSpeaking: true))
    }

    @Test("an unstamped utterance (no generation) never releases")
    func unstampedNeverReleases() {
        #expect(!VoiceGuidanceService.shouldReleaseDuck(
            finishedGeneration: nil, current: 2, isSpeaking: false))
    }
}

// Drives the real VoiceGuidanceService end-handler through synthetic utterances
// (the simulator's voice DB is often broken, so we don't rely on the synthesizer
// actually speaking — we register utterances under generations exactly as speak()
// does and fire the end-handler the delegate would). Asserts the interrupt does
// not release the duck and the duck releases only after the LAST utterance ends.
@Suite("VoiceGuidanceService interrupt holds the duck", .serialized)
@MainActor
struct VoiceGuidanceInterruptDuckTests {

    @Test("interrupt keeps the duck; only the final utterance releases it")
    func interruptHoldsDuckUntilFinalUtterance() {
        let service = VoiceGuidanceService.shared
        let duck = AudioDuckingService.shared

        // Clean slate: no class should be holding the session.
        service.stop()
        #expect(!duck.activeClasses.contains(.voice))

        // First prompt: activate the duck and stamp utterance A under gen N.
        duck.activateForVoiceGuidance()
        let first = AVSpeechUtterance(string: "In 500 feet, turn left onto Main Street")
        service.registerUtteranceForTesting(first)
        #expect(duck.activeClasses.contains(.voice))

        // A newer prompt interrupts: it re-activates the duck and stamps utterance
        // B under gen N+1 — mirroring speak()'s bump-before-cancel ordering.
        duck.activateForVoiceGuidance()
        let second = AVSpeechUtterance(string: "Then turn right onto 2nd Avenue")
        service.registerUtteranceForTesting(second)

        // The interrupted utterance A now reports didCancel. Its stamp is stale,
        // so the end-handler must NOT release the duck — media stays ducked under
        // the new prompt instead of popping back to full mid-instruction.
        let releasedOnCancel = service.handleUtteranceEnd(first)
        #expect(!releasedOnCancel)
        #expect(duck.activeClasses.contains(.voice), "interrupt must not un-duck media mid-prompt")

        // The final utterance B finishes naturally: it is the latest generation
        // and nothing is speaking, so NOW the duck releases and media restores.
        let releasedOnFinish = service.handleUtteranceEnd(second)
        #expect(releasedOnFinish)
        #expect(!duck.activeClasses.contains(.voice), "duck must release once the last utterance ends")

        service.stop()
    }
}
