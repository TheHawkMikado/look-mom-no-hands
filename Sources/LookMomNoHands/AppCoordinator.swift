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
    @Published var pendingClarification: Clarification?   // drives the on-screen ask panel
    @Published var isRunning = false          // app-level on/off (Start/Stop button)
    @Published var micAuthorized = false
    @Published var speechAuthorized = false
    @Published var accessibilityTrusted = false
    @Published var hasElevenLabsKey = false

    /// Which STT engine re-transcribes utterances (Apple always does wake/gating).
    /// Persisted so the choice survives relaunch; defaults to Scribe-for-dictation.
    @Published var speechEngine: SpeechEngine = .scribeDictation {
        didSet { UserDefaults.standard.set(speechEngine.rawValue, forKey: Self.engineKey) }
    }
    private static let engineKey = "speechEngine"
    private var elevenLabsKey: String?

    /// Modifier chord that toggles push-to-dictate (insert mode). Persisted.
    @Published var dictationChord: DictationChord = .controlOption {
        didSet {
            UserDefaults.standard.set(dictationChord.rawValue, forKey: Self.chordKey)
            hotkey.setChord(dictationChord.flags)
        }
    }
    /// Clean up push-to-dictate text with the model before pasting. Persisted.
    @Published var cleanUpInsertedText = true {
        didSet { UserDefaults.standard.set(cleanUpInsertedText, forKey: Self.cleanupKey) }
    }
    private static let chordKey = "dictationChord"
    private static let cleanupKey = "cleanUpInsertedText"
    private let hotkey = HotkeyMonitor()
    private var dictationOutput: DictationOutput = .report   // where the current note goes
    private var pendingHotkeyDictation = false               // start requested before the mic was on
    private var starting = false                             // start() in flight (async permission gap)
    private var insertTargetApp: NSRunningApplication?       // app to paste into (captured at insert start)
    private var lastExternalApp: NSRunningApplication?       // most recent frontmost app that ISN'T us

    /// Wake session open. Derived from `mode` so it can never desync; every mode
    /// change is accompanied by a `phase` write, which publishes the update.
    var isActive: Bool { mode != .standby }

    let store = AppStore()

    private enum Mode { case standby, command, dictation }
    private var mode: Mode = .standby
    private var processing = false            // Claude call / action in flight
    private var speaking = false             // TTS playing; recognition is ignored so we don't hear ourselves
    private var utterance = ""                // current partial transcript
    private var lastHeardAt = Date()
    private var sessionIdleSince = Date()
    private var dictationStartAt = Date()
    private var ticker: Timer?
    private var actionTask: Task<Void, Never>?   // in-flight parse/act; cancelled by stop()
    private var runGeneration = 0                // stale task completions must not touch newer state
    // The pending clarification exchange (question + prior turns), so the user's
    // next utterance is interpreted as an answer with full context.
    private var dialogue: [(role: String, content: String)] = []

    private let listener = VoiceListener()
    private var claude: ClaudeClient?
    private let speaker = Speaker()

    // Longer than the old 1.2s: a spoken request can be several action items, so
    // don't cut it off on a mid-sentence breath.
    private let commandSilence: TimeInterval = 2.2
    private let dictationSilence: TimeInterval = 3.0
    private let dictationMax: TimeInterval = 180
    private let sessionIdleLimit: TimeInterval = 90   // quiet this long → standby

    // The misspellings are how the recognizer actually renders the phrases;
    // contextualStrings biasing (set in init) reduces but doesn't eliminate them.
    nonisolated static let wakePhrases = ["hey mama", "hey mamma", "hey momma", "hey ma ma"]
    nonisolated static let stopPhrases = ["adios mama", "adios mamma", "adios momma", "adios ma ma", "adiós mama"]
    // Direct push-to-dictate voice triggers (no wake word needed). Kept distinct
    // from the wake/stop words so they don't collide.
    nonisolated static let dictateStartPhrases = ["mama dictate this", "mama dictate", "mama take dictation",
                                                  "mama start dictating", "you dictate this"]
    nonisolated static let dictateStopPhrases = ["mama stop dictating", "mama stop dictation",
                                                 "mama done dictating", "stop dictating", "you stop dictating"]

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.engineKey),
           let saved = SpeechEngine(rawValue: raw) {
            speechEngine = saved
        }
        if let raw = UserDefaults.standard.string(forKey: Self.chordKey),
           let saved = DictationChord(rawValue: raw) {
            dictationChord = saved
        }
        if UserDefaults.standard.object(forKey: Self.cleanupKey) != nil {
            cleanUpInsertedText = UserDefaults.standard.bool(forKey: Self.cleanupKey)
        }
        listener.contextualPhrases = ["Hey Mama", "Adios Mama"]
        listener.onPartial = { [weak self] text in self?.handlePartial(text) }
        listener.onInfo = { [weak self] msg in self?.store.log("speech", msg) }
        // Push-to-dictate chord works whenever the app is running, even before
        // Start — it turns the mic on on demand. Global delivery needs Accessibility.
        hotkey.onToggle = { [weak self] in self?.toggleHotkeyDictation() }
        hotkey.setChord(dictationChord.flags)
        hotkey.start()
        // Track the last app that had focus that ISN'T us, so a push-to-dictate
        // paste always targets the user's editor even if our panel was frontmost
        // when they triggered it.
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            Task { @MainActor in self?.lastExternalApp = app }
        }
        store.log("app", "launched")
        loadKey()
        refreshAuthFlags()
        store.log("app", "auth at launch: mic=\(micAuthorized) speech=\(speechAuthorized)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            guard !(self.micAuthorized && self.speechAuthorized) else { return }
            self.requestPermissions { _ in }
        }
        // Returning from System Settings reactivates the app — a free, event-
        // driven way to notice a just-granted permission with no timer at all.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAuthFlags() }
        }
        armAuthPoll()   // also catch a grant that lands while the panel sits open
    }

    private func refreshAuthFlags() {
        // Assign only on change: @Published fires objectWillChange on every set
        // regardless of equality, and this runs on a 1.5s poll — unconditional
        // writes would re-render every observing view each tick.
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let speech = SFSpeechRecognizer.authorizationStatus() == .authorized
        let ax = ScreenController.isTrusted
        if micAuthorized != mic { micAuthorized = mic }
        if speechAuthorized != speech { speechAuthorized = speech }
        if accessibilityTrusted != ax { accessibilityTrusted = ax }
    }

    private var allPermissionsGranted: Bool {
        micAuthorized && speechAuthorized && accessibilityTrusted
    }

    // TCC grants take effect live (no relaunch), but the status APIs are only read
    // when we poll. `didBecomeActive` covers returning from Settings; this bounded
    // poll covers granting while the panel stays open. It is deliberately NOT
    // open-ended — a user who declines a permission must not leave a timer waking
    // the run loop forever — so it stops after the window elapses OR all granted.
    private var authPoll: Timer?
    private var authPollDeadline = Date()

    private func armAuthPoll() {
        guard !allPermissionsGranted else { return }
        authPollDeadline = Date().addingTimeInterval(120)   // re-arming extends the window
        guard authPoll == nil else { return }
        authPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollAuth() }
        }
    }

    private func pollAuth() {
        let wasGranted = allPermissionsGranted
        refreshAuthFlags()
        if allPermissionsGranted, !wasGranted { store.log("perm", "all permissions granted") }
        if allPermissionsGranted || Date() > authPollDeadline {
            authPoll?.invalidate(); authPoll = nil
        }
    }

    deinit { authPoll?.invalidate() }

    /// Explicit, user-initiated Accessibility prompt (opens System Settings once).
    /// Never called automatically — only from the panel button, so we don't nag.
    func requestAccessibility() {
        ScreenController.requestTrust()
        // The user is about to grant it — (re-)arm the bounded poll so the panel
        // flips as soon as they do, without a relaunch.
        armAuthPoll()
    }

    // MARK: API key

    private static let elevenLabsAccount = "elevenlabs-api-key"

    private func loadKey() {
        if let env = ProcessInfo.processInfo.environment["LMNH_ANTHROPIC_API_KEY"] {
            claude = ClaudeClient(apiKey: env)
            store.log("app", "API key loaded from env")
        }
        if let env = ProcessInfo.processInfo.environment["LMNH_ELEVENLABS_API_KEY"] {
            speaker.elevenLabsKey = env
            elevenLabsKey = env
            hasElevenLabsKey = true
        }
        let needsAnthropic = claude == nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let anthropic = needsAnthropic ? KeychainStore.load() : nil
            let eleven = KeychainStore.load(account: Self.elevenLabsAccount)
            DispatchQueue.main.async {
                guard let self else { return }
                if let anthropic {
                    self.claude = ClaudeClient(apiKey: anthropic)
                    self.store.log("app", "API key loaded from keychain")
                } else if needsAnthropic {
                    self.store.log("app", "no keychain key — enter it in the panel")
                }
                if let eleven, !self.hasElevenLabsKey {
                    self.speaker.elevenLabsKey = eleven
                    self.elevenLabsKey = eleven
                    self.hasElevenLabsKey = true
                    self.store.log("app", "ElevenLabs key loaded — spoken replies on")
                }
            }
        }
    }

    func setAPIKey(_ key: String) {
        KeychainStore.save(key)
        claude = ClaudeClient(apiKey: key)
        store.log("app", "API key saved")
    }

    func setElevenLabsKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.save(trimmed, account: Self.elevenLabsAccount)
        speaker.elevenLabsKey = trimmed
        elevenLabsKey = trimmed.isEmpty ? nil : trimmed
        hasElevenLabsKey = !trimmed.isEmpty
        store.log("app", "ElevenLabs key saved — spoken replies on")
    }

    var hasKey: Bool { claude != nil }

    // MARK: Lifecycle

    func start() {
        guard !isRunning, !starting else { return }
        starting = true
        requestPermissions { [weak self] granted in
            guard let self else { return }
            self.starting = false
            guard granted else {
                self.pendingHotkeyDictation = false
                self.phase = .error("Mic/Speech permission denied")
                self.store.log("perm", "denied — cannot start")
                return
            }
            do {
                try self.listener.start()
            } catch {
                // Don't claim to be listening over a dead pipeline.
                self.pendingHotkeyDictation = false
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
            // A hotkey press that started the mic proceeds straight into dictation.
            if self.pendingHotkeyDictation {
                self.pendingHotkeyDictation = false
                self.startDictation(output: .insert)
            }
        }
    }

    /// The push-to-dictate chord/hotkey: toggles insert-mode dictation, starting
    /// the mic on demand if the app wasn't already listening.
    func toggleHotkeyDictation() {
        if mode == .dictation {
            finalizeDictation()
            return
        }
        // Capture the paste target NOW, before start() might activate our app on a
        // cold start (which would otherwise make US the frontmost app).
        captureInsertTarget()
        // Insert only needs the API key when cleanup is on (Scribe uses the
        // ElevenLabs key separately); raw paste works with just on-device ASR.
        guard hasKey || !cleanUpInsertedText else {
            phase = .error("No API key set")
            store.log("hotkey", "ignored — no API key (needed for cleanup)")
            return
        }
        if isRunning {
            startDictation(output: .insert)
        } else if starting || pendingHotkeyDictation {
            // A second press during the async startup cancels the pending start.
            pendingHotkeyDictation = false
            store.log("hotkey", "startup cancelled by second press")
        } else {
            pendingHotkeyDictation = true
            start()
        }
    }

    func stop() {
        runGeneration += 1
        actionTask?.cancel(); actionTask = nil
        speaker.cancel()
        processing = false
        speaking = false
        pendingClarification = nil
        dialogue = []
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
        // Ignore audio captured while we're talking — otherwise the app hears its
        // own spoken reply and treats it as a command.
        guard !speaking else { return }
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
            else if Self.dictateStartPhrases.contains(where: tail.contains) { startInsertByVoice() }
        case .command:
            if Self.stopPhrases.contains(where: tail.contains) { endSession(reason: "\"Adios Mama\"") }
            else if Self.dictateStartPhrases.contains(where: tail.contains) { startInsertByVoice() }
        case .dictation:
            // A voice stop phrase ends the note; otherwise a long pause does.
            if Self.dictateStopPhrases.contains(where: tail.contains) { finalizeDictation() }
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
        armCaptureForCurrentMode()
    }

    private func endSession(reason: String) {
        store.log("wake", "session ended (\(reason)) — back to standby")
        mode = .standby
        phase = .listeningWake
        pendingClarification = nil
        dialogue = []
        freshUtterance()
        stopTicker()
        armCaptureForCurrentMode()   // standby ⇒ capture off; stop buffering ambient audio
    }

    /// The user clicked an option in the on-screen clarification panel — treat it
    /// exactly as if they'd spoken it.
    func answerClarification(_ option: String) {
        guard isRunning, mode == .command, !processing else { return }
        // A clicked answer is authoritative — discard any buffered mic audio so
        // scribeAll can't re-transcribe ambient noise over the user's choice.
        listener.captureAudio = false
        finalizeCommand(typedAnswer: option)
    }

    func dismissClarification() {
        pendingClarification = nil
        dialogue = []
        if mode == .command, !processing { phase = .capturingCommand }
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
        settleSessionPhase()
    }

    /// Returns the app to a resting listening state after a command/dictation
    /// resolves, honoring whatever `mode` is now (a manual note from standby ends
    /// back in standby, not a phantom command session). Preserves an error or a
    /// pending question so the user still sees them.
    private func settleSessionPhase() {
        guard isRunning else { return }
        switch mode {
        case .command:
            switch phase {
            case .error, .clarifying: break
            default: phase = .capturingCommand
            }
            sessionIdleSince = Date()
        case .standby:
            if case .error = phase {} else { phase = .listeningWake }
            stopTicker()
        case .dictation:
            return   // still capturing; nothing to settle
        }
        // Discard anything heard while we were acting (e.g. our own typing sounds).
        freshUtterance()
        armCaptureForCurrentMode()
    }

    // MARK: Commands

    private func finalizeCommand(typedAnswer: String? = nil) {
        // A typed/clicked answer is authoritative and skips re-transcription.
        let appleText = typedAnswer ?? Self.strippingPhrases(Self.wakePhrases + Self.stopPhrases, from: utterance)
        // For the scribeAll option, re-transcribe the command audio too (adds a
        // round-trip before parsing — the documented latency tradeoff). Never for
        // a clicked answer.
        let wav = (typedAnswer == nil && scribeForCommand) ? listener.takeCapturedWAV() : nil
        listener.captureAudio = false
        freshUtterance()
        sessionIdleSince = Date()
        guard !appleText.isEmpty else { armCaptureForCurrentMode(); return }
        guard let claude else { phase = .error("No API key set"); armCaptureForCurrentMode(); return }

        // A spoken answer clears the on-screen question — from here it's just
        // another turn in the dialogue.
        let answeringClarification = pendingClarification != nil
        pendingClarification = nil
        processing = true
        phase = .thinking
        let startedAt = Date()
        let gen = runGeneration
        let priorDialogue = dialogue

        actionTask = Task {
            defer { self.finishProcessing(gen) }
            do {
                let raw = await self.transcribed(wav: wav, fallback: appleText)
                let text = wav != nil ? Self.strippingPhrases(Self.wakePhrases + Self.stopPhrases, from: raw) : raw
                try Task.checkCancellation()
                self.lastCommand = text
                self.store.log("asr", answeringClarification ? "answer: \(text)" : "command: \(text)")
                let plan = try await claude.parsePlan(text, dialogue: priorDialogue)
                try Task.checkCancellation()
                let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
                self.store.log("claude", "plan: \(plan.steps.count) step(s)\(plan.clarify != nil ? " + question" : "") conf=\(plan.confidence) (\(ms)ms)")
                try await self.runPlan(plan, transcript: text, priorDialogue: priorDialogue, gen: gen)
            } catch {
                // Cancellation isn't a failure: Stop was pressed while the call was
                // in flight, and acting now would defy the user's explicit off.
                guard !Task.isCancelled, gen == self.runGeneration else {
                    self.store.log("action", "abandoned — stopped mid-command")
                    return
                }
                // A parse that never produced a plan resolves this exchange —
                // don't carry the abandoned dialogue into the next command.
                self.dialogue = []
                self.phase = .error("\(error)")
                self.store.log("error", "\(error)")
                self.store.addTranscript(TranscriptRecord(kind: "command", transcript: self.lastCommand, outcome: "error: \(error)"))
                await self.speak("Sorry, that didn't go through.", gen: gen)
            }
        }
    }

    // Clarification history is capped so a stuck follow-up loop can't grow the
    // (latency-critical) Haiku context without bound. Even count keeps the
    // sequence starting on a user turn, as the Messages API requires.
    private static let maxDialogueTurns = 8

    /// Runs a parsed plan: either ask a clarifying question (and wait for the
    /// next utterance), or execute each step in order. Speaks the model's reply.
    private func runPlan(_ plan: ActionPlan, transcript: String,
                         priorDialogue: [(role: String, content: String)], gen: Int) async throws {
        if let clarify = plan.clarify {
            // Remember the exchange so the user's answer is interpreted in context.
            dialogue = priorDialogue
            dialogue.append((role: "user", content: transcript))
            dialogue.append((role: "assistant", content: "I need to clarify: \(clarify.question)"))
            if dialogue.count > Self.maxDialogueTurns {
                dialogue.removeFirst(dialogue.count - Self.maxDialogueTurns)
            }
            store.log("clarify", clarify.question)
            // Publish the panel/phase BEFORE speaking, so even if TTS stalls the
            // question is on screen. finishProcessing (task defer) preserves
            // .clarifying, so we keep listening for the answer.
            pendingClarification = clarify
            phase = .clarifying
            await speak(clarify.spoken, gen: gen)
            return
        }

        // A step failed to decode: the plan has a hole, and steps are ordered and
        // interdependent, so running the survivors could act against the wrong
        // context. Fail closed and ask the user to rephrase.
        if plan.malformed {
            dialogue = []
            phase = .error("didn't understand part of that")
            store.log("error", "plan had an undecodable step — refusing partial execution")
            await speak("I didn't catch part of that — could you say it again?", gen: gen)
            return
        }

        dialogue = []   // request resolved; next utterance starts fresh
        await speak(plan.say, gen: gen)
        guard gen == runGeneration, !Task.isCancelled else { return }

        var performed: [String] = []
        do {
            for step in plan.steps {
                try Task.checkCancellation()
                switch step.kind {
                case .dictateStart:
                    self.beginDictation(returnTo: .command, output: .report)
                    return   // dictation owns the session now; remaining steps don't apply
                case .none:
                    continue
                default:
                    self.phase = .acting
                    // The AX walk + CGEvent posting is synchronous and can be slow on
                    // a complex UI — run it off the main actor (a task-group child
                    // leaves the actor). Structured, not detached: cancelling
                    // actionTask propagates in, and perform() checks cancellation
                    // before every irreversible event, so Stop halts mid-walk/typing.
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try ScreenController.perform(step) }
                        try await group.waitForAll()
                    }
                    performed.append(Self.describe(step))
                    self.store.log("action", "performed: \(Self.describe(step))")
                }
            }
            if !performed.isEmpty {
                self.store.addTranscript(TranscriptRecord(kind: "command", transcript: transcript,
                                                          outcome: performed.joined(separator: " → ")))
            }
        } catch {
            if Task.isCancelled || gen != runGeneration { throw error }
            // A step failed partway. Persist what actually ran (so history and any
            // retry see partial completion, not a clean slate), report it on screen
            // AND aloud — this is a hands-free app, silence reads as success.
            let done = performed.isEmpty ? "" : performed.joined(separator: " → ") + " → "
            self.store.addTranscript(TranscriptRecord(kind: "command", transcript: transcript,
                                                      outcome: "\(done)FAILED: \(error)"))
            self.phase = .error("\(error)")
            self.store.log("error", "step failed after \(performed.count) done: \(error)")
            await self.speak(performed.isEmpty ? "That didn't work." : "I did the first part, then hit a problem.", gen: gen)
        }
    }

    private static func describe(_ step: ScreenAction) -> String {
        switch step.kind {
        case .openURL: return "open_url \(step.url)\(step.target.isEmpty ? "" : " in \(step.target)")"
        case .keystroke: return "keystroke \(step.keys)"
        case .type: return "type \(step.text)"
        case .scroll: return "scroll \(step.direction?.rawValue ?? "?")"
        default: return "\(step.kind.rawValue) \(step.target)".trimmingCharacters(in: .whitespaces)
        }
    }

    /// Speaks a reply with recognition muted so the app can't hear itself, then
    /// flushes whatever the mic captured meanwhile. `gen` guards against a Stop→
    /// Start that supersedes this run mid-utterance: the stale completion must
    /// not clear the new session's `speaking` flag or reset its live listener.
    private func speak(_ text: String, gen: Int) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speaking = true
        store.log("say", trimmed)
        await speaker.speak(trimmed)
        guard gen == runGeneration else { return }
        speaking = false
        freshUtterance()   // drop anything heard while talking
        lastHeardAt = Date()
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

    // Where a finishing note returns: a wake-word note keeps the command session
    // open; a one-tap note from standby returns to standby (no phantom session).
    private var dictationReturnMode: Mode = .command

    /// Voice-triggered insert: capture the paste target before starting (the app
    /// is already frontmost — no activation happens on this path).
    private func startInsertByVoice() {
        captureInsertTarget()
        startDictation(output: .insert)
    }

    /// The app to paste into: the current frontmost app, or — if that's us (panel
    /// open, or just launched) — the last external app that had focus. Never
    /// ourselves, so a push-to-dictate paste can't land in our own panel.
    private func captureInsertTarget() {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            insertTargetApp = front
        } else {
            insertTargetApp = lastExternalApp
        }
    }

    private func beginDictation(returnTo: Mode, output: DictationOutput) {
        dictationOutput = output
        // insertTargetApp is captured at the trigger site (hotkey / voice) before
        // any focus change, so it isn't touched here.
        store.log("dictation", "started (\(output == .insert ? "insert→cursor" : "report")) — pause or say a stop phrase to finish")
        // A note is a fresh intent — drop any pending clarification/context so it
        // isn't stranded on screen or carried into the next command.
        pendingClarification = nil
        dialogue = []
        dictationReturnMode = returnTo
        mode = .dictation
        dictationStartAt = Date()
        phase = .dictating
        freshUtterance()
        listener.carryForward = true   // a note may cross a recognition-request cycle
        armCaptureForCurrentMode()
    }

    /// Starts a dictation immediately (panel button, voice phrase, or hotkey) with
    /// no wake word. `.report` → summary panel; `.insert` → paste at cursor.
    func startDictation(output: DictationOutput = .report) {
        guard isRunning, !processing, mode != .dictation else { return }
        let returnTo: Mode = mode == .command ? .command : .standby
        if mode == .standby { startTicker() }   // dictation needs the silence-gate ticker
        beginDictation(returnTo: returnTo, output: output)
    }

    // Capture the utterance's raw audio only when Scribe will re-transcribe it, so
    // Apple stays the sole engine (and no buffering) whenever Scribe isn't in play.
    private func armCaptureForCurrentMode() {
        let want: Bool
        switch mode {
        case .standby: want = false
        case .command: want = hasElevenLabsKey && speechEngine.usesScribe(forDictation: false)
        case .dictation: want = hasElevenLabsKey && speechEngine.usesScribe(forDictation: true)
        }
        listener.captureAudio = want   // setting true also clears the prior clip
    }

    private var scribeForDictation: Bool { hasElevenLabsKey && speechEngine.usesScribe(forDictation: true) }
    private var scribeForCommand: Bool { hasElevenLabsKey && speechEngine.usesScribe(forDictation: false) }

    /// Re-transcribes the captured clip through Scribe for higher accuracy; returns
    /// `fallback` (Apple's transcript) when no clip was captured or Scribe fails.
    /// Never throws.
    private func transcribed(wav: Data?, fallback: String) async -> String {
        guard let wav, let key = elevenLabsKey else { return fallback }
        do {
            let text = try await ScribeClient(apiKey: key).transcribe(wav: wav)
            store.log("scribe", "re-transcribed \(wav.count / 1024)KB → \(text.count) chars")
            return text.isEmpty ? fallback : text
        } catch {
            store.log("scribe", "failed, using on-device transcript: \(error)")
            return fallback
        }
    }

    /// Strips a leading start phrase and a trailing stop phrase from a captured
    /// note. Word-based and punctuation-insensitive, so it handles the recognizer's
    /// real output ("Mama, stop dictating this.") — the comma and a couple trailing
    /// words ("this") no longer defeat it — while a phrase appearing mid-sentence
    /// as legitimate content is preserved.
    nonisolated static func stripDictationTriggers(_ text: String) -> String {
        // Up to this many words may follow the stop phrase and still be treated as
        // part of the trigger ("stop dictating THIS"), not note content.
        let maxTrailing = 2
        var words = text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.map(String.init)
        func norm(_ w: String) -> String {
            String(w.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        // Keep 1:1 with `words` (no filtering) so an index into `normed` slices
        // `words` correctly.
        func normWords(_ ws: [String]) -> [String] { ws.map(norm) }

        // Leading start phrase (prefix match on normalized words).
        var normed = normWords(words)
        for phrase in dictateStartPhrases.sorted(by: { $0.count > $1.count }) {
            let pw = phrase.split(separator: " ").map(String.init)
            if normed.count >= pw.count, Array(normed.prefix(pw.count)) == pw {
                words.removeFirst(pw.count)
                break
            }
        }

        // Trailing stop phrase: match its word sequence starting within the last
        // (phrase length + maxTrailing) words, and drop from there to the end.
        normed = normWords(words)
        outer: for phrase in dictateStopPhrases.sorted(by: { $0.count > $1.count }) {
            let pw = phrase.split(separator: " ").map(String.init)
            guard pw.count <= normed.count else { continue }
            let earliest = max(0, normed.count - pw.count - maxTrailing)
            var i = normed.count - pw.count
            while i >= earliest {
                if Array(normed[i..<i + pw.count]) == pw {
                    words.removeSubrange(i..<words.count)
                    break outer
                }
                i -= 1
            }
        }
        return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finalizeDictation() {
        listener.carryForward = false
        let output = dictationOutput
        // A spoken start/stop phrase lands at the note's edges — strip only there.
        let appleText = Self.stripDictationTriggers(utterance)
        // Grab the captured clip (if any) before freshUtterance/arming touches it.
        let wav = scribeForDictation ? listener.takeCapturedWAV() : nil
        listener.captureAudio = false
        freshUtterance()
        mode = dictationReturnMode
        // Report and cleanup-on insert need Claude; raw insert doesn't. Scribe uses
        // the ElevenLabs key separately.
        let needsClaude = output == .report || cleanUpInsertedText
        // Proceed if EITHER Apple heard something OR we captured audio Scribe can
        // still transcribe — a dead on-device recognizer must not lose the note.
        guard !appleText.isEmpty || wav != nil else {
            store.log("dictation", "empty note")
            settleSessionPhase()
            return
        }
        if needsClaude, claude == nil {
            phase = .error("No API key set")
            store.log("dictation", "needs an API key for \(output == .report ? "the report" : "cleanup")")
            settleSessionPhase()
            return
        }
        store.log("dictation", "captured \(appleText.count) chars\(wav != nil ? " (+audio for Scribe)" : "") — \(output == .insert ? "pasting" : "summarizing")")
        processing = true
        phase = .thinking
        let gen = runGeneration

        actionTask = Task {
            defer { self.finishProcessing(gen) }
            var text = await self.transcribed(wav: wav, fallback: appleText)
            // Scribe re-transcribes the whole clip, edge triggers included — strip again.
            text = Self.stripDictationTriggers(text)
            guard !text.isEmpty else {
                // Empty ⟹ Apple heard nothing AND Scribe returned nothing/failed on a
                // clip that existed. Persist it (recoverable) and surface — never
                // pretend success. (Insert notes still get an error so nothing is
                // pasted silently.)
                if let wav { await self.store.saveAudioAndWait(wav) }
                guard gen == self.runGeneration else { return }
                self.phase = .error("couldn't transcribe that note")
                self.store.log("dictation", "transcription failed on captured audio")
                await self.speak("Sorry, I couldn't make out that note.", gen: gen)
                return
            }
            do {
                try Task.checkCancellation()
                switch output {
                case .insert:
                    try await self.insertDictation(text, claude: self.claude, gen: gen)
                case .report:
                    guard let claude = self.claude else { return }   // guaranteed by needsClaude
                    let report = try await claude.buildDictationReport(text)
                    try Task.checkCancellation()
                    self.lastReport = report
                    self.store.log("claude", "report ready — \(report.keyPoints.count) points, \(report.actionItems.count) action items")
                    // Store the RAW transcript (Scribe or Apple) — it's the note's
                    // only durable copy, and the field means raw ASR text; the
                    // model-cleaned version lives in lastReport for display only.
                    self.store.addTranscript(TranscriptRecord(
                        kind: "dictation", transcript: text,
                        title: report.title, summary: report.summary,
                        keyPoints: report.keyPoints, actionItems: report.actionItems))
                }
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

    /// Insert mode: optionally clean the text, then paste it into the app the user
    /// was in and leave it on the clipboard. The final text is recorded so nothing
    /// is lost, even if the paste can't happen.
    private func insertDictation(_ raw: String, claude: ClaudeClient?, gen: Int) async throws {
        let final: String
        if cleanUpInsertedText, let claude {
            // Cleanup is a nicety — a failure just pastes the raw transcript.
            final = (try? await claude.cleanUpDictation(raw)) ?? raw
        } else {
            final = raw
        }
        try Task.checkCancellation()
        guard gen == runGeneration else { return }
        ScreenController.setClipboard(final)   // always — recoverable without Accessibility
        store.addTranscript(TranscriptRecord(kind: "dictation", transcript: final))
        guard ScreenController.isTrusted else {
            store.log("dictation", "\(final.count) chars on clipboard — press ⌘V (auto-paste needs Accessibility)")
            return
        }
        // Bring the user's editor to the front so ⌘V lands there, not in our panel
        // or whatever grabbed focus during transcription. Without a known target,
        // don't blind-paste into an unknown app — leave it on the clipboard.
        guard let target = insertTargetApp else {
            store.log("dictation", "\(final.count) chars on clipboard — no target window; press ⌘V where you want it")
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            target.activate(options: [])
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        try? await Task.sleep(nanoseconds: 40_000_000)   // let the app register the clipboard
        guard gen == runGeneration, !Task.isCancelled else { return }
        try? ScreenController.sendPaste()
        store.log("dictation", "pasted \(final.count) chars into \(target.localizedName ?? "target app")")
    }

    // MARK: Permissions

    func requestPermissions(_ completion: @escaping (Bool) -> Void) {
        // A menu-bar (accessory) app must be active for a TCC prompt to appear —
        // but ONLY activate when a prompt is actually pending (status not yet
        // determined). Stealing focus when permissions are already settled would
        // yank the user's editor away right before a push-to-dictate paste.
        let needsPrompt = SFSpeechRecognizer.authorizationStatus() == .notDetermined
            || AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        if needsPrompt { NSApplication.shared.activate(ignoringOtherApps: true) }
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
