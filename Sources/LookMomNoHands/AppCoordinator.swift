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
    /// When the Accessibility tree has no match for a click target, screenshot the
    /// screen and let Claude vision find it by pixel. Needs Screen Recording. Persisted.
    @Published var visionClickEnabled = true {
        didSet { UserDefaults.standard.set(visionClickEnabled, forKey: Self.visionKey) }
    }
    private static let chordKey = "dictationChord"
    private static let cleanupKey = "cleanUpInsertedText"
    private static let visionKey = "visionClickEnabled"
    private let hotkey = HotkeyMonitor()
    private let pill = RecorderPill()                        // floating recorder HUD
    private var recorderOutput: RecorderOutput = .note       // what the current recording produces
    private var starting = false                             // start() in flight (async permission gap)
    private var pendingRecording = false                     // recording requested before the mic was on
    private var pendingRecordingOutput: RecorderOutput = .note
    private var insertTargetApp: NSRunningApplication?       // app to paste into (captured at insert start)
    private var lastExternalApp: NSRunningApplication?       // most recent frontmost app that ISN'T us

    /// Wake session open. Derived from `mode` so it can never desync; every mode
    /// change is accompanied by a `phase` write, which publishes the update.
    var isActive: Bool { mode != .standby }

    let store = AppStore()

    // Always-on awareness of what's open, and the sticky focus the user is working
    // in. Both feed the planner so commands stay on-context across turns instead of
    // re-deriving intent every time.
    let environment = EnvironmentTracker()
    @Published var workingContext = WorkingContext()
    @Published private(set) var recentActions: [String] = []   // rolling command→outcome memory for the planner
    private static let recentActionsMax = 8

    private enum Mode { case standby, command, recording }
    private var mode: Mode = .standby

    // Otter-style live transcription: capture continuously and flush ~60s audio
    // chunks to Scribe at the next pause, appending to a growing transcript that
    // never buffers more than one chunk of audio in memory.
    @Published var liveActive = false
    @Published var liveTranscript = ""
    let meter = RecorderMeter()                 // 0…1 mic level (isolated from other views)
    @Published var recordingStartedAt: Date?    // drives the pill's elapsed timer
    private var lastFlushAt = Date()
    private var flushing = false
    private var liveGeneration = 0   // bumped each live session; stale flush tasks compare against it
    nonisolated static let liveChunkSecondsForTest: TimeInterval = 60    // aim to flush after this…
    nonisolated static let liveChunkSilenceForTest: TimeInterval = 1.5   // …at the next pause (sentence end)
    nonisolated static let liveChunkMaxForTest: TimeInterval = 90        // …but flush anyway by here
    private var liveChunkSeconds: TimeInterval { Self.liveChunkSecondsForTest }
    private var liveChunkSilence: TimeInterval { Self.liveChunkSilenceForTest }
    private var liveChunkMax: TimeInterval { Self.liveChunkMaxForTest }
    nonisolated static let liveStopPhrases = ["mama stop listening", "mama stop transcribing",
                                              "mama stop the transcript", "mama stop recording"]
    nonisolated static let liveStartPhrases = ["mama start listening", "mama take notes",
                                               "mama start transcribing", "mama transcribe this"]
    private var processing = false            // Claude call / action in flight
    private var speaking = false             // TTS playing; recognition is ignored so we don't hear ourselves
    private var utterance = ""                // current partial transcript
    private var lastHeardAt = Date()
    private var sessionIdleSince = Date()
    private var ticker: Timer?
    private var actionTask: Task<Void, Never>?   // in-flight parse/act; cancelled by stop()
    private var runGeneration = 0                // stale task completions must not touch newer state
    // The pending clarification exchange (question + prior turns), so the user's
    // next utterance is interpreted as an answer with full context.
    private var dialogue: [(role: String, content: String)] = []

    private let listener = VoiceListener()
    private var claude: ClaudeClient?
    private let speaker = Speaker()
    let vocabulary: VocabularyStore
    let profiles: ProfileStore
    let procedures: ProcedureStore
    let knowledge: KnowledgeStore
    let insertRules: InsertRulesStore

    // Longer than the old 1.2s: a spoken request can be several action items, so
    // don't cut it off on a mid-sentence breath.
    private let commandSilence: TimeInterval = 2.2
    // Seconds of silence that ends a recording. Editable + persisted. 0 = never
    // auto-end (you stop with the chord, a stop phrase, or the pill). Default 60s
    // so a thinking pause doesn't cut a note short. Chunk-flush uses a separate
    // short pause; this is only the session-end pause.
    @Published var recorderEndPause: TimeInterval = 60 {
        didSet { UserDefaults.standard.set(recorderEndPause, forKey: Self.silenceKey) }
    }
    private static let silenceKey = "recorderEndPause"
    // No hard cap: capture is chunked (never buffers more than one chunk of audio),
    // so a recording can run for hours.
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
    nonisolated static let repeatPhrases = ["do that again", "do it again", "again please",
                                            "repeat that", "one more time", "same thing again"]
    private var lastActionableCommand: String?   // last non-repeat command, for "do that again"

    /// True when a command is just "run the last thing again" — after stripping the
    /// wake word, the whole utterance is (or ends with) a repeat phrase, and it's
    /// short enough not to be a real command that merely mentions "again".
    nonisolated static func isRepeatPhrase(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        if repeatPhrases.contains(t) { return true }
        // A bare "again" counts; anything longer must match a full phrase to avoid
        // hijacking "remind me to call again tomorrow".
        return t == "again"
    }

    init() {
        vocabulary = VocabularyStore(directory: store.directory)
        profiles = ProfileStore(directory: store.directory)
        procedures = ProcedureStore(directory: store.directory)
        knowledge = KnowledgeStore(directory: store.directory)
        insertRules = InsertRulesStore(directory: store.directory)
        if UserDefaults.standard.object(forKey: Self.silenceKey) != nil {
            recorderEndPause = UserDefaults.standard.double(forKey: Self.silenceKey)
        }
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
        if UserDefaults.standard.object(forKey: Self.visionKey) != nil {
            visionClickEnabled = UserDefaults.standard.bool(forKey: Self.visionKey)
        }
        refreshContextualPhrases()
        listener.onPartial = { [weak self] text in self?.handlePartial(text) }
        listener.onInfo = { [weak self] msg in self?.store.log("speech", msg) }
        listener.onLevel = { [weak self] level in self?.meter.level = level }
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
        environment.start()   // track open apps/windows/tabs continuously, even before listening
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

    /// Biases the recognizer toward the wake/stop words plus the user's vocabulary
    /// (names, corrections, snippet triggers). Called on launch; call again after
    /// vocabulary edits to pick them up on the next recognition request.
    func refreshContextualPhrases() {
        listener.contextualPhrases = ["Hey Mama", "Adios Mama"] + vocabulary.contextualStrings
    }

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
                self.pendingRecording = false
                self.phase = .error("Mic/Speech permission denied")
                self.store.log("perm", "denied — cannot start")
                return
            }
            do {
                try self.listener.start()
            } catch {
                // Don't claim to be listening over a dead pipeline.
                self.pendingRecording = false
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
            // A trigger that started the mic proceeds straight into recording.
            if self.pendingRecording {
                self.pendingRecording = false
                self.startRecording(output: self.pendingRecordingOutput)
            }
        }
    }

    /// The push-to-dictate chord/hotkey: toggles insert-mode recording, starting
    /// the mic on demand if the app wasn't already listening.
    func toggleHotkeyDictation() {
        if mode == .recording {
            stopRecording()
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
            startRecording(output: .insert)
        } else if starting || pendingRecording {
            // A second press during the async startup cancels the pending start.
            pendingRecording = false
            store.log("hotkey", "startup cancelled by second press")
        } else {
            pendingRecording = true
            pendingRecordingOutput = .insert
            start()
        }
    }

    func stop() {
        runGeneration += 1
        actionTask?.cancel(); actionTask = nil
        speaker.cancel()
        processing = false
        speaking = false
        flushing = false
        pendingClarification = nil
        pendingRecording = false
        listener.metering = false
        meter.level = 0
        recordingStartedAt = nil
        pill.hide()
        liveActive = false
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
            else if Self.liveStartPhrases.contains(where: tail.contains) { startRecording(output: .note) }
            else if Self.dictateStartPhrases.contains(where: tail.contains) { startInsertByVoice() }
        case .command:
            if Self.stopPhrases.contains(where: tail.contains) { endSession(reason: "\"Adios Mama\"") }
            else if Self.liveStartPhrases.contains(where: tail.contains) { startRecording(output: .note) }
            else if Self.dictateStartPhrases.contains(where: tail.contains) { startInsertByVoice() }
        case .recording:
            // Either a dictation or a live stop phrase ends the recording; otherwise
            // capture continues (chunks accumulate) until a long pause or the pill.
            if Self.dictateStopPhrases.contains(where: tail.contains)
                || Self.liveStopPhrases.contains(where: tail.contains) { stopRecording() }
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
        case .recording:
            // Chunk-flush (Scribe only) at a short pause; unchanged from live.
            if scribeForRecording, !flushing {
                let sinceFlush = Date().timeIntervalSince(lastFlushAt)
                if (sinceFlush > liveChunkSeconds && quiet > liveChunkSilence) || sinceFlush > liveChunkMax {
                    flushLiveChunk(final: false)
                }
            }
            // End the whole recording after a long configured pause (0 = never).
            let hasContent = !utterance.isEmpty || !liveTranscript.isEmpty
            if recorderEndPause > 0, hasContent, quiet > recorderEndPause {
                stopRecording()
            } else if !hasContent, quiet > sessionIdleLimit {
                // Nothing was ever said (accidental trigger, muted mic) — don't leave
                // the mic + ticker running forever.
                store.log("recorder", "ended — no speech in \(Int(sessionIdleLimit))s")
                stopRecording()
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
        case .recording:
            return   // still capturing; nothing to settle
        }
        // Discard anything heard while we were acting (e.g. our own typing sounds).
        freshUtterance()
        armCaptureForCurrentMode()
    }

    // MARK: Recorder (unified dictation + live, chunked, any length)

    private var flushTask: Task<Void, Never>?   // in-flight periodic chunk transcription

    /// Starts one recorder for any length of speech. `output` decides what happens
    /// on stop: paste at the cursor, save a processed note, or both. Uses Scribe
    /// (chunked, unbounded) when the engine allows + a key exists; otherwise Apple
    /// on-device only. Starts the mic on demand.
    func startRecording(output: RecorderOutput) {
        // A note needs Claude to process; a raw insert doesn't. Fail early only when
        // the chosen output genuinely can't be produced.
        if output.producesNote, claude == nil {
            phase = .error("Saving a note needs an API key")
            store.log("recorder", "ignored — note output needs Claude")
            return
        }
        guard !processing, mode != .recording else { return }
        if !isRunning { pendingRecording = true; pendingRecordingOutput = output; start(); return }
        recorderOutput = output
        recorderReturnMode = (mode == .command) ? .command : .standby
        liveGeneration += 1   // invalidates any still-in-flight chunk from a prior recording
        liveTranscript = ""
        liveActive = true
        mode = .recording
        phase = .recording
        lastFlushAt = Date()
        lastHeardAt = Date()   // don't let the end-pause fire before any speech
        recordingStartedAt = Date()
        flushing = false
        freshUtterance()
        listener.carryForward = true
        listener.metering = true
        armCaptureForCurrentMode()
        startTicker()
        // Anchor the pill to the window the user is working in (not our own app,
        // which may be frontmost if they clicked the menu).
        let anchorApp = insertTargetApp ?? lastExternalApp ?? NSWorkspace.shared.frontmostApplication
        pill.show(coordinator: self, near: ScreenController.windowFrame(for: anchorApp))
        store.log("recorder", "started (\(output))")
    }

    /// Ends the recording and applies its output. Kicks a task that waits for the
    /// last chunk, assembles the full transcript, then inserts/processes it.
    func stopRecording() {
        guard mode == .recording else { return }
        let output = recorderOutput
        mode = recorderReturnMode
        liveActive = false
        listener.carryForward = false
        listener.metering = false
        meter.level = 0
        recordingStartedAt = nil
        store.log("recorder", "stopped (\(output)) — processing")
        finishRecording(output: output)
    }

    /// Discards the current recording without processing it (pill's ✕).
    func cancelRecording() {
        guard mode == .recording else { return }
        liveGeneration += 1            // drop any in-flight chunk
        mode = recorderReturnMode
        liveActive = false
        liveTranscript = ""
        listener.carryForward = false
        listener.metering = false
        listener.captureAudio = false
        meter.level = 0
        recordingStartedAt = nil
        pill.hide()
        freshUtterance()
        settleSessionPhase()
        store.log("recorder", "cancelled")
    }

    private func finishRecording(output: RecorderOutput) {
        processing = true
        phase = .thinking
        let gen = runGeneration
        actionTask = Task {
            // Gen-guard the hide: a superseded task must not hide a *newer*
            // recording's pill (Stop→retry overlapping an in-flight transcription).
            defer { self.finishProcessing(gen); if gen == self.runGeneration { self.pill.hide() } }
            let raw = await self.finalizeRecorderTranscript()
            let text = Self.stripDictationTriggers(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                // Silence reads as success in a hands-free app — say so instead.
                self.store.log("recorder", "empty recording")
                guard gen == self.runGeneration, !Task.isCancelled else { return }
                self.phase = .error("couldn't make out that recording")
                await self.speak("Sorry, I couldn't make out that recording.", gen: gen)
                return
            }
            do {
                try Task.checkCancellation()
                if output.producesInsert {
                    try await self.insertDictation(text, claude: self.claude, gen: gen)
                }
                if output.producesNote {
                    guard let claude = self.claude else {
                        self.store.addTranscript(TranscriptRecord(kind: "dictation", transcript: text))
                        return
                    }
                    let report = try await claude.buildDictationReport(text, vocabulary: self.vocabulary.promptContext, instructions: self.profiles.activeInstructions)
                    try Task.checkCancellation()
                    self.lastReport = report
                    self.store.addTranscript(TranscriptRecord(kind: "dictation", transcript: text,
                        title: report.title, summary: report.summary,
                        keyPoints: report.keyPoints, actionItems: report.actionItems))
                    self.store.log("claude", "note ready — \(report.keyPoints.count) points, \(report.actionItems.count) action items")
                }
            } catch {
                // Never lose the note — the raw text is the only durable copy.
                let outcome = Task.isCancelled ? "cancelled" : "error: \(error)"
                self.store.addTranscript(TranscriptRecord(kind: "dictation", transcript: text, outcome: outcome))
                guard !Task.isCancelled, gen == self.runGeneration else { return }
                self.phase = .error("\(error)")
                self.store.log("error", "\(error)")
            }
        }
    }

    /// Waits for any in-flight periodic chunk, transcribes the trailing audio, and
    /// returns the complete transcript. Prefers Scribe's accumulated text but falls
    /// back to Apple's on-device transcript — a Scribe outage must never lose a note.
    private func finalizeRecorderTranscript() async -> String {
        await flushTask?.value   // let the last periodic chunk land before the tail
        var tailWav: Data?
        if scribeForRecording, let key = elevenLabsKey, let wav = listener.takeCapturedWAV() {
            tailWav = wav
            let tail = ((try? await ScribeClient(apiKey: key).transcribe(wav: wav)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { liveTranscript += (liveTranscript.isEmpty ? "" : " ") + tail }
        }
        listener.captureAudio = false
        let scribe = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !scribe.isEmpty { return scribe }
        // Scribe produced nothing (offline / rate-limited / disabled) — use Apple's.
        if !utterance.isEmpty { return utterance }
        // Both engines silent but we had audio: persist the tail so it's recoverable.
        if let tailWav { await store.saveAudioAndWait(tailWav) }
        return ""
    }

    /// Transcribes one ~chunk of audio via Scribe and appends it — never holding
    /// more than a chunk in memory (what makes multi-hour recording safe).
    private func flushLiveChunk(final: Bool) {
        guard let key = elevenLabsKey else { return }
        guard let wav = listener.takeCapturedWAV() else { lastFlushAt = Date(); return }
        flushing = true
        lastFlushAt = Date()
        let gen = runGeneration
        let liveGen = liveGeneration
        flushTask = Task {
            let text = ((try? await ScribeClient(apiKey: key).transcribe(wav: wav)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.flushing = false
            // Drop only if the app was hard-stopped or a *new* recording started; a
            // graceful stop leaves both generations so the tail still lands.
            guard gen == self.runGeneration, liveGen == self.liveGeneration else { return }
            guard !text.isEmpty else { return }
            self.liveTranscript += (self.liveTranscript.isEmpty ? "" : " ") + text
            self.store.log("recorder", "\(final ? "final " : "")chunk +\(text.count) chars")
        }
    }

    func clearLiveTranscript() { liveTranscript = ""; liveAnswer = "" }

    @Published var liveBusy = false
    @Published var liveAnswer = ""

    /// Turns the live transcript into a titled summary + key points + action items
    /// (reuses the dictation report), shown in the panel.
    func summarizeLiveTranscript() {
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let claude, !liveBusy else { return }
        liveBusy = true
        Task {
            defer { self.liveBusy = false }
            if let report = try? await claude.buildDictationReport(text, vocabulary: self.vocabulary.promptContext, instructions: self.profiles.activeInstructions) {
                self.lastReport = report
                self.store.addTranscript(TranscriptRecord(kind: "dictation", transcript: text,
                    title: report.title, summary: report.summary,
                    keyPoints: report.keyPoints, actionItems: report.actionItems))
                self.store.log("live", "summarized \(text.count) chars")
            }
        }
    }

    /// Answers a question about the live transcript (Otter-style "ask your notes").
    func askLiveTranscript(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !text.isEmpty, let claude, !liveBusy else { return }
        liveBusy = true
        liveAnswer = ""
        Task {
            defer { self.liveBusy = false }
            self.liveAnswer = (try? await claude.answer(question: q, about: text)) ?? "Couldn't answer that."
        }
    }

    /// Saves the current live transcript as a note (a dictation record).
    func saveLiveAsNote() {
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addTranscript(TranscriptRecord(kind: "dictation", transcript: text, title: "Live note"))
        store.log("live", "saved as note")
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
        guard claude != nil else { phase = .error("No API key set"); armCaptureForCurrentMode(); return }

        // A spoken answer clears the on-screen question — from here it's just
        // another turn in the dialogue.
        let answeringClarification = pendingClarification != nil
        pendingClarification = nil
        processing = true
        phase = .thinking
        let gen = runGeneration
        // Resume a mid-task clarification with what was already done; a fresh command
        // starts clean.
        let seedProgress = answeringClarification ? carriedTaskProgress : []
        carriedTaskProgress = []

        actionTask = Task {
            defer { self.finishProcessing(gen) }
            do {
                let raw = await self.transcribed(wav: wav, fallback: appleText)
                var text = wav != nil ? Self.strippingPhrases(Self.wakePhrases + Self.stopPhrases, from: raw) : raw
                try Task.checkCancellation()
                self.lastCommand = text
                // "Do that again" re-runs the previous real command, re-parsed against
                // the current screen (not a replayed action list) so it acts on now.
                if !answeringClarification, Self.isRepeatPhrase(text) {
                    guard let prev = self.lastActionableCommand else {
                        await self.speak("I don't have a previous command to repeat.", gen: gen)
                        return
                    }
                    self.store.log("command", "repeat → \(prev)")
                    text = prev
                } else if !answeringClarification {
                    // Stored pre-parse: if this command turns out to need clarification,
                    // "do that again" will re-ask rather than replay the resolved action.
                    self.lastActionableCommand = text
                }
                self.store.log("asr", answeringClarification ? "answer: \(text)" : "command: \(text)")
                try await self.runGoal(text: text, gen: gen, seedProgress: seedProgress)
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

    // A goal runs as an act-observe loop, bounded so it can't run away.
    private static let maxTaskRounds = 6

    /// Drives one goal to completion: each round re-reads the screen, asks the model
    /// for the next action(s) toward the goal, executes them, and repeats until the
    /// model reports goal_complete (or nothing more to do, or the round cap). This is
    /// what makes it *finish* a task — continue into the panel it just opened rather
    /// than stopping there. Parse/network errors propagate to the caller's catch;
    /// step-execution failures are reported here and end the loop.
    private func runGoal(text: String, gen: Int, seedProgress: [String]) async throws {
        guard let claude else { return }
        var performedAll = seedProgress   // carried across a mid-task clarification
        var complete = false
        var round = 0
        var lastState = ""                      // (exact action + screen) of the prior round
        var consecutiveRepeats = 0              // back-to-back identical no-progress rounds
        var emptyRounds = 0                     // consecutive rounds that did nothing real
        var brokeOut = false                    // stopped early (loop/spin/blocked) — already spoke
        while round < Self.maxTaskRounds, !complete {
            try Task.checkCancellation()
            phase = .thinking
            let screen = try await gatherScreen(for: text, round: round)
            let context = buildPlannerContext(command: text, taskProgress: performedAll)
            let plan = try await claude.parsePlan(text, dialogue: dialogue,
                                                  vocabulary: vocabulary.promptContext,
                                                  screen: screen, context: context)
            try Task.checkCancellation()
            store.log("claude", "round \(round): \(plan.steps.count) step(s) complete=\(plan.goalComplete)\(plan.clarify != nil ? " +question" : "")")

            // A taught correction applies regardless of the rest of the plan.
            if let fact = plan.learn, fact.isValid, gen == runGeneration {
                vocabulary.learnCorrection(spoken: fact.spoken, written: fact.written)
                refreshContextualPhrases()
                store.log("learn", "\(fact.spoken) → \(fact.written)")
            }
            // A durable fact to remember about the user/setup (round 0 only).
            if round == 0, !plan.remember.isEmpty, gen == runGeneration {
                knowledge.remember(plan.remember)
                store.log("remember", plan.remember)
            }
            // The user taught a procedure — save it (only round 0, so a "teach and do
            // it now" task doesn't re-learn a drifting name every round).
            if round == 0, let taught = plan.teach, taught.isValid, gen == runGeneration {
                procedures.learn(taught)
                store.log("teach", "learned procedure: \(taught.name)")
                // Pure teaching with nothing to do (and no question) — confirm and stop.
                if plan.steps.isEmpty, plan.clarify == nil {
                    dialogue = []
                    await speak(plan.say.isEmpty ? "Got it — I'll remember how to \(taught.name)." : plan.say, gen: gen)
                    return
                }
            }

            if let clarify = plan.clarify {
                dialogue.append((role: "user", content: text))
                dialogue.append((role: "assistant", content: "I need to clarify: \(clarify.question)"))
                if dialogue.count > Self.maxDialogueTurns { dialogue.removeFirst(dialogue.count - Self.maxDialogueTurns) }
                carriedTaskProgress = performedAll   // resume the task (not re-run it) after the answer
                store.log("clarify", clarify.question)
                pendingClarification = clarify
                phase = .clarifying
                await speak(clarify.spoken, gen: gen)
                return
            }
            if plan.malformed {
                dialogue = []
                phase = .error("didn't understand part of that")
                await speak("I didn't catch part of that — could you say it again?", gen: gen)
                return
            }
            // The model gave up — record an incomplete outcome, don't loop or fake success.
            if plan.blocked {
                dialogue = []
                await speak(plan.say.isEmpty ? "I couldn't finish that." : plan.say, gen: gen)
                brokeOut = true
                break
            }

            dialogue = []                        // request resolved; next utterance is fresh
            if !plan.say.isEmpty { await speak(plan.say, gen: gen) }
            guard gen == runGeneration, !Task.isCancelled else { return }

            // Stuck-loop guard: the EXACT same action (including typed text) proposed
            // against the SAME screen on THREE CONSECUTIVE rounds. Consecutive-only
            // (the counter resets the moment the action or screen changes) so a
            // workflow that revisits a state non-consecutively is never affected;
            // requiring three-in-a-row (not one) tolerates a lossy/truncated snapshot
            // that happens to hash-collide on a productive repeat. A genuine stuck loop
            // repeats far more than that. Empty screen (round 0) can't match.
            let signature = Self.coarseSignature(plan.steps)
            if !signature.isEmpty, !screen.isEmpty {
                let state = "\(signature)@@\(screen.hashValue)"
                consecutiveRepeats = (state == lastState) ? consecutiveRepeats + 1 : 1
                lastState = state
                if consecutiveRepeats >= 3 {
                    store.log("command", "no-progress loop detected — stopping")
                    await speak("I keep doing the same thing without the screen changing, so I'll stop. Tell me exactly which element to use and I'll try that.", gen: gen)
                    brokeOut = true
                    break
                }
            } else {
                consecutiveRepeats = 0; lastState = ""   // a non-action round breaks the streak
            }

            do {
                let (performed, stop) = try await executeSteps(plan, gen: gen)
                performedAll += performed
                if stop { return }              // dictate_start handed the session to the recorder
                // Spin guard: two rounds in a row with no real action AND no observation
                // (e.g. the model keeps "waiting" for something it can't do) — stop.
                let observed = plan.steps.contains { $0.kind == .describeScreen }
                emptyRounds = (performed.isEmpty && !observed) ? emptyRounds + 1 : 0
                if emptyRounds >= 2, !plan.goalComplete {
                    store.log("command", "no progress for \(emptyRounds) rounds — stopping")
                    await speak("I'm not able to make progress on that — could you tell me the steps, or which element to use?", gen: gen)
                    brokeOut = true
                    break
                }
            } catch {
                if Task.isCancelled || gen != runGeneration { throw error }
                let done = performedAll.isEmpty ? "" : performedAll.joined(separator: " → ") + " → "
                store.addTranscript(TranscriptRecord(kind: "command", transcript: text, outcome: "\(done)FAILED: \(error)"))
                recordRecentAction("\(contextTag())\"\(text)\" → \(done)FAILED")
                phase = .error("\(error)")
                store.log("error", "step failed after \(performedAll.count) done: \(error)")
                await speak(performedAll.isEmpty ? "That didn't work." : "I did part of it, then hit a problem.", gen: gen)
                return
            }

            // Success requires an explicit goal_complete — an empty, non-complete,
            // non-blocked plan (a stalled/malformed response) must NOT count as done;
            // it falls through as a no-progress round (the emptyRounds guard catches a
            // persistent stall and records it INCOMPLETE).
            complete = plan.goalComplete
            round += 1
            // Let the UI settle (a menu/dialog appears) before the next observation —
            // but not after the final round (no next observation to wait for).
            if !complete, round < Self.maxTaskRounds { try? await Task.sleep(nanoseconds: 350_000_000) }
        }

        // Stop pressed during the loop's tail (esp. the sleep, which swallows
        // cancellation) must not write stale history or speak a completion line.
        guard gen == runGeneration, !Task.isCancelled else { return }
        // Record the outcome. A non-complete ending (blocked / stuck / spin / round
        // cap) is marked INCOMPLETE so it isn't logged as a false success and can't
        // contaminate future context/history.
        let didWork = !performedAll.isEmpty
        if didWork || !complete {
            let base = performedAll.joined(separator: " → ")
            let outcome = complete ? base : (didWork ? base + " → " : "") + "INCOMPLETE"
            store.addTranscript(TranscriptRecord(kind: "command", transcript: text, outcome: outcome))
            recordRecentAction("\(contextTag())\"\(text)\" → \(outcome)")
        }
        if !complete, !brokeOut {
            store.log("command", "stopped after \(round) rounds without goal_complete")
            await speak("I did what I could — it may not be fully finished.", gen: gen)
        }
    }

    /// A fingerprint of a round's actions INCLUDING the typed text/url, so that
    /// re-entering different values into the same form (a productive repeat) does NOT
    /// collide — only a byte-identical action does. Paired with the screen hash, this
    /// fires only when the exact same action is attempted against an unchanged screen.
    nonisolated static func coarseSignature(_ steps: [ScreenAction]) -> String {
        // Exclude none/describe (no mutation) and scroll (scroll-to-find legitimately
        // repeats the same action across rounds).
        steps.filter { $0.kind != .none && $0.kind != .describeScreen && $0.kind != .scroll }
            .map { "\($0.kind.rawValue):\($0.target.lowercased()):\($0.text):\($0.url):\($0.keys.lowercased()):\($0.direction?.rawValue ?? "")" }
            .joined(separator: "|")
    }

    private var carriedTaskProgress: [String] = []

    /// Executes one round's steps in order. Returns what ran and whether the loop
    /// must stop (a dictate_start step hands the mic to the recorder).
    private func executeSteps(_ plan: ActionPlan, gen: Int) async throws -> (performed: [String], stop: Bool) {
        var performed: [String] = []
        for step in plan.steps {
            try Task.checkCancellation()
            switch step.kind {
            case .dictateStart:
                self.startRecording(output: .note)
                return (performed, true)
            case .describeScreen:
                try await self.describeScreen(question: step.target, gen: gen)
            case .none:
                continue
            default:
                self.phase = .acting
                if step.kind == .click {
                    try await self.performClick(target: step.target, gen: gen)
                } else {
                    // Off the main actor + cancellable: perform() checks cancellation
                    // before every irreversible event, so Stop halts mid-walk/typing.
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try ScreenController.perform(step) }
                        try await group.waitForAll()
                    }
                }
                performed.append(Self.describe(step))
                self.updateContext(for: step)
                self.store.log("action", "performed: \(Self.describe(step))")
            }
        }
        return (performed, false)
    }

    /// Reads the focused window (raising the sticky-context window first). Round 0
    /// skips the AX walk for simple commands; later rounds always observe results.
    private func gatherScreen(for text: String, round: Int) async throws -> String {
        guard round > 0 || Self.needsScreenContext(text) else { return "" }
        // Establish the sticky window only on the first round. Re-raising it every
        // round would dismiss a menu/palette/overlay a prior round opened — the loop
        // must read (and act in) whatever the last action produced.
        if round == 0, let win = workingContext.window {
            let labels = environment.snapshot.apps.flatMap { a in a.windows.map { "\(a.name) \($0.title)" } }
            if ScreenController.bestWindowIndex(labels, query: win) != nil {
                try? await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try? ScreenController.focusWindow(matching: win) }
                    try await group.waitForAll()
                }
            } else {
                workingContext.window = nil   // stale — the window is gone
            }
        }
        let snap = try await withThrowingTaskGroup(of: ScreenController.Snapshot?.self) { group in
            group.addTask { try? ScreenController.focusedWindowSnapshot() }
            return try await group.next() ?? nil
        }
        guard let snap else { return "" }
        store.log("screen", "round \(round): read \(snap.elements.count) elements from \(snap.app)")
        return snap.promptText
    }

    private func buildPlannerContext(command: String, taskProgress: [String]) -> String {
        var parts = [knowledge.promptContext,
                     workingContext.promptText,
                     procedures.promptContext(for: command),
                     environment.snapshot.promptText,
                     recentActionsBlock()]
        if !taskProgress.isEmpty {
            parts.append("This task so far (already done — don't repeat):\n" + taskProgress.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: Working context + memory

    private func recentActionsBlock() -> String {
        guard !recentActions.isEmpty else { return "" }
        return "Recent actions (oldest first):\n" + recentActions.map { "- \($0)" }.joined(separator: "\n")
    }

    // Tags an action with the window/app it was performed in, so the memory reads
    // "[Chrome › GitHub] "open PRs" → …" — actions grouped by what they acted on.
    private func contextTag() -> String {
        workingContext.isEmpty ? "" : "[\(workingContext.label)] "
    }

    private func recordRecentAction(_ line: String) {
        recentActions.append(String(line.prefix(200)))
        if recentActions.count > Self.recentActionsMax {
            recentActions.removeFirst(recentActions.count - Self.recentActionsMax)
        }
    }

    /// Moves the sticky working context when a step changes the focused target, so
    /// the next command inherits it without the user re-naming the window.
    private func updateContext(for step: ScreenAction) {
        switch step.kind {
        case .openApp:
            workingContext = WorkingContext(app: step.target)
        case .openURL:
            // The site opened in the named browser (or the current app if unnamed) —
            // keep the app focus, drop the old window/tab. Never blank the context.
            if !step.target.isEmpty { workingContext = WorkingContext(app: step.target) }
            else if workingContext.app != nil { workingContext = WorkingContext(app: workingContext.app) }
        case .focusWindow:
            var ctx = WorkingContext(window: step.target)
            // Resolve the owning app from the live environment when we can.
            let labels = environment.snapshot.apps.flatMap { app in app.windows.map { (app.name, $0.title) } }
            if let idx = ScreenController.bestWindowIndex(labels.map { "\($0.0) \($0.1)" }, query: step.target) {
                ctx.app = labels[idx].0
            }
            workingContext = ctx
        case .switchTab:
            workingContext.tab = step.target
        default:
            break
        }
    }

    /// Clears the sticky focus (dashboard control / "work anywhere").
    func clearWorkingContext() { workingContext = WorkingContext() }

    /// Clicks `target`, first via the Accessibility tree; if that finds nothing and
    /// vision is enabled, screenshots the screen and lets Claude locate it by pixel.
    /// The vision path is why an all-canvas/Electron UI (poor AX) is still clickable.
    private func performClick(target: String, gen: Int) async throws {
        guard ScreenController.isTrusted else { throw ScreenController.ControlError.notTrusted }
        do {
            // Off the main actor + cancellable, same as the generic action path.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try ScreenController.click(target: target) }
                try await group.waitForAll()
            }
            return
        } catch let error as ScreenController.ControlError {
            // Only an AX miss is worth a screenshot retry; a real failure (not
            // trusted, cancelled) propagates unchanged.
            guard case .elementNotFound = error, visionClickEnabled, let claude else { throw error }
            store.log("vision", "AX had no match for \"\(target)\" — trying screenshot")
            try Task.checkCancellation()
            guard let shot = await ScreenController.captureDisplayForFrontWindow() else {
                throw error   // no Screen Recording permission → report the original miss
            }
            // Abandon (not silently succeed) if Stop/a newer command intervened during
            // the async screenshot or vision call — matches every other cancel path.
            guard gen == runGeneration, !Task.isCancelled else { throw CancellationError() }
            guard let norm = try await claude.locateElement(described: target, pngBase64: shot.pngBase64) else {
                throw error   // model couldn't see it either
            }
            guard gen == runGeneration, !Task.isCancelled else { throw CancellationError() }
            let point = ScreenController.normalizedToScreen(x: norm.x, y: norm.y, in: shot.frame)
            ScreenController.clickAt(point)
            store.log("vision", "clicked \"\(target)\" via screenshot at \(Int(point.x)),\(Int(point.y))")
        }
    }

    /// Screenshots the screen and speaks Claude's description/answer. Reuses the
    /// vision capture from the click fallback; needs Screen Recording, not AX.
    private func describeScreen(question: String, gen: Int) async throws {
        guard let claude else { return }
        phase = .thinking
        guard let shot = await ScreenController.captureDisplayForFrontWindow() else {
            await speak("I couldn't capture the screen — check Screen Recording permission.", gen: gen)
            return
        }
        guard gen == runGeneration, !Task.isCancelled else { throw CancellationError() }
        let answer = try await claude.describeScreen(question: question, pngBase64: shot.pngBase64)
        guard gen == runGeneration, !Task.isCancelled else { throw CancellationError() }
        store.addTranscript(TranscriptRecord(kind: "command",
                                             transcript: question.isEmpty ? "describe screen" : question,
                                             outcome: answer))
        store.log("vision", "described screen (\(answer.count) chars)")
        await speak(answer, gen: gen)
    }

    private static func describe(_ step: ScreenAction) -> String {
        switch step.kind {
        case .openURL: return "open_url \(step.url)\(step.target.isEmpty ? "" : " in \(step.target)")"
        case .focusWindow: return "focus_window \(step.target)"
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

    // Verbs/deictics that mean "act on what's on screen" — gate the AX snapshot
    // on these so "open YouTube" stays fast but "click the compose button" reads
    // the page first.
    nonisolated static let screenIntentWords = [
        "click", "press", "tap", "select", "choose", "read", "what", "which",
        "this", "that", "here", "it", "them", "page", "screen", "button", "link",
        "field", "check", "toggle", "close the", "scroll", "fill", "submit",
        "on the", "delete", "remove", "drag", "hover", "first", "second", "third",
        "last", "row", "item", "send", "save", "enter", "refresh", "back", "menu",
        "find", "search", "expand", "collapse", "dropdown", "checkbox", "icon",
        "the top", "the bottom", "open the", "go to the",
    ]
    nonisolated static func needsScreenContext(_ text: String) -> Bool {
        let t = text.lowercased()
        return screenIntentWords.contains { t.contains($0) }
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

    // MARK: Recorder triggers

    // Where a finishing recording returns: a wake-word note keeps the command
    // session open; a one-tap note from standby returns to standby.
    private var recorderReturnMode: Mode = .command

    /// Voice-triggered insert: capture the paste target before starting (the app
    /// is already frontmost — no activation happens on this path).
    private func startInsertByVoice() {
        captureInsertTarget()
        startRecording(output: .insert)
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

    // Capture the utterance's raw audio only when Scribe will re-transcribe it, so
    // Apple stays the sole engine (and no buffering) whenever Scribe isn't in play.
    private func armCaptureForCurrentMode() {
        let want: Bool
        switch mode {
        case .standby: want = false
        case .command: want = hasElevenLabsKey && speechEngine.usesScribe(forDictation: false)
        case .recording: want = scribeForRecording   // Apple-only recording captures nothing extra
        }
        listener.captureAudio = want   // setting true also clears the prior clip
    }

    // Recording uses Scribe (chunked, high-accuracy) when the engine setting allows
    // and a key exists; otherwise it's Apple on-device only (still works, unbounded).
    private var scribeForRecording: Bool { hasElevenLabsKey && speechEngine.usesScribe(forDictation: true) }
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

    /// Insert mode: optionally clean the text, then paste it into the app the user
    /// was in and leave it on the clipboard. The final text is recorded so nothing
    /// is lost, even if the paste can't happen.
    private func insertDictation(_ raw: String, claude: ClaudeClient?, gen: Int) async throws {
        // Format per the target app (general + per-app insert rules). Run the model
        // pass when cleanup is on OR a paste rule applies — so configured rules aren't
        // silently ignored just because the cleanup toggle is off. Failure → raw text.
        let rules = insertRules.instructions(forApp: insertTargetApp?.localizedName)
        let final: String
        if let claude, (cleanUpInsertedText || !rules.isEmpty) {
            final = (try? await claude.cleanUpDictation(raw, vocabulary: vocabulary.promptContext,
                                                        instructions: rules, cleanup: cleanUpInsertedText)) ?? raw
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
