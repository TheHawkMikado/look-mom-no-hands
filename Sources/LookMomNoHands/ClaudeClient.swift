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

    // MARK: Screen-action parsing + intent routing (forced tool use)

    func parseCommand(_ transcript: String) async throws -> ScreenAction {
        let json = try await post(Self.commandRequestBody(transcript: transcript, model: .haiku45), timeout: 15)
        try Self.checkRefusal(json)
        return try Self.decodeBlock(json, blockType: "tool_use", payloadKey: "input")
    }

    static func commandRequestBody(transcript: String, model: ClaudeModel) -> [String: Any] {
        let tool: [String: Any] = [
            "name": "emit_action",
            "description": """
            Interpret the user's spoken command and emit exactly one action.
            Use "dictate_start" when they want to take a note or dictate a passage rather than \
            control the screen. Use "none" if nothing is actionable.
            """,
            // No `strict: true` — forced tool_choice already guarantees the call,
            // and strict adds a server-side schema-compilation latency spike on
            // first use, which is exactly the hot path we want fast.
            "input_schema": [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "kind": ["type": "string",
                             "enum": ["click", "type", "scroll", "open_app", "dictate_start", "none"]],
                    "target": ["type": "string", "description": "UI element or app name; empty if unused"],
                    "text": ["type": "string", "description": "text to type; empty if unused"],
                    "direction": ["type": "string", "enum": ["up", "down", "left", "right"],
                                  "description": "Scroll direction. For scroll this controls the action; for every other kind emit \"down\" (ignored)."],
                    "confidence": ["type": "number"]
                ],
                // `direction` is required unconditionally: without strict mode the
                // model may omit non-required fields, and a scroll without a
                // direction hard-fails at execution.
                "required": ["kind", "target", "text", "direction", "confidence"]
            ]
        ]

        // No effort/thinking on this path regardless of model — latency-critical.
        return [
            "model": model.rawValue,
            "max_tokens": 1024,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "emit_action"],
            "messages": [["role": "user", "content": "Spoken command: \"\(transcript)\""]]
        ]
    }

    // MARK: Dictation report (output_config.format + adaptive thinking where supported)

    func buildDictationReport(_ rawTranscript: String) async throws -> DictationReport {
        let json = try await post(Self.reportRequestBody(transcript: rawTranscript, model: .opus48))
        try Self.checkRefusal(json)
        return try Self.decodeBlock(json, blockType: "text", payloadKey: "text")
    }

    static func reportRequestBody(transcript: String, model: ClaudeModel) -> [String: Any] {
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "summary": ["type": "string"],
                "action_items": ["type": "array", "items": ["type": "string"]],
                "transcript": ["type": "string"]
            ],
            "required": ["summary", "action_items", "transcript"]
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
                Turn this raw dictation into a report. Produce a tight TLDR summary, \
                a list of concrete action items (empty if none), and a lightly cleaned-up \
                transcript (fix obvious ASR errors, keep the meaning).

                Dictation:
                \(transcript)
                """
            ]]
        ]
        if model.supportsAdaptiveThinking { body["thinking"] = ["type": "adaptive"] }
        return body
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
