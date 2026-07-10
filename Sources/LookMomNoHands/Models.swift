import Foundation

// Shared value types across the app. Kept free of framework imports so any module can use them.

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
    let target: String      // element description or app name ("" when unused)
    let text: String        // text to type ("" when unused)
    let confidence: Double

    // The API returns snake_case-free enum strings; map "dictate_start" etc.
    private enum CodingKeys: String, CodingKey { case kind, target, text, confidence }
}

enum ScrollDirection: String, Sendable {
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
