import Foundation

/// The resolved routing table (MODEL_ROUTING.md, SPEC.md §7): one winning
/// route per task type, plus the quality floor the server applied. Clients
/// never pick between candidates — the server already did — so only the
/// winner is kept. Options are stringified provider knobs (`effort: low`,
/// `thinking: adaptive`, `stream: true`) exactly as the seed spells them.
struct RoutingTable: Equatable {
    struct Route: Equatable {
        let model: String
        let provider: String
        let options: [String: String]
    }

    var qualityFloor: Double
    var routes: [String: Route]

    /// The built-in fallback, identical to the MODEL_ROUTING.md table (top
    /// candidate per task type). Used until the first successful fetch and
    /// whenever the cache is unreadable, so the app behaves the same offline.
    static let seed = RoutingTable(qualityFloor: 0.6, routes: [
        "intent_classify":     Route(model: "claude-haiku-4-5",  provider: "anthropic", options: [:]),
        "task_extract":        Route(model: "claude-opus-5",     provider: "anthropic", options: ["effort": "low"]),
        "triage_decision":     Route(model: "claude-haiku-4-5",  provider: "anthropic", options: [:]),
        "summarize_meeting":   Route(model: "claude-opus-5",     provider: "anthropic", options: ["thinking": "adaptive"]),
        "draft_copy_short":    Route(model: "claude-opus-5",     provider: "anthropic", options: [:]),
        "draft_copy_long":     Route(model: "claude-opus-5",     provider: "anthropic", options: ["thinking": "adaptive", "stream": "true"]),
        "research_synthesize": Route(model: "claude-opus-5",     provider: "anthropic", options: ["web_search": "true"]),
        "code_change":         Route(model: "claude-opus-5",     provider: "anthropic", options: ["effort": "xhigh"]),
        "image_prompt":        Route(model: "claude-opus-5",     provider: "anthropic", options: [:]),
        "stt":                 Route(model: "apple-speech",      provider: "apple",     options: [:]),
        "speaker_id":          Route(model: "ecapa-tdnn-coreml", provider: "local",     options: [:]),
    ])

    /// Parses `GET /api/app/routing`:
    /// `{quality_floor, routes: {task_type: {model, provider, options, candidates}}}`.
    /// Tolerant per route — a task type with no usable model is dropped, not
    /// fatal — but nil when the envelope itself is wrong, so a garbled body can
    /// never replace a good table with an empty one. Pure for tests.
    static func parse(_ data: Data) -> RoutingTable? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawRoutes = json["routes"] as? [String: Any] else { return nil }
        let floor = (json["quality_floor"] as? NSNumber)?.doubleValue ?? seed.qualityFloor
        var routes: [String: Route] = [:]
        for (taskType, value) in rawRoutes {
            guard let r = value as? [String: Any],
                  let model = r["model"] as? String, !model.isEmpty else { continue }
            let provider = (r["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "anthropic"
            routes[taskType] = Route(model: model, provider: provider,
                                     options: stringified(r["options"] as? [String: Any] ?? [:]))
        }
        guard !routes.isEmpty else { return nil }
        return RoutingTable(qualityFloor: floor, routes: routes)
    }

    /// Options arrive as mixed JSON (strings, booleans, numbers). One string
    /// form keeps the table Equatable and the call sites simple; booleans are
    /// "true"/"false", numbers their plain decimal spelling.
    static func stringified(_ options: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in options {
            if let s = v as? String { out[k] = s }
            else if let n = v as? NSNumber {
                // NSNumber wraps Bool too; CFBoolean is the only way to tell.
                if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() { out[k] = n.boolValue ? "true" : "false" }
                else { out[k] = n.stringValue }
            }
        }
        return out
    }
}

/// The Mac's view of the model router (DECISIONS.md: "the model router lives in
/// the web service and is served to clients"). Fetches the resolved table once
/// per launch and every six hours, caches the last good copy in `routing.json`
/// under the app-support folder, and falls back to `RoutingTable.seed` — the
/// same table as MODEL_ROUTING.md — so no feature ever hardcodes a model and
/// nothing changes when the network is gone.
///
/// Reads are synchronous and lock-protected so ClaudeClient can ask for a
/// model on the command hot path without an actor hop; only the fetch touches
/// the main actor (it reads the account's bearer token the way the other
/// callers of `/api/app/*` do).
final class ModelRouter: @unchecked Sendable {
    static let shared = ModelRouter()

    /// Refresh cadence. The server caches for five minutes; six hours here is
    /// "once a working day", which is how often the table plausibly changes.
    nonisolated static let refreshInterval: TimeInterval = 6 * 3600

    private let lock = NSLock()
    private var table: RoutingTable = .seed
    private var cacheURL: URL?
    private var lastSuccess: Date?
    private var ticker: Timer?
    private var sourceStorage = "seed"
    /// Where the live table came from — "seed", "cache" or "server" — for the log.
    var source: String {
        lock.lock(); defer { lock.unlock() }
        return sourceStorage
    }

    init() {}

    // MARK: - Lookups (any thread)

    /// The model id for a task type; the seed's answer for a task type the
    /// server didn't route, and the seed's `intent_classify` route as the
    /// last resort so a caller always gets a real model string.
    func model(for taskType: String) -> String {
        route(for: taskType)?.model ?? RoutingTable.seed.routes["intent_classify"]!.model
    }

    /// Provider knobs for a task type (`effort`, `thinking`, …); empty when
    /// none. Callers apply only the knobs the chosen model supports.
    func options(for taskType: String) -> [String: String] {
        route(for: taskType)?.options ?? [:]
    }

    func route(for taskType: String) -> RoutingTable.Route? {
        lock.lock(); defer { lock.unlock() }
        return table.routes[taskType] ?? RoutingTable.seed.routes[taskType]
    }

    /// Replaces the live table. Exposed so a caller with a freshly parsed
    /// table (or a test) can install it without a network round trip.
    func install(_ newTable: RoutingTable, source: String) {
        lock.lock(); defer { lock.unlock() }
        table = newTable
        sourceStorage = source
    }

    // MARK: - Lifecycle (main actor)

    /// Call once at launch with the app-support directory. Loads the cached
    /// table (if any), fetches a fresh one, and keeps fetching every six hours.
    /// Idempotent: a second call only re-checks whether a refresh is due.
    @MainActor
    func start(directory: URL, log: ((String) -> Void)? = nil) {
        if cacheURL == nil {
            let url = directory.appendingPathComponent("routing.json")
            cacheURL = url
            if let data = try? Data(contentsOf: url), let cached = RoutingTable.parse(data) {
                install(cached, source: "cache")
                log?("routing table loaded from cache (\(cached.routes.count) task types)")
            }
        }
        if ticker == nil {
            // Hourly tick, six-hour throttle in refreshIfDue: a launch with no
            // network retries within the hour instead of waiting six.
            let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refreshIfDue(log: log) }
            }
            t.tolerance = 300
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        }
        Task { await refreshIfDue(log: log) }
    }

    @MainActor
    func refreshIfDue(log: ((String) -> Void)? = nil) async {
        if let last = lastSuccess, Date().timeIntervalSince(last) < Self.refreshInterval { return }
        await refresh(log: log)
    }

    /// One fetch of `GET /api/app/routing` with the account's bearer token.
    /// Soft-fails: not signed in, offline, a 401, a garbled body — all leave
    /// the current table (cache or seed) in place.
    @MainActor
    func refresh(log: ((String) -> Void)? = nil) async {
        guard let bearer = KeychainStore.load(account: AccountStore.appTokenAccount) else { return }
        var req = URLRequest(url: AccountStore.host.appendingPathComponent("api/app/routing"))
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let fresh = RoutingTable.parse(data) else {
            log?("routing table fetch failed — keeping \(source)")
            return
        }
        install(fresh, source: "server")
        lastSuccess = Date()
        if let cacheURL { try? data.write(to: cacheURL, options: .atomic) }
        log?("routing table refreshed (\(fresh.routes.count) task types; intent_classify → \(model(for: "intent_classify")), summarize_meeting → \(model(for: "summarize_meeting")))")
    }
}
