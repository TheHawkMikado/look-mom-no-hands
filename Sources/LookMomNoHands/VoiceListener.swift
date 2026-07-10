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
    /// Main queue; the text of the current utterance so far (grows as you speak).
    var onPartial: ((String) -> Void)?
    /// Main queue; diagnostics for the activity log.
    var onInfo: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    private var restartDelay: TimeInterval = 0.1
    private var generation = 0   // invalidates callbacks from a superseded request

    func start() {
        guard !running else { return }
        guard let recognizer, recognizer.isAvailable else {
            onInfo?("speech recognizer unavailable")
            return
        }
        running = true

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            running = false
            engine.inputNode.removeTap(onBus: 0)
            onInfo?("audio engine failed: \(error.localizedDescription)")
            return
        }
        onInfo?("audio engine running")
        beginRequest()
    }

    func stop() {
        guard running else { return }
        running = false
        generation += 1
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Ends the current utterance and immediately starts a fresh one.
    /// The engine keeps running — no mic hand-off, no race.
    func resetUtterance() {
        guard running else { return }
        beginRequest()
    }

    private func beginRequest() {
        generation += 1
        let gen = generation
        task?.cancel(); task = nil
        request?.endAudio()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.restartDelay = 0.1
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.running, gen == self.generation else { return }
                    self.onPartial?(text)
                }
            }
            // A request ends on error or when the recognizer finalizes (incl. the
            // ~1-minute on-device limit). While running, roll straight into a new
            // one with a small backoff so a persistent failure can't spin-loop.
            if error != nil || (result?.isFinal ?? false) {
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
