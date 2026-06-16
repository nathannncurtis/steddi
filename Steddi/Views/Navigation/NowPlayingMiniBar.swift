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

    /// Display-mode treatment threaded from the nav overlay (same source as the
    /// other readouts: DisplayModeService) so the title/artist promote in
    /// weight (highContrast) and grow in size (textScale) alongside the rest of
    /// the HUD in accessibility / passenger mode instead of staying thin/small.
    var textScale: Double = 1
    var highContrast: Bool = false

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
        // Faint scrim under the glass — the shared over-map protection the top
        // banner / street-name capsule use, so the title/artist hold contrast
        // against bright/varied cartography instead of washing out (the
        // translucent glass path has no opaque fill of its own). Same shape as
        // the glass below; skipped when glass is off (the fallback is opaque).
        .mapGlassScrim(in: RoundedRectangle(cornerRadius: SteddiTheme.radiusMedium))
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
                    .font(SteddiTheme.body((compact ? 13 : 14) * textScale, highContrast: highContrast).weight(.semibold))
                    .foregroundStyle(SteddiTheme.textPrimary)
                    .lineLimit(1)
                if !service.nowPlayingArtist.isEmpty {
                    Text(service.nowPlayingArtist)
                        .font(SteddiTheme.body((compact ? 11 : 12) * textScale, highContrast: highContrast))
                        .foregroundStyle(SteddiTheme.textSecondary(highContrast: highContrast))
                        .lineLimit(1)
                }
            } else {
                // Honest generic placeholder for apps we can't read.
                Text("Now Playing")
                    .font(SteddiTheme.body((compact ? 13 : 14) * textScale, highContrast: highContrast).weight(.semibold))
                    .foregroundStyle(SteddiTheme.textPrimary)
                    .lineLimit(1)
            }
        }
        // The track/artist ride translucent glass over the moving map; the soft
        // per-glyph shadow the sibling nav readouts use keeps them off the tiles
        // (textSecondary in particular is AA-proven only on solid surfaces).
        .legibleOverMap()
    }

    // MARK: - Play / Pause + long-press seek

    // Internal (not private) so the tap-target test can render it in isolation
    // and assert the 44pt minimum hit area without booting the full bar.
    var playPauseButton: some View {
        Image(systemName: isSeeking ? "forward.fill" : (service.isPlaying ? "pause.fill" : "play.fill"))
            .font(.system(size: compact ? 16 : 18, weight: .bold))
            .foregroundStyle(SteddiTheme.accent)
            .frame(width: height - (compact ? 12 : 14), height: height - (compact ? 12 : 14))
            .background(Circle().fill(SteddiTheme.accentSubtle))
            // Keep the smaller visual circle but expand the hit area to the 44pt
            // HIG minimum — this is the play/pause control used while driving,
            // and a near-miss falls through to the bar's tap (launching the
            // music app out of nav). Matches HomeView's sub-44 glyph pattern.
            .frame(width: 44, height: 44)
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
