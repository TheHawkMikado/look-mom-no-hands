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
        var req = URLRequest(url: AccountStore.host.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        return req
    }

    /// `POST /api/app/tasks {text, source:"voice"}`. nil = signed out or
    /// unreachable (the caller notes the request locally instead).
    func delegate(text: String) async -> IntakeReply? {
        guard let bearer = bearer() else { return nil }
        var req = request("api/app/tasks", method: "POST", bearer: bearer)
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "source": "voice"])
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { return nil }
        return Self.parseIntake(data)
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
                        confirmation: (row["confirmation"] as? String) ?? "")
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
