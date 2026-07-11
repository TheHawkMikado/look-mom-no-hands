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
        case keystroke                        // press a shortcut like "cmd+t"
        case dictateStart = "dictate_start"   // begin a Wisprflow-style dictation session
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
    let confidence: Double
    /// A step failed to decode (e.g. unknown kind). Steps are ordered and can
    /// depend on each other, so the coordinator must refuse to run a plan with a
    /// hole rather than execute the survivors against the wrong context.
    let malformed: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        say = (try? c.decodeIfPresent(String.self, forKey: .say)) ?? ""
        // Decode element-by-element so one bad step doesn't blank the whole array
        // (which would read as an empty, silently-successful plan) — but record
        // that a drop happened so execution can fail closed.
        let raw = (try? c.decodeIfPresent([FailableStep].self, forKey: .steps)) ?? []
        steps = raw.compactMap(\.value)
        malformed = steps.count != raw.count
        clarify = try? c.decodeIfPresent(Clarification.self, forKey: .clarify)
        confidence = (try? c.decodeIfPresent(Double.self, forKey: .confidence)) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case say, steps, clarify, confidence }

    /// Never throws out of an array decode — a bad element becomes nil.
    private struct FailableStep: Decodable {
        let value: ScreenAction?
        init(from decoder: Decoder) throws { value = try? ScreenAction(from: decoder) }
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

/// The Wisprflow-style report produced at the end of a dictation session.
struct DictationReport: Decodable, Sendable {
    let summary: String
    let actionItems: [String]
    let transcript: String

    private enum CodingKeys: String, CodingKey {
        case summary
        case actionItems = "action_items"
        case transcript
    }
}

/// High-level app state surfaced in the menu bar.
enum AppPhase: Equatable, Sendable {
    case idle                 // waiting for the wake word
    case listeningWake        // wake engine warming/running
    case capturingCommand     // recording a one-shot command
    case dictating            // recording a long note
    case thinking             // Claude call in flight
    case acting               // executing a screen action
    case clarifying           // asked the user a question; listening for the answer
    case error(String)

    var label: String {
        switch self {
        case .idle: return "Off"
        case .listeningWake: return "Standby — say “Hey Mama”"
        case .capturingCommand: return "Active — listening"
        case .dictating: return "Dictating…"
        case .thinking: return "Thinking…"
        case .acting: return "Acting…"
        case .clarifying: return "Waiting for your answer…"
        case .error(let m): return "Error: \(m)"
        }
    }
}
