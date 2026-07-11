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

/// One screen action decoded from the model's forced `emit_action` tool call.
/// `kind` doubles as the intent router: control kinds drive ScreenController,
/// `dictateStart` flips the coordinator into note-taking mode.
struct ScreenAction: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case click                            // click a described UI element
        case type                             // type text at the current focus
        case scroll                           // scroll the frontmost window
        case openApp = "open_app"             // launch/activate an app by name
        case dictateStart = "dictate_start"   // begin a Wisprflow-style dictation session
        case none                             // nothing actionable
    }

    let kind: Kind
    let target: String                  // element description or app name ("" when unused)
    let text: String                    // text to type ("" when unused)
    let direction: ScrollDirection?     // scroll only; the tool schema requires it
    let confidence: Double

    // Tolerant decoding: tool-use inputs aren't strictly schema-enforced server
    // side, so a junk or empty `direction` (or a missing optional-ish field)
    // must degrade to nil/defaults instead of failing the whole command. Only
    // `kind` is load-bearing enough to hard-fail on.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        target = (try? c.decodeIfPresent(String.self, forKey: .target)) ?? ""
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        confidence = (try? c.decodeIfPresent(Double.self, forKey: .confidence)) ?? 0
        let raw = (try? c.decodeIfPresent(String.self, forKey: .direction)) ?? nil
        direction = raw.flatMap { ScrollDirection(rawValue: $0.lowercased()) }
    }

    private enum CodingKeys: String, CodingKey { case kind, target, text, direction, confidence }
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
    case error(String)

    var label: String {
        switch self {
        case .idle: return "Off"
        case .listeningWake: return "Standby — say “Hey Mama”"
        case .capturingCommand: return "Active — listening"
        case .dictating: return "Dictating…"
        case .thinking: return "Thinking…"
        case .acting: return "Acting…"
        case .error(let m): return "Error: \(m)"
        }
    }
}
