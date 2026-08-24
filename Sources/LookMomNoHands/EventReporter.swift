import Foundation

/// Ships agent lifecycle events to the account backend so the /status page can
/// show them from a phone, and polls for remote approval verdicts while one is
/// outstanding. Two hard rules:
///  - Status text only. Never screenshots, transcripts, or command output —
///    the phone sees what a pager would.
///  - Soft-fail everywhere. Remote visibility must never break a local run;
///    a dead network just means the phone is behind.
@MainActor
final class EventReporter {

    struct Event: Codable {
        let id: String
        let kind: String        // goal_started | goal_progress | needs_approval | goal_done | goal_failed
        let title: String
        let detail: String
        let approvalId: String?
        let createdAt: Date
    }

    /// approvalId, approve? — wired to BackgroundAgentManager by the coordinator.
    var onVerdict: ((String, Bool) -> Void)?

    private var queue: [Event] = []
    private var outstandingApprovals: Set<String> = []
    private var flushTimer: Timer?
    private var pollTimer: Timer?
    private var lastPollAt: Date?

    private var bearer: String? { KeychainStore.load(account: AccountStore.appTokenAccount) }

    func report(kind: String, title: String, detail: String = "", approvalId: String? = nil) {
        guard bearer != nil else { return }   // not signed in — nothing to ship to
        queue.append(Event(id: UUID().uuidString, kind: kind,
                           title: String(title.prefix(120)),
                           detail: String(detail.prefix(500)),
                           approvalId: approvalId, createdAt: Date()))
        if kind == "needs_approval", let approvalId {
            outstandingApprovals.insert(approvalId)
            startPolling()
        }
        scheduleFlush()
    }

    /// The approval got answered locally (panel button / voice) — stop asking
    /// the backend about it.
    func approvalResolvedLocally(_ approvalId: String) {
        outstandingApprovals.remove(approvalId)
        if outstandingApprovals.isEmpty { stopPolling() }
    }

    // MARK: Shipping

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
        guard let bearer else { queue.removeAll(); return }
        let batch = Array(queue.prefix(40))
        var req = URLRequest(url: AccountStore.host.appendingPathComponent("api/app/events"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(["events": batch]) else { queue.removeAll(); return }
        req.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                queue.removeFirst(batch.count)
            } else if (400..<500).contains(status) {
                // The backend rejected the batch (old server, bad token) —
                // retrying the same payload forever would just spin. Drop it.
                queue.removeFirst(batch.count)
            }
            // 5xx / network errors: keep the batch, next tick retries.
        } catch {
            // Offline is normal; the queue is capped below.
        }
        if queue.count > 200 { queue.removeFirst(queue.count - 200) }
    }

    // MARK: Approval verdict polling — only while something is actually pending

    private func startPolling() {
        guard pollTimer == nil else { return }
        lastPollAt = Date()
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
        guard let bearer else { return }
        var req = URLRequest(url: AccountStore.host.appendingPathComponent("api/app/approvals/poll"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let iso = ISO8601DateFormatter()
        let since = lastPollAt.map { iso.string(from: $0.addingTimeInterval(-60)) }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["since": since as Any])
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let verdicts = json["verdicts"] as? [[String: Any]] else { return }
        lastPollAt = Date()
        for verdict in verdicts {
            guard let approvalId = verdict["approvalId"] as? String,
                  outstandingApprovals.contains(approvalId),
                  let decision = verdict["verdict"] as? String else { continue }
            outstandingApprovals.remove(approvalId)
            onVerdict?(approvalId, decision == "approve")
        }
        if outstandingApprovals.isEmpty { stopPolling() }
    }
}
