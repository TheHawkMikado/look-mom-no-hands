import Foundation

/// One name per lifecycle moment, shared by every producer in the app. The
/// authoritative mirror is AGENT_EVENT_KINDS in web/lib/db.ts — the server
/// silently skips kinds it doesn't know, so a stringly-typed producer could
/// ship events into the void. Keep the two lists identical.
enum AgentEventKind: String {
    case goalStarted = "goal_started"
    case goalProgress = "goal_progress"
    case needsApproval = "needs_approval"
    case goalDone = "goal_done"
    case goalFailed = "goal_failed"
}

/// Ships agent lifecycle events to the account backend so the /status page can
/// show them from a phone, and polls for remote approval verdicts while one is
/// outstanding. Two hard rules:
///  - Status text only. Never screenshots, transcripts, or command output —
///    the phone sees what a pager would.
///  - Soft-fail everywhere. Remote visibility must never break a local run;
///    a dead network just means the phone is behind.
@MainActor
final class EventReporter {

    /// Client half of the wire contract; the server's constants live in
    /// web/app/api/app/events/route.ts (TITLE_MAX/DETAIL_MAX/BATCH_MAX) and
    /// web/lib/db.ts (retention). Change them together.
    private enum Contract {
        static let titleMax = 200
        static let detailMax = 500
        static let batchMax = 40      // under the server's 50 so a full queue never 4xxes
        static let queueMax = 200     // matches server retention; older is unshowable anyway
    }

    struct Event: Codable {
        let id: String
        let kind: String
        let title: String
        let detail: String
        let approvalId: String?
        let createdAt: Date
    }

    /// approvalId, approve? — wired to BackgroundAgentManager by the coordinator.
    var onVerdict: ((String, Bool) -> Void)?
    /// A spoken goal submitted from the phone app; wired to the coordinator's
    /// remote-goal path. Delivery is take-once server-side, so firing this is
    /// already exclusive across the account's Macs.
    var onPhoneGoal: ((String) -> Void)?
    /// Gate asked BEFORE the take: delivery destroys the goal server-side, so a
    /// Mac that can't run it right now (busy, no key, queue not empty) must not
    /// take it — an idle fleet Mac, or this one in ten seconds, will.
    var canAcceptGoal: (() -> Bool)?
    /// Fires every poll tick regardless of the gate — the coordinator uses it
    /// to drain a locally-queued goal stranded by a race.
    var onGoalTick: (() -> Void)?

    private var queue: [Event] = []
    private var outstandingApprovals: Set<String> = []
    private var flushTimer: Timer?
    private var pollTimer: Timer?
    /// Cursor for verdict polling, in SERVER time: the `decidedAt` of the last
    /// verdict seen, echoed back verbatim. Never derived from the Mac's clock —
    /// a machine running two minutes fast would otherwise poll a window that is
    /// permanently in the server's future and miss every verdict.
    private var verdictCursor: String?

    /// The bearer token changes only at sign-in/sign-out, so one Keychain read
    /// is cached instead of a Security-framework IPC round trip on every report
    /// and timer tick. A 401 clears it (token revoked server-side).
    private var cachedBearer: String?
    private var lastBearerMiss: Date?
    private func bearer() -> String? {
        if let cachedBearer { return cachedBearer }
        // A signed-out Mac must not pay a securityd IPC on every 10s tick;
        // 60s keeps the post-sign-in pickup delay barely noticeable.
        if let miss = lastBearerMiss, Date().timeIntervalSince(miss) < 60 { return nil }
        cachedBearer = KeychainStore.load(account: AccountStore.appTokenAccount)
        lastBearerMiss = cachedBearer == nil ? Date() : nil
        return cachedBearer
    }

    func report(kind: AgentEventKind, title: String, detail: String = "", approvalId: String? = nil) {
        guard bearer() != nil else { return }   // not signed in — nothing to ship to
        queue.append(Event(id: UUID().uuidString, kind: kind.rawValue,
                           title: String(title.prefix(Contract.titleMax)),
                           detail: String(detail.prefix(Contract.detailMax)),
                           approvalId: approvalId, createdAt: Date()))
        if kind == .needsApproval, let approvalId {
            outstandingApprovals.insert(approvalId)
            startPolling()
        }
        scheduleFlush()
    }

    /// The approval got answered (or its agent was cancelled) locally — stop
    /// asking the backend about it.
    func approvalResolvedLocally(_ approvalId: String) {
        outstandingApprovals.remove(approvalId)
        if outstandingApprovals.isEmpty { stopPolling() }
    }

    // MARK: - Requests (one recipe for both endpoints)

    private func authedRequest(_ path: String, bearer: String) -> URLRequest {
        var req = URLRequest(url: AccountStore.host.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        return req
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // MARK: - Shipping

    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        // Batched, not per-event: a chatty run must not turn into a request storm.
        let t = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.flush() }
        }
        RunLoop.main.add(t, forMode: .common)
        flushTimer = t
    }

    private func flush() async {
        guard !queue.isEmpty else {
            flushTimer?.invalidate(); flushTimer = nil
            return
        }
        guard let bearer = bearer() else { queue.removeAll(); return }
        let batch = Array(queue.prefix(Contract.batchMax))
        var req = authedRequest("api/app/events", bearer: bearer)
        guard let body = try? Self.encoder.encode(["events": batch]) else { queue.removeAll(); return }
        req.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                queue.removeFirst(batch.count)
            } else if status == 401 {
                cachedBearer = nil          // signed out / token revoked — retry re-reads
            } else if (400..<500).contains(status) {
                // The backend rejected the batch (old server, malformed) —
                // retrying the same payload forever would just spin. Drop it.
                queue.removeFirst(batch.count)
            }
            // 5xx / network errors: keep the batch, next tick retries.
        } catch {
            // Offline is normal; the queue is capped below.
        }
        if queue.count > Contract.queueMax { queue.removeFirst(queue.count - Contract.queueMax) }
    }

    // MARK: - Phone goal inbox — the standing 10s poll that makes the phone work

    private var goalTimer: Timer?

    /// Unlike approval polling (armed only while something is pending), this
    /// runs whenever we're signed in: the Mac can't know when the phone will
    /// speak. One indexed SELECT per 10s per account is the price of "say it
    /// and walk away".
    func startGoalPolling() {
        guard goalTimer == nil else { return }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollGoals() }
        }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        goalTimer = t
    }

    private struct GoalsResponse: Decodable {
        struct Goal: Decodable {
            let id: String
            let text: String
        }
        let goals: [Goal]
    }

    private func pollGoals() async {
        onGoalTick?()
        // Ask before taking: delivery is destructive, so a Mac that can't run
        // the goal right now leaves it on the server for whoever can.
        guard canAcceptGoal?() != false else { return }
        guard let bearer = bearer(), onPhoneGoal != nil else { return }
        let req = authedRequest("api/app/goals/poll", bearer: bearer)
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { cachedBearer = nil; return }
        guard (200..<300).contains(status),
              let decoded = try? JSONDecoder().decode(GoalsResponse.self, from: data) else { return }
        for goal in decoded.goals where !goal.text.isEmpty {
            onPhoneGoal?(goal.text)
        }
    }

    // MARK: - Approval verdict polling — only while something is actually pending

    private struct PollBody: Encodable { let since: String? }
    private struct PollResponse: Decodable {
        struct Verdict: Decodable { let approvalId: String; let verdict: String; let decidedAt: String }
        let verdicts: [Verdict]
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let t = Timer(timeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() async {
        guard !outstandingApprovals.isEmpty else { stopPolling(); return }
        guard let bearer = bearer() else { return }
        var req = authedRequest("api/app/approvals/poll", bearer: bearer)
        req.httpBody = try? Self.encoder.encode(PollBody(since: verdictCursor))
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { cachedBearer = nil; return }
        guard (200..<300).contains(status),
              let decoded = try? JSONDecoder().decode(PollResponse.self, from: data) else { return }
        // Verdicts arrive oldest-first; the last one's decidedAt is the next
        // cursor. Replays are harmless — outstandingApprovals filters them.
        if let last = decoded.verdicts.last { verdictCursor = last.decidedAt }
        for verdict in decoded.verdicts {
            guard outstandingApprovals.contains(verdict.approvalId) else { continue }
            outstandingApprovals.remove(verdict.approvalId)
            onVerdict?(verdict.approvalId, verdict.verdict == "approve")
        }
        if outstandingApprovals.isEmpty { stopPolling() }
    }
}
