import Testing
import Foundation
@testable import Steddi

// MARK: - OnboardingCoordinator (beat flow + selection state)

@MainActor
@Suite("OnboardingCoordinator")
struct OnboardingCoordinatorTests {

    @Test("Starts on the hero beat")
    func startsOnHero() {
        let c = OnboardingCoordinator()
        #expect(c.currentBeat == .hero)
    }

    @Test("Advance walks the beats in CaseIterable order")
    func advanceWalksInOrder() {
        let c = OnboardingCoordinator()
        #expect(c.currentBeat == .hero)
        #expect(c.advance() == true)
        #expect(c.currentBeat == .permissions)
        #expect(c.advance() == true)
        #expect(c.currentBeat == .theme)
        #expect(c.advance() == true)
        #expect(c.currentBeat == .emergency)
    }

    @Test("Advance on the last beat returns false and stays put")
    func advancePastEndReturnsFalse() {
        let c = OnboardingCoordinator()
        c.skipToCompletion() // jump to the final beat
        #expect(c.currentBeat == .emergency)
        #expect(c.advance() == false)
        #expect(c.currentBeat == .emergency)
    }

    @Test("hasNextBeat is true until the final beat")
    func hasNextBeatGate() {
        let c = OnboardingCoordinator()
        #expect(c.hasNextBeat == true)            // hero
        _ = c.advance(); #expect(c.hasNextBeat)   // permissions
        _ = c.advance(); #expect(c.hasNextBeat)   // theme
        _ = c.advance()                           // emergency
        #expect(c.hasNextBeat == false)
    }

    @Test("skipToCompletion lands on the final beat")
    func skipToCompletion() {
        let c = OnboardingCoordinator()
        c.skipToCompletion()
        #expect(c.currentBeat == OnboardingCoordinator.OnboardingBeat.allCases.last)
        #expect(c.currentBeat == .emergency)
    }

    // MARK: - Skip gating

    @Test("Every beat allows Skip except permissions")
    func skipGating() {
        #expect(OnboardingCoordinator.OnboardingBeat.hero.allowsSkip)
        #expect(OnboardingCoordinator.OnboardingBeat.permissions.allowsSkip == false)
        #expect(OnboardingCoordinator.OnboardingBeat.theme.allowsSkip)
        #expect(OnboardingCoordinator.OnboardingBeat.emergency.allowsSkip)
    }

    // MARK: - Primary button label

    @Test("Only the final beat's primary reads Get Started")
    func primaryLabel() {
        #expect(OnboardingCoordinator.OnboardingBeat.hero.primaryLabel == "Next")
        #expect(OnboardingCoordinator.OnboardingBeat.permissions.primaryLabel == "Next")
        #expect(OnboardingCoordinator.OnboardingBeat.theme.primaryLabel == "Next")
        #expect(OnboardingCoordinator.OnboardingBeat.emergency.primaryLabel == "Get Started")
    }

    // MARK: - Permission state

    @Test("Location grant flag defaults off and flips on")
    func locationGrantFlag() {
        let c = OnboardingCoordinator()
        #expect(c.locationGranted == false)
        c.locationGranted = true
        #expect(c.locationGranted == true)
    }

    // MARK: - Emergency contact

    @Test("Setting a contact stores the trimmed number")
    func setContactStores() {
        let c = OnboardingCoordinator()
        #expect(c.emergencyContact == nil)
        c.setEmergencyContact("  555-1234  ")
        #expect(c.emergencyContact == "555-1234")
    }

    @Test("Setting an empty or whitespace contact clears it")
    func setEmptyContactClears() {
        let c = OnboardingCoordinator()
        c.setEmergencyContact("555-1234")
        #expect(c.emergencyContact == "555-1234")
        c.setEmergencyContact("   ")
        #expect(c.emergencyContact == nil)
        c.setEmergencyContact("555-1234")
        c.setEmergencyContact(nil)
        #expect(c.emergencyContact == nil)
    }

    // MARK: - Selection defaults

    @Test("Theme defaults to a sane mode and accent")
    func selectionDefaults() {
        let c = OnboardingCoordinator()
        // Accent mirrors the current stored accent; theme mirrors current mode.
        #expect(SteddiTheme.AccentOption.allCases.contains(c.selectedAccent))
        #expect(ThemeModeEx.allCases.contains(c.selectedTheme))
    }
}
