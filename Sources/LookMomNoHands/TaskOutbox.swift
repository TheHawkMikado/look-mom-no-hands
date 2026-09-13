import Foundation
import Combine

/// One action item waiting to reach the web (SPEC.md Phase 6: offline
/// queueing). Holds exactly what the POST would carry — the item's text and
/// the one-time delivery hand-off — never the transcript it came from.
struct OutboxEntry: Codable, Equatable, Sendable {
    var id: String
    var text: String
    var source: String            // "meeting"
    var meeting: String           // meeting basename, for the receipt line
    var createdAt: Date
    var attempts: Int
    var deliverChannel: String?
    var deliverTo: String?
    var deliverName: String?

    init(id: String = UUID().uuidString, text: String, source: String = "meeting", meeting: String,
         createdAt: Date = Date(), attempts: Int = 0, deliver: TicketDelivery? = nil) {
        self.id = id
        self.text = text
        self.source = source
        self.meeting = meeting
        // Whole seconds: ISO-8601 on disk has no fraction, so an entry must
        // compare equal to itself after a reload.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.attempts = attempts
        self.deliverChannel = deliver?.channel
        self.deliverTo = deliver?.to
        self.deliverName = deliver?.name
    }

    var delivery: TicketDelivery? {
        guard let c = deliverChannel, let to = deliverTo, let n = deliverName, !to.isEmpty else { return nil }
        return TicketDelivery(channel: c, to: to, name: n)
    }
}

/// `brain/outbox.json`: action items the end-of-meeting triage could not hand
/// over because the web was unreachable. The coordinator retries every minute
/// until each one lands; an item is removed only after a 2xx, so a crash or
/// a quit between attempts never loses one. Small JSON file, rewritten whole.
@MainActor
final class TaskOutbox: ObservableObject {
    @Published private(set) var entries: [OutboxEntry] = []
    let fileURL: URL

    /// `brainDirectory` is the brain folder itself (`LocalBrain.directory`).
    init(brainDirectory: URL) {
        fileURL = brainDirectory.appendingPathComponent("outbox.json")
        if let data = try? Data(contentsOf: fileURL), let loaded = Self.decode(data) {
            entries = loaded
        }
    }

    var isEmpty: Bool { entries.isEmpty }

    func enqueue(_ entry: OutboxEntry) {
        entries.append(entry)
        persist()
    }

    /// Marks one more failed attempt (kept for the receipt line; nothing is
    /// ever dropped because of a count).
    func recordAttempt(id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].attempts += 1
        persist()
    }

    func remove(id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = Self.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Pure (tests)

    nonisolated static func encode(_ entries: [OutboxEntry]) -> Data? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(entries)
    }

    nonisolated static func decode(_ data: Data) -> [OutboxEntry]? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode([OutboxEntry].self, from: data)
    }
}
