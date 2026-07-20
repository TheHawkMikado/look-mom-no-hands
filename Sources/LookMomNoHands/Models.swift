import Foundation

// Shared value types across the app. Kept free of framework imports so any module can use them.

/// Single home for the app's identity strings. The public face says "Ma" while
/// the binary/bundle says "Mom"; that split already shipped (storage folder,
/// keychain service, manual keychain items), so these values are frozen —
/// changing any of them strands existing users' data or TCC grants.
enum AppIdentity {
    static let displayName = "Look Ma, No Hands"
    static let storageFolder = "LookMaNoHands"              // under ~/Library/Application Support/
    static let keychainService = "com.lookmomnohands.anthropic"
    static let manualKeychainNames = ["Look Ma No Hands", "Look Mom No Hands"]
    static let storeQueueLabel = "com.lookmomnohands.store.io"
}

/// One step decoded from the model's forced `emit_plan` tool call.
/// `kind` doubles as the intent router: control kinds drive ScreenController,
/// `dictateStart` flips the coordinator into note-taking mode.
struct ScreenAction: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case click                            // click a described UI element
        case type                             // type text at the current focus
        case scroll                           // scroll the frontmost window
        case openApp = "open_app"             // launch/activate an app by name
        case openURL = "open_url"             // open a website (optionally in a named browser)
        case focusWindow = "focus_window"     // raise a specific open window by its title/app
        case moveWindow = "move_window"       // move a window to another display
        case switchTab = "switch_tab"         // switch to a browser tab by its title
        case keystroke                        // press a shortcut like "cmd+t"
        case dictateStart = "dictate_start"   // begin a Wisprflow-style dictation session
        case describeScreen = "describe_screen" // read/answer about what's on screen (vision)
        case watchStart = "watch_start"       // record the user's demonstration as a procedure
        case spawnBackgroundAgent = "spawn_background_agent" // runs a headless background agent
        case none                             // nothing actionable
    }

    let kind: Kind
    let target: String                  // element description / app name ("" when unused)
    let text: String                    // text to type ("" when unused)
    let url: String                     // open_url only ("" when unused)
    let keys: String                    // keystroke only, e.g. "cmd+shift+t"
    let prompt: String                  // spawn_background_agent only ("" when unused)
    let direction: ScrollDirection?     // scroll only; the tool schema requires it

    // Tolerant decoding: tool-use inputs aren't strictly schema-enforced server
    // side, so a junk or empty field must degrade to nil/defaults instead of
    // failing the whole plan. Only `kind` is load-bearing enough to hard-fail on.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        target = (try? c.decodeIfPresent(String.self, forKey: .target)) ?? ""
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
        keys = (try? c.decodeIfPresent(String.self, forKey: .keys)) ?? ""
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? ""
        let raw = (try? c.decodeIfPresent(String.self, forKey: .direction)) ?? nil
        direction = raw.flatMap { ScrollDirection(rawValue: $0.lowercased()) }
    }

    private enum CodingKeys: String, CodingKey { case kind, target, text, url, keys, prompt, direction }
}

/// The model's full response to one spoken request: an ordered list of steps,
/// a short sentence to speak back, and — when the request was too ambiguous to
/// act on — a clarification question instead of steps.
struct ActionPlan: Decodable, Sendable {
    let say: String                     // spoken reply ("" = say nothing)
    let steps: [ScreenAction]
    let clarify: Clarification?         // set ⇒ steps is empty; ask before acting
    let learn: LearnedFact?             // a durable mapping the user just taught/corrected
    let teach: TaughtProcedure?         // a task the user just taught how to do
    let remember: String                // a durable fact to store ("" = none)
    let confidence: Double
    /// The act-observe loop's stop signal: the model sets this true once the user's
    /// goal is fully achieved. While false (and steps ran), the coordinator re-reads
    /// the screen and asks for the next actions — so a task like "create a new
    /// session" continues into the panel it just opened instead of stopping there.
    let goalComplete: Bool
    /// The model gave up: it can't make progress toward the goal. Distinct from
    /// goal_complete so a failed task is recorded as incomplete, not a false success.
    let blocked: Bool
    /// A step failed to decode (e.g. unknown kind). Steps are ordered and can
    /// depend on each other, so the coordinator must refuse to run a plan with a
    /// hole rather than execute the survivors against the wrong context.
    let malformed: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        say = (try? c.decodeIfPresent(String.self, forKey: .say)) ?? ""
        learn = try? c.decodeIfPresent(LearnedFact.self, forKey: .learn)
        teach = try? c.decodeIfPresent(TaughtProcedure.self, forKey: .teach)
        remember = (try? c.decodeIfPresent(String.self, forKey: .remember)) ?? ""
        // Decode element-by-element so one bad step doesn't blank the whole array
        // (which would read as an empty, silently-successful plan) — but record
        // that anything was dropped so execution can fail closed. A `steps` field
        // that's present but not an array (schema drift) is malformed too, not a
        // clean empty plan.
        if c.contains(.steps), (try? c.decodeNil(forKey: .steps)) == false {
            if let raw = try? c.decode([FailableStep].self, forKey: .steps) {
                steps = raw.compactMap(\.value)
                malformed = steps.count != raw.count
            } else {
                steps = []
                malformed = true   // present but not a decodable array
            }
        } else {
            steps = []             // genuinely absent or null
            malformed = false
        }
        clarify = try? c.decodeIfPresent(Clarification.self, forKey: .clarify)
        confidence = (try? c.decodeIfPresent(Double.self, forKey: .confidence)) ?? 0
        // Default false so the loop keeps going toward completion; the round cap and
        // the empty-steps break prevent runaway if the model omits it.
        goalComplete = (try? c.decodeIfPresent(Bool.self, forKey: .goalComplete)) ?? false
        blocked = (try? c.decodeIfPresent(Bool.self, forKey: .blocked)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case say, steps, clarify, learn, teach, remember, blocked, confidence
        case goalComplete = "goal_complete"
    }

    /// Never throws out of an array decode — a bad element becomes nil.
    private struct FailableStep: Decodable {
        let value: ScreenAction?
        init(from decoder: Decoder) throws { value = try? ScreenAction(from: decoder) }
    }
}

/// A durable mapping the user taught the assistant ("when I say Chrome I mean
/// Google Chrome"), captured into their vocabulary so it applies from then on.
struct LearnedFact: Decodable, Sendable {
    let spoken: String
    let written: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spoken = (try? c.decodeIfPresent(String.self, forKey: .spoken)) ?? ""
        written = (try? c.decodeIfPresent(String.self, forKey: .written)) ?? ""
    }
    private enum CodingKeys: String, CodingKey { case spoken, written }

    var isValid: Bool {
        !spoken.trimmingCharacters(in: .whitespaces).isEmpty
        && !written.trimmingCharacters(in: .whitespaces).isEmpty
        && spoken.lowercased() != written.lowercased()
    }
}

/// An on-screen (and spoken) question the model asks when a request needs
/// interpretation it isn't confident about.
struct Clarification: Decodable, Sendable {
    let question: String
    let options: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = try c.decode(String.self, forKey: .question)
        options = (try? c.decodeIfPresent([String].self, forKey: .options)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case question, options }

    /// Spoken form: just the question. The options are shown on the clarify panel —
    /// reading them all aloud is the "blah blah blah" that makes her feel long-winded.
    var spoken: String { question }
}

enum ScrollDirection: String, Decodable, Sendable {
    case up, down, left, right
}

/// What the recorder does with a finished transcript. `note` runs the active
/// processing profile into a saved report; `insert` cleans it and pastes at the
/// cursor (+ clipboard); `both` does both. One recorder, output chosen per run.
enum RecorderOutput: Sendable, Equatable {
    case insert
    case note
    case both

    var producesNote: Bool { self == .note || self == .both }
    var producesInsert: Bool { self == .insert || self == .both }
    var label: String {
        switch self {
        case .insert: return "Insert at cursor"
        case .note: return "Save as note"
        case .both: return "Insert + note"
        }
    }
}

/// A per-app instruction for how to format text before it's pasted (insert mode).
/// E.g. app "Code" → "format as a clear prompt with numbered steps." Applied on top
/// of the general insert instruction.
struct InsertRule: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var app: String            // matched against the target app's name (contains, case-insensitive)
    var instructions: String

    init(id: String = UUID().uuidString, app: String, instructions: String) {
        self.id = id
        self.app = app.trimmingCharacters(in: .whitespacesAndNewlines)
        // NOT trimmed: this is edited live through a Binding, and trimming on every
        // keystroke strips a trailing space before the next character can arrive.
        self.instructions = instructions
    }
}

/// A durable fact the assistant knows about the user or their setup ("my main
/// project is look-mom-no-hands", "I use Brave", "my work email is …"). Fed into
/// every command so it doesn't have to be re-told. The "general memory."
struct KnowledgeFact: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var text: String
    let createdAt: Date

    init(id: String = UUID().uuidString, text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
    }
}

/// A task the user has taught the assistant how to do ("here's how I create a new
/// Claude Code session: …"). Stored and, when a command matches its triggers, fed
/// to the planner as the authoritative recipe so it follows the user's process.
/// An ever-growing, editable library of actions.
struct Procedure: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var triggers: [String]   // phrases that should invoke it
    var steps: String        // the narrated process, in order
    let createdAt: Date

    init(id: String = UUID().uuidString, name: String, triggers: [String] = [], steps: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.triggers = triggers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.steps = steps.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
    }
}

/// A procedure the user just taught, decoded from the planner's `teach` output.
struct TaughtProcedure: Decodable, Sendable {
    let name: String
    let triggers: [String]
    let steps: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        triggers = (try? c.decodeIfPresent([String].self, forKey: .triggers)) ?? []
        steps = (try? c.decodeIfPresent(String.self, forKey: .steps)) ?? ""
    }
    private enum CodingKeys: String, CodingKey { case name, triggers, steps }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !steps.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// A named set of instructions that shapes how a recording is turned into a note
/// — "what to extract and when." The user picks the active one; its `instructions`
/// are injected into the report prompt (title/summary/points/actions still frame
/// the output, the instructions steer emphasis and what counts as a point/action).
struct ProcessingProfile: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var instructions: String
    let builtIn: Bool

    init(id: String = UUID().uuidString, name: String, instructions: String, builtIn: Bool = false) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.builtIn = builtIn
    }

    /// Seeded on first run; the user can edit/duplicate/add their own.
    static let seeds: [ProcessingProfile] = [
        ProcessingProfile(id: "builtin.general", name: "General note", builtIn: true, instructionsText:
            "A clear title, a 2–3 sentence summary, the key points, and any concrete action items (with an owner and date when stated)."),
        ProcessingProfile(id: "builtin.meeting", name: "Meeting", builtIn: true, instructionsText:
            "Treat this as meeting notes. Summary of what was discussed, decisions made, action items with owners and due dates, and any open questions. List attendees if named."),
        ProcessingProfile(id: "builtin.tasks", name: "Task list", builtIn: true, instructionsText:
            "Extract a checklist of concrete to-dos, each as a short imperative bullet under action items. Keep the summary to one line. Ignore filler."),
        ProcessingProfile(id: "builtin.idea", name: "Idea / brainstorm", builtIn: true, instructionsText:
            "Capture the core idea in the summary, then list every distinct thought as a key point. Only include action items if a concrete next step was stated."),
        ProcessingProfile(id: "builtin.journal", name: "Journal", builtIn: true, instructionsText:
            "A reflective title and a faithful prose summary in the first person. Key points optional; usually no action items.")
    ]

    // Convenience init used only by the seeds above (keeps them readable).
    private init(id: String, name: String, builtIn: Bool, instructionsText: String) {
        self.init(id: id, name: name, instructions: instructionsText, builtIn: builtIn)
    }
}

/// One entry in the user's vocabulary — the unified store behind "dictionary"
/// (recognize/spell terms), "corrections" (fix consistent mishearings), and
/// "snippets" (expand a spoken trigger). All three are the same shape (a spoken
/// form → a written form) and are applied by the model, not brittle text
/// replacement, so they compose with the rest of the sentence.
struct VocabEntry: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case word         // a name/term to spell right and bias recognition ("Styku")
        case correction   // a consistent mishearing to fix ("stycu" → "Styku")
        case snippet      // a spoken shortcut to expand ("my email" → "me@x.com")
    }
    let id: String
    var kind: Kind
    var spoken: String    // word text / misheard phrase / trigger phrase
    var written: String   // "" for a plain word; the correct/expanded text otherwise
    let date: Date

    init(kind: Kind, spoken: String, written: String = "") {
        self.id = UUID().uuidString
        self.kind = kind
        self.spoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.written = written.trimmingCharacters(in: .whitespacesAndNewlines)
        self.date = Date()
    }

    /// The display term (what the recognizer should be biased toward).
    var biasTerm: String { written.isEmpty ? spoken : written }
}

/// Which speech-to-text engine transcribes captured utterances. Apple on-device
/// always runs the always-on wake-word + silence gating regardless — this only
/// controls the higher-quality re-transcription of the actual command/dictation.
enum SpeechEngine: String, CaseIterable, Sendable {
    case appleOnly          // on-device for everything (free, private, fastest)
    case scribeDictation    // Scribe for notes, Apple for commands (default)
    case scribeAll          // Scribe for commands + notes (max accuracy, +latency)

    var label: String {
        switch self {
        case .appleOnly: return "Apple on-device (everywhere)"
        case .scribeDictation: return "ElevenLabs for dictation"
        case .scribeAll: return "ElevenLabs for commands + dictation"
        }
    }

    func usesScribe(forDictation dictation: Bool) -> Bool {
        switch self {
        case .appleOnly: return false
        case .scribeDictation: return dictation
        case .scribeAll: return true
        }
    }
}

/// The VoiceDash-style report produced at the end of a dictation session.
struct DictationReport: Decodable, Sendable {
    let title: String
    let summary: String
    let keyPoints: [String]
    let actionItems: [String]
    let transcript: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerant like the other model outputs: a missing field degrades rather
        // than throwing away the whole report.
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        keyPoints = (try? c.decodeIfPresent([String].self, forKey: .keyPoints)) ?? []
        actionItems = (try? c.decodeIfPresent([String].self, forKey: .actionItems)) ?? []
        transcript = (try? c.decodeIfPresent(String.self, forKey: .transcript)) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case summary
        case keyPoints = "key_points"
        case actionItems = "action_items"
        case transcript
    }
}

// MARK: - Environment awareness

/// A single open window (with its browser tabs, when the app exposes them).
struct EnvWindow: Sendable, Equatable, Identifiable {
    let app: String
    let title: String
    let focused: Bool          // the app's focused/main window
    var tabs: [String] = []    // browser tabs, empty otherwise
    var activeTab: String? = nil
    var display: Int = 0       // 0 = main display, 1 = second, …
    var id: String { "\(app)›\(title)" }
}

/// One running app and its windows. Grouped from the flat window list so the
/// planner and dashboard see the screen→app→window→tab hierarchy the user wants.
struct EnvApp: Sendable, Equatable, Identifiable {
    let name: String
    let bundleID: String?
    let active: Bool           // frontmost app
    var windows: [EnvWindow]
    var id: String { name }
}

/// A point-in-time picture of everything open. Rebuilt on a timer so the app
/// "knows" what's available even when it isn't actively listening.
struct EnvSnapshot: Sendable, Equatable {
    var apps: [EnvApp] = []
    var displayCount: Int = 1

    /// Compact rendering for the planner. Capped — this rides on the latency-
    /// critical command path, so a machine with 30 apps open can't bloat the prompt.
    var promptText: String {
        guard !apps.isEmpty else { return "" }
        var s = "Open apps and windows right now:"
        if displayCount > 1 {
            s += " (\(displayCount) displays; windows marked [display N] are on that display, unmarked are on the main one — move_window relocates them)"
        }
        for app in apps.prefix(14) {
            s += "\n- \(app.name)\(app.active ? " (frontmost)" : "")"
            for w in app.windows.prefix(8) where !w.title.isEmpty {
                s += "\n    • \(w.title.prefix(100))\(w.focused ? " (focused)" : "")\(w.display > 0 ? " [display \(w.display + 1)]" : "")"
                if !w.tabs.isEmpty {
                    let shown = w.tabs.prefix(12).map { $0.prefix(60) }.joined(separator: " | ")
                    s += "\n        tabs: \(shown)\(w.tabs.count > 12 ? " …+\(w.tabs.count - 12)" : "")"
                }
            }
        }
        if apps.count > 14 { s += "\n- …and \(apps.count - 14) more apps" }
        return s
    }
}

/// The sticky focus the user is working in: once set ("go to the X window"),
/// every command applies here until they switch. Screen→app→window→tab.
struct WorkingContext: Sendable, Equatable {
    var app: String? = nil
    var window: String? = nil
    var tab: String? = nil

    var isEmpty: Bool { app == nil && window == nil && tab == nil }

    var promptText: String {
        guard !isEmpty else { return "" }
        var parts: [String] = []
        if let app { parts.append("app “\(app)”") }
        if let window { parts.append("window “\(window)”") }
        if let tab { parts.append("tab “\(tab)”") }
        return "Working context (act here unless I name a different target): " + parts.joined(separator: ", ") + "."
    }

    var label: String {
        guard !isEmpty else { return "No focus set" }
        return [app, window, tab].compactMap { $0 }.joined(separator: " › ")
    }
}

/// High-level app state surfaced in the menu bar.
enum AppPhase: Equatable, Sendable {
    case idle                 // waiting for the wake word
    case listeningWake        // wake engine warming/running
    case capturingCommand     // recording a one-shot command
    case recording            // recording a note/dictation (any length)
    case thinking             // Claude call in flight
    case acting               // executing a screen action
    case clarifying           // asked the user a question; listening for the answer
    case watching             // recording the user's demonstration of a task
    case error(String)

    var label: String {
        switch self {
        case .idle: return "Off"
        case .listeningWake: return "Standby — say “Hey Mama”"
        case .capturingCommand: return "Active — listening"
        case .recording: return "Recording…"
        case .thinking: return "Thinking…"
        case .acting: return "Acting…"
        case .clarifying: return "Waiting for your answer…"
        case .watching: return "Watching your demonstration — say “Mama done” to finish"
        case .error(let m): return "Error: \(m)"
        }
    }
}
