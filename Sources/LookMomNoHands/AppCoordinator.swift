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
    /// Selected input device UID (nil = system default). Persisted. Lets the
    /// user record from a different mic than other transcription tools, so a
    /// second recorder can run in parallel as a backup.
    @Published private(set) var micUID: String?
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    private static let micKey = "inputMicUID"

    /// Visible transcription-failure state (pill + Live tab). The 30-minute loss
    /// happened because 30 consecutive failures were invisible — this makes the
    /// very first one show on screen. Cleared when a flush fully succeeds.
    @Published private(set) var transcriptionTrouble: String?

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
    private let demo = DemonstrationRecorder()               // watch-me click/key capture
    @Published private(set) var demonstrating = false
    private var demoName = ""
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
    // Chunk WAVs whose Scribe transcription failed, oldest first. Retried in order
    // at the next flush and again at stop; whatever still fails is saved to disk.
    // Failed chunks used to be silently discarded — that is how a 30-minute
    // recording once shrank to its final sentence.
    private var unsentChunks: [Data] = []
    private static let unsentChunksMax = 20   // ~30 min of audio; beyond that spill to disk
    private var scribeMissedAudio = false     // audio existed that Scribe never transcribed
    // Short chunks on purpose: the live transcript visibly moves every few
    // seconds of speech, and a failure can only ever cost one small chunk —
    // 60–90s chunks once turned a transcription outage into a 30-minute loss.
    // Scribe bills by audio duration, so more/smaller requests cost the same.
    nonisolated static let liveChunkSecondsForTest: TimeInterval = 12    // aim to flush after this…
    nonisolated static let liveChunkSilenceForTest: TimeInterval = 0.8   // …at the next pause (phrase end)
    nonisolated static let liveChunkMaxForTest: TimeInterval = 25        // …but flush anyway by here
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

    // Clause-pause gate: act this soon after a natural pause so a compound request
    // runs step-by-step; wait longer when the phrase clearly continues; snap back
    // fastest on a clarification answer.
    // 1.5s, not 1.0: a deliberate speaker pauses mid-sentence ("...puppy [breath]
    // videos on YouTube..."); too short a gate finalizes a FRAGMENT and drops the
    // rest (which then arrives during processing and is lost). Err toward hearing
    // the whole clause over acting a beat sooner.
    private let clausePause: TimeInterval = 0.8
    private let midThoughtPause: TimeInterval = 1.5
    private let clarifyAnswerPause: TimeInterval = 0.8
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
    // Ends a watch-me demonstration. All require "mama" so narrating "…done watching
    // the video…" mid-demo can't end it early. Stored in NORMALIZED form (matched
    // against normalizedForMatching, which drops apostrophes → "I'm" becomes "i m").
    nonisolated static let demoStopPhrases = ["mama done", "mama i m done", "mama stop watching",
                                              "mama finished", "mama that s it"]
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
        micUID = UserDefaults.standard.string(forKey: Self.micKey)
        listener.preferredInputUID = micUID
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
        if demonstrating { return }   // a chord press during a demo would fight the recording
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
        if demonstrating { _ = demo.stop(); demonstrating = false }
        screenPrefetch = nil   // a snapshot from the stopped run must not feed the next
        listener.metering = false
        meter.level = 0
        recordingStartedAt = nil
        pill.hide()
        liveActive = false
        if !unsentChunks.isEmpty {
            // Disabling listening mid-outage must not vaporize untranscribed speech.
            let orphans = unsentChunks
            Task {
                for wav in orphans { await self.store.saveAudioAndWait(wav) }
                self.store.log("scribe", "\(orphans.count) untranscribed chunk(s) saved in \(self.store.directory.path)")
            }
        }
        unsentChunks = []
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
        if speaking {
            // Software barge-in (no hardware echo cancellation): the mic hears our own
            // TTS, so the recognizer transcribes what SHE is saying. A partial that
            // DIVERGES from her spoken text — has new words that aren't in it — means
            // YOU are talking over her. Stop talking and listen, like a real
            // conversation. Until divergence, ignore the echo of her own voice.
            if !bargedIn {
                guard Self.isBargeOverTTS(partial: text, tts: speakingText) else { return }
                bargedIn = true
                speaker.cancel()      // she stops immediately
                freshUtterance()      // drop the garbled TTS+you overlap; capture you cleanly next
                store.log("barge", "you interrupted — stopping")
            }
            return   // wait for speak() to settle; clean partials resume once she's silent
        }
        utterance = text
        lastHeardAt = Date()
        guard !processing else { return }

        // While watching a demonstration, the ONLY spoken input we act on is the
        // stop phrase — everything else is the user narrating to themselves, and
        // prefetching would raise windows and fight their demo.
        if demonstrating {
            let tail = Self.normalizedForMatching(String(text.suffix(64)))
            if Self.demoStopPhrases.contains(where: tail.contains) { finishDemonstration() }
            return
        }

        // Overlap work with speech: while the user is still talking in a command
        // session, read the screen in the background so the parse can start the
        // moment they stop — instead of paying the AX walk after the silence gate.
        if mode == .command { prefetchScreenIfStale() }

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
            // On the isolated meter object: partials arrive several times a second
            // and must not re-render every coordinator-observing view.
            meter.heard = String(text.suffix(200))
            // Either a dictation or a live stop phrase ends the recording; otherwise
            // capture continues (chunks accumulate) until a long pause or the pill.
            if Self.dictateStopPhrases.contains(where: tail.contains)
                || Self.liveStopPhrases.contains(where: tail.contains) { stopRecording() }
        }
    }

    // Words/short fragments that signal the user is mid-thought — don't act yet.
    nonisolated static let continuationWords: Set<String> = [
        "and", "then", "so", "to", "the", "a", "an", "of", "for", "with", "or", "but",
        "plus", "also", "now", "next", "after", "before", "when", "that", "which", "on",
        "in", "at", "my", "your", "this", "into", "onto", "up"
    ]

    /// True when the utterance ends on a word that implies more is coming (a
    /// conjunction/article/preposition), or is too short to be a whole command — so
    /// the silence gate waits instead of acting on a half-spoken clause. Pure/tested.
    nonisolated static func endsMidThought(_ text: String) -> Bool {
        let words = normalizedForMatching(text).split(separator: " ").map(String.init)
        guard let last = words.last else { return false }
        if words.count < 2 { return true }
        return continuationWords.contains(last)
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
            if demonstrating { break }   // watching a demo — no silence gates, no idle end
            // Act on each clause as you pause, not after the whole sentence: a short
            // gate (1s) fires on a natural clause pause so "open YouTube [pause] search
            // cats [pause] play the first one" executes step-by-step live. But if the
            // phrase clearly continues ("…and", "…then to"), wait longer so a
            // mid-thought breath isn't cut. Clarification answers snap back fastest.
            let gate: TimeInterval
            if pendingClarification != nil { gate = clarifyAnswerPause }
            else if Self.endsMidThought(utterance) { gate = midThoughtPause }
            else { gate = clausePause }
            if !utterance.isEmpty, quiet > gate {
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
        screenPrefetch = nil   // a snapshot from this session must not feed the next
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
            case .error, .clarifying, .watching: break   // don't stomp a live state
            default: phase = .capturingCommand
            }
            sessionIdleSince = Date()
        case .standby:
            if case .error = phase {} else { phase = .listeningWake }
            stopTicker()
        case .recording:
            return   // still capturing; nothing to settle
        }
        // Keep whatever's in the utterance when settling a command: the user may have
        // spoken the NEXT clause while this one was executing ("open YouTube" running
        // while they say "…now search cats") — wiping it would drop that clause. It's
        // safe because finalizeCommand already cleared the finished clause, and screen
        // actions are synthetic (no mic noise). Only clear on the way to standby.
        if mode == .standby { freshUtterance() }
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
        guard mode != .recording else { return }   // already recording
        // The previous recording is still transcribing: starting now would race its
        // finalize for the mic capture and cross-pollinate the two transcripts.
        guard !finalizingRecording else {
            store.log("recorder", "ignored — still processing the previous recording")
            return
        }
        // Dictation takes priority: stop an in-flight command from acting on the
        // screen while you dictate. The session resumes normally after you finish.
        cancelCommandInFlight()
        if !isRunning { pendingRecording = true; pendingRecordingOutput = output; start(); return }
        recorderOutput = output
        recorderReturnMode = (mode == .command) ? .command : .standby
        liveGeneration += 1   // invalidates any still-in-flight chunk from a prior recording
        liveTranscript = ""
        meter.heard = ""
        unsentChunks = []
        scribeMissedAudio = false
        transcriptionTrouble = nil
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

    /// Cancels an in-flight command action so it stops touching the screen — a
    /// dictation is taking over. Keeps the mic on and the session mode as-is, so the
    /// main assistant resumes once the dictation finishes.
    private func cancelCommandInFlight() {
        guard processing else { return }
        runGeneration += 1            // a stale command task's completion must not touch new state
        actionTask?.cancel(); actionTask = nil
        speaker.cancel()
        speaking = false
        processing = false
        pendingClarification = nil
        dialogue = []
        screenPrefetch = nil
        if case .clarifying = phase { phase = .capturingCommand }
        store.log("app", "command interrupted for dictation")
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
        unsentChunks = []
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

    private var finalizingRecording = false   // a stop's transcription is in flight
    private var micChangePending = false      // mic switched mid-recording; apply at stop

    private func finishRecording(output: RecorderOutput) {
        processing = true
        finalizingRecording = true
        phase = .thinking
        let gen = runGeneration
        let liveGen = liveGeneration
        actionTask = Task {
            // Gen-guard the hide: a superseded task must not hide a *newer*
            // recording's pill (Stop→retry overlapping an in-flight transcription).
            defer {
                self.finalizingRecording = false
                self.finishProcessing(gen)
                if gen == self.runGeneration {
                    self.pill.hide()
                    if self.micChangePending {
                        self.micChangePending = false
                        self.selectMicrophone(uid: self.micUID)
                    }
                }
            }
            let raw = await self.finalizeRecorderTranscript(gen: gen, liveGen: liveGen)
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

    /// Waits for any in-flight periodic chunk, transcribes the retry queue plus the
    /// trailing audio, and returns the complete transcript. Prefers Scribe's text
    /// but falls back to Apple's on-device transcript — a Scribe outage must never
    /// lose a note, and audio nobody could transcribe is persisted, not dropped.
    private func finalizeRecorderTranscript(gen: Int, liveGen: Int) async -> String {
        await flushTask?.value   // let the last periodic chunk land before the tail
        // Guard with the generations captured BEFORE the await: if a new session
        // started while we waited, the mic capture and live transcript belong to
        // it now — touching either would steal its audio or wipe its text.
        guard gen == runGeneration, liveGen == liveGeneration else { return "" }
        if scribeForRecording, let key = elevenLabsKey {
            let lost = await transcribeInOrder(drainPendingAudio(), key: key,
                                               gen: gen, liveGen: liveGen)
            // Speech no engine will ever hear again — save the audio for recovery
            // and say so loudly instead of quietly returning a fragment.
            for wav in lost { await store.saveAudioAndWait(wav) }
            if !lost.isEmpty, gen == runGeneration, liveGen == liveGeneration {
                scribeMissedAudio = true
                transcriptionTrouble = "⚠︎ \(lost.count) chunk(s) couldn't be transcribed — audio saved to disk"
                store.log("recorder", "⚠︎ \(lost.count) chunk(s) untranscribed — audio saved in \(store.directory.path)")
            }
        }
        // Re-check after the transcription awaits for the same reason as above.
        guard gen == runGeneration, liveGen == liveGeneration else { return "" }
        listener.captureAudio = false
        let scribe = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = Self.chooseTranscript(scribe: scribe, apple: utterance,
                                           scribeLostAudio: scribeMissedAudio)
        if !scribe.isEmpty, chosen != scribe {
            store.log("recorder", "kept on-device transcript (\(chosen.count) chars) — Scribe only heard \(scribe.count)")
            liveTranscript = chosen   // the Live panel/tools should see what the note sees
        }
        return chosen
    }

    /// Picks the final transcript: Scribe (higher accuracy) when it heard the whole
    /// recording; the on-device transcript when Scribe verifiably lost audio and
    /// Apple heard more — everything at lower accuracy beats a fragment at high
    /// accuracy. Pure/tested.
    nonisolated static func chooseTranscript(scribe: String, apple: String, scribeLostAudio: Bool) -> String {
        let s = scribe.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = apple.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return a }
        if scribeLostAudio, a.count > s.count { return a }
        return s
    }

    /// Atomically takes everything Scribe still owes us: the retry queue plus the
    /// audio captured since the last flush, in spoken order.
    private func drainPendingAudio() -> [Data] {
        var queue = unsentChunks
        unsentChunks = []
        if let wav = listener.takeCapturedWAV() { queue.append(wav) }
        return queue
    }

    /// Transcribes WAVs in spoken order, appending each result to the live
    /// transcript as it lands. Stops at the first failure and returns the
    /// untranscribed remainder (order preserved) so the caller can retry or
    /// persist it. Genuine silence (success, no text) is skipped, not retried.
    private func transcribeInOrder(_ queue: [Data], key: String, gen: Int, liveGen: Int) async -> [Data] {
        for (i, wav) in queue.enumerated() {
            guard gen == runGeneration, liveGen == liveGeneration else { return Array(queue[i...]) }
            do {
                let text = try await ScribeClient(apiKey: key).transcribe(wav: wav, timeout: 60)
                guard gen == runGeneration, liveGen == liveGeneration else { return Array(queue[i...]) }
                if !text.isEmpty {
                    liveTranscript += (liveTranscript.isEmpty ? "" : " ") + text
                    store.log("recorder", "chunk +\(text.count) chars")
                    // Crash insurance: the growing transcript survives a crash,
                    // force-quit, or power loss — not just a graceful stop.
                    store.writeLiveTranscript(liveTranscript)
                }
            } catch ScribeClient.ScribeError.noText {
                continue
            } catch {
                transcriptionTrouble = Self.scribeTroubleMessage(error)
                store.log("scribe", "chunk failed (\(wav.count / 1024)KB, kept for retry): \(error)")
                return Array(queue[i...])
            }
        }
        return []
    }

    /// What the pill shows the moment transcription starts failing. Auth failures
    /// name the likely culprit — a silent 401 once cost a 30-minute recording.
    nonisolated static func scribeTroubleMessage(_ error: Error) -> String {
        let desc = "\(error)"
        if desc.contains("401") || desc.contains("403") {
            return "⚠︎ ElevenLabs rejected the API key (billing or key issue) — audio safe, on-device transcript still running"
        }
        return "⚠︎ transcription failing — audio safe, retrying"
    }

    /// Flushes the captured audio (plus any chunks awaiting retry) through Scribe —
    /// never holding more than the retry queue in memory. A chunk that fails goes
    /// back on the queue; it is never dropped.
    private func flushLiveChunk(final: Bool) {
        guard let key = elevenLabsKey else { return }
        let queue = drainPendingAudio()
        guard !queue.isEmpty else { lastFlushAt = Date(); return }
        flushing = true
        lastFlushAt = Date()
        let gen = runGeneration
        let liveGen = liveGeneration
        flushTask = Task {
            let remaining = await self.transcribeInOrder(queue, key: key, gen: gen, liveGen: liveGen)
            self.flushing = false
            // The session this audio belongs to ended while we were transcribing
            // (stopped, cancelled, or a new recording started). Don't guess which —
            // park the audio on disk; recovery files are cheap and pruned.
            guard gen == self.runGeneration, liveGen == self.liveGeneration else {
                for wav in remaining { await self.store.saveAudioAndWait(wav) }
                if !remaining.isEmpty {
                    self.store.log("scribe", "\(remaining.count) chunk(s) from an ended recording saved in \(self.store.directory.path)")
                }
                return
            }
            if remaining.isEmpty { self.transcriptionTrouble = nil }   // recovered
            self.unsentChunks = remaining + self.unsentChunks
            // Bound memory on a long outage: spill the oldest audio to disk.
            while self.unsentChunks.count > Self.unsentChunksMax {
                let oldest = self.unsentChunks.removeFirst()
                self.scribeMissedAudio = true
                await self.store.saveAudioAndWait(oldest)
                self.store.log("scribe", "retry queue full — chunk saved in \(self.store.directory.path)")
            }
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
    private static let maxTaskRounds = 8   // multi-step web tasks (open→wait→search→wait→click→verify)

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
        var navAttempts: [String: Int] = [:]    // real (non-idempotent) opens per host this goal
        var brokeOut = false                    // stopped early (loop/spin/blocked) — already spoke
        while round < Self.maxTaskRounds, !complete {
            try Task.checkCancellation()
            phase = .thinking
            // A fresh speculative snapshot (taken while the user was still talking)
            // saves the whole AX walk on round 0 — the parse starts immediately.
            let screen: String
            if round == 0, let p = screenPrefetch, p.gen == gen, Date().timeIntervalSince(p.at) < 4 {
                screen = p.text
                screenPrefetch = nil
                store.log("screen", "using prefetched snapshot")
            } else {
                screen = try await gatherScreen(for: text, round: round)
            }
            let context = buildPlannerContext(command: text, taskProgress: performedAll)
            // `vocabulary` is the cached half of the prompt, so only genuinely stable
            // things belong here — the word list and durable facts about the user.
            // Anything that changes between turns goes in `context`/`screen` instead,
            // or it invalidates the cache on every command.
            let stable = [vocabulary.promptContext, knowledge.promptContext]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
            let plan = try await claude.parsePlan(text, dialogue: dialogue,
                                                  vocabulary: stable,
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
            // Intermediate turns keep `say` empty (per the prompt), so awaiting here
            // costs nothing on multi-step tasks and avoids concurrent TTS.
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

            var navigated = false
            var didAct = false
            do {
                let result = try await executeSteps(plan, gen: gen)
                performedAll += result.performed
                navigated = result.navigated
                didAct = !result.performed.isEmpty
                if result.stop { return }       // dictate_start handed the session to the recorder
                // Backstop for the tab-explosion loop: count opens that ACTUALLY spawned
                // a tab (idempotent skips don't set navigated). If a site won't come up
                // after a few real opens, stop instead of burying the user in tabs.
                if navigated, let h = lastNavHost, !h.isEmpty {
                    navAttempts[h, default: 0] += 1
                    if navAttempts[h]! >= 3 {
                        store.log("command", "opened \(h) \(navAttempts[h]!)× without it settling — stopping to avoid spawning more tabs")
                        await speak("I keep opening \(h) but it isn't coming up, so I'll stop instead of opening more tabs. Open it yourself and say Mama when it's ready.", gen: gen)
                        brokeOut = true
                        break
                    }
                }
                // Spin guard: two rounds in a row with no real action AND no observation
                // (e.g. the model keeps "waiting" for something it can't do) — stop.
                let observed = plan.steps.contains { $0.kind == .describeScreen }
                emptyRounds = (result.performed.isEmpty && !observed) ? emptyRounds + 1 : 0
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
            // A navigation forces another observe round even if the model (wrongly)
            // marked the plan complete before the page loaded.
            complete = plan.goalComplete && !navigated
            round += 1
            if !complete, round < Self.maxTaskRounds {
                if navigated {
                    // Opening a site/app: wait until it has actually loaded (changed to
                    // the destination and settled) so the next round sees the real page.
                    await waitForPage(toHost: lastNavHost, requireChange: true, gen: gen, maxWait: 6.0)
                } else if didAct {
                    // Any other action can change the page (submitting a search, clicking
                    // a link) — let it settle, but cap short for a plain click.
                    await waitForPage(toHost: nil, requireChange: false, gen: gen, maxWait: 2.0)
                } else {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
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

    // MARK: Watch-me demonstration

    /// Starts recording the user's clicks/keystrokes as a procedure ("watch me do
    /// this"). Ends on a demo stop phrase; the captured steps become a narrated
    /// procedure the planner follows next time.
    private func startDemonstration(name: String) {
        guard !demonstrating else { return }
        guard ScreenController.isTrusted else {
            phase = .error("Watching needs Accessibility")
            return
        }
        demoName = name
        demonstrating = true
        demo.start()
        phase = .watching
        store.log("teach", "watching demonstration: \(name)")
        Task { await self.speak("Watching. Show me how, then say Mama done.", gen: self.runGeneration) }
    }

    private func finishDemonstration() {
        guard demonstrating else { return }
        demonstrating = false
        let actions = demo.stop()
        phase = mode == .command ? .capturingCommand : .listeningWake
        sessionIdleSince = Date()   // a long demo must not read as session inactivity
        freshUtterance()
        guard !actions.isEmpty else {
            store.log("teach", "demonstration ended — no actions captured")
            Task { await self.speak("I didn't catch any clicks or keys. Try again, or tell me the steps in words.", gen: self.runGeneration) }
            return
        }
        let narration = actions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " ")
        procedures.upsert(Procedure(name: demoName, triggers: [demoName], steps: narration))
        store.log("teach", "learned by demonstration: \(demoName) (\(actions.count) steps) — review in Procedures tab")
        // Secure/unclassifiable typing is auto-hidden; the rest is editable in the
        // Procedures tab, so nudge a review.
        let sensitive = narration.contains(DemonstrationRecorder.redactionMark)
        let tail = sensitive ? " I hid some text I couldn't confirm was safe to store — review the steps in the Procedures tab." : " You can review the steps in the Procedures tab."
        Task { await self.speak("Got it — I learned how to \(self.demoName).\(tail)", gen: self.runGeneration) }
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
    private func executeSteps(_ plan: ActionPlan, gen: Int) async throws -> (performed: [String], stop: Bool, navigated: Bool) {
        var performed: [String] = []
        for (i, step) in plan.steps.enumerated() {
            try Task.checkCancellation()
            switch step.kind {
            case .dictateStart:
                self.startRecording(output: .note)
                return (performed, true, false)
            case .watchStart:
                self.startDemonstration(name: step.target.isEmpty ? "demonstrated action" : step.target)
                return (performed, true, false)   // the demo owns the session until "Mama done"
            case .describeScreen:
                try await self.describeScreen(question: step.target, gen: gen)
            case .none:
                continue
            default:
                self.phase = .acting
                // Idempotent navigation: `open <url>` spawns a NEW browser tab every
                // time — it never reuses the tab already on that site. So if we're
                // already on the target host, re-opening would bury the user in
                // duplicate tabs AND wipe the search/scroll state we just built. Skip
                // the open and keep working the live page. (This is what turned "start
                // over" into 5 blank YouTube tabs.)
                if step.kind == .openURL, let cur = try? await Self.frontURL(),
                   let host = Self.redundantOpenHost(url: step.url.isEmpty ? step.target : step.url, currentURL: cur) {
                    self.store.log("action", "already on \(host) — skipping open (would duplicate the tab)")
                    continue
                }
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
                // Opening a site/app loads ASYNCHRONOUSLY, so END the round here and flag
                // `navigated`: the loop then WAITS for the page to finish loading before
                // it observes again, and any remaining steps this round are deferred to
                // run against the LOADED page. Without this it reads the OLD page and
                // clicks the address bar → searches Google instead of YouTube.
                if step.kind == .openURL || step.kind == .openApp {
                    // Remember where we're going so the loop can wait until the page
                    // actually becomes that site (open_url has the url; open_app has none).
                    lastNavHost = step.kind == .openURL ? Self.domainLabel(step.url.isEmpty ? step.target : step.url) : nil
                    if i < plan.steps.count - 1 { self.store.log("action", "navigated — deferring \(plan.steps.count - 1 - i) step(s) until the page loads") }
                    return (performed, false, true)
                }
            }
        }
        return (performed, false, false)
    }

    /// Waits for the frontmost window to finish loading before the loop observes
    /// again — the user's "wait for the page to load." For a navigation it waits
    /// until the page has actually CHANGED from the pre-nav page and then settled
    /// (and, if we know the destination host, until the URL reflects it) — so it
    /// can't declare the still-showing OLD page "loaded" just because it briefly
    /// looked stable. For a plain UI update it just waits for stability. Bounded,
    /// cancellable, off the main actor.
    private func waitForPage(toHost host: String?, requireChange: Bool, gen: Int, maxWait: TimeInterval) async {
        let start = Date()
        var initial: String? = nil
        var last = ""
        var sleepNs: UInt64 = 50_000_000
        while Date().timeIntervalSince(start) < maxWait {
            try? await Task.sleep(nanoseconds: sleepNs)
            sleepNs = min(sleepNs * 2, 250_000_000)
            guard gen == runGeneration, !Task.isCancelled else { return }
            let snap = try? await withThrowingTaskGroup(of: ScreenController.Snapshot?.self) { group in
                group.addTask { try? ScreenController.focusedWindowSnapshot(maxElements: 25) }
                return try await group.next() ?? nil
            }
            let url = (snap?.url ?? "").lowercased()
            let sig = "\(url)|\(snap?.title ?? "")|\(snap?.elements.count ?? 0)"
            let stable = (sig == last && !sig.isEmpty)
            // Strong signal: the URL is now the destination and has settled.
            if let host, !host.isEmpty, url.contains(host), stable { return }
            if initial == nil { initial = sig; last = sig; continue }   // baseline (pre-load)
            // General: the page has changed from the pre-nav baseline AND settled.
            if stable, (!requireChange || sig != initial) { return }
            last = sig
        }
    }

    /// The frontmost window's current URL, lowercased ("" if none / not a browser).
    /// Used to make open_url idempotent — don't re-open a site we're already on.
    private static func frontURL() async throws -> String {
        let snap = try? await withThrowingTaskGroup(of: ScreenController.Snapshot?.self) { group in
            group.addTask { try? ScreenController.focusedWindowSnapshot(maxElements: 1) }
            return try await group.next() ?? nil
        }
        return (snap?.url ?? "").lowercased()
    }

    /// Returns the target host if opening `url` would be redundant because the
    /// front window is already on it (so the open should be skipped to avoid a
    /// duplicate tab), else nil. Pure/tested.
    nonisolated static func redundantOpenHost(url: String, currentURL: String) -> String? {
        let host = domainLabel(url)
        guard !host.isEmpty, currentURL.lowercased().contains(host) else { return nil }
        return host
    }

    /// The distinctive domain word of a URL for load-matching ("youtube.com" →
    /// "youtube", "https://www.google.com/x" → "google"). Pure/tested.
    nonisolated static func domainLabel(_ url: String) -> String {
        let skip: Set<String> = ["http", "https", "www", "com", "org", "net", "io", "co", "app", "gov", "edu"]
        let tokens = url.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return tokens.first { $0.count > 2 && !skip.contains($0) } ?? ""
    }

    // Speculative snapshot taken mid-utterance so the post-silence path skips the
    // AX walk. Refreshed while the user keeps talking; consumed by round 0 only if
    // it belongs to the same run generation (a Stop/Start or session change must
    // not feed a new command last session's screen).
    private var screenPrefetch: (text: String, at: Date, gen: Int)?
    private var prefetching = false
    private var lastNavHost: String?   // destination domain word of the last open_url, for load-waiting

    private func prefetchScreenIfStale() {
        guard !utterance.isEmpty, Self.needsScreenContext(utterance) else { return }
        if let p = screenPrefetch, Date().timeIntervalSince(p.at) < 1.5 { return }
        guard !prefetching else { return }
        prefetching = true
        let gen = runGeneration
        Task {
            defer { self.prefetching = false }
            // raise:false — the prefetch reads the screen but must not steal focus /
            // raise a window while the user is mid-sentence or a step is acting.
            let text = (try? await self.gatherScreen(for: self.utterance, round: 0, raise: false)) ?? ""
            guard gen == self.runGeneration, !text.isEmpty else { return }
            self.screenPrefetch = (text, Date(), gen)
        }
    }

    /// Reads the focused window (raising the sticky-context window first). Round 0
    /// skips the AX walk for simple commands; later rounds always observe results.
    private func gatherScreen(for text: String, round: Int, raise: Bool = true) async throws -> String {
        guard round > 0 || Self.needsScreenContext(text) else { return "" }
        // Establish the sticky window only on the first round. Re-raising it every
        // round would dismiss a menu/palette/overlay a prior round opened — the loop
        // must read (and act in) whatever the last action produced. `raise` is false
        // for the speculative prefetch (reads only, never steals focus mid-utterance).
        if raise, round == 0, let win = workingContext.window {
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
            // Higher cap so content-heavy pages (a YouTube results grid) surface real
            // targets — video links — not just the site's nav chrome.
            group.addTask { try? ScreenController.focusedWindowSnapshot(maxElements: 100) }
            return try await group.next() ?? nil
        }
        guard let snap else { return "" }
        store.log("screen", "round \(round): read \(snap.elements.count) elements from \(snap.app)")
        return snap.promptText
    }

    private func buildPlannerContext(command: String, taskProgress: [String]) -> String {
        // knowledge.promptContext deliberately excluded — it's stable, so it rides in
        // the cached prefix alongside the vocabulary (see the parsePlan call site).
        // Everything below changes turn to turn.
        var parts = [workingContext.promptText,
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
        case .moveWindow:
            // The moved window is now the working focus (if it was named).
            if !step.target.isEmpty { workingContext.window = step.target }
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

    private var speakEpoch = 0     // the latest speak() owns the state cleanup
    private var bargedIn = false   // the user talked over the TTS
    private var speakingText = ""  // what she's currently saying, for barge-in divergence

    /// Speaks a reply while recognition KEEPS running (continuous listening). The
    /// mic hears her own TTS, so handlePartial ignores the echo of her words but cuts
    /// her off the moment your speech diverges (barge-in). Latest speak wins; `gen`
    /// guards against a Stop→Start that supersedes this run mid-utterance.
    private func speak(_ text: String, gen: Int) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speaker.cancel()            // a stale utterance must not hold the floor
        speakEpoch += 1
        let epoch = speakEpoch
        bargedIn = false
        speaking = true
        speakingText = trimmed      // barge-in compares your words against these
        freshUtterance()            // zero the stream: anything heard from here on is you
        store.log("say", trimmed)
        await speaker.speak(trimmed)
        guard gen == runGeneration, epoch == speakEpoch else { return }
        speaking = false
        speakingText = ""
        if bargedIn {
            bargedIn = false
            // You interrupted: handlePartial already reset the stream, and your
            // continued speech is captured cleanly now that she's silent.
        } else {
            freshUtterance()        // drop any echo remnants heard while talking
        }
        lastHeardAt = Date()
    }

    // How people actually cut in mid-sentence — short words the ">2 chars, need 2"
    // content heuristic would miss entirely. Any ONE of these (that she isn't
    // saying) stops her immediately.
    nonisolated static let bargeInterruptWords: Set<String> = [
        "no", "nope", "stop", "wait", "hold", "hang", "cancel", "quiet", "hush",
        "shush", "enough", "mama", "mom", "nevermind", "actually", "hey"
    ]

    /// True when a partial heard DURING her TTS is you talking over her. Fires on
    /// either (a) an explicit interrupt word she isn't saying — "no", "stop",
    /// "wait", "Mama" — since that's how people actually barge in, or (b) two+
    /// novel content words (a new instruction spoken over her), which the echo of
    /// her own voice can't produce. Pure/tested.
    nonisolated static func isBargeOverTTS(partial: String, tts: String) -> Bool {
        let herWords = Set(normalizedForMatching(tts).split(separator: " ").map(String.init))
        let heard = normalizedForMatching(partial).split(separator: " ").map(String.init)
        if heard.contains(where: { bargeInterruptWords.contains($0) && !herWords.contains($0) }) { return true }
        let novel = heard.filter { $0.count > 2 && !herWords.contains($0) }
        return novel.count >= 2
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

    // MARK: Microphone selection

    func refreshInputDevices() {
        inputDevices = VoiceListener.inputDevices()
    }

    /// Switches the capture device. The tap's format is device-specific, so a
    /// live engine restarts; during a recording the change waits for the stop
    /// (restarting mid-take would drop the mic for a beat).
    func selectMicrophone(uid: String?) {
        micUID = uid
        if let uid { UserDefaults.standard.set(uid, forKey: Self.micKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.micKey) }
        listener.preferredInputUID = uid
        let name = uid.flatMap { u in inputDevices.first { $0.uid == u }?.name } ?? "system default"
        store.log("mic", "selected: \(name)")
        guard isRunning else { return }
        guard mode != .recording else {
            micChangePending = true
            store.log("mic", "change applies after this recording ends")
            return
        }
        listener.stop()
        do { try listener.start() } catch {
            isRunning = false
            phase = .error("\(error)")
            store.log("error", "mic switch failed: \(error)")
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
        var final = raw
        if let claude, cleanUpInsertedText || !rules.isEmpty {
            // Cleanup is for short dictations: past ~8k chars the model's output cap
            // truncates and Haiku drifts into condensing — never risk content for polish.
            if raw.count > 8000 {
                store.log("dictation", "long dictation (\(raw.count) chars) — pasted raw, no cleanup pass")
            } else {
                let cleaned = (try? await claude.cleanUpDictation(raw, vocabulary: vocabulary.promptContext,
                                                                  instructions: rules, cleanup: cleanUpInsertedText)) ?? raw
                // Filler removal shrinks a little; halving means it summarized. Only a
                // paste rule (an explicit reformat) is allowed to shrink that much.
                if rules.isEmpty, raw.count > 400, cleaned.count < raw.count / 2 {
                    store.log("dictation", "cleanup shrank \(raw.count)→\(cleaned.count) chars — pasting raw")
                } else {
                    final = cleaned
                }
            }
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
