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

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.engineKey),
           let saved = SpeechEngine(rawValue: raw) {
            speechEngine = saved
        }
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
        utterance = option
        finalizeCommand()
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

    private func finalizeCommand() {
        let appleText = Self.strippingPhrases(Self.wakePhrases + Self.stopPhrases, from: utterance)
        // For the scribeAll option, re-transcribe the command audio too (adds a
        // round-trip before parsing — the documented latency tradeoff).
        let wav = scribeForCommand ? listener.takeCapturedWAV() : nil
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
                    self.beginDictation(returnTo: .command)
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

    private func beginDictation(returnTo: Mode) {
        store.log("dictation", "started — recording note (pause \(Int(dictationSilence))s to finish)")
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

    /// Starts a dictation immediately, from the panel button — no wake word needed.
    /// Requires listening to be on so the mic pipeline exists.
    func startDictation() {
        guard isRunning, !processing, mode != .dictation else { return }
        let returnTo: Mode = mode == .command ? .command : .standby
        if mode == .standby { startTicker() }   // dictation needs the silence-gate ticker
        beginDictation(returnTo: returnTo)
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

    private func finalizeDictation() {
        listener.carryForward = false
        let appleText = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        // Grab the captured clip (if any) before freshUtterance/arming touches it.
        let wav = scribeForDictation ? listener.takeCapturedWAV() : nil
        listener.captureAudio = false
        freshUtterance()
        mode = dictationReturnMode
        // Proceed if EITHER Apple heard something OR we captured audio Scribe can
        // still transcribe — a dead on-device recognizer must not lose the note.
        guard !appleText.isEmpty || wav != nil, let claude else {
            store.log("dictation", "empty note")
            settleSessionPhase()
            return
        }
        store.log("dictation", "captured \(appleText.count) chars\(wav != nil ? " (+audio for Scribe)" : "") — summarizing")
        processing = true
        phase = .thinking
        let gen = runGeneration

        actionTask = Task {
            defer { self.finishProcessing(gen) }
            let text = await self.transcribed(wav: wav, fallback: appleText)
            guard !text.isEmpty else {
                // Reaching here means Apple heard nothing AND Scribe returned
                // nothing/failed — and the outer guard guarantees a captured clip
                // exists (empty appleText only passes with wav != nil). That's a
                // transcription failure on a real note, so persist the clip
                // (best-effort, recoverable) and ALWAYS surface it — never pretend
                // success, even if the save itself fails.
                if let wav { await self.store.saveAudioAndWait(wav) }
                guard gen == self.runGeneration else { return }
                self.phase = .error("couldn't transcribe that note")
                self.store.log("dictation", "transcription failed on captured audio")
                await self.speak("Sorry, I couldn't make out that note.", gen: gen)
                return
            }
            do {
                try Task.checkCancellation()
                let report = try await claude.buildDictationReport(text)
                try Task.checkCancellation()
                self.lastReport = report
                self.store.log("claude", "report ready — \(report.keyPoints.count) points, \(report.actionItems.count) action items")
                // Store the RAW transcript (Scribe or Apple) — it's the note's only
                // durable copy, and the field means raw ASR text; the model-cleaned
                // version lives in lastReport for display only.
                self.store.addTranscript(TranscriptRecord(
                    kind: "dictation",
                    transcript: text,
                    title: report.title,
                    summary: report.summary,
                    keyPoints: report.keyPoints,
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
