import Foundation
import AVFoundation

/// Speaks short replies back to the user. Uses ElevenLabs when a key is
/// configured (natural voice, needs network); falls back to Apple's on-device
/// synthesizer when there's no key or the request fails, so replies never go
/// silent. One utterance at a time — the coordinator awaits each speak() and
/// mutes recognition while it runs, so the app can't hear itself.
///
/// @MainActor is load-bearing: AVAudioPlayer/AVSpeechSynthesizer deliver their
/// delegate callbacks on the thread that started playback, so starting on the
/// main run loop guarantees they fire, and it keeps `continuation`/`player`
/// single-threaded — no lock, no double-resume race.
@MainActor
final class Speaker: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {

    /// ElevenLabs key; nil/empty → local voice. Set by the coordinator.
    var elevenLabsKey: String?

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var utterance: AVSpeechUtterance?   // the one currently speaking
    private var continuation: CheckedContinuation<Void, Never>?

    // Overridable so a different voice is a env-var change, not a rebuild.
    private static let voiceID =
        ProcessInfo.processInfo.environment["LMNH_ELEVENLABS_VOICE"] ?? "21m00Tcm4TlvDq8ikWAM"
    // Flash model: lowest latency tier, plenty for one-sentence replies.
    private static let modelID = "eleven_flash_v2_5"

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let key = elevenLabsKey, !key.isEmpty, await speakElevenLabs(trimmed, key: key) {
            return
        }
        await speakLocal(trimmed)
    }

    private func speakElevenLabs(_ text: String, key: String) async -> Bool {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(Self.voiceID)?output_format=mp3_44100_64") else {
            return false
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10   // a slow TTS reply must not wedge the session
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": Self.modelID
        ])
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let player = try? AVAudioPlayer(data: data) else {
            return false   // caller falls back to the local voice
        }
        self.player = player
        player.delegate = self
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            continuation = c
            if !player.play() { finish() }
        }
        self.player = nil
        return true
    }

    private func speakLocal(_ text: String) async {
        let u = AVSpeechUtterance(string: text)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            continuation = c
            utterance = u
            synth.speak(u)
        }
        utterance = nil
    }

    /// Cuts off whatever is playing (Stop pressed). Clearing the identities first
    /// means the delegate callbacks that follow from stop()/stopSpeaking() don't
    /// match and so can't resume a later utterance's continuation.
    func cancel() {
        player?.stop()
        synth.stopSpeaking(at: .immediate)
        player = nil
        utterance = nil
        finish()
    }

    // Resumes exactly once; a second delegate/cancel finds continuation nil.
    private func finish() {
        continuation?.resume()
        continuation = nil
    }

    // MARK: Delegates
    //
    // AVFoundation calls these on the playback-start thread (main, since we start
    // on the main actor). They're nonisolated to satisfy the protocols; each hops
    // to the main actor and finishes ONLY if the callback belongs to the utterance
    // still playing — a stale callback from a cancelled utterance must not resume
    // a newer one's continuation (which would un-mute recognition mid-speech).

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in if player === self.player { self.finish() } }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in if player === self.player { self.finish() } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if utterance === self.utterance { self.finish() } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in if utterance === self.utterance { self.finish() } }
    }
}
