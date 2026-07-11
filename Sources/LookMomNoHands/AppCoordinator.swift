import Foundation
import SwiftUI
import Speech
import AVFoundation

/// The brain: interprets the single always-on speech stream according to mode
/// (the mic is never released while on), routes commands through Claude,
/// executes screen actions, and records everything to the store. Modes:
///   • STANDBY  — watching the stream for "Hey Mama". Nothing else happens.
///   • COMMAND  — active session: each pause-delimited utterance is parsed and
///     executed, then it keeps listening. "Adios Mama" returns to standby.
///   • DICTATION — long capture; a long pause ends the note and produces a report.
@MainActor
final class AppCoordinator: ObservableObject {
    @Published var phase: AppPhase = .idle
    @Published var lastCommand: String = ""
    @Published var lastReport: DictationReport?
    @Published var isRunning = false          // app-level on/off (Start/Stop button)
    @Published var micAuthorized = false
    @Published var speechAuthorized = false
    @Published var accessibilityTrusted = false

    /// Wake session open. Derived from `mode` so it can never desync; every mode
    /// change is accompanied by a `phase` write, which publishes the update.
    var isActive: Bool { mode != .standby }

    let store = AppStore()

    private enum Mode { case standby, command, dictation }
    private var mode: Mode = .standby
    private var processing = false            // Claude call / action in flight
    private var utterance = ""                // current partial transcript
    private var lastHeardAt = Date()
    private var sessionIdleSince = Date()
    private var dictationStartAt = Date()
    private var ticker: Timer?
    private var actionTask: Task<Void, Never>?   // in-flight parse/act; cancelled by stop()
    private var runGeneration = 0                // stale task completions must not touch newer state

    private let listener = VoiceListener()
    private var claude: ClaudeClient?

    private let commandSilence: TimeInterval = 1.2
    private let dictationSilence: TimeInterval = 3.0
    private let dictationMax: TimeInterval = 180
    private let sessionIdleLimit: TimeInterval = 90   // quiet this long → standby

    // The misspellings are how the recognizer actually renders the phrases;
    // contextualStrings biasing (set in init) reduces but doesn't eliminate them.
    nonisolated static let wakePhrases = ["hey mama", "hey mamma", "hey momma", "hey ma ma"]
    nonisolated static let stopPhrases = ["adios mama", "adios mamma", "adios momma", "adios ma ma", "adiós mama"]

    init() {
        listener.contextualPhrases = ["Hey Mama", "Adios Mama"]
        listener.onPartial = { [weak self] text in self?.handlePartial(text) }
        listener.onInfo = { [weak self] msg in self?.store.log("speech", msg) }
        store.log("app", "launched")
        loadKey()
        refreshAuthFlags()
        store.log("app", "auth at launch: mic=\(micAuthorized) speech=\(speechAuthorized)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            guard !(self.micAuthorized && self.speechAuthorized) else { return }
            self.requestPermissions { _ in }
        }
    }

    private func refreshAuthFlags() {
        micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized
        accessibilityTrusted = ScreenController.isTrusted
    }

    /// Explicit, user-initiated Accessibility prompt (opens System Settings once).
    /// Never called automatically — only from the panel button, so we don't nag.
    func requestAccessibility() {
        ScreenController.requestTrust()
    }

    // MARK: API key

    private func loadKey() {
        if let env = ProcessInfo.processInfo.environment["LMNH_ANTHROPIC_API_KEY"] {
            claude = ClaudeClient(apiKey: env)
            store.log("app", "API key loaded from env")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let key = KeychainStore.load()
            DispatchQueue.main.async {
                guard let self else { return }
                if let key {
                    self.claude = ClaudeClient(apiKey: key)
                    self.store.log("app", "API key loaded from keychain")
                } else {
                    self.store.log("app", "no keychain key — enter it in the panel")
                }
            }
        }
    }

    func setAPIKey(_ key: String) {
        KeychainStore.save(key)
        claude = ClaudeClient(apiKey: key)
        store.log("app", "API key saved")
    }

    var hasKey: Bool { claude != nil }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        requestPermissions { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.phase = .error("Mic/Speech permission denied")
                self.store.log("perm", "denied — cannot start")
                return
            }
            do {
                try self.listener.start()
            } catch {
                // Don't claim to be listening over a dead pipeline.
                self.phase = .error("\(error)")
                self.store.log("error", "listener failed to start: \(error)")
                return
            }
            self.runGeneration += 1
            self.isRunning = true
            self.mode = .standby
            self.phase = .listeningWake
            self.utterance = ""
            self.store.log("app", "listening enabled (standby)")
        }
    }

    func stop() {
        runGeneration += 1
        actionTask?.cancel(); actionTask = nil
        processing = false
        isRunning = false
        mode = .standby
        stopTicker()
        listener.stop()
        phase = .idle
        store.log("app", "listening disabled")
    }

    // The ticker only exists inside a session — silence gates are meaningless in
    // standby, and an always-on 4 Hz timer would wake the main thread all day.
    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate(); ticker = nil
    }

    // MARK: Stream interpretation

    private func handlePartial(_ text: String) {
        guard isRunning else { return }
        utterance = text
        lastHeardAt = Date()
        guard !processing else { return }

        // Phrases only ever arrive at the tail of new speech; scanning the whole
        // growing utterance every partial is O(n²) over a long session. Normalizing
        // strips the recognizer's unpredictable punctuation ("Hey, Mama.").
        let tail = Self.normalizedForMatching(String(text.suffix(64)))
        switch mode {
        case .standby:
            if Self.wakePhrases.contains(where: tail.contains) { beginSession() }
        case .command:
            if Self.stopPhrases.contains(where: tail.contains) { endSession(reason: "\"Adios Mama\"") }
        case .dictation:
            break // a long pause ends the note; "adios" could be part of it
        }
    }

    /// Lowercase, reduced to space-separated alphanumeric runs.
    nonisolated static func normalizedForMatching(_ text: String) -> String {
        let mapped = String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
        return mapped.split(separator: " ").joined(separator: " ")
    }

    /// Runs 4×/second while a session is open; applies silence gates without ever
    /// touching the mic.
    private func tick() {
        guard isRunning, !processing else { return }
        let quiet = Date().timeIntervalSince(lastHeardAt)

        switch mode {
        case .standby:
            break
        case .command:
            if !utterance.isEmpty, quiet > commandSilence {
                finalizeCommand()
            } else if utterance.isEmpty,
                      Date().timeIntervalSince(sessionIdleSince) > sessionIdleLimit {
                endSession(reason: "inactivity")
            }
        case .dictation:
            let tooLong = Date().timeIntervalSince(dictationStartAt) > dictationMax
            if (!utterance.isEmpty && quiet > dictationSilence) || tooLong {
                finalizeDictation()
            }
        }
    }

    // MARK: Session

    private func beginSession() {
        store.log("wake", "\"Hey Mama\" — session active")
        mode = .command
        phase = .capturingCommand
        freshUtterance()
        sessionIdleSince = Date()
        startTicker()
    }

    private func endSession(reason: String) {
        store.log("wake", "session ended (\(reason)) — back to standby")
        mode = .standby
        phase = .listeningWake
        freshUtterance()
        stopTicker()
    }

    private func freshUtterance() {
        utterance = ""
        listener.resetUtterance()
    }

    /// Post-flight cleanup shared by the command and dictation tasks. A task that
    /// outlived its run (Stop was pressed, maybe Start again) must not touch newer
    /// state; an error phase set in the catch stays visible instead of being
    /// clobbered back to "listening".
    private func finishProcessing(_ gen: Int) {
        guard gen == runGeneration else { return }
        processing = false
        guard isRunning, mode == .command else { return }
        if case .error = phase {} else { phase = .capturingCommand }
        // Discard anything heard while we were acting (e.g. our own typing sounds).
        freshUtterance()
        sessionIdleSince = Date()
    }

    // MARK: Commands

    private func finalizeCommand() {
        let text = Self.strippingPhrases(Self.wakePhrases + Self.stopPhrases, from: utterance)
        freshUtterance()
        sessionIdleSince = Date()
        guard !text.isEmpty else { return }
        guard let claude else { phase = .error("No API key set"); return }

        lastCommand = text
        store.log("asr", "command: \(text)")
        processing = true
        phase = .thinking
        let startedAt = Date()
        let gen = runGeneration

        actionTask = Task {
            defer { self.finishProcessing(gen) }
            do {
                let action = try await claude.parseCommand(text)
                try Task.checkCancellation()
                let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
                self.store.log("claude", "action=\(action.kind.rawValue) target=\"\(action.target)\" conf=\(action.confidence) (\(ms)ms)")
                switch action.kind {
                case .dictateStart:
                    self.beginDictation()
                case .none:
                    self.store.log("action", "nothing actionable — still listening")
                default:
                    self.phase = .acting
                    // The AX tree walk + CGEvent posting is synchronous and can be
                    // slow on a complex UI — run it off the main actor so it never
                    // stalls the event loop. AX/CGEvent APIs are thread-safe.
                    try await Task.detached(priority: .userInitiated) {
                        try ScreenController.perform(action)
                    }.value
                    try Task.checkCancellation()
                    let outcome = "\(action.kind.rawValue) \(action.target)".trimmingCharacters(in: .whitespaces)
                    self.store.log("action", "performed: \(outcome)")
                    self.store.addTranscript(TranscriptRecord(kind: "command", transcript: text, outcome: outcome))
                }
            } catch {
                // Cancellation isn't a failure: Stop was pressed while the call was
                // in flight, and acting now would defy the user's explicit off.
                guard !Task.isCancelled, gen == self.runGeneration else {
                    self.store.log("action", "abandoned — stopped mid-command")
                    return
                }
                self.phase = .error("\(error)")
                self.store.log("error", "\(error)")
                self.store.addTranscript(TranscriptRecord(kind: "command", transcript: text, outcome: "error: \(error)"))
            }
        }
    }

    nonisolated static func strippingPhrases(_ phrases: [String], from text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for phrase in phrases {
            // .caseInsensitive matches on `out` directly, so the returned range's
            // indices are valid on `out` (unlike range(of:) on a lowercased copy).
            while let range = out.range(of: phrase, options: .caseInsensitive) {
                out.removeSubrange(range)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    // MARK: Dictation

    private func beginDictation() {
        store.log("dictation", "started — recording note (pause \(Int(dictationSilence))s to finish)")
        mode = .dictation
        dictationStartAt = Date()
        phase = .dictating
        freshUtterance()
        listener.carryForward = true   // a note may cross a recognition-request cycle
    }

    private func finalizeDictation() {
        listener.carryForward = false
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        freshUtterance()
        mode = .command
        guard !text.isEmpty, let claude else {
            store.log("dictation", "empty note")
            phase = .capturingCommand
            sessionIdleSince = Date()
            return
        }
        store.log("dictation", "captured \(text.count) chars — summarizing")
        processing = true
        phase = .thinking
        let gen = runGeneration

        actionTask = Task {
            defer { self.finishProcessing(gen) }
            do {
                let report = try await claude.buildDictationReport(text)
                try Task.checkCancellation()
                self.lastReport = report
                self.store.log("claude", "report ready — \(report.actionItems.count) action items")
                self.store.addTranscript(TranscriptRecord(
                    kind: "dictation",
                    transcript: text,
                    summary: report.summary,
                    actionItems: report.actionItems
                ))
            } catch {
                // Whatever went wrong, never lose the note — the raw text is already
                // gone from the live buffer, so this record is its only copy.
                let outcome = Task.isCancelled ? "cancelled" : "error: \(error)"
                self.store.addTranscript(TranscriptRecord(kind: "dictation", transcript: text, outcome: outcome))
                guard !Task.isCancelled, gen == self.runGeneration else {
                    self.store.log("dictation", "stopped mid-summarize — raw note saved")
                    return
                }
                self.phase = .error("\(error)")
                self.store.log("error", "\(error)")
            }
        }
    }

    // MARK: Permissions

    func requestPermissions(_ completion: @escaping (Bool) -> Void) {
        // A menu-bar (accessory) app must be active for the TCC prompt to appear.
        NSApplication.shared.activate(ignoringOtherApps: true)
        store.log("perm", "requesting: speech=\(Self.speechName(SFSpeechRecognizer.authorizationStatus())) mic=\(Self.micName(AVCaptureDevice.authorizationStatus(for: .audio)))")
        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                DispatchQueue.main.async {
                    self?.store.log("perm", "result: speech=\(Self.speechName(speechStatus)) mic=\(micGranted ? "granted" : "denied")")
                    self?.refreshAuthFlags()
                    completion(speechStatus == .authorized && micGranted)
                }
            }
        }
        // Accessibility is NOT prompted here — only via the panel's explicit button,
        // so clicking Start never opens System Settings. Just record the status.
        store.log("perm", "accessibility trusted: \(ScreenController.isTrusted)")
    }

    // These two switches look mergeable but aren't: the enums assign different raw
    // values to denied/restricted, so a shared raw-value table would mislabel.
    private static func speechName(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    private static func micName(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }
}
