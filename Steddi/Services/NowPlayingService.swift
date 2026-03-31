import MediaPlayer
import UIKit

/// Manages Now Playing media controls for CarPlay and the phone nav UI.
/// Registers for remote command events so steering wheel buttons work.
final class NowPlayingService {
    static let shared = NowPlayingService()

    private let commandCenter = MPRemoteCommandCenter.shared()
    private var isRegistered = false

    private init() {}

    /// Current now playing info for display
    var title: String { MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String ?? "" }
    var artist: String { MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String ?? "" }
    var artwork: UIImage? {
        guard let mpArtwork = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork else { return nil }
        return mpArtwork.image(at: CGSize(width: 60, height: 60))
    }
    var isPlaying: Bool { MPNowPlayingInfoCenter.default().playbackState == .playing }

    /// Register for remote commands — call when CarPlay connects or nav starts
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

        // These commands pass through to whatever audio app is playing
        // We don't need handlers — the system routes them automatically
        // when we're not an audio app ourselves
    }

    /// Unregister when CarPlay disconnects
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
    }
}
