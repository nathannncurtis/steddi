import SwiftUI

/// Compact now-playing card for the navigation overlay. Shows artwork +
/// title/artist + a play/pause button for Apple Music, and falls back to a
/// generic music glyph + "Now Playing" label when metadata is unavailable
/// (third-party apps) — never fabricates a title.
///
/// Long-pressing the play button enters skip-to-seek (Control Center style),
/// driven by `NowPlayingService.beginSeeking`/`endSeeking`.
struct NowPlayingMiniBar: View {
    var service: NowPlayingService = .shared

    /// Compact landscape variant: tighter padding + smaller artwork so it fits
    /// the bottom-left button column without crowding the ETA bar.
    var compact: Bool = false

    @State private var isSeeking = false

    private var artSize: CGFloat { compact ? 30 : 36 }
    private var height: CGFloat { compact ? 44 : 52 }

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            artwork
            labels
            Spacer(minLength: 6)
            playPauseButton
        }
        .padding(.horizontal, compact ? 10 : 12)
        .frame(height: height)
        // Route through the centralized glass modifier so Reduce Transparency /
        // high-contrast goes opaque like the rest of the nav chrome instead of
        // leaving the title/artist fighting the moving map underneath.
        .steddiGlass(
            in: RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium),
            fallbackStrokeOpacity: 0.12
        )
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium))
        .onTapGesture { service.openNowPlayingApp() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Artwork

    @ViewBuilder private var artwork: some View {
        if let image = service.nowPlayingArtwork {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: artSize, height: artSize)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            // Generic chrome — no fabricated artwork.
            RoundedRectangle(cornerRadius: 8)
                .fill(SteddiTheme.accentSubtle)
                .frame(width: artSize, height: artSize)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: artSize * 0.45, weight: .semibold))
                        .foregroundStyle(SteddiTheme.accent)
                )
        }
    }

    // MARK: - Labels

    @ViewBuilder private var labels: some View {
        VStack(alignment: .leading, spacing: 1) {
            if service.hasReliableMetadata {
                Text(service.nowPlayingTitle)
                    .font(SteddiTheme.body(compact ? 13 : 14).weight(.semibold))
                    .foregroundStyle(SteddiTheme.textPrimary)
                    .lineLimit(1)
                if !service.nowPlayingArtist.isEmpty {
                    Text(service.nowPlayingArtist)
                        .font(SteddiTheme.body(compact ? 11 : 12))
                        .foregroundStyle(SteddiTheme.textSecondary)
                        .lineLimit(1)
                }
            } else {
                // Honest generic placeholder for apps we can't read.
                Text("Now Playing")
                    .font(SteddiTheme.body(compact ? 13 : 14).weight(.semibold))
                    .foregroundStyle(SteddiTheme.textPrimary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Play / Pause + long-press seek

    private var playPauseButton: some View {
        Image(systemName: isSeeking ? "forward.fill" : (service.isPlaying ? "pause.fill" : "play.fill"))
            .font(.system(size: compact ? 16 : 18, weight: .bold))
            .foregroundStyle(SteddiTheme.accent)
            .frame(width: height - (compact ? 12 : 14), height: height - (compact ? 12 : 14))
            .background(Circle().fill(SteddiTheme.accentSubtle))
            .contentShape(Circle())
            .onTapGesture {
                guard !isSeeking else { return }
                service.togglePlayPause()
                HapticService.shared.fire(.uiToggle)
            }
            .gesture(
                LongPressGesture(minimumDuration: 0.4)
                    .onEnded { _ in
                        isSeeking = true
                        service.beginSeeking(forward: true)
                        HapticService.shared.fire(.uiToggle)
                    }
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onEnded { _ in
                        if isSeeking {
                            service.endSeeking()
                            isSeeking = false
                        }
                    }
            )
            .accessibilityLabel(service.isPlaying ? "Pause" : "Play")
            .accessibilityHint("Long press to seek forward")
    }

    private var accessibilityText: String {
        if service.hasReliableMetadata {
            return "Now playing: \(service.nowPlayingTitle), \(service.nowPlayingArtist)"
        }
        return "Now playing"
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3).ignoresSafeArea()
        VStack(spacing: 16) {
            NowPlayingMiniBar()
            NowPlayingMiniBar(compact: true)
                .frame(width: 260)
        }
        .padding()
    }
}
