import Foundation
import SwiftUI
import Speech
import AVFoundation

/// The brain: interprets the single always-on speech stream according to mode,
/// routes commands through Claude, executes screen actions, and records
/// everything to the store.
///
/// Modes over one continuous pipeline (the mic is never released while on):
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
    @Published var isActive = false           // wake session open
    @Published var micAuthorized = false
    @Published var speechAuthorized = false

    let store = AppStore()

    private enum Mode { case standby, command, dictation }
    private var mode: Mode = .standby
    private var processing = false            // Claude call / action in flight
    private var utterance = ""                // current partial transcript
    private var lastHeardAt = Date()
    private var sessionIdleSince = Date()
    private var dictationStartAt = Date()
    private var ticker: Timer?

    private let listener = VoiceListener()
    private var claude: ClaudeClient?

    private let commandSilence: TimeInterval = 1.2
    private let dictationSilence: TimeInterval = 3.0
    private let dictationMax: TimeInterval = 180
    private let sessionIdleLimit: TimeInterval = 90   // quiet this long → standby

    private let wakePhrases = ["hey mama", "hey mamma", "hey momma", "hey ma ma"]
    private let stopPhrases = ["adios mama", "adios mamma", "adios momma", "adios ma ma", "adiós mama"]

    init() {
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
            self.isRunning = true
            self.mode = .standby
            self.isActive = false
            self.phase = .listeningWake
            self.utterance = ""
            self.listener.start()
            self.startTicker()
            self.store.log("app", "listening enabled (standby)")
        }
    }

    func stop() {
        isRunning = false
        isActive = false
        mode = .standby
        ticker?.invalidate(); ticker = nil
        listener.stop()
        phase = .idle
        store.log("app", "listening disabled")
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    // MARK: Stream interpretation

    private func handlePartial(_ text: String) {
        guard isRunning else { return }
        utterance = text
        lastHeardAt = Date()
        guard !processing else { return }

        let lowered = text.lowercased()
        switch mode {
        case .standby:
            if wakePhrases.contains(where: lowered.contains) { beginSession() }
        case .command:
            if stopPhrases.contains(where: lowered.contains) { endSession(reason: "\"Adios Mama\"") }
        case .dictation:
            break // a long pause ends the note; "adios" could be part of it
        }
    }

    /// Runs 4×/second; applies silence gates without ever touching the mic.
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
        isActive = true
        phase = .capturingCommand
        freshUtterance()
        sessionIdleSince = Date()
    }

    private func endSession(reason: String) {
        store.log("wake", "session ended (\(reason)) — back to standby")
        mode = .standby
        isActive = false
        phase = .listeningWake
        freshUtterance()
    }

    private func freshUtterance() {
        utterance = ""
        listener.resetUtterance()
    }

    // MARK: Commands

    private func finalizeCommand() {
        let text = Self.strippingPhrases(wakePhrases + stopPhrases, from: utterance)
        freshUtterance()
        sessionIdleSince = Date()
        guard !text.isEmpty else { return }
        guard let claude else { phase = .error("No API key set"); return }

        lastCommand = text
        store.log("asr", "command: \(text)")
        processing = true
        phase = .thinking

        Task {
            defer {
                self.processing = false
                if self.isRunning, self.mode == .command {
                    self.phase = .capturingCommand
                    // Discard anything heard while we were acting (e.g. our own typing sounds).
                    self.freshUtterance()
                    self.sessionIdleSince = Date()
                }
            }
            do {
                let action = try await claude.parseCommand(text)
                store.log("claude", "action=\(action.kind.rawValue) target=\"\(action.target)\" conf=\(action.confidence)")
                switch action.kind {
                case .dictateStart:
                    self.beginDictation()
                case .none:
                    self.store.log("action", "nothing actionable — still listening")
                default:
                    self.phase = .acting
                    try ScreenController.perform(action)
                    let outcome = "\(action.kind.rawValue) \(action.target)".trimmingCharacters(in: .whitespaces)
                    self.store.log("action", "performed: \(outcome)")
                    self.store.addTranscript(TranscriptRecord(kind: "command", transcript: text, outcome: outcome))
                }
            } catch {
                self.phase = .error("\(error)")
                self.store.log("error", "\(error)")
                self.store.addTranscript(TranscriptRecord(kind: "command", transcript: text, outcome: "error: \(error)"))
            }
        }
    }

    private static func strippingPhrases(_ phrases: [String], from text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for phrase in phrases {
            while let range = out.lowercased().range(of: phrase) {
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
    }

    private func finalizeDictation() {
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
        Task {
            defer {
                self.processing = false
                if self.isRunning, self.mode == .command {
                    self.phase = .capturingCommand
                    self.freshUtterance()
                    self.sessionIdleSince = Date()
                }
            }
            do {
                let report = try await claude.buildDictationReport(text)
                self.lastReport = report
                self.store.log("claude", "report ready — \(report.actionItems.count) action items")
                self.store.addTranscript(TranscriptRecord(
                    kind: "dictation",
                    transcript: text,
                    summary: report.summary,
                    actionItems: report.actionItems
                ))
            } catch {
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
        if !ScreenController.isTrusted {
            store.log("perm", "accessibility not yet trusted — prompting toward System Settings")
            ScreenController.requestTrust()
        }
    }

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
