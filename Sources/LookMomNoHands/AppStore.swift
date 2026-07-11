import Foundation
import Combine

/// One persisted transcript entry — either a one-shot command or a dictation report.
struct TranscriptRecord: Codable, Identifiable, Sendable {
    let id: String
    let date: Date
    let kind: String            // "command" | "dictation"
    let transcript: String      // raw ASR text
    var title: String?          // dictation only
    var summary: String?        // dictation only
    var keyPoints: [String]?    // dictation only
    var actionItems: [String]?  // dictation only
    var outcome: String?        // command: what was executed, or the error

    init(kind: String, transcript: String,
         title: String? = nil, summary: String? = nil,
         keyPoints: [String]? = nil, actionItems: [String]? = nil, outcome: String? = nil) {
        self.id = UUID().uuidString
        self.date = Date()
        self.kind = kind
        self.transcript = transcript
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.actionItems = actionItems
        self.outcome = outcome
    }
}

/// One activity-log line with a stable identity, so SwiftUI list rows don't all
/// re-identify (and rebuild) every time a new line is inserted at the front.
struct ActivityEntry: Identifiable, Sendable {
    let id = UUID()
    let line: String
}

/// Disk-backed store: a JSONL copy of every transcript and a VoiceDash-style
/// activity log of everything the app does. Both live under
/// ~/Library/Application Support/LookMaNoHands/ and are also published for the UI.
@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var transcripts: [TranscriptRecord] = []   // newest first
    @Published private(set) var activity: [ActivityEntry] = []         // newest first (display)

    let directory: URL
    private let transcriptsURL: URL
    private let activityURL: URL
    private let io = DispatchQueue(label: AppIdentity.storeQueueLabel)

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// How many records/lines to keep in memory for the UI. The files on disk keep
    /// the full history; these caps just bound RAM as they grow without limit.
    private static let memoryCap = 1000

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent(AppIdentity.storageFolder, isDirectory: true)
        transcriptsURL = directory.appendingPathComponent("transcripts.jsonl")
        activityURL = directory.appendingPathComponent("activity.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadFromDisk()
    }

    /// Reads and decodes both files off the main thread (they grow unbounded), then
    /// publishes the most-recent slice on main.
    private func loadFromDisk() {
        let transcriptsURL = self.transcriptsURL
        let activityURL = self.activityURL
        let cap = Self.memoryCap
        io.async {
            var records: [TranscriptRecord] = []
            if let text = try? String(contentsOf: transcriptsURL, encoding: .utf8) {
                records = Array(text.split(separator: "\n").suffix(cap).compactMap {
                    try? Self.decoder.decode(TranscriptRecord.self, from: Data($0.utf8))
                }.reversed())
            }
            var entries: [ActivityEntry] = []
            if let text = try? String(contentsOf: activityURL, encoding: .utf8) {
                entries = text.split(separator: "\n").suffix(cap).reversed()
                    .map { ActivityEntry(line: String($0)) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Append, don't assign: anything logged/recorded while the read ran
                // (e.g. the launch log lines) is newer than the file snapshot and
                // already sits at the front.
                self.transcripts += records
                self.activity += entries
            }
        }
    }

    // MARK: Transcripts

    func addTranscript(_ record: TranscriptRecord) {
        transcripts.insert(record, at: 0)
        if transcripts.count > Self.memoryCap { transcripts.removeLast() }
        io.async { [transcriptsURL, record] in
            guard let line = try? Self.encoder.encode(record) else { return }
            var data = line
            data.append(0x0A) // newline
            Self.append(data, to: transcriptsURL)
        }
    }

    /// Persists a captured clip when transcription failed, so a spoken note is
    /// recoverable instead of silently lost. Returns the file URL.
    func saveAudio(_ data: Data) -> URL? {
        let url = directory.appendingPathComponent("note-\(UUID().uuidString).wav")
        do { try data.write(to: url); return url } catch { return nil }
    }

    // MARK: Activity log — "ISO8601: [subsystem] message"

    func log(_ subsystem: String, _ message: String) {
        let line = "\(iso.string(from: Date())): [\(subsystem)] \(message)"
        activity.insert(ActivityEntry(line: line), at: 0)
        if activity.count > Self.memoryCap { activity.removeLast() }
        io.async { [activityURL] in
            Self.append(Data((line + "\n").utf8), to: activityURL)
        }
    }

    // MARK: Files

    nonisolated private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    nonisolated private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    nonisolated private static func append(_ data: Data, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url) // file didn't exist yet
        }
    }
}
