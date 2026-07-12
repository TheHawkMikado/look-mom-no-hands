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
                   vocabulary: String = "", screen: String = "", context: String = "") async throws -> ActionPlan {
        let json = try await post(Self.planRequestBody(transcript: transcript, dialogue: dialogue,
                                                        vocabulary: vocabulary, screen: screen, context: context, model: .haiku45), timeout: 20)
        try Self.checkRefusal(json)
        return try Self.decodeBlock(json, blockType: "tool_use", payloadKey: "input")
    }

    static func planRequestBody(transcript: String,
                                dialogue: [(role: String, content: String)] = [],
                                vocabulary: String = "",
                                screen: String = "",
                                context: String = "",
                                model: ClaudeModel) -> [String: Any] {
        let step: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "kind": ["type": "string",
                         "enum": ["click", "type", "scroll", "open_app", "open_url", "focus_window", "move_window", "switch_tab", "keystroke", "dictate_start", "describe_screen", "watch_start", "none"]],
                "target": ["type": "string", "description": "UI element / app name; for open_url optionally the browser; for focus_window/move_window the window description to match (empty for move_window = the current/context window); for switch_tab the browser tab title; for describe_screen the question to answer about the screen; for watch_start a short name for the task being demonstrated; empty if unused"],
                "text": ["type": "string", "description": "text to type; for move_window the destination display (\"main display\", \"second display\", \"display 2\"); empty if unused"],
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

            You run in an ACT-OBSERVE LOOP. You are called repeatedly for ONE goal: \
            each turn you see the current screen and the actions already taken this \
            task, and you emit the NEXT action(s) toward the goal. Do NOT stop at \
            opening a menu/palette/dialog — the next turn you'll see it, so continue \
            into it (select the item, type, confirm) until the goal is actually done. \
            Set goal_complete=true ONLY when the whole goal is achieved; if the request \
            had several parts, finish ALL of them first. Keep `say` EMPTY on \
            intermediate turns; speak only to ask, report completion, or report a problem.

            STAY IN THE CURRENT PAGE/WINDOW. You are already where the user is working. \
            Do the task THERE using the on-screen controls. Do NOT open a new tab or \
            window, and do NOT type into the browser address/URL bar (labels like \
            "Address and search bar"), for a task the current page can do — e.g. on \
            YouTube use YouTube's own search box, not the address bar. Only navigate \
            away if the user explicitly asks to.

            CAPABILITY DISCIPLINE — use the RIGHT kind, never a lookalike. Acting on an \
            EXISTING window is focus_window (raise/go to) or move_window (relocate to a \
            display) — NEVER open_app/open_url for those: that creates a NEW window, \
            which is wrong when the user said "move it" / "put it on my main screen". \
            "It"/"that window" = the working-context window or the window just acted \
            on. If the request needs something none of the kinds can do, set \
            blocked=true and say so plainly — never substitute a similar-looking action.

            NEVER REPEAT A FAILED ACTION. If "this task so far" already shows an action \
            and the screen indicates it didn't achieve the goal, do something DIFFERENT \
            (a different element, scroll to find it, or read the page) — never re-issue \
            the same click/type/search. Prefer reading and acting on what's actually on \
            the page (search the visible results/fields) over re-navigating. If you're \
            stuck and cannot make progress, set blocked=true (NOT goal_complete) and \
            say what you managed and what's blocking you, rather than looping.

            You may be given a working context (the app/window/tab the user is \
            operating in), the list of everything currently open, and a log of recent \
            actions. Treat the working context as the ACTIVE target: apply commands to \
            it without re-asking which window, unless the user names a different app/ \
            window/tab. Resolve vague references ("that window", "the editor", "it") \
            against the working context and the open-windows list. When the user says \
            to go to / switch to / open an app, window, or site, emit the matching \
            open_app / open_url / focus_window step (that also moves the working \
            context there). Only ask for clarification when the target is genuinely \
            unresolvable from the context and the open windows.

            say: one short spoken sentence confirming what you're doing or reporting; \
            empty for a single obvious action.

            teach: set when the user NARRATES how to do a task in words ("here's how to \
            X: first…, then…"). Capture a short name, trigger phrases, and the ordered \
            steps. Don't perform it in the same turn unless they say to do it now. If a \
            taught procedure in the context matches the request, follow its steps.

            watch_start: when the user wants to SHOW you a task by doing it ("watch me", \
            "watch this action", "learn this from my screen"), emit ONE watch_start step \
            with target = a short name for the task. Their clicks and keystrokes will be \
            recorded until they say "Mama done" and saved as a procedure. Do not also \
            set teach, and do not invent steps yourself.

            learn: set ONLY when the user EXPLICITLY teaches or corrects you — they use \
            corrective/teaching language ("no, I meant…", "when I say X I mean Y", \
            "remember that…"), or they just answered a clarification telling you what a \
            term means. Do NOT set learn for an ordinary command like "open Chrome" even \
            if you resolve Chrome to Google Chrome — resolving is not correcting. When you \
            do set it, still carry out the request in the same plan. Example: after you \
            asked which browser and the user replies "I always mean Brave", set \
            learn.spoken="browser", learn.written="Brave".
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
                    "learn": [
                        "type": "object",
                        "additionalProperties": false,
                        "description": "Set ONLY when the user teaches or corrects a durable mapping — \"when I say X I mean Y\", or after a clarification where they told you what a term means (e.g. \"chrome\" → \"Google Chrome\"). Omit otherwise.",
                        "properties": [
                            "spoken": ["type": "string", "description": "what the user says"],
                            "written": ["type": "string", "description": "what they mean / how to write it"]
                        ],
                        "required": ["spoken", "written"]
                    ],
                    "teach": [
                        "type": "object",
                        "additionalProperties": false,
                        "description": "Set ONLY when the user is teaching you HOW to do a task (\"here's how to…\", \"I'll show you how to…\", \"remember how to…\", \"the way I do X is…\"). Capture it as a reusable procedure. Do NOT also perform it unless they say to do it now.",
                        "properties": [
                            "name": ["type": "string", "description": "short name for the task, e.g. \"create a new Claude Code session\""],
                            "triggers": ["type": "array", "items": ["type": "string"], "description": "phrases that should invoke this procedure later"],
                            "steps": ["type": "string", "description": "the process in order, as the user described it"]
                        ],
                        "required": ["name", "triggers", "steps"]
                    ],
                    "remember": ["type": "string", "description": "Set to a durable fact when the user tells you to remember something about them or their setup (\"remember that my main project is X\", \"note that I use Brave\", \"for future reference, …\"). One concise fact. Empty otherwise."],
                    "confidence": ["type": "number"],
                    "goal_complete": ["type": "boolean", "description": "true ONLY when the user's whole goal is fully achieved and no further action is needed. false if more steps remain (e.g. you just opened a panel/dialog and must still act inside it)."],
                    "blocked": ["type": "boolean", "description": "true if you cannot make progress toward the goal (you're stuck, an element can't be found, or the task isn't doable). Use INSTEAD of goal_complete when the goal was NOT achieved; explain in `say`."]
                ],
                "required": ["say", "steps", "confidence", "goal_complete"]
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
        let system = [vocabulary, context, screen].filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !system.isEmpty { body["system"] = system }
        return body
    }

    // MARK: Dictation report (output_config.format + adaptive thinking where supported)

    func buildDictationReport(_ rawTranscript: String, vocabulary: String = "", instructions: String = "") async throws -> DictationReport {
        let json = try await post(Self.reportRequestBody(transcript: rawTranscript, vocabulary: vocabulary, instructions: instructions, model: .opus48))
        try Self.checkRefusal(json)
        return try Self.decodeBlock(json, blockType: "text", payloadKey: "text")
    }

    static func reportRequestBody(transcript: String, vocabulary: String = "", instructions: String = "", model: ClaudeModel) -> [String: Any] {
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
                \(instructions.isEmpty ? "" : "\n                Follow the user's processing instructions for what to emphasize and include:\n                \(instructions)\n")
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
    /// `cleanup` = the user's cleanup toggle. When false, we only apply the explicit
    /// formatting `instructions` (a paste rule) and otherwise keep the text verbatim —
    /// so a paste rule doesn't silently re-enable the cleanup the user turned off.
    func cleanUpDictation(_ raw: String, vocabulary: String = "", instructions: String = "", cleanup: Bool = true) async throws -> String {
        let content: String
        if cleanup {
            let extra = instructions.isEmpty ? "" : """


                Also follow these formatting instructions for where this is being pasted:
                \(instructions)
                """
            content = """
                Clean up this dictated text so it can be pasted as-is: fix obvious \
                speech-to-text errors, add sensible punctuation and capitalization, \
                and remove filler words and false starts (um, uh, "like", repeated \
                words). Keep the user's wording and meaning — do NOT summarize, \
                rephrase, or add anything unless the formatting instructions say to. \
                Output ONLY the cleaned text.\(extra)

                \(raw)
                """
        } else {
            // Formatting-only: apply the paste rule, otherwise keep it verbatim.
            content = """
                Apply ONLY these formatting instructions to the text below; otherwise \
                keep it EXACTLY as-is (do not fix speech-to-text errors, change \
                punctuation, or remove filler). Output ONLY the result.

                Formatting instructions:
                \(instructions)

                Text:
                \(raw)
                """
        }
        var body: [String: Any] = [
            "model": ClaudeModel.haiku45.rawValue,
            "max_tokens": 4000,
            "messages": [[
                "role": "user",
                "content": content
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

    /// Answers a question about a transcript (Otter-style "ask your notes").
    func answer(question: String, about transcript: String) async throws -> String {
        let body: [String: Any] = [
            "model": ClaudeModel.opus48.rawValue,
            "max_tokens": 2000,
            "messages": [[
                "role": "user",
                "content": """
                Here is a transcript. Answer the question using only what it contains; \
                if it isn't covered, say so briefly.

                Transcript:
                \(transcript)

                Question: \(question)
                """
            ]]
        ]
        let json = try await post(body, timeout: 30)
        try Self.checkRefusal(json)
        guard let text = Self.firstTextBlock(json), !text.isEmpty else { throw ClaudeError.decoding("no text") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstTextBlock(_ json: [String: Any]) -> String? {
        (json["content"] as? [[String: Any]])?
            .first { $0["type"] as? String == "text" }?["text"] as? String
    }

    // MARK: - Vision click fallback

    /// Given a screenshot (base64 PNG) and a description of what to click, returns
    /// the point to click as a fraction (0…1) of the image, or nil if the model
    /// can't see it. Used only when the Accessibility tree has no match — many
    /// Electron/web UIs expose almost nothing to AX, so this is the "actually look
    /// at the pixels" path. Opus (not Haiku) because localization accuracy matters
    /// more than latency on this rare fallback.
    func locateElement(described target: String, pngBase64: String) async throws -> (x: Double, y: Double)? {
        let tool: [String: Any] = [
            "name": "locate",
            "description": "Report where on the screenshot to click for the described element.",
            "input_schema": [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "found": ["type": "boolean", "description": "true only if the element is actually visible in the image"],
                    "x": ["type": "number", "description": "horizontal click point as a fraction of image width (0=left edge, 1=right edge)"],
                    "y": ["type": "number", "description": "vertical click point as a fraction of image height (0=top edge, 1=bottom edge)"]
                ],
                "required": ["found", "x", "y"]
            ]
        ]
        let body: [String: Any] = [
            "model": ClaudeModel.opus48.rawValue,
            "max_tokens": 300,
            "tool_choice": ["type": "tool", "name": "locate"],
            "tools": [tool],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": pngBase64]],
                    ["type": "text", "text": "Point to the center of this UI element so I can click it: \"\(target)\". If it isn't visible on screen, set found=false."]
                ]
            ]]
        ]
        let json = try await post(body, timeout: 30)
        try Self.checkRefusal(json)
        let hit: VisionHit = try Self.decodeBlock(json, blockType: "tool_use", payloadKey: "input")
        // Missing coordinates count as "not found" rather than defaulting to (0,0),
        // which would click the display's top-left corner.
        guard hit.found, let x = hit.x, let y = hit.y else { return nil }
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }

    /// Describes or answers a question about a screenshot, phrased for text-to-speech.
    /// This is the "read my screen" path — richer than the AX text snapshot because
    /// it sees rendered text, images, and layout the Accessibility tree omits.
    func describeScreen(question: String, pngBase64: String) async throws -> String {
        let prompt = question.isEmpty
            ? "Describe what's on this screen for someone who can't see it: the app, the main content, and anything they'd act on. Two to four sentences, conversational, for text-to-speech."
            : "Based only on this screenshot, answer briefly and conversationally (for text-to-speech): \(question)"
        let body: [String: Any] = [
            "model": ClaudeModel.opus48.rawValue,
            "max_tokens": 600,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": pngBase64]],
                    ["type": "text", "text": prompt]
                ]
            ]]
        ]
        let json = try await post(body, timeout: 30)
        try Self.checkRefusal(json)
        guard let text = Self.firstTextBlock(json), !text.isEmpty else { throw ClaudeError.decoding("no text") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct VisionHit: Decodable {
        let found: Bool; let x: Double?; let y: Double?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            found = (try? c.decodeIfPresent(Bool.self, forKey: .found)) ?? false
            x = (try? c.decodeIfPresent(Double.self, forKey: .x)) ?? nil
            y = (try? c.decodeIfPresent(Double.self, forKey: .y)) ?? nil
        }
        private enum CodingKeys: String, CodingKey { case found, x, y }
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
