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

    @Test("ducking alert keeps media audible (duckOthers, never exclusive)")
    func alertDuckNeverPauses() {
        // Alerts use bare .duckOthers — which lowers but never pauses other
        // audio. The key adversarial invariant: the option set is never empty,
        // because an empty set means an exclusive session that would PAUSE media.
        let alert = DuckingPolicy.sessionOptions(for: .alert, shouldDuck: true)
        #expect(!alert.isEmpty)
        #expect(alert.contains(.duckOthers))
    }

    @Test("only voice interrupts spoken audio — alerts must not")
    func onlyVoiceInterruptsSpokenAudio() {
        // Interrupting spoken audio (pausing podcasts/audiobooks) is the
        // navigation-prompt behaviour. A sparse alert chime must NOT pause a
        // podcast — it only ducks. Guards against copy-pasting voice options.
        let alert = DuckingPolicy.sessionOptions(for: .alert, shouldDuck: true)
        #expect(!alert.contains(.interruptSpokenAudioAndMixWithOthers))
        let voice = DuckingPolicy.sessionOptions(for: .voice, shouldDuck: true)
        #expect(voice.contains(.interruptSpokenAudioAndMixWithOthers))
    }

    @Test("not-ducking options are identical across sound classes")
    func notDuckingIsClassIndependent() {
        // When ducking is off the behaviour is pure mix-in regardless of class;
        // the two classes must not diverge in the non-ducking branch.
        let voice = DuckingPolicy.sessionOptions(for: .voice, shouldDuck: false)
        let alert = DuckingPolicy.sessionOptions(for: .alert, shouldDuck: false)
        #expect(voice == alert)
        #expect(voice == [.mixWithOthers])
    }

    @Test("shouldDuck is exhaustive and stable across the toggle matrix")
    func shouldDuckFullMatrix() {
        // All four toggle combinations, both classes — each class follows only
        // its own toggle and is unaffected by the other's.
        for v in [true, false] {
            for a in [true, false] {
                #expect(DuckingPolicy.shouldDuck(for: .voice, voiceEnabled: v, alertEnabled: a) == v)
                #expect(DuckingPolicy.shouldDuck(for: .alert, voiceEnabled: v, alertEnabled: a) == a)
            }
        }
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

    @Test("a class is tracked active even when its ducking toggle is off")
    func tracksActiveWhenDuckingDisabled() {
        // Ducking off still activates the session (to mix our sound in over
        // media); the class must be tracked so the lifecycle stays balanced and
        // deactivation timing is correct. Mutate + restore the toggle.
        let key = "steddi.voiceNavDuckingEnabled"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)

        let service = makeService()
        service.activateForVoiceGuidance()
        #expect(service.activeClasses.contains(.voice))
        service.deactivateVoiceGuidance()
        #expect(service.activeClasses.isEmpty)
    }

    @Test("full deactivate then re-activate cycles cleanly")
    func lifecycleReentry() {
        let service = makeService()
        service.activateForAlert()
        service.deactivateAlert()
        #expect(service.activeClasses.isEmpty)
        // Re-entering after a full teardown must work, not get wedged.
        service.activateForAlert()
        #expect(service.activeClasses == [.alert])
        service.deactivateAlert()
        #expect(service.activeClasses.isEmpty)
    }

    @Test("alert then voice: deactivating alert keeps voice holding the duck")
    func conflictAlertThenVoice() {
        // Mirror of the existing voice-then-alert case in the opposite order:
        // ordering must not matter for who holds the surviving duck.
        let service = makeService()
        service.activateForAlert()
        service.activateForVoiceGuidance()
        service.deactivateAlert()
        #expect(service.activeClasses == [.voice])
        service.deactivateVoiceGuidance()
        #expect(service.activeClasses.isEmpty)
    }
}
