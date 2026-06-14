import Testing
import MediaPlayer
@testable import Steddi

/// Verifies the honest-metadata contract and that the seek command surface is
/// safe to drive. The shared service talks to the system music player, which is
/// idle in the test host — so we assert the invariants that hold regardless of
/// what (if anything) is playing rather than mocking MediaPlayer internals.
@Suite("NowPlayingService")
@MainActor
struct NowPlayingServiceTests {

    @Test("metadata is reliable only when a title is present")
    func reliableMetadataRequiresTitle() {
        let service = NowPlayingService.shared
        service.refresh()
        // hasReliableMetadata must never be true with an empty title — that is
        // the guard against showing fabricated chrome for third-party apps.
        if service.hasReliableMetadata {
            #expect(!service.nowPlayingTitle.isEmpty)
        } else {
            #expect(service.nowPlayingTitle.isEmpty)
        }
    }

    @Test("no fabricated metadata in the test host (nothing playing)")
    func noFakeMetadataWhenIdle() {
        let service = NowPlayingService.shared
        service.refresh()
        // The test host isn't playing Apple Music, so there's no reliable
        // metadata; the service must not invent any.
        #expect(!service.hasReliableMetadata)
        #expect(service.nowPlayingTitle.isEmpty)
        #expect(service.nowPlayingArtist.isEmpty)
        #expect(service.nowPlayingArtwork == nil)
    }

    @Test("seek increment defaults to 15 seconds")
    func seekIncrementDefault() {
        #expect(NowPlayingService.shared.seekIncrement == 15)
    }

    @Test("begin/end seeking in both directions is safe to call")
    func seekCommandsDoNotCrash() {
        let service = NowPlayingService.shared
        // Long-press skip-to-seek drives these; they must be safe even with no
        // active media (the routed remote command is simply a no-op).
        service.beginSeeking(forward: true)
        service.endSeeking()
        service.beginSeeking(forward: false)
        service.endSeeking()
        // Reaching here without trapping is the assertion.
        #expect(Bool(true))
    }

    @Test("registering commands enables the skip commands with the seek interval")
    func registerEnablesSkipCommands() {
        let service = NowPlayingService.shared
        service.registerCommands()
        let center = MPRemoteCommandCenter.shared()
        #expect(center.skipForwardCommand.isEnabled)
        #expect(center.skipBackwardCommand.isEnabled)
        #expect(center.skipForwardCommand.preferredIntervals == [NSNumber(value: service.seekIncrement)])
        // Idempotent: a second call is a no-op, commands stay enabled.
        service.registerCommands()
        #expect(center.playCommand.isEnabled)
    }

    @Test("hasNowPlaying reflects play state or reliable metadata")
    func hasNowPlayingContract() {
        let service = NowPlayingService.shared
        service.refresh()
        #expect(service.hasNowPlaying == (service.isPlaying || service.hasReliableMetadata))
    }
}
