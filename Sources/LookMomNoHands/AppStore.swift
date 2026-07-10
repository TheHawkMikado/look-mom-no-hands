import Foundation
import Combine

/// One persisted transcript entry — either a one-shot command or a dictation report.
struct TranscriptRecord: Codable, Identifiable, Sendable {
    let id: String
    let date: Date
    let kind: String            // "command" | "dictation"
    let transcript: String      // raw ASR text
    var summary: String?        // dictation only
    var actionItems: [String]?  // dictation only
    var outcome: String?        // command: what was executed, or the error

    init(kind: String, transcript: String,
         summary: String? = nil, actionItems: [String]? = nil, outcome: String? = nil) {
        self.id = UUID().uuidString
        self.date = Date()
        self.kind = kind
        self.transcript = transcript
        self.summary = summary
        self.actionItems = actionItems
        self.outcome = outcome
    }
}

/// Disk-backed store: a JSONL copy of every transcript and a VoiceDash-style
/// activity log of everything the app does. Both live under
/// ~/Library/Application Support/LookMaNoHands/ and are also published for the UI.
@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var transcripts: [TranscriptRecord] = []   // newest first
    @Published private(set) var activity: [String] = []                // newest first (display)

    let directory: URL
    private let transcriptsURL: URL
    private let activityURL: URL
    private let io = DispatchQueue(label: "com.lookmomnohands.store.io")

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("LookMaNoHands", isDirectory: true)
        transcriptsURL = directory.appendingPathComponent("transcripts.jsonl")
        activityURL = directory.appendingPathComponent("activity.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadTranscripts()
        loadActivityTail()
    }

    // MARK: Transcripts

    func addTranscript(_ record: TranscriptRecord) {
        transcripts.insert(record, at: 0)
        io.async { [transcriptsURL, record] in
            guard let line = try? Self.encoder.encode(record) else { return }
            var data = line
            data.append(0x0A) // newline
            Self.append(data, to: transcriptsURL)
        }
    }

    private func loadTranscripts() {
        guard let text = try? String(contentsOf: transcriptsURL, encoding: .utf8) else { return }
        let decoded = text.split(separator: "\n").compactMap { line -> TranscriptRecord? in
            try? Self.decoder.decode(TranscriptRecord.self, from: Data(line.utf8))
        }
        transcripts = decoded.reversed() // file is oldest-first; show newest-first
    }

    // MARK: Activity log — "ISO8601: [subsystem] message"

    func log(_ subsystem: String, _ message: String) {
        let line = "\(iso.string(from: Date())): [\(subsystem)] \(message)"
        activity.insert(line, at: 0)
        if activity.count > 1000 { activity.removeLast() }
        io.async { [activityURL] in
            Self.append(Data((line + "\n").utf8), to: activityURL)
        }
    }

    private func loadActivityTail() {
        guard let text = try? String(contentsOf: activityURL, encoding: .utf8) else { return }
        activity = text.split(separator: "\n").suffix(1000).reversed().map(String.init)
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
