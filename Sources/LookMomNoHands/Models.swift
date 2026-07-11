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
        case switchTab = "switch_tab"         // switch to a browser tab by its title
        case keystroke                        // press a shortcut like "cmd+t"
        case dictateStart = "dictate_start"   // begin a Wisprflow-style dictation session
        case describeScreen = "describe_screen" // read/answer about what's on screen (vision)
        case none                             // nothing actionable
    }

    let kind: Kind
    let target: String                  // element description / app name ("" when unused)
    let text: String                    // text to type ("" when unused)
    let url: String                     // open_url only ("" when unused)
    let keys: String                    // keystroke only, e.g. "cmd+shift+t"
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
        let raw = (try? c.decodeIfPresent(String.self, forKey: .direction)) ?? nil
        direction = raw.flatMap { ScrollDirection(rawValue: $0.lowercased()) }
    }

    private enum CodingKeys: String, CodingKey { case kind, target, text, url, keys, direction }
}

/// The model's full response to one spoken request: an ordered list of steps,
/// a short sentence to speak back, and — when the request was too ambiguous to
/// act on — a clarification question instead of steps.
struct ActionPlan: Decodable, Sendable {
    let say: String                     // spoken reply ("" = say nothing)
    let steps: [ScreenAction]
    let clarify: Clarification?         // set ⇒ steps is empty; ask before acting
    let learn: LearnedFact?             // a durable mapping the user just taught/corrected
    let confidence: Double
    /// A step failed to decode (e.g. unknown kind). Steps are ordered and can
    /// depend on each other, so the coordinator must refuse to run a plan with a
    /// hole rather than execute the survivors against the wrong context.
    let malformed: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        say = (try? c.decodeIfPresent(String.self, forKey: .say)) ?? ""
        learn = try? c.decodeIfPresent(LearnedFact.self, forKey: .learn)
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
    }

    private enum CodingKeys: String, CodingKey { case say, steps, clarify, learn, confidence }

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

    /// Question plus its options, phrased for text-to-speech.
    var spoken: String {
        guard !options.isEmpty else { return question }
        return question + " Options: " + options.joined(separator: ", ") + "."
    }
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

    /// Compact rendering for the planner. Capped — this rides on the latency-
    /// critical command path, so a machine with 30 apps open can't bloat the prompt.
    var promptText: String {
        guard !apps.isEmpty else { return "" }
        var s = "Open apps and windows right now:"
        for app in apps.prefix(14) {
            s += "\n- \(app.name)\(app.active ? " (frontmost)" : "")"
            for w in app.windows.prefix(8) where !w.title.isEmpty {
                s += "\n    • \(w.title.prefix(100))\(w.focused ? " (focused)" : "")"
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
        case .error(let m): return "Error: \(m)"
        }
    }
}
