import Foundation

/// The silence meter: decides whether a captured chunk contains any speech
/// energy at all, BEFORE it costs anything — no Scribe upload, no cleanup
/// call, no hallucinated "thank you" from a transcription model fed room tone.
///
/// Deliberately biased toward sending: the measure is the LOUDEST 100ms window
/// (max, not average), so one word inside twelve seconds of silence passes the
/// whole chunk, and the threshold sits low enough that quiet speech clears it
/// easily. This gate exists to stop dead air, not soft talkers.
enum SpeechGate {

    /// ≈ -46 dBFS. Windowed speech, even murmured at a distance, measures an
    /// order of magnitude above this; HVAC hum and mic self-noise sit below.
    static let voiceThreshold: Double = 0.005

    /// True when any 100ms window of the WAV reaches speech-level energy.
    nonisolated static func hasVoice(wav: Data) -> Bool {
        peakWindowRMS(wav: wav) >= voiceThreshold
    }

    /// Max RMS over 100ms windows of a canonical 16-bit mono WAV (the only
    /// format VoiceListener.wav(from:sampleRate:) produces). Malformed or
    /// header-only data reads as 0 — silent, never a crash.
    nonisolated static func peakWindowRMS(wav: Data) -> Double {
        let headerBytes = 44
        guard wav.count > headerBytes + 2 else { return 0 }
        let sampleRate = wav.withUnsafeBytes { buf -> UInt32 in
            buf.loadUnaligned(fromByteOffset: 24, as: UInt32.self)
        }
        let window = max(1, Int(sampleRate) / 10)   // 100ms of samples
        var peak = 0.0
        wav.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let sampleBytes = buf.count - headerBytes
            let count = sampleBytes / 2
            var index = 0
            while index < count {
                let end = min(index + window, count)
                var sum = 0.0
                for i in index..<end {
                    let s = Double(buf.loadUnaligned(fromByteOffset: headerBytes + i * 2, as: Int16.self)) / 32768.0
                    sum += s * s
                }
                peak = max(peak, (sum / Double(end - index)).squareRoot())
                index = end
            }
        }
        return peak
    }

    /// One to three words need no model pass: pasting them verbatim loses
    /// nothing, and skipping the call closes the door the garbage-in bug came
    /// through — a cleanup model handed a hallucinated scrap has nothing to
    /// riff on if it's never asked.
    nonisolated static func tooShortForCleanup(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count <= 3
    }

    /// A cleanup result that BALLOONED from a short input is the model talking,
    /// not the user — "I'm ready to clean up dictated text…" pasted into an
    /// editor is how this failure looks. Growth on long input is normal
    /// (punctuation, paragraph breaks); growth from almost nothing is not.
    nonisolated static func cleanupLooksInvented(raw: String, cleaned: String) -> Bool {
        raw.count < 60 && cleaned.count > max(raw.count * 4, 40)
    }
}
