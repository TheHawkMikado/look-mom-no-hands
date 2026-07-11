import Foundation

// Talks to the Anthropic Messages API directly over URLSession — no SDK exists for Swift.
// Two structured-output paths:
//   1. parseCommand(...)        → forced tool use, fast, thinking off  (screen control + intent routing)
//   2. buildDictationReport(...) → output_config.format json_schema, thinking on  (Wisprflow-style report)
// Model choice: Haiku 4.5 on the command hot path (latency), Opus 4.8 for reports (quality).

enum ClaudeModel: String, Sendable {
    case opus48 = "claude-opus-4-8"      // default brain: planning, summaries
    case haiku45 = "claude-haiku-4-5"    // fast path: command parsing

    // Request shape is gated on these instead of comments at call sites, so a
    // model swap can't reintroduce the "Haiku rejects `effort` with a 400" bug.
    var supportsAdaptiveThinking: Bool { self == .opus48 }
    var supportsEffort: Bool { self == .opus48 }
}

enum ClaudeError: Error, CustomStringConvertible {
    case http(status: Int, body: String)
    case refusal(category: String?)
    case noToolUse
    case decoding(String)

    var description: String {
        switch self {
        case .http(let s, let b): return "HTTP \(s): \(b.prefix(200))"
        case .refusal(let c): return "refused (\(c ?? "policy"))"
        case .noToolUse: return "model returned no tool call"
        case .decoding(let m): return "decoding: \(m)"
        }
    }
}

final class ClaudeClient: @unchecked Sendable {
    private let apiKey: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    // Store the key in Keychain and pass it in — never hard-code it into the app bundle.
    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: Plan parsing + intent routing (forced tool use)

    /// `dialogue` carries a pending clarification exchange: earlier turns as
    /// (role, content) pairs, ending before the current transcript.
    func parsePlan(_ transcript: String, dialogue: [(role: String, content: String)] = [],
                   vocabulary: String = "", screen: String = "") async throws -> ActionPlan {
        let json = try await post(Self.planRequestBody(transcript: transcript, dialogue: dialogue,
                                                        vocabulary: vocabulary, screen: screen, model: .haiku45), timeout: 20)
        try Self.checkRefusal(json)
        return try Self.decodeBlock(json, blockType: "tool_use", payloadKey: "input")
    }

    static func planRequestBody(transcript: String,
                                dialogue: [(role: String, content: String)] = [],
                                vocabulary: String = "",
                                screen: String = "",
                                model: ClaudeModel) -> [String: Any] {
        let step: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "kind": ["type": "string",
                         "enum": ["click", "type", "scroll", "open_app", "open_url", "focus_window", "keystroke", "dictate_start", "none"]],
                "target": ["type": "string", "description": "UI element / app name; for open_url optionally the browser; for focus_window the window description to match (e.g. \"the look-mom-no-hands VS Code\"); empty if unused"],
                "text": ["type": "string", "description": "text to type; empty if unused"],
                "url": ["type": "string", "description": "open_url only: the website, e.g. \"youtube.com\"; empty if unused"],
                "keys": ["type": "string", "description": "keystroke only: shortcut like \"cmd+t\", \"cmd+shift+t\", \"enter\"; empty if unused"],
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"],
                              "description": "Scroll direction. For scroll this controls the action; for every other kind emit \"down\" (ignored)."]
            ],
            // Everything required: without strict mode the model may omit
            // non-required fields, and execution needs the ""-when-unused
            // convention to hold.
            "required": ["kind", "target", "text", "url", "keys", "direction"]
        ]

        let tool: [String: Any] = [
            "name": "emit_plan",
            "description": """
            Interpret the user's spoken request and emit ONE plan. A long request may \
            contain several action items — emit one step per item, in the order they \
            should run. Prefer open_url for websites ("open YouTube" means youtube.com \
            unless a macOS app by that name plainly exists), open_app for applications, \
            focus_window when the user names a specific already-open window ("go to the \
            look-mom-no-hands VS Code") — put their description in target, keystroke for \
            app shortcuts (new tab = cmd+t; submit/send = enter), type to enter text, \
            click/type/scroll for direct screen control. To type into a named window, \
            emit focus_window first, then type, then keystroke "enter" if they say submit/ \
            send. Use a single dictate_start step for note-taking. Use a single none step \
            when nothing is actionable.

            If the request is ambiguous or you are not confident what the user wants, \
            emit NO steps and set clarify with one concise question and 2-4 short \
            answer options — do not guess. When the user's latest message answers a \
            previous clarification question, act on it; if they decline, emit no steps \
            and a brief acknowledging say.

            say: one short spoken sentence confirming what you're doing or reporting; \
            empty for a single obvious action.
            """,
            // No `strict: true` — forced tool_choice already guarantees the call,
            // and strict adds a server-side schema-compilation latency spike on
            // first use, which is exactly the hot path we want fast.
            "input_schema": [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "say": ["type": "string"],
                    "steps": ["type": "array", "items": step],
                    "clarify": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "question": ["type": "string"],
                            "options": ["type": "array", "items": ["type": "string"]]
                        ],
                        "required": ["question", "options"]
                    ],
                    "confidence": ["type": "number"]
                ],
                "required": ["say", "steps", "confidence"]
            ]
        ]

        var messages: [[String: Any]] = dialogue.map { ["role": $0.role, "content": $0.content] }
        messages.append(["role": "user", "content": "Spoken request: \"\(transcript)\""])

        // No effort/thinking on this path regardless of model — latency-critical.
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 2048,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "emit_plan"],
            "messages": messages
        ]
        let system = [vocabulary, screen].filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !system.isEmpty { body["system"] = system }
        return body
    }

    // MARK: Dictation report (output_config.format + adaptive thinking where supported)

    func buildDictationReport(_ rawTranscript: String, vocabulary: String = "") async throws -> DictationReport {
        let json = try await post(Self.reportRequestBody(transcript: rawTranscript, vocabulary: vocabulary, model: .opus48))
        try Self.checkRefusal(json)
        return try Self.decodeBlock(json, blockType: "text", payloadKey: "text")
    }

    static func reportRequestBody(transcript: String, vocabulary: String = "", model: ClaudeModel) -> [String: Any] {
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "title": ["type": "string"],
                "summary": ["type": "string"],
                "key_points": ["type": "array", "items": ["type": "string"]],
                "action_items": ["type": "array", "items": ["type": "string"]],
                "transcript": ["type": "string"]
            ],
            "required": ["title", "summary", "key_points", "action_items", "transcript"]
        ]

        var outputConfig: [String: Any] = [
            "format": ["type": "json_schema", "schema": schema]
        ]
        if model.supportsEffort { outputConfig["effort"] = "medium" }

        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 16000,
            "output_config": outputConfig,
            "messages": [[
                "role": "user",
                "content": """
                Turn this raw dictation into a structured report:
                - title: a short (3-8 word) headline naming what this note is about.
                - summary: a tight TLDR (1-3 sentences).
                - key_points: the main ideas as short bullets (empty if none).
                - action_items: concrete to-dos as short bullets (empty if none).
                - transcript: the dictation lightly cleaned up (fix obvious ASR errors, \
                remove filler, keep the meaning and wording).

                Dictation:
                \(transcript)
                """
            ]]
        ]
        if model.supportsAdaptiveThinking { body["thinking"] = ["type": "adaptive"] }
        if !vocabulary.isEmpty { body["system"] = vocabulary }
        return body
    }

    // MARK: Dictation-insert cleanup (fast, plain text out)

    /// Lightly cleans dictated text for pasting at the cursor: fixes obvious ASR
    /// errors, adds punctuation/capitalization, drops filler — keeps the wording.
    /// Haiku for latency (this sits directly in front of a paste). Returns the
    /// cleaned text, or throws so the caller can paste the raw transcript.
    func cleanUpDictation(_ raw: String, vocabulary: String = "") async throws -> String {
        var body: [String: Any] = [
            "model": ClaudeModel.haiku45.rawValue,
            "max_tokens": 4000,
            "messages": [[
                "role": "user",
                "content": """
                Clean up this dictated text so it can be pasted as-is: fix obvious \
                speech-to-text errors, add sensible punctuation and capitalization, \
                and remove filler words and false starts (um, uh, "like", repeated \
                words). Keep the user's wording and meaning — do NOT summarize, \
                rephrase, or add anything. Output ONLY the cleaned text.

                \(raw)
                """
            ]]
        ]
        if !vocabulary.isEmpty { body["system"] = vocabulary }
        let json = try await post(body, timeout: 15)
        try Self.checkRefusal(json)
        guard let text = Self.firstTextBlock(json), !text.isEmpty else {
            throw ClaudeError.decoding("no text block")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstTextBlock(_ json: [String: Any]) -> String? {
        (json["content"] as? [[String: Any]])?
            .first { $0["type"] as? String == "text" }?["text"] as? String
    }

    // MARK: - Response unpacking

    // Both endpoints unpack "first block of a type → decode its payload" — one
    // implementation so response-shape fixes land everywhere at once.
    static func decodeBlock<T: Decodable>(_ json: [String: Any], blockType: String, payloadKey: String) throws -> T {
        guard let content = json["content"] as? [[String: Any]],
              let block = content.first(where: { $0["type"] as? String == blockType }),
              let payload = block[payloadKey] else {
            if blockType == "tool_use" { throw ClaudeError.noToolUse }
            throw ClaudeError.decoding("no \(blockType) block")
        }
        let data: Data
        if let text = payload as? String {
            data = Data(text.utf8)
        } else {
            data = try JSONSerialization.data(withJSONObject: payload)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Transport

    private func post(_ body: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout               // fail fast instead of hanging
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ClaudeError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.decoding("response not an object")
        }
        return json
    }

    // Safety classifiers return HTTP 200 with stop_reason == "refusal" — check before reading content.
    private static func checkRefusal(_ json: [String: Any]) throws {
        if json["stop_reason"] as? String == "refusal" {
            let category = (json["stop_details"] as? [String: Any])?["category"] as? String
            throw ClaudeError.refusal(category: category)
        }
    }
}
