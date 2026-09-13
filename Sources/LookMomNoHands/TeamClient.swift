import Foundation

/// A task as the web reports it — the cloud half of SPEC.md §10, titles and
/// statuses only. Never detail, never a transcript (residency: the Mac keeps
/// those). `confirmation` is the one sentence the user hears.
struct TeamTask: Equatable, Sendable {
    let id: String
    let title: String
    let status: String
    let ownerName: String?
    let confirmation: String
    /// agent | human | user, when the row says. Nil on older replies.
    let ownerKind: String?
    /// text | voice | meeting — meeting-born tasks get the stricter voice-
    /// approval rule (SPEC.md §6, §12).
    let source: String?
    let blastTier: Int

    init(id: String, title: String, status: String, ownerName: String?, confirmation: String,
         ownerKind: String? = nil, source: String? = nil, blastTier: Int = 0) {
        self.id = id
        self.title = title
        self.status = status
        self.ownerName = ownerName
        self.confirmation = confirmation
        self.ownerKind = ownerKind
        self.source = source
        self.blastTier = blastTier
    }

    /// Approving this by voice needs the owner's voice verified right now:
    /// it came out of a meeting (other people's speech is data, never an
    /// instruction) and it reaches outside the account (tier ≥ 2).
    var needsVerifiedVoiceApproval: Bool { source == "meeting" && blastTier >= 2 }
}

/// A question the bot wants to ask (`GET /api/app/prompts`): one question
/// with a default, so silence is a valid answer. `kind` is escalation |
/// daily_brief | deliver_reminder | promotion.
struct TeamPrompt: Equatable, Sendable {
    let id: String
    let kind: String
    let question: String
    let defaultAnswer: String
    let taskID: String?
}

/// The one-time address hand-off for a human ticket (DECISIONS.md: the Mac
/// hands over the address, once). Sent inside the POST body and never stored
/// anywhere but the Local Brain.
struct TicketDelivery: Equatable, Sendable {
    let channel: String   // "email" | "sms"
    let to: String
    let name: String

    var json: [String: Any] { ["channel": channel, "to": to, "name": name] }
}

/// What `POST /api/app/tasks` says back: the intake's intent (question | task |
/// decision | note | smalltalk), the sentence to speak, and the task when the
/// utterance became one.
struct IntakeReply: Equatable, Sendable {
    let intent: String
    let confirmation: String
    let task: TeamTask?
}

/// The Mac's calls to the team behind the app (`/api/app/tasks*`, SPEC.md §5.1
/// and §6). Three verbs: hand a request over, ask what's outstanding, decide a
/// pending approval. Same bearer token and soft-fail rules as EventReporter —
/// a dead network returns nil and the coordinator says so, it never throws
/// into a voice session.
///
/// Speed rule (SPEC.md §1): `delegate` returns the moment the server replies,
/// with the confirmation already in hand. Nothing here waits on Paperclip.
@MainActor
final class TeamClient {
    private func bearer() -> String? { KeychainStore.load(account: AccountStore.appTokenAccount) }

    private func request(_ path: String, method: String, bearer: String) -> URLRequest {
        // A path with a query ("prompts?mark=spoken") must not have its "?"
        // percent-escaped the way appendingPathComponent would.
        let url: URL
        if path.contains("?"), let withQuery = URL(string: AccountStore.host.absoluteString + "/" + path) {
            url = withQuery
        } else {
            url = AccountStore.host.appendingPathComponent(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        return req
    }

    /// `POST /api/app/tasks {text, source:"voice"}`. nil = signed out or
    /// unreachable (the caller notes the request locally instead).
    func delegate(text: String) async -> IntakeReply? {
        await submit(text: text, source: "voice", deliver: nil)
    }

    /// One extracted meeting action item → `POST /api/app/tasks {text,
    /// source:"meeting", deliver?}`. The body is the item's text ONLY — the
    /// transcript never leaves the Mac (SPEC.md §4.3). nil = signed out or
    /// unreachable; the caller keeps the item in the outbox and retries.
    func submitMeetingItem(text: String, deliver: TicketDelivery?) async -> IntakeReply? {
        await submit(text: text, source: "meeting", deliver: deliver)
    }

    private func submit(text: String, source: String, deliver: TicketDelivery?) async -> IntakeReply? {
        guard let bearer = bearer() else { return nil }
        var req = request("api/app/tasks", method: "POST", bearer: bearer)
        req.httpBody = try? JSONSerialization.data(withJSONObject: Self.intakeBody(text: text, source: source, deliver: deliver))
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { return nil }
        return Self.parseIntake(data)
    }

    /// Pure: the intake body. Tested so a residency slip (a transcript field)
    /// can't creep in unnoticed.
    nonisolated static func intakeBody(text: String, source: String, deliver: TicketDelivery?) -> [String: Any] {
        var body: [String: Any] = ["text": text, "source": source]
        if let deliver { body["deliver"] = deliver.json }
        return body
    }

    // MARK: - Prompts (the bot initiates, SPEC.md §5.4)

    /// `GET /api/app/prompts?mark=spoken` — the questions whose moment has
    /// come, oldest first. Marking them spoken keeps two Macs on one account
    /// from both asking. nil = signed out or unreachable.
    func prompts(markSpoken: Bool = true) async -> [TeamPrompt]? {
        guard let bearer = bearer() else { return nil }
        var req = request(markSpoken ? "api/app/prompts?mark=spoken" : "api/app/prompts", method: "GET", bearer: bearer)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { return nil }
        return Self.parsePrompts(data)
    }

    /// `POST /api/app/prompts/{id}/answer {answer}` — an empty answer means
    /// "the default". True on a 2xx.
    func answerPrompt(id: String, answer: String) async -> Bool {
        guard let bearer = bearer() else { return false }
        var req = request("api/app/prompts/\(id)/answer", method: "POST", bearer: bearer)
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["answer": answer])
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// `GET /api/app/tasks?status=…` — newest first, as the server orders them.
    /// nil = unreachable; an empty array is a real "nothing outstanding".
    func tasks(status: [String]) async -> [TeamTask]? {
        guard let bearer = bearer() else { return nil }
        var comps = URLComponents(url: AccountStore.host.appendingPathComponent("api/app/tasks"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "status", value: status.joined(separator: ",")),
                             URLQueryItem(name: "limit", value: "20")]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { return nil }
        return Self.parseTasks(data)
    }

    /// The statuses that count as "outstanding" for a spoken status query.
    nonisolated static let outstandingStatuses = ["needs_decision", "awaiting_approval", "in_progress"]

    /// `POST /api/app/tasks/{id}/decide {verdict, via:"voice", speakerVerified}`.
    /// true on a 2xx. A 409 means nothing was awaiting approval any more.
    func decide(taskID: String, verdict: String, speakerVerified: Bool) async -> Bool {
        guard let bearer = bearer() else { return false }
        var req = request("api/app/tasks/\(taskID)/decide", method: "POST", bearer: bearer)
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "verdict": verdict, "via": "voice", "speakerVerified": speakerVerified
        ])
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - Pure parsing (nonisolated: called from tests and any actor)

    nonisolated static func parseIntake(_ data: Data) -> IntakeReply? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let intent = (json["intent"] as? String) ?? "task"
        let confirmation = (json["confirmation"] as? String) ?? ""
        let task = (json["task"] as? [String: Any]).flatMap(parseTask)
        return IntakeReply(intent: intent, confirmation: confirmation, task: task)
    }

    nonisolated static func parseTasks(_ data: Data) -> [TeamTask]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = json["tasks"] as? [[String: Any]] else { return nil }
        return rows.compactMap(parseTask)
    }

    /// nil without an id and a title — there is nothing to say or decide on.
    nonisolated static func parseTask(_ row: [String: Any]) -> TeamTask? {
        guard let id = row["id"] as? String, !id.isEmpty,
              let title = row["title"] as? String, !title.isEmpty else { return nil }
        return TeamTask(id: id, title: title,
                        status: (row["status"] as? String) ?? "",
                        ownerName: row["owner_name"] as? String,
                        confirmation: (row["confirmation"] as? String) ?? "",
                        ownerKind: row["owner_kind"] as? String,
                        source: row["source"] as? String,
                        blastTier: (row["blast_tier"] as? NSNumber)?.intValue ?? 0)
    }

    /// `{prompts:[{id, kind, question, defaultAnswer|default_answer, taskId}]}`.
    /// nil when the envelope is wrong (unreachable), empty when nothing is due.
    nonisolated static func parsePrompts(_ data: Data) -> [TeamPrompt]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = json["prompts"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty,
                  let question = row["question"] as? String, !question.isEmpty else { return nil }
            let def = (row["defaultAnswer"] as? String) ?? (row["default_answer"] as? String) ?? ""
            let taskID = (row["taskId"] as? String) ?? (row["task_id"] as? String)
            return TeamPrompt(id: id, kind: (row["kind"] as? String) ?? "escalation",
                              question: question, defaultAnswer: def, taskID: taskID)
        }
    }

    /// What the Mac says for a prompt: the question, then the default as a
    /// promise ("I'll nudge unless you say otherwise.") so silence is a
    /// choice, not a miss. Pure — tested.
    nonisolated static func spokenPrompt(_ p: TeamPrompt) -> String {
        let q = p.question.trimmingCharacters(in: .whitespacesAndNewlines)
        var question = q
        if let last = q.last, !".!?".contains(last) { question += "?" }
        let def = p.defaultAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !def.isEmpty else { return question }
        if p.kind == "daily_brief" { return question }
        return "\(question) I'll \(def) unless you say otherwise."
    }

    /// One spoken sentence for "what's outstanding": the count and the top two
    /// titles, newest first. Short on purpose — every word is TTS time.
    nonisolated static func outstandingSummary(_ tasks: [TeamTask]) -> String {
        switch tasks.count {
        case 0: return "Nothing is outstanding."
        case 1: return "One thing is outstanding: \(tasks[0].title)."
        case 2: return "Two things are outstanding: \(tasks[0].title), and \(tasks[1].title)."
        default:
            return "\(tasks.count) things are outstanding. The latest: \(tasks[0].title), and \(tasks[1].title)."
        }
    }

    /// A short line for the panel / activity log once a delegation lands.
    nonisolated static func receiptLine(_ reply: IntakeReply) -> String {
        guard let task = reply.task else { return "intake: \(reply.intent) — \(reply.confirmation)" }
        let owner = task.ownerName.map { " → \($0)" } ?? ""
        return "receipt: \"\(task.title)\" \(task.status)\(owner) [\(task.id)]"
    }
}
