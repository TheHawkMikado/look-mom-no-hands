import Foundation
import Combine

// Wearable ingest (SPEC.md §4.1 "Wearable ingest", Phase 6): a recorder the
// user wears all day — Limitless first, Plaud later — whose transcripts the
// Mac pulls and runs through the SAME extraction and end-of-session triage
// as a live meeting. The raw text lands in the Local Brain as
// `meetings/<source>-<id>.md` and is never uploaded; only the extracted task
// text reaches the web (source "meeting"), exactly as for a live session.

/// One recording (a Limitless "lifelog", a Plaud note) as the pipeline sees
/// it: an id to remember, a title, the text with whatever speaker labels the
/// vendor gives, and when it happened.
struct WearableRecording: Equatable, Sendable {
    let id: String
    let title: String
    let text: String
    let startedAt: Date?
}

struct WearableBatch: Equatable, Sendable {
    let recordings: [WearableRecording]
    /// Opaque page cursor to store for the next poll; nil when caught up.
    let nextCursor: String?
}

enum WearableError: Error, CustomStringConvertible {
    case noKey
    case http(Int)
    case badBody
    case notImplemented(String)

    var description: String {
        switch self {
        case .noKey: return "no API key"
        case .http(let s): return "HTTP \(s)"
        case .badBody: return "unexpected response shape"
        case .notImplemented(let s): return "\(s) is not wired yet"
        }
    }
}

/// A vendor adapter. Stateless: the ingest loop owns the cursor and the key.
protocol WearableSource: AnyObject {
    /// "limitless" | "plaud" — the Keychain account suffix and the file prefix.
    var id: String { get }
    var label: String { get }
    /// Recordings newer than `cursor` (or since `since` on the first call),
    /// oldest first, with the cursor to continue from.
    func fetch(apiKey: String, cursor: String?, since: Date) async throws -> WearableBatch
}

// MARK: - Limitless

/// Limitless developer API, as documented at the time of writing
/// (https://www.limitless.ai/developers):
///
///     GET https://api.limitless.ai/v1/lifelogs
///         header  X-API-Key: <key>
///         params  start=<ISO 8601>  end=<ISO 8601>  date=<YYYY-MM-DD>  timezone=<IANA>
///                 cursor=<opaque>  direction=asc|desc  limit=<≤10>
///                 includeMarkdown=true|false  includeHeadings=true|false
///     200     { data: { lifelogs: [ { id, title, markdown, startTime, endTime,
///                        contents: [ { type, content, startTime, endTime,
///                                      speakerName, speakerIdentifier } ] } ] },
///               meta: { lifelogs: { nextCursor, count } } }
///
/// The docs host was not reachable from the build box; `parse` is written
/// against that shape and unit-tested on a sample. The first real poll will
/// confirm the field names — anything unexpected reads as `badBody`, never as
/// an empty "all caught up".
final class LimitlessSource: WearableSource {
    let id = "limitless"
    let label = "Limitless"
    static let endpoint = URL(string: "https://api.limitless.ai/v1/lifelogs")!
    static let pageSize = 10

    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func fetch(apiKey: String, cursor: String?, since: Date) async throws -> WearableBatch {
        var req = URLRequest(url: Self.url(cursor: cursor, since: since))
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw WearableError.http(status) }
        guard let batch = Self.parse(data) else { throw WearableError.badBody }
        return batch
    }

    /// Pure — tested. With a cursor, only the cursor is sent (the server
    /// remembers the window); without one, `start` bounds the first fetch so
    /// enabling the integration doesn't ingest a year of lifelogs.
    static func url(cursor: String?, since: Date) -> URL {
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "limit", value: String(pageSize)),
                     URLQueryItem(name: "direction", value: "asc"),
                     URLQueryItem(name: "includeMarkdown", value: "true"),
                     URLQueryItem(name: "includeHeadings", value: "false")]
        if let cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        } else {
            items.append(URLQueryItem(name: "start", value: iso.string(from: since)))
        }
        comps.queryItems = items
        return comps.url ?? endpoint
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Pure — tested. Nil when the envelope is missing (an error page, a
    /// changed API); an empty `lifelogs` array is a real "nothing new".
    static func parse(_ data: Data) -> WearableBatch? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let rows = dataObj["lifelogs"] as? [[String: Any]] else { return nil }
        let recordings: [WearableRecording] = rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let title = ((row["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = transcriptText(row)
            guard !text.isEmpty else { return nil }
            let started = (row["startTime"] as? String).flatMap { parseDate($0) }
            return WearableRecording(id: id, title: title.isEmpty ? "Limitless recording" : title,
                                     text: text, startedAt: started)
        }
        let meta = (json["meta"] as? [String: Any])?["lifelogs"] as? [String: Any]
        let next = (meta?["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return WearableBatch(recordings: recordings, nextCursor: next)
    }

    /// "Speaker: words" lines from `contents` (the shape the meeting extractor
    /// already reads), falling back to the markdown when there are no
    /// speaker-tagged blocks. Headings are skipped — they are Limitless's own
    /// summaries, not speech.
    static func transcriptText(_ row: [String: Any]) -> String {
        var lines: [String] = []
        func walk(_ blocks: [[String: Any]]) {
            for b in blocks {
                let type = (b["type"] as? String) ?? ""
                let content = ((b["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !type.hasPrefix("heading"), !content.isEmpty {
                    var speaker = ((b["speakerName"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                    if speaker.isEmpty { speaker = (b["speakerIdentifier"] as? String) == "user" ? "Me" : "Speaker" }
                    lines.append("\(speaker): \(content)")
                }
                if let children = b["children"] as? [[String: Any]] { walk(children) }
            }
        }
        if let contents = row["contents"] as? [[String: Any]] { walk(contents) }
        if !lines.isEmpty { return lines.joined(separator: "\n") }
        return ((row["markdown"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseDate(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

// MARK: - Plaud (stub)

/// Plaud has no public pull API at the time of writing; recordings leave the
/// device through the Plaud app's export (share sheet / cloud sync). The
/// protocol is in place so that when a developer API or a watched export
/// folder is wired up, the ingest loop, the extraction and the Local Brain
/// filing need no change: implement `fetch`, return `WearableBatch`, done.
/// Until then it is disabled in Settings and `fetch` says why.
final class PlaudSource: WearableSource {
    let id = "plaud"
    let label = "Plaud"
    func fetch(apiKey: String, cursor: String?, since: Date) async throws -> WearableBatch {
        throw WearableError.notImplemented("Plaud")
    }
}

// MARK: - Ingest loop

/// Polls the enabled sources every ten minutes while online, keeps one cursor
/// per source, and hands each new recording to `onRecording` (the coordinator
/// runs the meeting pipeline on it). Ids already processed are remembered so
/// a cursor reset can't file the same lifelog twice. The API key lives in the
/// Keychain (`limitless-api-key`), never in defaults or the brain.
@MainActor
final class WearableIngest: ObservableObject {
    static let pollInterval: TimeInterval = 600
    static let limitlessKeyAccount = "limitless-api-key"
    private static let enabledKey = "limitlessEnabled"
    private static let cursorKey = "limitlessCursor"
    private static let sinceKey = "limitlessSince"
    private static let seenKey = "limitlessSeenIDs"

    @Published var limitlessEnabled: Bool {
        didSet {
            defaults.set(limitlessEnabled, forKey: Self.enabledKey)
            // Enabling starts the clock now: nothing older than this is pulled.
            if limitlessEnabled, defaults.object(forKey: Self.sinceKey) == nil {
                defaults.set(Date().timeIntervalSince1970, forKey: Self.sinceKey)
            }
            if limitlessEnabled { Task { await self.poll() } }
        }
    }
    @Published private(set) var hasLimitlessKey = false
    @Published private(set) var lastPoll: Date?
    @Published private(set) var lastStatus = ""
    @Published private(set) var polling = false

    /// Called once per new recording, oldest first. Async so the pipeline
    /// (extraction, triage) finishes before the cursor moves past it.
    var onRecording: ((WearableRecording) async -> Void)?
    var log: (String) -> Void = { _ in }

    let limitless: WearableSource
    let plaud: WearableSource = PlaudSource()
    private let defaults: UserDefaults
    private let keyProvider: () -> String?
    private var timer: Timer?

    /// `keyProvider` defaults to the Keychain item; tests inject a constant so
    /// they never touch the login keychain.
    init(defaults: UserDefaults = .standard, limitless: WearableSource = LimitlessSource(),
         keyProvider: (() -> String?)? = nil) {
        self.defaults = defaults
        self.limitless = limitless
        self.keyProvider = keyProvider ?? { KeychainStore.load(account: WearableIngest.limitlessKeyAccount) }
        limitlessEnabled = defaults.bool(forKey: Self.enabledKey)
        hasLimitlessKey = self.keyProvider() != nil
    }

    func setLimitlessKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainStore.save(trimmed, account: Self.limitlessKeyAccount)
        hasLimitlessKey = true
        lastStatus = "key saved"
    }

    func clearLimitlessKey() {
        KeychainStore.delete(account: Self.limitlessKeyAccount)
        hasLimitlessKey = false
        limitlessEnabled = false
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.poll() }
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if limitlessEnabled { Task { await poll() } }
    }

    /// One pass over Limitless: page through everything new, filing each
    /// recording before advancing the cursor. Soft-fails into `lastStatus`.
    func poll() async {
        guard limitlessEnabled, !polling else { return }
        guard let key = keyProvider() else {
            lastStatus = "Limitless: no API key"
            return
        }
        polling = true
        defer { polling = false }
        let since = Date(timeIntervalSince1970: defaults.double(forKey: Self.sinceKey))
        var cursor = defaults.string(forKey: Self.cursorKey)
        var filed = 0
        for _ in 0..<20 {   // ≤ 200 lifelogs per poll — a backlog drains over a few polls
            let batch: WearableBatch
            do {
                batch = try await limitless.fetch(apiKey: key, cursor: cursor, since: since)
            } catch {
                lastStatus = "Limitless: \(error)"
                log("limitless fetch failed: \(error)")
                lastPoll = Date()
                return
            }
            var seen = Set(defaults.stringArray(forKey: Self.seenKey) ?? [])
            for r in batch.recordings where !seen.contains(r.id) {
                await onRecording?(r)
                seen.insert(r.id)
                filed += 1
                defaults.set(Array(seen.suffix(400)), forKey: Self.seenKey)
            }
            if let next = batch.nextCursor, next != cursor {
                cursor = next
                defaults.set(next, forKey: Self.cursorKey)
            } else {
                break
            }
            if batch.recordings.isEmpty { break }
        }
        lastPoll = Date()
        lastStatus = filed == 0 ? "Limitless: up to date" : "Limitless: filed \(filed) recording\(filed == 1 ? "" : "s")"
        if filed > 0 { log("limitless: filed \(filed) new recording(s)") }
    }
}
