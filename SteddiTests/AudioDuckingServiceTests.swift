import Testing
import AVFoundation
@testable import Steddi

/// Pure ducking-decision matrix. These mirror the spec's conflict matrix and
/// run without touching the shared AVAudioSession.
@Suite("DuckingPolicy")
struct DuckingPolicyTests {

    // MARK: - shouldDuck (toggle gating)

    @Test("voice ducks only when the voice toggle is on")
    func voiceToggleGatesVoiceDuck() {
        #expect(DuckingPolicy.shouldDuck(for: .voice, voiceEnabled: true, alertEnabled: false))
        #expect(!DuckingPolicy.shouldDuck(for: .voice, voiceEnabled: false, alertEnabled: true))
    }

    @Test("alert ducks only when the alert toggle is on")
    func alertToggleGatesAlertDuck() {
        #expect(DuckingPolicy.shouldDuck(for: .alert, voiceEnabled: false, alertEnabled: true))
        #expect(!DuckingPolicy.shouldDuck(for: .alert, voiceEnabled: true, alertEnabled: false))
    }

    @Test("the two toggles are independent")
    func togglesAreIndependent() {
        // Voice off, alert on: voice does not duck, alert does. (Spec row 1.)
        #expect(!DuckingPolicy.shouldDuck(for: .voice, voiceEnabled: false, alertEnabled: true))
        #expect(DuckingPolicy.shouldDuck(for: .alert, voiceEnabled: false, alertEnabled: true))
    }

    // MARK: - sessionOptions

    @Test("ducking voice mixes, ducks, and interrupts spoken audio")
    func voiceDuckOptions() {
        let opts = DuckingPolicy.sessionOptions(for: .voice, shouldDuck: true)
        #expect(opts.contains(.duckOthers))
        #expect(opts.contains(.interruptSpokenAudioAndMixWithOthers))
    }

    @Test("ducking alert ducks others")
    func alertDuckOptions() {
        let opts = DuckingPolicy.sessionOptions(for: .alert, shouldDuck: true)
        #expect(opts.contains(.duckOthers))
    }

    @Test("not ducking mixes without lowering media volume — never pauses")
    func notDuckingMixesOnly() {
        for soundClass in DuckingSoundClass.allCases {
            let opts = DuckingPolicy.sessionOptions(for: soundClass, shouldDuck: false)
            #expect(opts.contains(.mixWithOthers))
            #expect(!opts.contains(.duckOthers), "\(soundClass) must not duck when its toggle is off")
        }
    }

    @Test("a ducking sound never carries options that would pause media")
    func neverPauses() {
        // duckOthers + mix means media keeps playing at reduced volume; we must
        // never omit a mix/duck option set that would let our sound take the
        // session exclusively and pause others.
        let voice = DuckingPolicy.sessionOptions(for: .voice, shouldDuck: true)
        #expect(voice.contains(.interruptSpokenAudioAndMixWithOthers) || voice.contains(.mixWithOthers))
    }

    // MARK: - canDeactivate (conflict matrix)

    @Test("can deactivate when no other class is active")
    func deactivateWhenAlone() {
        #expect(DuckingPolicy.canDeactivate(ending: .voice, otherClassActive: false))
        #expect(DuckingPolicy.canDeactivate(ending: .alert, otherClassActive: false))
    }

    @Test("cannot deactivate while the other class still holds the duck")
    func holdWhileOtherActive() {
        // Voice ends but an alert is still firing: keep the session up so the
        // alert's duck survives. (Spec: media reduced for the surviving sound.)
        #expect(!DuckingPolicy.canDeactivate(ending: .voice, otherClassActive: true))
        #expect(!DuckingPolicy.canDeactivate(ending: .alert, otherClassActive: true))
    }
}

/// Stateful service: verifies active-class tracking and that deactivation only
/// happens once the last sound class ends.
@Suite("AudioDuckingService")
@MainActor
struct AudioDuckingServiceTests {

    /// Fresh service per test so activeClasses state doesn't leak between cases.
    private func makeService() -> AudioDuckingService {
        AudioDuckingService(session: .sharedInstance())
    }

    @Test("activating a class records it as active")
    func activateTracks() {
        let service = makeService()
        service.activateForVoiceGuidance()
        #expect(service.activeClasses.contains(.voice))
        #expect(!service.activeClasses.contains(.alert))
    }

    @Test("deactivating removes only that class")
    func deactivateRemoves() {
        let service = makeService()
        service.activateForVoiceGuidance()
        service.activateForAlert()
        service.deactivateVoiceGuidance()
        #expect(!service.activeClasses.contains(.voice))
        #expect(service.activeClasses.contains(.alert))
    }

    @Test("voice then alert: deactivating voice keeps the alert holding the duck")
    func conflictVoiceThenAlert() {
        let service = makeService()
        service.activateForVoiceGuidance()
        service.activateForAlert()
        // Voice prompt ends first; alert is still active.
        service.deactivateVoiceGuidance()
        #expect(service.activeClasses == [.alert])
        // Alert ends → session can fully tear down.
        service.deactivateAlert()
        #expect(service.activeClasses.isEmpty)
    }

    @Test("deactivating an inactive class is a no-op")
    func deactivateInactiveIsNoOp() {
        let service = makeService()
        service.deactivateAlert()
        #expect(service.activeClasses.isEmpty)
    }

    @Test("re-activating the same class doesn't duplicate it")
    func reactivateIdempotent() {
        let service = makeService()
        service.activateForVoiceGuidance()
        service.activateForVoiceGuidance()
        #expect(service.activeClasses == [.voice])
    }
}
