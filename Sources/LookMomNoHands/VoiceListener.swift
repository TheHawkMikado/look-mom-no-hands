import Foundation
import AVFoundation
import Speech

/// Single always-on speech pipeline. The audio engine + mic tap run continuously;
/// only the recognition request is cycled (on utterance boundaries, on errors, and
/// at Apple's ~1-minute per-request limit). Cycling the request instead of the
/// engine is the load-bearing choice: the previous design used two engines (wake +
/// transcriber) and the mic hand-off between them raced, so recognition died the
/// moment a session started.
final class VoiceListener {

    enum ListenError: Error, CustomStringConvertible {
        case recognizerUnavailable
        case engineStartFailed(String)

        var description: String {
            switch self {
            case .recognizerUnavailable: return "speech recognizer unavailable"
            case .engineStartFailed(let m): return "audio engine failed: \(m)"
            }
        }
    }

    /// Main queue; the text of the current utterance so far (grows as you speak).
    var onPartial: ((String) -> Void)?
    /// Main queue; diagnostics for the activity log.
    var onInfo: ((String) -> Void)?
    /// Phrases the recognizer is biased toward (wake/stop words). Set before start().
    var contextualPhrases: [String] = []
    /// Main queue; smoothed 0…1 mic level for the recorder pill's waveform. Only
    /// emitted while `metering` is on (recording), to avoid needless main-thread churn.
    var onLevel: ((Float) -> Void)?
    var metering = false
    private var levelSmoothed: Float = 0

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    // The mic tap appends on a realtime audio thread while the main thread swaps
    // requests; the lock is what keeps that from being a data race (appending to
    // a request whose endAudio() already ran, or a torn pointer read).
    private let requestLock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?   // guarded by requestLock
    private var task: SFSpeechRecognitionTask?
    private var running = false
    private var restartDelay: TimeInterval = 0.1
    private var generation = 0   // invalidates callbacks from a superseded request
    // Text finalized by earlier requests within the same utterance. A recognition
    // request finalizes on a pause or Apple's ~1-minute cap; without carrying this
    // forward, a note that crosses a cycle would keep only the last request's text.
    // Only accumulates while `carryForward` is set (dictation) — in standby/command
    // each request is independent, so ambient speech can't pile up across cycles.
    // All fields except `request` are read/written on the main queue only.
    private var committed = ""
    // Best text seen from the CURRENT request — committed when a request dies
    // with an error (no isFinal arrives), so a mid-dictation recognition failure
    // doesn't drop speech the user already saw transcribed.
    private var lastPartial = ""

    /// Set by the coordinator for long continuous capture (dictation). Off for
    /// standby and single commands.
    var carryForward = false

    // Raw PCM capture for re-transcription through Scribe. Gated on `captureAudio`
    // so we only buffer when a higher-quality transcript is actually wanted (never
    // in always-on standby). Appended on the audio thread under captureLock; read
    // on main via takeCapturedWAV().
    private let captureLock = NSLock()
    private var captureSamples: [Int16] = []
    private var captureSampleRate: Double = 0
    private var _captureAudio = false
    var captureAudio: Bool {
        get { captureLock.lock(); defer { captureLock.unlock() }; return _captureAudio }
        set {
            captureLock.lock()
            _captureAudio = newValue
            if newValue { captureSamples.removeAll(keepingCapacity: true) }
            captureLock.unlock()
        }
    }

    /// Returns the captured audio as a 16-bit PCM WAV and clears the buffer, or
    /// nil if nothing was captured.
    func takeCapturedWAV() -> Data? {
        captureLock.lock()
        let samples = captureSamples
        let rate = captureSampleRate
        captureSamples.removeAll(keepingCapacity: true)
        captureLock.unlock()
        guard !samples.isEmpty, rate > 0 else { return nil }
        return Self.wav(from: samples, sampleRate: rate)
    }

    /// Throws instead of soft-failing so the coordinator can't report a healthy
    /// "listening" state over a dead pipeline.
    func start() throws {
        guard !running else { return }
        guard let recognizer, recognizer.isAvailable else {
            throw ListenError.recognizerUnavailable
        }
        committed = ""
        carryForward = false

        let input = engine.inputNode
        // NOTE: OS voice-processing (hardware AEC) was tried here but reconfigured the
        // input format and broke SFSpeechRecognizer (the wake word stopped firing), so
        // we stay on the plain always-on tap. Barge-in is done in SOFTWARE instead: the
        // coordinator keeps listening during TTS and detects your voice by transcript
        // divergence from what it's saying (see isBargeOverTTS).
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Append INSIDE the lock: swapRequest calls endAudio() under the same
            // lock, so a buffer can never land on a request that already ended.
            self.requestLock.lock()
            self.request?.append(buffer)
            self.requestLock.unlock()
            self.captureIfNeeded(buffer)
            self.emitLevel(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw ListenError.engineStartFailed(error.localizedDescription)
        }
        running = true
        onInfo?("audio engine running")
        beginRequest()
    }

    func stop() {
        guard running else { return }
        running = false
        committed = ""
        carryForward = false
        captureAudio = false
        generation += 1
        task?.cancel(); task = nil
        swapRequest(nil)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    // Realtime audio thread. Convert the tap's float samples (channel 0) to Int16
    // and accumulate while capture is on. Native sample rate — Scribe accepts
    // standard WAV, so no resampling needed.
    private func captureIfNeeded(_ buffer: AVAudioPCMBuffer) {
        captureLock.lock()
        defer { captureLock.unlock() }
        guard _captureAudio, let channel = buffer.floatChannelData?[0] else { return }
        captureSampleRate = buffer.format.sampleRate
        let n = Int(buffer.frameLength)
        captureSamples.reserveCapacity(captureSamples.count + n)
        for i in 0..<n {
            let clamped = max(-1, min(1, channel[i]))
            captureSamples.append(Int16(clamped * Float(Int16.max)))
        }
    }

    // Realtime audio thread. Emits a smoothed mic level for the pill waveform.
    private func emitLevel(_ buffer: AVAudioPCMBuffer) {
        guard metering, let cb = onLevel, let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let level = Self.normalizedLevel(rms: Self.rms(channel, n))
        levelSmoothed = levelSmoothed * 0.7 + level * 0.3   // ease jitter
        let out = levelSmoothed
        DispatchQueue.main.async { cb(out) }
    }

    private static func rms(_ samples: UnsafePointer<Float>, _ n: Int) -> Float {
        var sum: Float = 0
        for i in 0..<n { let s = samples[i]; sum += s * s }
        return (sum / Float(n)).squareRoot()
    }

    /// Maps a raw RMS (speech is a small fraction of full-scale) to a lively 0…1
    /// bar height. Pure — unit-tested.
    static func normalizedLevel(rms: Float) -> Float {
        min(1, max(0, rms * 12))
    }

    /// Builds a canonical 16-bit mono PCM WAV. Pure function — unit-tested.
    static func wav(from samples: [Int16], sampleRate: Double) -> Data {
        let rate = UInt32(sampleRate)
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let byteRate = rate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataBytes = samples.count * 2
        var d = Data()
        func str(_ s: String) { d.append(Data(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + dataBytes)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(channels); u32(rate); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        str("data"); u32(UInt32(dataBytes))
        for s in samples { u16(UInt16(bitPattern: s)) }
        return d
    }

    /// Ends the current utterance and immediately starts a fresh one — a real
    /// utterance boundary, so the carried-forward text is cleared. The engine keeps
    /// running (no mic hand-off, no race). Must be called on the main queue.
    func resetUtterance() {
        guard running else { return }
        committed = ""
        beginRequest()
    }

    /// Replaces the live request and ends the old one atomically with respect to
    /// the tap's append — both under requestLock, so append-after-endAudio can't
    /// interleave.
    private func swapRequest(_ new: SFSpeechAudioBufferRecognitionRequest?) {
        requestLock.lock()
        let old = request
        request = new
        old?.endAudio()
        requestLock.unlock()
    }

    /// Always invoked on the main queue (from start/resetUtterance, or the callback
    /// hop below), so all listener state stays single-threaded.
    private func beginRequest() {
        generation += 1
        let gen = generation
        lastPartial = ""
        task?.cancel(); task = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        if !contextualPhrases.isEmpty { request.contextualStrings = contextualPhrases }
        swapRequest(request)

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            // Snapshot the values off the recognition thread, then do ALL state
            // work on main — nothing mutates listener state off-main.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            DispatchQueue.main.async { [weak self] in
                // Guard first: a superseded request (its generation bumped by a
                // newer beginRequest) does nothing — no partial, no restart, and
                // crucially no restartDelay bump or committed pollution.
                guard let self, self.running, gen == self.generation else { return }

                if let text {
                    self.restartDelay = 0.1
                    self.lastPartial = text
                    self.onPartial?(self.committed + text)
                }

                // A request ends on error or when the recognizer finalizes (a pause
                // or the ~1-minute cap). Carry the best text forward — the final
                // result when there is one, the last partial when the request died
                // with an error — then roll into a fresh request with backoff so a
                // hard failure can't spin. Clearing lastPartial makes a stray
                // second end-callback for the same request commit nothing.
                if failed || isFinal {
                    if self.carryForward {
                        let segment = isFinal ? (text ?? self.lastPartial) : self.lastPartial
                        if !segment.isEmpty { self.committed += segment + " " }
                    }
                    self.lastPartial = ""
                    let delay = self.restartDelay
                    self.restartDelay = min(self.restartDelay * 2, 2.0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, self.running, gen == self.generation else { return }
                        self.beginRequest()
                    }
                }
            }
        }
    }
}
