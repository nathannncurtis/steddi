import MediaPlayer
import UIKit
import Observation

/// Manages Now Playing media controls for CarPlay and the phone nav UI.
///
/// Honest iOS limitation: remote *commands* (play/pause/skip/seek) route to
/// whatever app owns audio, so they work for Spotify, podcasts, Apple Music,
/// etc. But *metadata* (title/artist/artwork) is only reliably readable for
/// Apple Music via `MPMusicPlayerController.systemMusicPlayer`. Third-party
/// apps do not publish their now-playing metadata to us. So we read Apple
/// Music's player for metadata, expose `hasReliableMetadata` to let the UI
/// decide between rich chrome and a generic "Now Playing" placeholder, and
/// NEVER fabricate title/artist for an app we can't read.
@Observable
@MainActor
final class NowPlayingService {
    static let shared = NowPlayingService()

    // MARK: - Published now-playing state (observed by the mini-bar)

    /// Track title — empty when no reliable metadata is available.
    private(set) var nowPlayingTitle: String = ""
    /// Track artist — empty when no reliable metadata is available.
    private(set) var nowPlayingArtist: String = ""
    /// Artwork — Apple Music only; nil for everything else.
    private(set) var nowPlayingArtwork: UIImage?
    /// Whether *some* audio is playing right now (covers all apps via the
    /// system music player's playback state, falling back to the audio session
    /// when another app owns output).
    private(set) var isPlaying: Bool = false

    /// True only when we have trustworthy title/artist (i.e. Apple Music is the
    /// active player). The mini-bar shows generic chrome when this is false but
    /// `isPlaying` is true.
    var hasReliableMetadata: Bool { !nowPlayingTitle.isEmpty }

    /// Anything to show in the mini-bar at all — either real metadata or a known
    /// "something is playing" state.
    var hasNowPlaying: Bool { isPlaying || hasReliableMetadata }

    // MARK: - Internals

    @ObservationIgnored private let commandCenter = MPRemoteCommandCenter.shared()
    @ObservationIgnored private let musicPlayer = MPMusicPlayerController.systemMusicPlayer
    @ObservationIgnored private var isRegistered = false
    @ObservationIgnored private var isObserving = false
    /// Default seek increment in seconds (spec: 15s). Used by long-press skip.
    @ObservationIgnored let seekIncrement: TimeInterval = 15

    private init() {}

    // MARK: - Observation lifecycle

    /// Begin observing playback so `isPlaying` / metadata stay current. Call
    /// when the nav UI appears.
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(playbackStateChanged),
                       name: .MPMusicPlayerControllerPlaybackStateDidChange, object: musicPlayer)
        nc.addObserver(self, selector: #selector(nowPlayingItemChanged),
                       name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: musicPlayer)
        musicPlayer.beginGeneratingPlaybackNotifications()
        refresh()
    }

    /// Stop observing. Call when the nav UI disappears.
    func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        musicPlayer.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func playbackStateChanged() { refresh() }
    @objc private func nowPlayingItemChanged() { refresh() }

    /// Pull the latest state from the system music player. Apple Music exposes a
    /// real `nowPlayingItem`; for other apps it's nil, so metadata stays empty
    /// and we only report play/pause via `AVAudioSession.isOtherAudioPlaying`.
    func refresh() {
        if let item = musicPlayer.nowPlayingItem {
            nowPlayingTitle = item.title ?? ""
            nowPlayingArtist = item.artist ?? ""
            nowPlayingArtwork = item.artwork?.image(at: CGSize(width: 72, height: 72))
            isPlaying = musicPlayer.playbackState == .playing
        } else {
            // No Apple Music item — could be a third-party app. Don't fake
            // metadata; just report whether other audio is active.
            nowPlayingTitle = ""
            nowPlayingArtist = ""
            nowPlayingArtwork = nil
            isPlaying = AVAudioSession.sharedInstance().isOtherAudioPlaying
        }
    }

    // MARK: - Remote commands

    /// Register for remote commands — call when CarPlay connects or nav starts.
    /// These pass through to whatever audio app is playing; the system routes
    /// them automatically since Steddi isn't itself an audio app.
    func registerCommands() {
        guard !isRegistered else { return }
        isRegistered = true

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.seekForwardCommand.isEnabled = true
        commandCenter.seekBackwardCommand.isEnabled = true
        // Long-press skip-to-seek: begin/end seeking bracket a continuous scrub.
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: seekIncrement)]
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: seekIncrement)]
    }

    /// Unregister when CarPlay disconnects.
    func unregisterCommands() {
        guard isRegistered else { return }
        isRegistered = false

        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
    }

    // MARK: - Playback control (mini-bar buttons)

    /// Toggle play/pause on the system music player. Works for Apple Music; for
    /// other apps the user controls them in their own app / Control Center, so
    /// the mini-bar's tap-to-focus opens that surface instead.
    func togglePlayPause() {
        if musicPlayer.playbackState == .playing {
            musicPlayer.pause()
        } else {
            musicPlayer.play()
        }
        refresh()
    }

    func nextTrack() { musicPlayer.skipToNextItem(); refresh() }
    func previousTrack() { musicPlayer.skipToPreviousItem(); refresh() }

    // MARK: - Long-press skip-to-seek

    /// Begin a continuous seek in the given direction. Mirrors the Control
    /// Center long-press scrub via `beginSeekingCommand`. Apple Music scrubs
    /// directly; other apps receive the routed remote command.
    func beginSeeking(forward: Bool) {
        let command = forward ? commandCenter.seekForwardCommand : commandCenter.seekBackwardCommand
        command.isEnabled = true
        if forward {
            musicPlayer.endSeeking()
            musicPlayer.beginSeekingForward()
        } else {
            musicPlayer.endSeeking()
            musicPlayer.beginSeekingBackward()
        }
    }

    /// End a continuous seek started by `beginSeeking(forward:)`.
    func endSeeking() {
        musicPlayer.endSeeking()
    }

    // MARK: - Focus the player

    /// User tapped the mini-bar: open the active player. For Apple Music we open
    /// the Music app; otherwise we surface Control Center isn't programmatically
    /// openable, so we fall back to the Music URL which the OS routes to the
    /// frontmost media app where possible.
    func openNowPlayingApp() {
        if let url = URL(string: "music://"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
}
