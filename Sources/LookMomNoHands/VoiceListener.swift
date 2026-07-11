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
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Append INSIDE the lock: swapRequest calls endAudio() under the same
            // lock, so a buffer can never land on a request that already ended.
            self.requestLock.lock()
            self.request?.append(buffer)
            self.requestLock.unlock()
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
        generation += 1
        task?.cancel(); task = nil
        swapRequest(nil)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
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
