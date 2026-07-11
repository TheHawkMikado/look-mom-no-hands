import Foundation

// Talks to the Anthropic Messages API directly over URLSession — no SDK exists for Swift.
// Two structured-output paths:
//   1. parseCommand(...)        → forced tool use, fast, thinking off  (screen control + intent routing)
//   2. buildDictationReport(...) → output_config.format json_schema, thinking on  (Wisprflow-style report)

enum ClaudeModel: String, Sendable {
    case opus48 = "claude-opus-4-8"      // default brain: planning, summaries
    case fable5 = "claude-fable-5"       // most capable tier
    case sonnet5 = "claude-sonnet-5"
    case haiku45 = "claude-haiku-4-5"    // fast path: command parsing
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

    // MARK: Screen-action parsing + intent routing (forced tool use, strict schema)

    func parseCommand(_ transcript: String,
                      model: ClaudeModel = .haiku45) async throws -> ScreenAction {
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
                    "confidence": ["type": "number"]
                ],
                "required": ["kind", "target", "text", "confidence"]
            ]
        ]

        // No effort/thinking params: Haiku 4.5 rejects `effort` with a 400, and
        // omitting thinking keeps this hot path fast.
        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 1024,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "emit_action"],
            "messages": [["role": "user", "content": "Spoken command: \"\(transcript)\""]]
        ]

        let json = try await post(body, timeout: 15)
        try Self.checkRefusal(json)

        guard let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { $0["type"] as? String == "tool_use" }),
              let input = toolUse["input"] as? [String: Any] else {
            throw ClaudeError.noToolUse
        }
        let data = try JSONSerialization.data(withJSONObject: input)
        return try JSONDecoder().decode(ScreenAction.self, from: data)
    }

    // MARK: Dictation report (output_config.format + adaptive thinking)

    func buildDictationReport(_ rawTranscript: String,
                              model: ClaudeModel = .opus48) async throws -> DictationReport {
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

        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 16000,
            "thinking": ["type": "adaptive"],
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": schema]
            ],
            "messages": [[
                "role": "user",
                "content": """
                Turn this raw dictation into a report. Produce a tight TLDR summary, \
                a list of concrete action items (empty if none), and a lightly cleaned-up \
                transcript (fix obvious ASR errors, keep the meaning).

                Dictation:
                \(rawTranscript)
                """
            ]]
        ]

        let json = try await post(body)
        try Self.checkRefusal(json)

        guard let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { $0["type"] as? String == "text" }),
              let text = textBlock["text"] as? String,
              let data = text.data(using: .utf8) else {
            throw ClaudeError.decoding("no text block")
        }
        return try JSONDecoder().decode(DictationReport.self, from: data)
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
