import AVFoundation
import os

private let cameraToneLog = Logger(subsystem: "to.nathancurtis.steddi", category: "SpeedCameraTone")

/// Plays the speed-camera proximity tone: a single, gentle two-note chime —
/// deliberately understated, NOT the repeating klaxon other nav apps use. The
/// tone is synthesized in code (no bundled asset) so it ships with zero binary
/// weight, and it ducks media via `AudioDuckingService` exactly like voice
/// guidance: media dips, the chime plays over it, media restores when it ends.
///
/// Singleton + `@MainActor` to match the codebase's audio-service idiom
/// (`VoiceGuidanceService`, `AudioDuckingService`). The generated buffer is built
/// once and reused.
@MainActor
final class SpeedCameraAlertTone: NSObject {
    static let shared = SpeedCameraAlertTone()

    private var player: AVAudioPlayer?
    /// Built lazily on first play and cached — the WAV bytes are tiny but
    /// regenerating per alert would be wasteful.
    private var toneData: Data?

    private override init() {
        super.init()
    }

    /// Play the camera chime once, ducking media for its duration. No-op if the
    /// tone can't be built or is already playing (so overlapping alerts don't
    /// stack into noise).
    func play() {
        if let player, player.isPlaying { return }

        let data: Data
        if let toneData {
            data = toneData
        } else {
            guard let built = Self.makeChimeWAV() else {
                cameraToneLog.error("Failed to synthesize camera alert tone")
                return
            }
            toneData = built
            data = built
        }

        // Duck media (respecting the alert-ducking toggle) before playing.
        AudioDuckingService.shared.activateForAlert()
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.volume = 0.7 // subtle, not jarring
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            cameraToneLog.error("Camera alert tone playback failed: \(error.localizedDescription)")
            // Playback never started — release the duck we just took.
            AudioDuckingService.shared.deactivateAlert()
        }
    }

    // MARK: - Tone synthesis

    /// Two short sine notes (a rising perfect fourth, ~G5 -> C6) with quick
    /// attack/decay envelopes so it reads as a clean "ding-dong" cue rather than
    /// a beep. Returns a complete 16-bit mono PCM WAV.
    nonisolated static func makeChimeWAV() -> Data? {
        let sampleRate = 44_100.0
        // (frequency Hz, duration seconds)
        let notes: [(Double, Double)] = [(784.0, 0.14), (1046.5, 0.20)]

        var samples: [Int16] = []
        for (frequency, duration) in notes {
            let frameCount = Int(sampleRate * duration)
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                // Linear attack over first 8ms, exponential-ish decay after, so
                // notes don't click on or off.
                let attack = min(1.0, t / 0.008)
                let decay = exp(-3.0 * (t / duration))
                let envelope = attack * decay
                let value = sin(2.0 * .pi * frequency * t) * envelope * 0.6
                samples.append(Int16(max(-1.0, min(1.0, value)) * Double(Int16.max)))
            }
        }

        return encodeWAV(samples: samples, sampleRate: Int(sampleRate))
    }

    /// Wrap 16-bit mono PCM samples in a canonical 44-byte WAV header.
    private nonisolated static func encodeWAV(samples: [Int16], sampleRate: Int) -> Data {
        let bitsPerSample = 16
        let channels = 1
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = samples.count * bitsPerSample / 8

        var data = Data()
        func appendString(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func appendUInt32LE(_ v: UInt32) {
            data.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
        }
        func appendUInt16LE(_ v: UInt16) {
            data.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)])
        }

        appendString("RIFF")
        appendUInt32LE(UInt32(36 + dataSize))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32LE(16)                  // PCM fmt chunk size
        appendUInt16LE(1)                   // PCM format
        appendUInt16LE(UInt16(channels))
        appendUInt32LE(UInt32(sampleRate))
        appendUInt32LE(UInt32(byteRate))
        appendUInt16LE(UInt16(blockAlign))
        appendUInt16LE(UInt16(bitsPerSample))
        appendString("data")
        appendUInt32LE(UInt32(dataSize))
        for sample in samples {
            appendUInt16LE(UInt16(bitPattern: sample))
        }
        return data
    }
}

extension SpeedCameraAlertTone: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Restore media volume (unless voice guidance still holds the duck).
        MainActor.assumeIsolated { AudioDuckingService.shared.deactivateAlert() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        MainActor.assumeIsolated { AudioDuckingService.shared.deactivateAlert() }
    }
}
